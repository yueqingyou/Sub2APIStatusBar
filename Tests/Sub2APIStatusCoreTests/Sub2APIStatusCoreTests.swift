import Foundation
import XCTest
@testable import Sub2APIStatusCore

final class MemoryTokenStore: TokenStore, @unchecked Sendable {
    var tokens = StoredAuthTokens()
    var saves: [StoredAuthTokens] = []

    func loadTokens() -> StoredAuthTokens {
        tokens
    }

    func saveTokens(_ tokens: StoredAuthTokens) throws {
        self.tokens = tokens
        saves.append(tokens)
    }
}

final class StaticTokenStore: TokenStore, @unchecked Sendable {
    var tokens: StoredAuthTokens

    init(tokens: StoredAuthTokens) {
        self.tokens = tokens
    }

    func loadTokens() -> StoredAuthTokens {
        tokens
    }

    func saveTokens(_ tokens: StoredAuthTokens) throws {
        self.tokens = tokens
    }
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    static var responses: [String: Data] = [:]
    static var responseQueues: [String: [(status: Int, data: Data)]] = [:]
    static var requestedPaths: [String] = []

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: Sub2APIError.invalidBaseURL)
            return
        }

        let key = url.path + (url.query.map { "?\($0)" } ?? "")
        Self.requestedPaths.append(key)
        let queuedResponse: (status: Int, data: Data)?
        if var queue = Self.responseQueues[key], !queue.isEmpty {
            queuedResponse = queue.removeFirst()
            Self.responseQueues[key] = queue
        } else {
            queuedResponse = nil
        }
        let data = queuedResponse?.data ?? Self.responses[key] ?? Data(#"{"code":404,"message":"not found"}"#.utf8)
        let status = queuedResponse?.status ?? (Self.responses[key] == nil ? 404 : 200)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class Sub2APIStatusCoreTests: XCTestCase {

override func setUp() {
    super.setUp()
    StubURLProtocol.responses = [:]
    StubURLProtocol.responseQueues = [:]
    StubURLProtocol.requestedPaths = []
}

func testAppConfigNormalizesBaseURLAndRefreshInterval() {
    var config = AppConfig(baseURL: " http://127.0.0.1:8080/api/v1/// ", authToken: " token ", refreshIntervalSeconds: 1, language: .zhHans, monitorMode: .user)

    config.normalize()

    XCTAssert(config.baseURL == "http://127.0.0.1:8080")
    XCTAssert(config.authToken == "token")
    XCTAssert(config.refreshIntervalSeconds == 1)
    XCTAssert(config.monitorMode == .user)
    XCTAssert(config.showsMenuBarText == false)
    XCTAssert(config.launchAtLogin == false)
}

func testAppConfigDefaultsMenuBarWindowAndItems() {
    let config = AppConfig(baseURL: "http://127.0.0.1:8080")

    XCTAssert(config.menuBarUsageWindow == .last24Hours)
    XCTAssert(config.menuBarDisplayItems == [
        .totalCost,
        .model,
        .reasoningEffort,
        .contextLength,
        .fast,
        .rpm,
    ])
}

func testAppConfigDefaultsToChineseLanguage() {
    let config = AppConfig(baseURL: "http://127.0.0.1:8080")

    XCTAssert(config.language == .zhHans)
}

func testAppConfigDefaultsToSystemAppearance() {
    let config = AppConfig(baseURL: "http://127.0.0.1:8080")

    XCTAssert(config.appearance == .system)
}

func testAppLanguageFallsBackToChineseWhenEnvironmentIsMissingOrUnknown() {
    XCTAssert(AppLanguage.fromEnvironment(nil) == .zhHans)
    XCTAssert(AppLanguage.fromEnvironment("") == .zhHans)
    XCTAssert(AppLanguage.fromEnvironment("auto") == .zhHans)
    XCTAssert(AppLanguage.fromEnvironment("english") == .en)
}

func testAppAppearanceFallsBackToSystemWhenEnvironmentIsMissingOrUnknown() {
    XCTAssert(AppAppearance.fromEnvironment(nil) == .system)
    XCTAssert(AppAppearance.fromEnvironment("") == .system)
    XCTAssert(AppAppearance.fromEnvironment("auto") == .system)
    XCTAssert(AppAppearance.fromEnvironment("system") == .system)
    XCTAssert(AppAppearance.fromEnvironment("light") == .light)
    XCTAssert(AppAppearance.fromEnvironment("dark-aqua") == .dark)
    XCTAssert(AppAppearance.fromEnvironment("unknown") == .system)
}

func testLegacyAutoLanguageNormalizesToChinese() throws {
    let data = """
    {
      "baseURL": "http://127.0.0.1:8080",
      "language": "auto"
    }
    """.data(using: .utf8)!

    let config = try JSONDecoder.sub2api.decode(AppConfig.self, from: data)

    XCTAssert(config.language == .zhHans)
}

func testLegacyConfigWithoutAppearanceDefaultsToSystem() throws {
    let data = """
    {
      "baseURL": "http://127.0.0.1:8080",
      "language": "zhHans"
    }
    """.data(using: .utf8)!

    let config = try JSONDecoder.sub2api.decode(AppConfig.self, from: data)

    XCTAssert(config.appearance == .system)
}

func testAppConfigPersistsMenuBarTextPreference() throws {
    let configURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("config.json")
    let store = ConfigStore(configURL: configURL, tokenStore: MemoryTokenStore())
    let config = AppConfig(baseURL: "http://127.0.0.1:8080", showsMenuBarText: true)

    try store.save(config)
    let loaded = store.load()

    XCTAssert(loaded.baseURL == "http://127.0.0.1:8080")
    XCTAssert(loaded.showsMenuBarText == true)
}

func testAppConfigPersistsMenuBarDetailPreferences() throws {
    let configURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("config.json")
    let store = ConfigStore(configURL: configURL, tokenStore: MemoryTokenStore())
    let config = AppConfig(
        baseURL: "http://127.0.0.1:8080",
        showsMenuBarText: true,
        menuBarUsageWindow: .today,
        menuBarDisplayItems: [.totalRequests, .inputPrice, .outputPrice]
    )

    try store.save(config)
    let loaded = store.load()

    XCTAssert(loaded.menuBarUsageWindow == .today)
    XCTAssert(loaded.menuBarDisplayItems == [.totalRequests, .inputPrice, .outputPrice])
}

func testAppConfigPersistsAppearancePreference() throws {
    let configURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("config.json")
    let store = ConfigStore(configURL: configURL, tokenStore: MemoryTokenStore())
    let config = AppConfig(baseURL: "http://127.0.0.1:8080", appearance: .dark)

    try store.save(config)
    let loaded = store.load()

    XCTAssert(loaded.appearance == .dark)
}

func testAppConfigPersistsLaunchAtLoginPreference() throws {
    let configURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("config.json")
    let store = ConfigStore(configURL: configURL, tokenStore: MemoryTokenStore())
    let config = AppConfig(baseURL: "http://127.0.0.1:8080", launchAtLogin: true)

    try store.save(config)
    let loaded = store.load()

    XCTAssert(loaded.launchAtLogin == true)
}

func testLaunchAtLoginManagerWritesAndRemovesUserLaunchAgent() throws {
    let launchAgentsURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("LaunchAgents", isDirectory: true)
    let appURL = URL(fileURLWithPath: "/Applications/Sub2APIStatusBar.app", isDirectory: true)
    let manager = LaunchAtLoginManager(
        appBundleURL: appURL,
        launchAgentsDirectory: launchAgentsURL,
        label: "com.example.sub2api-statusbar.login"
    )

    try manager.setEnabled(true)

    let plist = try manager.loadLaunchAgentPlist()
    XCTAssert(plist["Label"] as? String == "com.example.sub2api-statusbar.login")
    XCTAssert(plist["ProgramArguments"] as? [String] == ["/usr/bin/open", appURL.path])
    XCTAssert(plist["RunAtLoad"] as? Bool == true)
    XCTAssert(manager.isEnabled == true)

    try manager.setEnabled(false)

    XCTAssert(FileManager.default.fileExists(atPath: manager.plistURL.path) == false)
    XCTAssert(manager.isEnabled == false)
}

func testLaunchAtLoginManagerTreatsStaleAppPathAsDisabled() throws {
    let launchAgentsURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("LaunchAgents", isDirectory: true)
    let manager = LaunchAtLoginManager(
        appBundleURL: URL(fileURLWithPath: "/Applications/Sub2APIStatusBar.app", isDirectory: true),
        launchAgentsDirectory: launchAgentsURL,
        label: "com.example.sub2api-statusbar.login"
    )
    let staleManager = LaunchAtLoginManager(
        appBundleURL: URL(fileURLWithPath: "/Users/me/Downloads/Sub2APIStatusBar.app", isDirectory: true),
        launchAgentsDirectory: launchAgentsURL,
        label: "com.example.sub2api-statusbar.login"
    )

    try staleManager.setEnabled(true)

    XCTAssert(manager.isEnabled == false)
}

func testConfigStoreSavesTokensOutsideConfigJSON() throws {
    let configURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("config.json")
    let tokenStore = MemoryTokenStore()
    let store = ConfigStore(configURL: configURL, tokenStore: tokenStore)
    let config = AppConfig(
        baseURL: "http://127.0.0.1:8080",
        authToken: "access-token",
        refreshToken: "refresh-token",
        showsMenuBarText: true
    )

    try store.save(config)

    let rawJSON = try String(contentsOf: configURL, encoding: .utf8)
    XCTAssert(!rawJSON.contains("access-token"))
    XCTAssert(!rawJSON.contains("refresh-token"))
    XCTAssert(!rawJSON.contains("authToken"))
    XCTAssert(!rawJSON.contains("refreshToken"))
    XCTAssert(tokenStore.tokens.authToken == "access-token")
    XCTAssert(tokenStore.tokens.refreshToken == "refresh-token")
    XCTAssert(store.load().authToken == "access-token")
}

func testConfigStoreMigratesLegacyJSONTokensOutOfConfigFile() throws {
    let configURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("config.json")
    try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try """
    {
      "baseURL" : "http://127.0.0.1:8080",
      "authToken" : "legacy-access",
      "refreshToken" : "legacy-refresh",
      "refreshIntervalSeconds" : 15,
      "language" : "auto",
      "monitorMode" : "user",
      "showsMenuBarText" : true
    }
    """.write(to: configURL, atomically: true, encoding: .utf8)
    let tokenStore = MemoryTokenStore()
    let store = ConfigStore(configURL: configURL, tokenStore: tokenStore)

    let loaded = store.load()

    XCTAssert(loaded.authToken == "legacy-access")
    XCTAssert(loaded.refreshToken == "legacy-refresh")
    XCTAssert(tokenStore.tokens.authToken == "legacy-access")
    XCTAssert(tokenStore.tokens.refreshToken == "legacy-refresh")

    let migratedJSON = try String(contentsOf: configURL, encoding: .utf8)
    XCTAssert(!migratedJSON.contains("legacy-access"))
    XCTAssert(!migratedJSON.contains("legacy-refresh"))
    XCTAssert(!migratedJSON.contains("authToken"))
    XCTAssert(!migratedJSON.contains("refreshToken"))
}

func testStoredAuthTokensEncodeAsSingleCredentialsPayload() throws {
    let tokens = StoredAuthTokens(authToken: "access", refreshToken: "refresh")

    let data = try JSONEncoder.sub2api.encode(tokens)
    let rawJSON = try XCTUnwrap(String(data: data, encoding: .utf8))
    let decoded = try JSONDecoder.sub2api.decode(StoredAuthTokens.self, from: data)

    XCTAssert(rawJSON.contains("auth_token"))
    XCTAssert(rawJSON.contains("refresh_token"))
    XCTAssert(decoded == tokens)
}

func testLocalCredentialsTokenStorePersistsTokensInPrivateFile() throws {
    let credentialsURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("credentials.json")
    let store = LocalCredentialsTokenStore(credentialsURL: credentialsURL)
    let tokens = StoredAuthTokens(authToken: "access-token", refreshToken: "refresh-token")

    try store.saveTokens(tokens)
    let loaded = store.loadTokens()
    let attributes = try FileManager.default.attributesOfItem(atPath: credentialsURL.path)
    let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)

    XCTAssertEqual(loaded, tokens)
    XCTAssertEqual(permissions.intValue & 0o777, 0o600)
}

func testLocalCredentialsTokenStorePersistsEmptyCredentialsToPreventLegacyRemigration() throws {
    let credentialsURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("credentials.json")
    let legacyStore = StaticTokenStore(tokens: StoredAuthTokens(authToken: "legacy-access", refreshToken: "legacy-refresh"))
    let store = LocalCredentialsTokenStore(credentialsURL: credentialsURL, legacyTokenStore: legacyStore)

    try store.saveTokens(StoredAuthTokens(authToken: "access-token", refreshToken: "refresh-token"))
    try store.saveTokens(StoredAuthTokens())

    XCTAssertEqual(store.loadTokens(), StoredAuthTokens())
    XCTAssertTrue(FileManager.default.fileExists(atPath: credentialsURL.path))
}

func testAppConfigDefaultsToUserMode() {
    let config = AppConfig(baseURL: "http://127.0.0.1:8080")

    XCTAssert(config.monitorMode == .user)
}

func testAppConfigRejectsUnknownMonitorMode() {
    let data = """
    {
      "baseURL": "http://127.0.0.1:8080",
      "monitorMode": "operator"
    }
    """.data(using: .utf8)!

    XCTAssertThrowsError(try JSONDecoder.sub2api.decode(AppConfig.self, from: data))
}

func testUserModeNormalizationRemovesAdminOnlyMenuItems() {
    let config = AppConfig(
        baseURL: "http://127.0.0.1:8080",
        monitorMode: .user,
        menuBarDisplayItems: [.totalCost, .realtimeConcurrency, .normalAccounts],
        adminMonitoredUserID: 42
    )

    XCTAssert(config.adminMonitoredUserID == nil)
    XCTAssert(config.menuBarDisplayItems == [.totalCost])
}

func testAppConfigSupportsAdminModeAndSelectedUser() throws {
    let data = """
    {
      "baseURL": "http://127.0.0.1:8080",
      "monitorMode": "admin",
      "adminMonitoredUserID": 42,
      "menuBarDisplayItems": ["totalCost", "realtimeConcurrency"]
    }
    """.data(using: .utf8)!

    let config = try JSONDecoder.sub2api.decode(AppConfig.self, from: data)

    XCTAssert(config.monitorMode == .admin)
    XCTAssert(config.adminMonitoredUserID == 42)
    XCTAssert(config.menuBarDisplayItems == [.totalCost, .realtimeConcurrency])
}

func testMenuBarDisplayItemsExposeAdminOnlyConcurrencySeparately() {
    XCTAssert(MenuBarDisplayItem.defaultSelection.contains(.realtimeConcurrency) == false)
    XCTAssert(MenuBarDisplayItem.userVisibleCases.contains(.realtimeConcurrency) == false)
    XCTAssert(MenuBarDisplayItem.adminVisibleCases.contains(.realtimeConcurrency) == true)
    XCTAssert(MenuBarDisplayItem.defaultSelection.contains(.normalAccounts) == false)
    XCTAssert(MenuBarDisplayItem.userVisibleCases.contains(.normalAccounts) == false)
    XCTAssert(MenuBarDisplayItem.adminVisibleCases.contains(.normalAccounts) == true)
    XCTAssert(MenuBarDisplayItem.adminVisibleCases.contains(.rpm) == false)
}

func testMenuBarSummaryIncludesRealtimeConcurrencyWhenAdminSelectsIt() {
    let config = AppConfig(
        baseURL: "http://127.0.0.1:8080",
        monitorMode: .admin,
        menuBarDisplayItems: [.realtimeConcurrency]
    )
    let snapshot = MonitorSnapshot(
        mode: .admin,
        connected: true,
        stats: nil,
        realtime: nil,
        realtimeConcurrency: UserRealtimeConcurrency(
            userID: 42,
            userEmail: "target@example.com",
            username: "target",
            currentInUse: 3,
            maxCapacity: 100,
            loadPercentage: 3,
            waitingInQueue: 0
        ),
        accountHealth: nil,
        subscriptionSummary: nil,
        lastUpdatedAt: nil,
        message: nil
    )

    XCTAssert(snapshot.menuBarSummary(config: config) == "3 CC")
}

func testMenuBarSummaryIncludesNormalAccountsWhenAdminSelectsIt() {
    let config = AppConfig(
        baseURL: "http://127.0.0.1:8080",
        monitorMode: .admin,
        menuBarDisplayItems: [.normalAccounts]
    )
    let snapshot = MonitorSnapshot(
        mode: .admin,
        connected: true,
        stats: nil,
        realtime: nil,
        adminNormalAccountCount: 4,
        accountHealth: nil,
        subscriptionSummary: nil,
        lastUpdatedAt: nil,
        message: nil
    )

    XCTAssert(snapshot.menuBarSummary(config: config) == "4 normal")
}

func testAppConfigClearsAuthTokens() {
    var config = AppConfig(baseURL: "http://127.0.0.1:8080", authToken: "access", refreshToken: "refresh")

    config.clearAuthTokens()

    XCTAssert(config.authToken.isEmpty)
    XCTAssert(config.refreshToken.isEmpty)
}

func testApiEnvelopeDecodesWrappedData() throws {
    let json = """
    {
      "code": 0,
      "message": "ok",
      "data": {
        "active_requests": 2,
        "requests_per_minute": 13.5,
        "average_response_time": 840,
        "error_rate": 0.025
      }
    }
    """.data(using: .utf8)!

    let metrics = try JSONDecoder.sub2api.decode(Sub2APIEnvelope<RealtimeMetrics>.self, from: json).value()

    XCTAssert(metrics.activeRequests == 2)
    XCTAssert(metrics.requestsPerMinute == 13.5)
    XCTAssert(metrics.averageResponseTime == 840)
    XCTAssert(metrics.errorRate == 0.025)
}

func testSub2APIErrorIdentifiesUnauthorizedResponses() {
    XCTAssert(Sub2APIError.badStatus(401, "expired").isUnauthorized == true)
    XCTAssert(Sub2APIError.badStatus(403, "forbidden").isUnauthorized == false)
    XCTAssert(Sub2APIError.invalidBaseURL.isUnauthorized == false)
}

func testAppVersionComparesSemanticVersions() {
    XCTAssert(AppVersion("v0.1.10") > AppVersion("0.1.2"))
    XCTAssert(AppVersion("1.0") == AppVersion("1.0.0"))
    XCTAssert(AppVersion("v2.0.0-beta") > AppVersion("1.9.9"))
}

func testGithubReleaseDecodesLatestReleasePayload() throws {
    let json = """
    {
      "tag_name": "v0.1.3",
      "name": "Sub2API Status Bar v0.1.3",
      "html_url": "https://github.com/yueqingyou/Sub2APIStatusBar/releases/tag/v0.1.3",
      "draft": false,
      "prerelease": false,
      "assets": [
        {
          "name": "Sub2APIStatusBar-0.1.3-macOS.zip.sha256",
          "browser_download_url": "https://github.com/yueqingyou/Sub2APIStatusBar/releases/download/v0.1.3/Sub2APIStatusBar-0.1.3-macOS.zip.sha256",
          "content_type": "text/plain",
          "size": 96
        },
        {
          "name": "Sub2APIStatusBar-0.1.3-macOS.zip",
          "browser_download_url": "https://github.com/yueqingyou/Sub2APIStatusBar/releases/download/v0.1.3/Sub2APIStatusBar-0.1.3-macOS.zip",
          "content_type": "application/zip",
          "size": 4096
        }
      ]
    }
    """.data(using: .utf8)!

    let release = try JSONDecoder().decode(GitHubRelease.self, from: json)
    let asset = release.installArchiveAsset(repositoryName: "Sub2APIStatusBar")

    XCTAssert(release.tagName == "v0.1.3")
    XCTAssert(release.version == AppVersion("0.1.3"))
    XCTAssert(release.releaseURL.absoluteString.hasSuffix("/v0.1.3"))
    XCTAssert(release.assets.count == 2)
    XCTAssert(asset?.name == "Sub2APIStatusBar-0.1.3-macOS.zip")
    XCTAssert(asset?.downloadURL.absoluteString.hasSuffix("/Sub2APIStatusBar-0.1.3-macOS.zip") == true)
}

func testDefaultUpdateCheckerUsesPublishedRepository() {
    let checker = GitHubUpdateChecker()

    XCTAssert(checker.owner == "yueqingyou")
    XCTAssert(checker.repository == "Sub2APIStatusBar")
}

func testUpdateInfoDetectsAvailableRelease() {
    let release = GitHubRelease(
        tagName: "v0.1.3",
        name: "Sub2API Status Bar v0.1.3",
        releaseURL: URL(string: "https://github.com/yueqingyou/Sub2APIStatusBar/releases/tag/v0.1.3")!,
        draft: false,
        prerelease: false
    )

    let available = UpdateInfo(currentVersion: AppVersion("0.1.2"), release: release)
    let current = UpdateInfo(currentVersion: AppVersion("0.1.3"), release: release)

    XCTAssert(available.isUpdateAvailable == true)
    XCTAssert(available.statusText == "Version 0.1.3 is available.")
    XCTAssert(current.isUpdateAvailable == false)
    XCTAssert(current.statusText == "You are up to date.")
}

func testGitHubReleaseSelectsMacOSZipAssetOverOtherAssets() {
    let checksum = GitHubReleaseAsset(
        name: "Sub2APIStatusBar-0.1.9-macOS.zip.sha256",
        downloadURL: URL(string: "https://example.com/Sub2APIStatusBar-0.1.9-macOS.zip.sha256")!,
        contentType: "text/plain",
        size: 96
    )
    let symbols = GitHubReleaseAsset(
        name: "Sub2APIStatusBar-0.1.9-symbols.zip",
        downloadURL: URL(string: "https://example.com/Sub2APIStatusBar-0.1.9-symbols.zip")!,
        contentType: "application/zip",
        size: 2048
    )
    let app = GitHubReleaseAsset(
        name: "Sub2APIStatusBar-0.1.9-macOS.zip",
        downloadURL: URL(string: "https://example.com/Sub2APIStatusBar-0.1.9-macOS.zip")!,
        contentType: "application/zip",
        size: 4096
    )
    let release = GitHubRelease(
        tagName: "v0.1.9",
        name: "Sub2API Status Bar v0.1.9",
        releaseURL: URL(string: "https://github.com/yueqingyou/Sub2APIStatusBar/releases/tag/v0.1.9")!,
        draft: false,
        prerelease: false,
        assets: [checksum, symbols, app]
    )

    XCTAssert(release.installArchiveAsset(repositoryName: "Sub2APIStatusBar") == app)
}

func testAppUpdateInstallerValidatesExtractedAppBundleMetadata() throws {
    let appURL = try makeTemporaryAppBundle(bundleIdentifier: "com.geekywizkid.sub2api-statusbar", version: "0.1.9")
    let installer = AppUpdateInstaller()

    XCTAssertNoThrow(try installer.validateExtractedApp(
        at: appURL,
        expectedVersion: AppVersion("0.1.9"),
        bundleIdentifier: "com.geekywizkid.sub2api-statusbar"
    ))
}

func testAppUpdateInstallerRejectsUnexpectedBundleIdentifier() throws {
    let appURL = try makeTemporaryAppBundle(bundleIdentifier: "com.example.other", version: "0.1.9")
    let installer = AppUpdateInstaller()

    XCTAssertThrowsError(try installer.validateExtractedApp(
        at: appURL,
        expectedVersion: AppVersion("0.1.9"),
        bundleIdentifier: "com.geekywizkid.sub2api-statusbar"
    )) { error in
        if case AppUpdateInstallerError.unexpectedBundleIdentifier = error {
            return
        }
        XCTFail("Expected unexpectedBundleIdentifier, got \\(error)")
    }
}

func testAppUpdateInstallerBuildsSelfReplacementScript() {
    let installer = AppUpdateInstaller()
    let script = installer.installScript(
        sourceAppURL: URL(fileURLWithPath: "/tmp/Sub2API's Status Bar.app"),
        targetAppURL: URL(fileURLWithPath: "/Applications/Sub2APIStatusBar.app"),
        currentProcessID: 1234
    )

    XCTAssert(script.contains("SOURCE_APP='/tmp/Sub2API'\"'\"'s Status Bar.app'"))
    XCTAssert(script.contains("TARGET_APP='/Applications/Sub2APIStatusBar.app'"))
    XCTAssert(script.contains("while /bin/kill -0 \"$APP_PID\""))
    XCTAssert(script.contains("/bin/kill -TERM \"$APP_PID\""))
    XCTAssert(script.contains("/bin/kill -KILL \"$APP_PID\""))
    XCTAssert(script.contains("/usr/bin/ditto \"$SOURCE_APP\" \"$TARGET_APP\""))
    XCTAssert(script.contains("/usr/bin/open \"$TARGET_APP\""))
    XCTAssert(script.contains("Sub2APIStatusBar-update-install.log"))
}

func testAppUpdateInstallerScriptTerminatesStuckProcessAndReplacesTarget() throws {
    let fileManager = FileManager.default
    let rootURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let sourceAppURL = rootURL.appendingPathComponent("Source.app", isDirectory: true)
    let targetAppURL = rootURL.appendingPathComponent("Target.app", isDirectory: true)
    try fileManager.createDirectory(at: sourceAppURL, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: targetAppURL, withIntermediateDirectories: true)
    try "new".write(to: sourceAppURL.appendingPathComponent("version.txt"), atomically: true, encoding: .utf8)
    try "old".write(to: targetAppURL.appendingPathComponent("version.txt"), atomically: true, encoding: .utf8)

    let stuckProcess = Process()
    stuckProcess.executableURL = URL(fileURLWithPath: "/bin/sleep")
    stuckProcess.arguments = ["30"]
    try stuckProcess.run()
    defer {
        if stuckProcess.isRunning {
            stuckProcess.terminate()
        }
    }

    let script = AppUpdateInstaller().installScript(
        sourceAppURL: sourceAppURL,
        targetAppURL: targetAppURL,
        currentProcessID: stuckProcess.processIdentifier,
        appExitWaitIterations: 1
    )
    let scriptURL = rootURL.appendingPathComponent("install-update.sh")
    try script.write(to: scriptURL, atomically: true, encoding: .utf8)

    let installerProcess = Process()
    installerProcess.executableURL = URL(fileURLWithPath: "/bin/sh")
    installerProcess.arguments = [scriptURL.path]
    var environment = ProcessInfo.processInfo.environment
    environment["TMPDIR"] = rootURL.path
    installerProcess.environment = environment
    try installerProcess.run()
    installerProcess.waitUntilExit()

    XCTAssert(installerProcess.terminationStatus == 0)
    XCTAssert(stuckProcess.isRunning == false)
    XCTAssert(try String(contentsOf: targetAppURL.appendingPathComponent("version.txt")) == "new")
    XCTAssert(fileManager.fileExists(atPath: "\(targetAppURL.path).updater-backup") == false)

    let logURL = rootURL.appendingPathComponent("Sub2APIStatusBar-update-install.log")
    let log = try String(contentsOf: logURL)
    XCTAssert(log.contains("sending TERM"))
    XCTAssert(log.contains("Installed update"))
}

func testCurrentUserResponseDecodesDirectUserPayload() throws {
    let json = """
    {
      "id": 7,
      "email": "user@example.com",
      "username": "das",
      "role": "user",
      "balance": 12.34,
      "concurrency": 100,
      "status": "active"
    }
    """.data(using: .utf8)!

    let response = try JSONDecoder.sub2api.decode(CurrentUserResponse.self, from: json)

    XCTAssert(response.user.balance == 12.34)
    XCTAssert(response.user.username == "das")
    XCTAssert(response.user.concurrency == 100)
}

func testCurrentUserResponseRequiresConcurrencyField() {
    let json = """
    {
      "id": 7,
      "email": "user@example.com",
      "username": "das",
      "role": "user",
      "balance": 12.34,
      "status": "active"
    }
    """.data(using: .utf8)!

    XCTAssertThrowsError(try JSONDecoder.sub2api.decode(CurrentUserResponse.self, from: json))
}

func testCurrentUserRecognizesAdminRole() throws {
    let json = """
    {
      "id": 1,
      "email": "admin@example.com",
      "username": "root",
      "role": "admin",
      "balance": 0,
      "concurrency": 100,
      "status": "active"
    }
    """.data(using: .utf8)!

    let response = try JSONDecoder.sub2api.decode(CurrentUserResponse.self, from: json)

    XCTAssert(response.user.isAdmin == true)
}

func testAdminUserConcurrencyStatsDecodeRealUserConcurrencyPayload() throws {
    let json = """
    {
      "code": 0,
      "message": "success",
      "data": {
        "enabled": true,
        "user": {
          "42": {
            "user_id": 42,
            "user_email": "target@example.com",
            "username": "target",
            "current_in_use": 3,
            "max_capacity": 100,
            "load_percentage": 3,
            "waiting_in_queue": 1
          }
        },
        "timestamp": "2026-05-21T12:34:56Z"
      }
    }
    """.data(using: .utf8)!

    let stats = try JSONDecoder.sub2api.decode(Sub2APIEnvelope<AdminUserConcurrencyStats>.self, from: json).value()
    let target = try XCTUnwrap(stats.concurrency(forUserID: 42, userEmail: "target@example.com", username: "target", maxCapacity: 100))

    XCTAssert(stats.enabled == true)
    XCTAssert(target.userID == 42)
    XCTAssert(target.currentInUse == 3)
    XCTAssert(target.maxCapacity == 100)
    XCTAssert(target.waitingInQueue == 1)
}

func testAdminUserConcurrencyStatsTreatsMissingActiveUserAsZeroOnlyWhenEnabled() throws {
    let enabledJSON = """
    {
      "enabled": true,
      "user": {},
      "timestamp": "2026-05-21T12:34:56Z"
    }
    """.data(using: .utf8)!
    let disabledJSON = """
    {
      "enabled": false,
      "user": {},
      "timestamp": "2026-05-21T12:34:56Z"
    }
    """.data(using: .utf8)!

    let enabled = try JSONDecoder.sub2api.decode(AdminUserConcurrencyStats.self, from: enabledJSON)
    let disabled = try JSONDecoder.sub2api.decode(AdminUserConcurrencyStats.self, from: disabledJSON)

    XCTAssert(enabled.concurrency(forUserID: 99, userEmail: "idle@example.com", username: nil, maxCapacity: 12)?.currentInUse == 0)
    XCTAssert(enabled.concurrency(forUserID: 99, userEmail: "idle@example.com", username: nil, maxCapacity: 12)?.maxCapacity == 12)
    XCTAssert(disabled.concurrency(forUserID: 99, userEmail: "idle@example.com", username: nil, maxCapacity: 12) == nil)
}

func testAdminUsersPageDecodesStrictUserListShape() throws {
    let json = """
    {
      "items": [
        {
          "id": 42,
          "email": "target@example.com",
          "username": "target",
          "role": "user",
          "balance": 8.25,
          "status": "active",
          "concurrency": 100,
          "current_concurrency": 3
        }
      ],
      "total": 1,
      "page": 1,
      "page_size": 20,
      "pages": 1
    }
    """.data(using: .utf8)!

    let page = try JSONDecoder.sub2api.decode(AdminUsersPage.self, from: json)

    XCTAssert(page.items.first?.id == 42)
    XCTAssert(page.items.first?.email == "target@example.com")
    XCTAssert(page.items.first?.concurrency == 100)
    XCTAssert(page.items.first?.currentConcurrency == 3)
    XCTAssert(page.pageSize == 20)
}

func testSub2APIClientFetchesAllAdminUsersAcrossPages() async throws {
    StubURLProtocol.responses = [
        "/api/v1/admin/users?page=1&page_size=1000": Data("""
        {
          "items": [
            {
              "id": 1,
              "email": "one@example.com",
              "username": "one",
              "role": "user",
              "balance": 0,
              "status": "active",
              "concurrency": 10,
              "current_concurrency": 0
            }
          ],
          "total": 2,
          "page": 1,
          "page_size": 1000,
          "pages": 2
        }
        """.utf8),
        "/api/v1/admin/users?page=2&page_size=1000": Data("""
        {
          "items": [
            {
              "id": 2,
              "email": "two@example.com",
              "username": "two",
              "role": "user",
              "balance": 0,
              "status": "active",
              "concurrency": 10,
              "current_concurrency": 1
            }
          ],
          "total": 2,
          "page": 2,
          "page_size": 1000,
          "pages": 2
        }
        """.utf8),
    ]
    StubURLProtocol.requestedPaths = []
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let client = Sub2APIClient(config: AppConfig(baseURL: "https://example.test", authToken: "token"), session: session)

    let users = try await client.allAdminUsers()

    XCTAssert(users.map(\.id) == [1, 2])
    XCTAssert(StubURLProtocol.requestedPaths == [
        "/api/v1/admin/users?page=1&page_size=1000",
        "/api/v1/admin/users?page=2&page_size=1000",
    ])
}

func testSub2APIClientFetchesNormalAccountCountFromAccountFilterTotal() async throws {
    StubURLProtocol.responses = [
        "/api/v1/admin/accounts?page=1&page_size=1&status=active&lite=true": Data("""
        {
          "items": [
            {
              "account": {
                "id": 41,
                "name": "normal",
                "platform": "openai",
                "type": "oauth",
                "status": "active",
                "schedulable": true,
                "error_message": ""
              },
              "current_concurrency": 0
            }
          ],
          "total": 4,
          "page": 1,
          "page_size": 1,
          "pages": 4
        }
        """.utf8),
    ]
    StubURLProtocol.requestedPaths = []
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let client = Sub2APIClient(config: AppConfig(baseURL: "https://example.test", authToken: "token"), session: session)

    let count = try await client.adminNormalAccountCount()

    XCTAssert(count == 4)
    XCTAssert(StubURLProtocol.requestedPaths == [
        "/api/v1/admin/accounts?page=1&page_size=1&status=active&lite=true",
    ])
}

func testSub2APIClientRequiresNormalAccountCountTotal() async throws {
    StubURLProtocol.responses = [
        "/api/v1/admin/accounts?page=1&page_size=1&status=active&lite=true": Data("""
        {
          "items": [],
          "page": 1,
          "page_size": 1,
          "pages": 1
        }
        """.utf8),
    ]
    StubURLProtocol.requestedPaths = []
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let client = Sub2APIClient(config: AppConfig(baseURL: "https://example.test", authToken: "token"), session: session)

    do {
        _ = try await client.adminNormalAccountCount()
        XCTFail("Missing total must not fall back to item count.")
    } catch {
        XCTAssert(StubURLProtocol.requestedPaths == [
            "/api/v1/admin/accounts?page=1&page_size=1&status=active&lite=true",
        ])
    }
}

func testSub2APIClientUsesAdminFilteredEndpointsForSelectedUserMetrics() async throws {
    StubURLProtocol.responses = [
        "/api/v1/admin/users/2": Data("""
        {
          "id": 2,
          "email": "target@example.com",
          "username": "target",
          "role": "user",
          "balance": 66937.34,
          "status": "active",
          "concurrency": 100,
          "notes": "admin detail payload"
        }
        """.utf8),
        "/api/v1/admin/usage/stats?user_id=2&start_date=2026-05-21&end_date=2026-05-21&timezone=Asia/Shanghai": Data("""
        {
          "total_requests": 3953,
          "total_actual_cost": 1010.5504306,
          "total_tokens": 511283323,
          "total_input_tokens": 38967768,
          "total_output_tokens": 3026083,
          "total_cache_creation_tokens": 0,
          "total_cache_read_tokens": 469289472,
          "average_duration_ms": 14514.63
        }
        """.utf8),
        "/api/v1/admin/usage?user_id=2&page=1&page_size=1&sort_by=created_at&sort_order=desc&timezone=Asia/Shanghai": Data("""
        {
          "items": [
            {
              "id": 133605,
              "user_id": 2,
              "model": "gpt-5.5",
              "service_tier": "priority",
              "reasoning_effort": "xhigh",
              "input_tokens": 430,
              "output_tokens": 1172,
              "cache_creation_tokens": 0,
              "cache_read_tokens": 164224,
              "actual_cost": 0.238844,
              "created_at": "2026-05-21T15:37:40.960689+08:00"
            }
          ],
          "total": 1,
          "page": 1,
          "page_size": 1,
          "pages": 1
        }
        """.utf8),
        "/api/v1/admin/dashboard/trend?user_id=2&start_date=2026-05-15&end_date=2026-05-21&granularity=day&timezone=Asia/Shanghai": Data("""
        {
          "trend": [
            {
              "date": "2026-05-21",
              "requests": 3955,
              "input_tokens": 38968948,
              "output_tokens": 3027292,
              "cache_read_tokens": 469653760,
              "total_tokens": 511650000,
              "cost": 1010.9990586,
              "actual_cost": 1010.9990586
            }
          ]
        }
        """.utf8),
        "/api/v1/admin/dashboard/models?user_id=2&start_date=2026-05-15&end_date=2026-05-21&timezone=Asia/Shanghai": Data("""
        {
          "models": [
            {
              "model": "gpt-5.5",
              "requests": 38595,
              "input_tokens": 355961052,
              "output_tokens": 28255560,
              "cache_read_tokens": 4380570437,
              "total_tokens": 4772887049,
              "cost": 6224.069159,
              "actual_cost": 6224.069159
            }
          ]
        }
        """.utf8),
    ]
    StubURLProtocol.requestedPaths = []
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let client = Sub2APIClient(config: AppConfig(baseURL: "https://example.test", authToken: "token"), session: session)

    let user = try await client.adminUser(id: 2)
    let stats = try await client.adminUsageStats(userID: 2, startDate: "2026-05-21", endDate: "2026-05-21", timezone: "Asia/Shanghai")
    let latest = try await client.adminUsageLogs(userID: 2, page: 1, pageSize: 1, sortBy: "created_at", sortOrder: "desc", timezone: "Asia/Shanghai")
    let trend = try await client.adminDashboardTrend(userID: 2, startDate: "2026-05-15", endDate: "2026-05-21", granularity: "day", timezone: "Asia/Shanghai")
    let models = try await client.adminDashboardModels(userID: 2, startDate: "2026-05-15", endDate: "2026-05-21", timezone: "Asia/Shanghai")

    XCTAssert(user.balance == 66937.34)
    XCTAssert(stats.totalRequests == 3953)
    XCTAssert(stats.totalCacheReadTokens == 469_289_472)
    XCTAssert(latest.items.first?.model == "gpt-5.5")
    XCTAssert(latest.items.first?.reasoningEffort == "xhigh")
    XCTAssert(trend.trend.first?.requests == 3955)
    XCTAssert(models.models.first?.model == "gpt-5.5")
    XCTAssert(StubURLProtocol.requestedPaths == [
        "/api/v1/admin/users/2",
        "/api/v1/admin/usage/stats?user_id=2&start_date=2026-05-21&end_date=2026-05-21&timezone=Asia/Shanghai",
        "/api/v1/admin/usage?user_id=2&page=1&page_size=1&sort_by=created_at&sort_order=desc&timezone=Asia/Shanghai",
        "/api/v1/admin/dashboard/trend?user_id=2&start_date=2026-05-15&end_date=2026-05-21&granularity=day&timezone=Asia/Shanghai",
        "/api/v1/admin/dashboard/models?user_id=2&start_date=2026-05-15&end_date=2026-05-21&timezone=Asia/Shanghai",
    ])
}

func testDashboardSnapshotDecodesTokenBreakdownAndModelDistribution() throws {
    let json = """
    {
      "generated_at": "2026-04-28T13:00:00Z",
      "stats": {
        "today_requests": 1119,
        "today_tokens": 121800000,
        "today_input_tokens": 7400000,
        "today_output_tokens": 513900,
        "total_tokens": 594300000,
        "total_input_tokens": 40200000,
        "total_output_tokens": 3500000,
        "today_actual_cost": 113.3052,
        "rpm": 3,
        "tpm": 12200,
        "average_duration_ms": 14570
      },
      "model_distribution": [
        {
          "model": "gpt-5.5",
          "requests": 2116,
          "total_tokens": 244400000,
          "input_tokens": 200000000,
          "output_tokens": 44400000,
          "actual_cost": 218.2116,
          "standard_cost": 218.2116
        }
      ]
    }
    """.data(using: .utf8)!

    let snapshot = try JSONDecoder.sub2api.decode(DashboardSnapshot.self, from: json)

    XCTAssert(snapshot.stats?.todayInputTokens == 7_400_000)
    XCTAssert(snapshot.stats?.todayOutputTokens == 513_900)
    XCTAssert(snapshot.stats?.totalInputTokens == 40_200_000)
    XCTAssert(snapshot.stats?.totalOutputTokens == 3_500_000)
    XCTAssert(snapshot.modelDistribution?.first?.model == "gpt-5.5")
    XCTAssert(snapshot.modelDistribution?.first?.requests == 2116)
    XCTAssert(snapshot.modelDistribution?.first?.actualCost == 218.2116)
}

func testUsageDashboardDecodesUserStatsTrendAndModels() throws {
    let statsJSON = """
    {
      "total_api_keys": 2,
      "active_api_keys": 2,
      "total_requests": 5476,
      "total_input_tokens": 40529619,
      "total_output_tokens": 3499464,
      "total_cache_creation_tokens": 0,
      "total_cache_read_tokens": 554867072,
      "total_tokens": 598896155,
      "total_cost": 498.69043735,
      "total_actual_cost": 498.69043735,
      "today_requests": 1186,
      "today_input_tokens": 7657045,
      "today_output_tokens": 536098,
      "today_cache_creation_tokens": 0,
      "today_cache_read_tokens": 118193024,
      "today_tokens": 126386167,
      "today_cost": 117.56682985,
      "today_actual_cost": 117.56682985,
      "average_duration_ms": 14514.6375,
      "rpm": 1,
      "tpm": 10752
    }
    """.data(using: .utf8)!
    let trendJSON = """
    {
      "trend": [
        {
          "date": "2026-04-28",
          "requests": 1187,
          "input_tokens": 7672001,
          "output_tokens": 536486,
          "cache_creation_tokens": 0,
          "cache_read_tokens": 118310656,
          "total_tokens": 126519143,
          "cost": 117.71206585,
          "actual_cost": 117.71206585
        }
      ]
    }
    """.data(using: .utf8)!
    let modelsJSON = """
    {
      "models": [
        {
          "model": "gpt-5.5",
          "requests": 2184,
          "input_tokens": 14103149,
          "output_tokens": 1004490,
          "cache_creation_tokens": 0,
          "cache_read_tokens": 234003712,
          "total_tokens": 249111351,
          "cost": 222.61852,
          "actual_cost": 222.61852,
          "account_cost": 222.61852
        }
      ]
    }
    """.data(using: .utf8)!

    let stats = try JSONDecoder.sub2api.decode(DashboardStats.self, from: statsJSON)
    let trend = try JSONDecoder.sub2api.decode(DashboardTrendResponse.self, from: trendJSON)
    let models = try JSONDecoder.sub2api.decode(DashboardModelsResponse.self, from: modelsJSON)

    XCTAssert(stats.todayCacheReadTokens == 118_193_024)
    XCTAssert(stats.todayCost == 117.56682985)
    XCTAssert(trend.trend.first?.inputTokens == 7_672_001)
    XCTAssert(trend.trend.first?.cacheReadTokens == 118_310_656)
    XCTAssert(models.models.first?.accountCost == 222.61852)
    XCTAssert(models.models.first?.standardCost == 222.61852)
}

func testMenuBarUsageWindowBuildsDateRangesLikeWebPreset() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
    let now = Date(timeIntervalSince1970: 1_777_456_800) // 2026-04-29 20:00:00 +0800

    XCTAssert(MenuBarUsageWindow.last24Hours.dateRange(now: now, calendar: calendar) == MenuBarDateRange(start: "2026-04-28", end: "2026-04-29"))
    XCTAssert(MenuBarUsageWindow.today.dateRange(now: now, calendar: calendar) == MenuBarDateRange(start: "2026-04-29", end: "2026-04-29"))
}

