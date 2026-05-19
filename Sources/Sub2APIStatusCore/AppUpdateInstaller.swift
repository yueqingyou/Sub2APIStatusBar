import Foundation

public struct PreparedAppUpdate: Sendable {
    public let archiveURL: URL
    public let extractionDirectoryURL: URL
    public let appURL: URL

    public init(archiveURL: URL, extractionDirectoryURL: URL, appURL: URL) {
        self.archiveURL = archiveURL
        self.extractionDirectoryURL = extractionDirectoryURL
        self.appURL = appURL
    }
}

public enum AppUpdateInstallerError: Error, Equatable, LocalizedError, Sendable {
    case missingInstallArchiveAsset
    case downloadFailed(Int)
    case extractionFailed(Int32)
    case extractedAppNotFound
    case invalidAppBundle(URL)
    case missingBundleIdentifier
    case unexpectedBundleIdentifier(String?)
    case missingVersion
    case versionMismatch(found: AppVersion, expected: AppVersion)
    case targetIsNotAppBundle(URL)
    case helperLaunchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingInstallArchiveAsset:
            return "This release does not include a downloadable macOS app archive."
        case let .downloadFailed(status):
            return "Update download failed with HTTP \(status)."
        case let .extractionFailed(status):
            return "Update archive extraction failed with status \(status)."
        case .extractedAppNotFound:
            return "The downloaded update did not contain Sub2APIStatusBar.app."
        case let .invalidAppBundle(url):
            return "The downloaded update is not a valid app bundle: \(url.path)."
        case .missingBundleIdentifier:
            return "The downloaded update is missing a bundle identifier."
        case let .unexpectedBundleIdentifier(identifier):
            return "The downloaded update has an unexpected bundle identifier: \(identifier ?? "missing")."
        case .missingVersion:
            return "The downloaded update is missing a version."
        case let .versionMismatch(found, expected):
            return "The downloaded update version is \(found), expected \(expected)."
        case let .targetIsNotAppBundle(url):
            return "The current app path is not an app bundle: \(url.path)."
        case let .helperLaunchFailed(message):
            return "Could not start the update installer: \(message)."
        }
    }
}

public struct AppUpdateInstaller {
    public let session: URLSession
    public let fileManager: FileManager

    public init(session: URLSession = .shared, fileManager: FileManager = .default) {
        self.session = session
        self.fileManager = fileManager
    }

    public func downloadAndExtract(
        release: GitHubRelease,
        expectedBundleIdentifier: String = AppBuildInfo.bundleIdentifier,
        appName: String = "\(AppBuildInfo.repositoryName).app"
    ) async throws -> PreparedAppUpdate {
        guard let asset = release.installArchiveAsset() else {
            throw AppUpdateInstallerError.missingInstallArchiveAsset
        }

        let workspaceURL = fileManager.temporaryDirectory
            .appendingPathComponent("Sub2APIStatusBar-update-\(UUID().uuidString)", isDirectory: true)
        let extractionURL = workspaceURL.appendingPathComponent("extracted", isDirectory: true)
        try fileManager.createDirectory(at: extractionURL, withIntermediateDirectories: true)

        var request = URLRequest(url: asset.downloadURL)
        request.timeoutInterval = 120
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("Sub2APIStatusBar", forHTTPHeaderField: "User-Agent")

        let (temporaryArchiveURL, response) = try await session.download(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AppUpdateInstallerError.downloadFailed(http.statusCode)
        }

        let archiveURL = workspaceURL.appendingPathComponent(asset.name)
        if fileManager.fileExists(atPath: archiveURL.path) {
            try fileManager.removeItem(at: archiveURL)
        }
        try fileManager.moveItem(at: temporaryArchiveURL, to: archiveURL)

        let appURL = try extractApp(from: archiveURL, to: extractionURL, appName: appName)
        try validateExtractedApp(
            at: appURL,
            expectedVersion: release.version,
            bundleIdentifier: expectedBundleIdentifier
        )
        return PreparedAppUpdate(archiveURL: archiveURL, extractionDirectoryURL: extractionURL, appURL: appURL)
    }