func testUsageLogDecodesLatestMetadataAndDerivedValues() throws {
    let json = """
    {
      "id": 133605,
      "model": "gpt-5.5",
      "service_tier": "priority",
      "reasoning_effort": "xhigh",
      "input_tokens": 946,
      "output_tokens": 429,
      "cache_creation_tokens": 12000,
      "cache_read_tokens": 75432,
      "input_cost": 0.00946,
      "output_cost": 0.02574,
      "total_cost": 0.0352,
      "actual_cost": 0.124712,
      "duration_ms": 1456,
      "created_at": "2026-04-29T19:15:11.118937+08:00"
    }
    """.data(using: .utf8)!

    let usage = try JSONDecoder.sub2api.decode(UsageLog.self, from: json)

    XCTAssert(usage.model == "gpt-5.5")
    XCTAssert(usage.reasoningEffort == "xhigh")
    XCTAssert(usage.isFastEnabled == true)
    XCTAssert(usage.contextLengthTokens == 88_378)
    XCTAssertEqual(usage.inputPricePerMillion ?? 0, 10, accuracy: 0.000001)
    XCTAssertEqual(usage.outputPricePerMillion ?? 0, 60, accuracy: 0.000001)
    XCTAssertEqual(usage.totalCost, 0.0352, accuracy: 0.000001)
    XCTAssertEqual(usage.durationMs, 1456, accuracy: 0.000001)
}

func testUsageLogRecognizesUpdatedFastModeServiceTierAlias() throws {
    let json = """
    {
      "id": 133606,
      "model": "gpt-5.5",
      "service_tier": "fast-mode-2026-02-01",
      "input_tokens": 946,
      "output_tokens": 429,
      "created_at": "2026-04-29T19:15:11.118937+08:00"
    }
    """.data(using: .utf8)!

    let usage = try JSONDecoder.sub2api.decode(UsageLog.self, from: json)

    XCTAssert(usage.isFastEnabled == true)
}

func testUsagePeriodStatsDecodesPartialStatsPayload() throws {
    let json = """
    {
      "total_requests": 1051,
      "total_actual_cost": 123.45,
      "total_tokens": 98765,
      "average_duration_ms": 12.3
    }
    """.data(using: .utf8)!

    let stats = try JSONDecoder.sub2api.decode(UsagePeriodStats.self, from: json)

    XCTAssert(stats.totalRequests == 1051)
    XCTAssert(stats.totalActualCost == 123.45)
    XCTAssert(stats.totalTokens == 98_765)
    XCTAssert(stats.totalInputTokens == 0)
    XCTAssert(stats.totalOutputTokens == 0)
    XCTAssert(stats.totalCacheCreationTokens == 0)
    XCTAssert(stats.totalCacheReadTokens == 0)
}