    public func extractApp(from archiveURL: URL, to destinationURL: URL, appName: String = "\(AppBuildInfo.repositoryName).app") throws -> URL {
        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archiveURL.path, destinationURL.path]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw AppUpdateInstallerError.extractionFailed(process.terminationStatus)
        }

        let directAppURL = destinationURL.appendingPathComponent(appName, isDirectory: true)
        if fileManager.fileExists(atPath: directAppURL.path) {
            return directAppURL
        }

        if let nestedAppURL = findAppBundle(named: appName, under: destinationURL) {
            return nestedAppURL
        }

        throw AppUpdateInstallerError.extractedAppNotFound
    }

    public func validateExtractedApp(
        at appURL: URL,
        expectedVersion: AppVersion,
        bundleIdentifier: String
    ) throws {
        guard appURL.pathExtension == "app", let bundle = Bundle(url: appURL) else {
            throw AppUpdateInstallerError.invalidAppBundle(appURL)
        }

        guard let actualIdentifier = bundle.object(forInfoDictionaryKey: "CFBundleIdentifier") as? String else {
            throw AppUpdateInstallerError.missingBundleIdentifier
        }
        guard actualIdentifier == bundleIdentifier else {
            throw AppUpdateInstallerError.unexpectedBundleIdentifier(actualIdentifier)
        }

        guard let versionString = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            throw AppUpdateInstallerError.missingVersion
        }
        let actualVersion = AppVersion(versionString)
        guard actualVersion == expectedVersion else {
            throw AppUpdateInstallerError.versionMismatch(found: actualVersion, expected: expectedVersion)
        }
    }

    public func startInstall(extractedAppURL: URL, targetAppURL: URL, currentProcessID: Int32) throws {
        guard targetAppURL.pathExtension == "app" else {
            throw AppUpdateInstallerError.targetIsNotAppBundle(targetAppURL)
        }

        let scriptURL = try writeInstallScript(
            sourceAppURL: extractedAppURL,
            targetAppURL: targetAppURL,
            currentProcessID: currentProcessID
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path]
        do {
            try process.run()
        } catch {
            throw AppUpdateInstallerError.helperLaunchFailed(error.localizedDescription)
        }
    }

    public func writeInstallScript(sourceAppURL: URL, targetAppURL: URL, currentProcessID: Int32) throws -> URL {
        let script = installScript(sourceAppURL: sourceAppURL, targetAppURL: targetAppURL, currentProcessID: currentProcessID)
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("Sub2APIStatusBar-installer-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let scriptURL = directoryURL.appendingPathComponent("install-update.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    public func installScript(
        sourceAppURL: URL,
        targetAppURL: URL,
        currentProcessID: Int32,
        appExitWaitIterations: Int = 20
    ) -> String {
        """
        #!/bin/sh
        set -u

        SOURCE_APP=\(shellQuote(sourceAppURL.path))
        TARGET_APP=\(shellQuote(targetAppURL.path))
        APP_PID='\(currentProcessID)'
        BACKUP_APP="${TARGET_APP}.updater-backup"
        LOG_FILE="${TMPDIR:-/tmp}/Sub2APIStatusBar-update-install.log"

        log() {
          /bin/echo "$(/bin/date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE" 2>/dev/null || true
        }

        wait_for_app_exit() {
          WAIT_LIMIT="$1"
          WAIT_COUNT=0
          while /bin/kill -0 "$APP_PID" 2>/dev/null && [ "$WAIT_COUNT" -lt "$WAIT_LIMIT" ]; do
            WAIT_COUNT=$((WAIT_COUNT + 1))
            /bin/sleep 0.5
          done

          ! /bin/kill -0 "$APP_PID" 2>/dev/null
        }

        log "Installer started for $TARGET_APP from $SOURCE_APP"

        if ! wait_for_app_exit \(appExitWaitIterations); then
          log "App PID $APP_PID is still running; sending TERM"
          /bin/kill -TERM "$APP_PID" 2>/dev/null || true
        fi

        if ! wait_for_app_exit \(appExitWaitIterations); then
          log "App PID $APP_PID is still running; sending KILL"
          /bin/kill -KILL "$APP_PID" 2>/dev/null || true
        fi

        if ! wait_for_app_exit \(appExitWaitIterations); then
          log "App PID $APP_PID did not exit; aborting install"
          exit 1
        fi

        /bin/rm -rf "$BACKUP_APP" >> "$LOG_FILE" 2>&1 || true
        if [ -d "$TARGET_APP" ]; then
          /bin/mv "$TARGET_APP" "$BACKUP_APP" >> "$LOG_FILE" 2>&1 || {
            log "Failed to move $TARGET_APP to backup"
            exit 1
          }
        fi

        if /usr/bin/ditto "$SOURCE_APP" "$TARGET_APP" >> "$LOG_FILE" 2>&1; then
          /usr/bin/xattr -cr "$TARGET_APP" 2>/dev/null || true
          /bin/rm -rf "$BACKUP_APP" >> "$LOG_FILE" 2>&1 || true
          log "Installed update; opening $TARGET_APP"
          /usr/bin/open "$TARGET_APP" >> "$LOG_FILE" 2>&1 || true
          exit 0
        fi

        log "Failed to copy update; restoring backup"
        /bin/rm -rf "$TARGET_APP" >> "$LOG_FILE" 2>&1 || true
        if [ -d "$BACKUP_APP" ]; then
          /bin/mv "$BACKUP_APP" "$TARGET_APP" 2>/dev/null || true
          /usr/bin/open "$TARGET_APP" 2>/dev/null || true
        fi
        exit 1
        """
    }

    private func findAppBundle(named appName: String, under directoryURL: URL) -> URL? {
        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for case let url as URL in enumerator where url.lastPathComponent == appName {
            return url
        }
        return nil
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }
}