func testAccountHealthSummaryCountsRuntimeStates() {
    let accounts = [
        AccountSummary(id: 1, name: "ok", platform: "openai", type: "oauth", status: "active", schedulable: true, quotaLimit: 100, quotaUsed: 30, quotaDailyLimit: nil, quotaDailyUsed: nil, quotaWeeklyLimit: nil, quotaWeeklyUsed: nil, errorMessage: "", rateLimitResetAt: nil),
        AccountSummary(id: 2, name: "blocked", platform: "openai", type: "oauth", status: "active", schedulable: false, quotaLimit: 100, quotaUsed: 91, quotaDailyLimit: nil, quotaDailyUsed: nil, quotaWeeklyLimit: nil, quotaWeeklyUsed: nil, errorMessage: "", rateLimitResetAt: nil),
        AccountSummary(id: 3, name: "bad", platform: "anthropic", type: "setup_token", status: "disabled", schedulable: false, quotaLimit: nil, quotaUsed: nil, quotaDailyLimit: nil, quotaDailyUsed: nil, quotaWeeklyLimit: nil, quotaWeeklyUsed: nil, errorMessage: "expired", rateLimitResetAt: nil),
    ]

    let summary = AccountHealthSummary(accounts: accounts)

    XCTAssert(summary.total == 3)
    XCTAssert(summary.active == 2)
    XCTAssert(summary.schedulable == 1)
    XCTAssert(summary.blocked == 2)
    XCTAssert(summary.nearQuotaLimit == 1)
}

func testSubscriptionProgressFindsHighestUsageRatio() {
    let subscriptions = [
        SubscriptionSummaryItem(id: 1, groupName: "Claude", status: "active", dailyProgress: 0.25, weeklyProgress: nil, monthlyProgress: 0.6, expiresAt: nil, daysRemaining: 12),
        SubscriptionSummaryItem(id: 2, groupName: "OpenAI", status: "active", dailyProgress: 0.82, weeklyProgress: 0.71, monthlyProgress: nil, expiresAt: nil, daysRemaining: 2),
    ]

    let summary = SubscriptionSummary(activeCount: 2, subscriptions: subscriptions)

    XCTAssert(summary.highestProgress == 0.82)
    XCTAssert(summary.expiringSoonCount == 1)
}

func testSubscriptionSummaryDecodesUsdUsageIntoProgress() throws {
    let json = """
    {
      "active_count": 1,
      "total_used_usd": 498.38329835,
      "subscriptions": [
        {
          "id": 2,
          "group_name": "codex",
          "status": "active",
          "daily_used_usd": 117.25969085,
          "daily_limit_usd": 124.97,
          "weekly_used_usd": 153.11513095,
          "weekly_limit_usd": 500,
          "monthly_used_usd": 498.38329835,
          "monthly_limit_usd": 2000,
          "daily_reset_in_seconds": 6960,
          "weekly_reset_in_seconds": 435660,
          "monthly_reset_in_seconds": 1821660,
          "days_remaining": 22,
          "expires_at": "2026-05-20T16:29:44+08:00"
        }
      ]
    }
    """.data(using: .utf8)!

    let summary = try JSONDecoder.sub2api.decode(SubscriptionSummary.self, from: json)

    XCTAssert(summary.totalUsedUSD == 498.38329835)
    XCTAssert(summary.subscriptions.first?.dailyProgress ?? 0 > 0.93)
    XCTAssert(summary.subscriptions.first?.monthlyProgress ?? 0 > 0.24)
    XCTAssert(summary.subscriptions.first?.dailyResetInSeconds == 6960)
    XCTAssert(summary.subscriptions.first?.daysRemaining == 22)
}

func testAdminUserSubscriptionBuildsSelectedUserSubscriptionSummary() throws {
    let json = """
    [
      {
        "id": 9,
        "user_id": 2,
        "group_id": 3,
        "starts_at": "2026-05-01T00:00:00+08:00",
        "expires_at": "2026-05-23T00:00:00+08:00",
        "status": "active",
        "daily_usage_usd": 117.25,
        "weekly_usage_usd": 153.11,
        "monthly_usage_usd": 498.38,
        "group": {
          "id": 3,
          "name": "codex",
          "daily_limit_usd": 125,
          "weekly_limit_usd": 500,
          "monthly_limit_usd": 2000
        }
      }
    ]
    """.data(using: .utf8)!
    let referenceDate = ISO8601DateFormatter().date(from: "2026-05-21T00:00:00+08:00")!

    let subscriptions = try JSONDecoder.sub2api.decode([AdminUserSubscription].self, from: json)
    let summary = SubscriptionSummary(adminSubscriptions: subscriptions, referenceDate: referenceDate)

    XCTAssert(subscriptions.first?.userID == 2)
    XCTAssert(summary.activeCount == 1)
    XCTAssertEqual(summary.totalUsedUSD, 498.38, accuracy: 0.000001)
    XCTAssert(summary.subscriptions.first?.groupName == "codex")
    XCTAssertEqual(summary.subscriptions.first?.dailyProgress ?? 0, 0.938, accuracy: 0.000001)
    XCTAssert(summary.subscriptions.first?.daysRemaining == 2)
}

func testMonitorSnapshotEscalatesSeverityFromSignals() {
    let healthy = MonitorSnapshot(
        mode: .user,
        connected: true,
        stats: DashboardStats(todayRequests: 20, todayActualCost: 1.2, rpm: 4),
        realtime: RealtimeMetrics(errorRate: 0.01),
        accountHealth: AccountHealthSummary(accounts: []),
        subscriptionSummary: nil,
        lastUpdatedAt: Date(timeIntervalSince1970: 0),
        message: nil
    )

    let warned = MonitorSnapshot(
        mode: .user,
        connected: true,
        stats: DashboardStats(todayRequests: 20, todayActualCost: 1.2, rpm: 4),
        realtime: RealtimeMetrics(errorRate: 0.01),
        accountHealth: AccountHealthSummary(accounts: [
            AccountSummary(id: 1, name: "quota", platform: "openai", type: "oauth", status: "active", schedulable: true, quotaLimit: 10, quotaUsed: 9.1, quotaDailyLimit: nil, quotaDailyUsed: nil, quotaWeeklyLimit: nil, quotaWeeklyUsed: nil, errorMessage: "", rateLimitResetAt: nil),
        ]),
        subscriptionSummary: nil,
        lastUpdatedAt: Date(timeIntervalSince1970: 0),
        message: nil
    )

    let failed = MonitorSnapshot(
        mode: .user,
        connected: false,
        stats: nil,
        realtime: nil,
        accountHealth: nil,
        subscriptionSummary: nil,
        lastUpdatedAt: nil,
        message: "offline"
    )

    XCTAssert(healthy.severity == .healthy)
    XCTAssert(warned.severity == .warning)
    XCTAssert(failed.severity == .error)
}

func testMonitorSnapshotLabelsNearLimitSeparatelyFromConnectionFailure() {
    let nearLimit = MonitorSnapshot(
        mode: .user,
        connected: true,
        stats: nil,
        realtime: nil,
        accountHealth: nil,
        subscriptionSummary: SubscriptionSummary(activeCount: 1, subscriptions: [
            SubscriptionSummaryItem(id: 1, groupName: "codex", status: "active", dailyProgress: 0.966, weeklyProgress: nil, monthlyProgress: nil, expiresAt: nil, daysRemaining: 20),
        ]),
        lastUpdatedAt: Date(timeIntervalSince1970: 0),
        message: nil
    )
    let disconnected = MonitorSnapshot(
        mode: .user,
        connected: false,
        stats: nil,
        realtime: nil,
        accountHealth: nil,
        subscriptionSummary: nil,
        lastUpdatedAt: nil,
        message: "offline"
    )

    XCTAssert(nearLimit.statusLabel == "Near Limit")
    XCTAssert(disconnected.statusLabel == "Disconnected")
}

func testMonitorSnapshotBuildsMenuBarSummaryFromDashboardStats() {
    let latestUsage = UsageLog(
        id: 133605,
        model: "gpt-5.5",
        serviceTier: "priority",
        reasoningEffort: "xhigh",
        inputTokens: 946,
        outputTokens: 429,
        cacheCreationTokens: 12_000,
        cacheReadTokens: 75_432,
        inputCost: 0.00946,
        outputCost: 0.02574,
        actualCost: 0.124712,
        createdAt: Date(timeIntervalSince1970: 1_777_453_711)
    )
    let snapshot = MonitorSnapshot(
        mode: .user,
        connected: true,
        stats: DashboardStats(todayRequests: 1119, todayActualCost: 113.3052, rpm: 3),
        menuBarUsageStats: UsagePeriodStats(totalRequests: 2048, totalActualCost: 12.3456),
        latestUsage: latestUsage,
        realtime: nil,
        accountHealth: nil,
        subscriptionSummary: nil,
        lastUpdatedAt: Date(timeIntervalSince1970: 0),
        message: nil
    )
    let defaultConfig = AppConfig(baseURL: "http://127.0.0.1:8080")
    let customConfig = AppConfig(
        baseURL: "http://127.0.0.1:8080",
        menuBarDisplayItems: [.totalRequests, .inputPrice, .outputPrice]
    )

    XCTAssert(snapshot.menuBarSummary(config: defaultConfig) == "$12.35 · gpt-5.5 · xhigh · 88.4K ctx · Fast · 3 RPM")
    XCTAssert(snapshot.menuBarSummary(config: customConfig) == "2048 req · in $10.0000/1M · out $60.0000/1M")
}

func testMonitorSnapshotOmitsFastTextWhenFastIsNotEnabled() {
    let latestUsage = UsageLog(
        id: 133605,
        model: "gpt-5.5",
        serviceTier: "standard",
        reasoningEffort: "xhigh",
        inputTokens: 946,
        outputTokens: 429,
        cacheCreationTokens: 12_000,
        cacheReadTokens: 75_432,
        inputCost: 0.00946,
        outputCost: 0.02574,
        actualCost: 0.124712,
        createdAt: Date(timeIntervalSince1970: 1_777_453_711)
    )
    let snapshot = MonitorSnapshot(
        mode: .user,
        connected: true,
        stats: DashboardStats(todayRequests: 1119, todayActualCost: 113.3052, rpm: 3),
        menuBarUsageStats: UsagePeriodStats(totalRequests: 2048, totalActualCost: 12.3456),
        latestUsage: latestUsage,
        realtime: nil,
        accountHealth: nil,
        subscriptionSummary: nil,
        lastUpdatedAt: Date(timeIntervalSince1970: 0),
        message: nil
    )
    let config = AppConfig(baseURL: "http://127.0.0.1:8080")

    XCTAssert(snapshot.menuBarSummary(config: config) == "$12.35 · gpt-5.5 · xhigh · 88.4K ctx · 3 RPM")
}

func testMonitorSnapshotMenuBarPresentationHidesHealthyImageWhenTextIsShown() {
    let latestUsage = UsageLog(id: 133605, model: "gpt-5.5")
    let snapshot = MonitorSnapshot(
        mode: .user,
        connected: true,
        stats: DashboardStats(),
        latestUsage: latestUsage,
        realtime: nil,
        accountHealth: nil,
        subscriptionSummary: nil,
        lastUpdatedAt: Date(timeIntervalSince1970: 0),
        message: nil
    )
    let config = AppConfig(
        baseURL: "http://127.0.0.1:8080",
        showsMenuBarText: true,
        menuBarDisplayItems: [.model]
    )

    let presentation = snapshot.menuBarStatusPresentation(config: config)

    XCTAssert(presentation.title == " gpt-5.5")
    XCTAssert(presentation.hidesHealthyStatusImage == true)
}

func testMonitorSnapshotMenuBarPresentationTruncatesLongStatusTextOnly() {
    let latestUsage = UsageLog(
        id: 133605,
        model: "gpt-5.5",
        serviceTier: "priority",
        reasoningEffort: "xhigh",
        inputTokens: 430,
        outputTokens: 1172,
        cacheReadTokens: 164_224,
        actualCost: 0.238844
    )
    let snapshot = MonitorSnapshot(
        mode: .admin,
        connected: true,
        stats: DashboardStats(todayRequests: 239, todayActualCost: 0.22, rpm: 52),
        menuBarUsageStats: UsagePeriodStats(totalRequests: 239, totalActualCost: 0.22),
        latestUsage: latestUsage,
        realtime: nil,
        realtimeConcurrency: UserRealtimeConcurrency(userID: 2, userEmail: "target@example.com", username: "target", currentInUse: 1, maxCapacity: 100, loadPercentage: 0.01, waitingInQueue: 0),
        adminNormalAccountCount: 4,
        accountHealth: nil,
        subscriptionSummary: nil,
        lastUpdatedAt: Date(timeIntervalSince1970: 0),
        message: nil
    )
    let config = AppConfig(
        baseURL: "http://127.0.0.1:8080",
        monitorMode: .admin,
        showsMenuBarText: true,
        menuBarDisplayItems: [.totalCost, .totalRequests, .model, .reasoningEffort, .fast, .rpm, .realtimeConcurrency, .normalAccounts]
    )

    let fullSummary = snapshot.menuBarSummary(config: config)
    let presentation = snapshot.menuBarStatusPresentation(config: config)

    XCTAssertEqual(fullSummary, "$0.22 · 239 req · gpt-5.5 · xhigh · Fast · 1 CC · 4 normal")
    XCTAssertEqual(presentation.title, " $0.22·239r·gpt-5.5·xh·F·1CC·4N")
    XCTAssert(presentation.hidesHealthyStatusImage == true)
}

func testMonitorSnapshotCompactMenuBarSummaryKeepsAllSelectedItemsWhenPossible() {
    let latestUsage = UsageLog(
        id: 133605,
        model: "gpt-5.5",
        serviceTier: "priority",
        reasoningEffort: "xhigh",
        inputTokens: 430,
        outputTokens: 1172,
        cacheReadTokens: 164_224,
        actualCost: 0.238844
    )
    let snapshot = MonitorSnapshot(
        mode: .admin,
        connected: true,
        stats: DashboardStats(todayRequests: 239, todayActualCost: 0.22, rpm: 52),
        menuBarUsageStats: UsagePeriodStats(totalRequests: 239, totalActualCost: 2864.10),
        latestUsage: latestUsage,
        realtime: nil,
        realtimeConcurrency: UserRealtimeConcurrency(userID: 2, userEmail: "target@example.com", username: "target", currentInUse: 1, maxCapacity: 100, loadPercentage: 0.01, waitingInQueue: 0),
        adminNormalAccountCount: 4,
        accountHealth: nil,
        subscriptionSummary: nil,
        lastUpdatedAt: Date(timeIntervalSince1970: 0),
        message: nil
    )
    let config = AppConfig(
        baseURL: "http://127.0.0.1:8080",
        monitorMode: .admin,
        showsMenuBarText: true,
        menuBarDisplayItems: [.totalCost, .model, .reasoningEffort, .fast, .realtimeConcurrency, .normalAccounts]
    )

    let fullSummary = snapshot.menuBarSummary(config: config)
    let compactSummary = snapshot.compactMenuBarSummary(config: config, maxCharacters: 36)

    XCTAssertEqual(fullSummary, "$2864.10 · gpt-5.5 · xhigh · Fast · 1 CC · 4 normal")
    XCTAssertEqual(compactSummary, "$2.86K·gpt-5.5·xh·F·1CC·4N")
    XCTAssert(compactSummary.count <= 36)
}

func testMonitorSnapshotCompactMenuBarSummaryCompressesPricesAndRates() {
    let latestUsage = UsageLog(
        id: 133605,
        model: "gpt-5.5",
        serviceTier: "priority",
        inputTokens: 946,
        outputTokens: 429,
        inputCost: 0.00946,
        outputCost: 0.02574,
        actualCost: 0.124712
    )
    let snapshot = MonitorSnapshot(
        mode: .user,
        connected: true,
        stats: DashboardStats(todayRequests: 2048, todayActualCost: 12.34, rpm: 3),
        menuBarUsageStats: UsagePeriodStats(totalRequests: 2048, totalActualCost: 12.34),
        latestUsage: latestUsage,
        realtime: nil,
        accountHealth: nil,
        subscriptionSummary: nil,
        lastUpdatedAt: Date(timeIntervalSince1970: 0),
        message: nil
    )
    let config = AppConfig(
        baseURL: "http://127.0.0.1:8080",
        showsMenuBarText: true,
        menuBarDisplayItems: [.totalRequests, .inputPrice, .outputPrice, .rpm]
    )

    XCTAssertEqual(snapshot.compactMenuBarSummary(config: config, maxCharacters: 36), "2048r·i$10/M·o$60/M·3rpm")
}

func testCompactMenuBarSummaryAlwaysRespectsMaximumLength() {
    let summary = "$0.22 · 239 req · gpt-5.5 · xhigh · Fast · 1 CC · 8 normal"

    XCTAssertEqual(MonitorSnapshot.compactMenuBarSummary(summary, maxCharacters: summary.count), summary)

    for limit in 1...40 {
        let compacted = MonitorSnapshot.compactMenuBarSummary(summary, maxCharacters: limit)
        XCTAssert(compacted.count <= limit)
    }
}

func testMonitorSnapshotMenuBarPresentationUsesEmptyTitleWhenOnlyDisabledFastIsSelected() {
    let latestUsage = UsageLog(id: 133605, model: "gpt-5.5", serviceTier: "standard")
    let snapshot = MonitorSnapshot(
        mode: .user,
        connected: true,
        stats: DashboardStats(),
        latestUsage: latestUsage,
        realtime: nil,
        accountHealth: nil,
        subscriptionSummary: nil,
        lastUpdatedAt: Date(timeIntervalSince1970: 0),
        message: nil
    )
    let config = AppConfig(
        baseURL: "http://127.0.0.1:8080",
        showsMenuBarText: true,
        menuBarDisplayItems: [.fast]
    )

    let presentation = snapshot.menuBarStatusPresentation(config: config)

    XCTAssert(presentation.title == "")
    XCTAssert(presentation.hidesHealthyStatusImage == false)
}

func testMonitorSnapshotDoesNotUseTodayFallbackForLast24HourMenuBarStats() {
    let snapshot = MonitorSnapshot(
        mode: .user,
        connected: true,
        stats: DashboardStats(todayRequests: 503, todayActualCost: 12.34, rpm: 3),
        menuBarUsageStats: nil,
        realtime: nil,
        accountHealth: nil,
        subscriptionSummary: nil,
        lastUpdatedAt: Date(timeIntervalSince1970: 0),
        message: nil
    )
    let config = AppConfig(
        baseURL: "http://127.0.0.1:8080",
        menuBarUsageWindow: .last24Hours,
        menuBarDisplayItems: [.totalCost, .totalRequests]
    )

    XCTAssert(!snapshot.menuBarSummary(config: config).contains("503"))
    XCTAssert(!snapshot.menuBarSummary(config: config).contains("$12.34"))
}

func testMonitorSnapshotAllowsEmptyMenuBarItemSelection() {
    let snapshot = MonitorSnapshot(
        mode: .user,
        connected: true,
        stats: DashboardStats(todayRequests: 1119, todayActualCost: 113.3052, rpm: 3),
        menuBarUsageStats: UsagePeriodStats(totalRequests: 2048, totalActualCost: 12.3456),
        realtime: nil,
        accountHealth: nil,
        subscriptionSummary: nil,
        lastUpdatedAt: Date(timeIntervalSince1970: 0),
        message: nil
    )
    let config = AppConfig(baseURL: "http://127.0.0.1:8080", menuBarDisplayItems: [])

    XCTAssert(snapshot.menuBarSummary(config: config) == "")
}

func testSub2APIClientRetriesTransientFailuresBeforeDecodingSuccess() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    StubURLProtocol.responses = [:]
    StubURLProtocol.responseQueues = [
        "/api/v1/auth/me": [
            (status: 500, data: Data(#"{"code":500,"message":"temporary"}"#.utf8)),
            (status: 200, data: Data(#"{"code":0,"message":"ok","data":{"user":{"id":7,"email":"a@example.com","role":"user","concurrency":4}}}"#.utf8)),
        ],
    ]
    StubURLProtocol.requestedPaths = []
    let client = Sub2APIClient(
        config: AppConfig(baseURL: "http://127.0.0.1:8080", authToken: "token"),
        session: session,
        retryPolicy: HTTPRetryPolicy(maxRetries: 2, baseDelaySeconds: 0)
    )

    let response = try await client.currentUser()

    XCTAssert(response.user.id == 7)
    XCTAssert(StubURLProtocol.requestedPaths == ["/api/v1/auth/me", "/api/v1/auth/me"])
}

func testSub2APIClientDoesNotRetryUnauthorizedResponses() async {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    StubURLProtocol.responses = [:]
    StubURLProtocol.responseQueues = [
        "/api/v1/auth/me": [
            (status: 401, data: Data(#"{"code":401,"message":"unauthorized"}"#.utf8)),
            (status: 200, data: Data(#"{"code":0,"message":"ok","data":{"user":{"id":7,"email":"a@example.com","role":"user","concurrency":4}}}"#.utf8)),
        ],
    ]
    StubURLProtocol.requestedPaths = []
    let client = Sub2APIClient(
        config: AppConfig(baseURL: "http://127.0.0.1:8080", authToken: "expired"),
        session: session,
        retryPolicy: HTTPRetryPolicy(maxRetries: 2, baseDelaySeconds: 0)
    )

    do {
        _ = try await client.currentUser()
        XCTFail("401 should throw without retrying so the auth refresh path can handle it.")
    } catch {
        XCTAssert((error as? Sub2APIError)?.isUnauthorized == true)
        XCTAssert(StubURLProtocol.requestedPaths == ["/api/v1/auth/me"])
    }
}

func testSub2APIClientDoesNotRetryPostRequests() async {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    StubURLProtocol.responses = [:]
    StubURLProtocol.responseQueues = [
        "/api/v1/auth/login": [
            (status: 500, data: Data(#"{"code":500,"message":"temporary"}"#.utf8)),
            (status: 200, data: Data(#"{"code":0,"message":"ok","data":{"accessToken":"access","refreshToken":"refresh"}}"#.utf8)),
        ],
    ]
    StubURLProtocol.requestedPaths = []
    let client = Sub2APIClient(
        config: AppConfig(baseURL: "http://127.0.0.1:8080"),
        session: session,
        retryPolicy: HTTPRetryPolicy(maxRetries: 2, baseDelaySeconds: 0)
    )

    do {
        _ = try await client.login(email: "a@example.com", password: "secret")
        XCTFail("POST login should not retry automatically.")
    } catch {
        XCTAssert(StubURLProtocol.requestedPaths == ["/api/v1/auth/login"])
    }
}

func testMonitorSnapshotRetainsLastSuccessDataWhenRefreshFails() {
    let previous = MonitorSnapshot(
        mode: .user,
        connected: true,
        currentUser: CurrentUser(id: 7, email: "a@example.com", username: "alice", role: "user", balance: 12.5, concurrency: 4, status: "active"),
        stats: DashboardStats(todayRequests: 1119, todayActualCost: 113.3052, rpm: 3),
        menuBarUsageStats: UsagePeriodStats(totalRequests: 2048, totalActualCost: 12.3456),
        latestUsage: UsageLog(id: 133605, model: "gpt-5.5"),
        realtime: nil,
        accountHealth: nil,
        subscriptionSummary: nil,
        lastUpdatedAt: Date(timeIntervalSince1970: 100),
        message: nil
    )
    let stale = previous.retainingDataAfterRefreshFailure("temporary timeout")
    let config = AppConfig(
        baseURL: "http://127.0.0.1:8080",
        showsMenuBarText: true,
        menuBarDisplayItems: [.totalCost, .model, .rpm]
    )

    XCTAssert(stale.connected == true)
    XCTAssert(stale.isStale == true)
    XCTAssert(stale.severity == .warning)
    XCTAssert(stale.statusLabel == "Refresh Failed")
    XCTAssert(stale.lastUpdatedAt == Date(timeIntervalSince1970: 100))
    XCTAssert(stale.menuBarSummary(config: config) == "$12.35 · gpt-5.5 · 3 RPM")
    XCTAssert(stale.menuBarStatusPresentation(config: config).title == " $12.35·gpt-5.5·3rpm")
}

func testLoginFormStateRequiresURLAccountAndPassword() {
    XCTAssert(LoginFormState(baseURL: "", email: "a@example.com", password: "secret").canSubmit == false)
    XCTAssert(LoginFormState(baseURL: "http://127.0.0.1:8080", email: "", password: "secret").canSubmit == false)
    XCTAssert(LoginFormState(baseURL: "http://127.0.0.1:8080", email: "a@example.com", password: "").canSubmit == false)
    XCTAssert(LoginFormState(baseURL: "http://127.0.0.1:8080", email: "a@example.com", password: "secret").canSubmit == true)
}

private func makeTemporaryAppBundle(bundleIdentifier: String, version: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let appURL = root.appendingPathComponent("Sub2APIStatusBar.app", isDirectory: true)
    let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
    let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
    try FileManager.default.createDirectory(at: macOSURL, withIntermediateDirectories: true)
    let plist: [String: Any] = [
        "CFBundleIdentifier": bundleIdentifier,
        "CFBundleShortVersionString": version,
        "CFBundleExecutable": "Sub2APIStatusBar",
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: contentsURL.appendingPathComponent("Info.plist"))
    return appURL
}

}
