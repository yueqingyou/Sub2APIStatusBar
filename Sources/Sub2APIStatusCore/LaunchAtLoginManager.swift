import Foundation

public enum LaunchAtLoginError: LocalizedError, Equatable, Sendable {
    case requiresAppBundle(String)

    public var errorDescription: String? {
        switch self {
        case let .requiresAppBundle(path):
            return "Open at Login requires the packaged app bundle. Current path: \(path)"
        }
    }
}

public struct LaunchAtLoginManager: Sendable {
    public let appBundleURL: URL
    public let launchAgentsDirectory: URL
    public let label: String

    public init(
        appBundleURL: URL,
        launchAgentsDirectory: URL? = nil,
        label: String = "\(AppBuildInfo.bundleIdentifier).login"
    ) {
        self.appBundleURL = appBundleURL
        self.label = label
        if let launchAgentsDirectory {
            self.launchAgentsDirectory = launchAgentsDirectory
        } else {
            self.launchAgentsDirectory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("LaunchAgents", isDirectory: true)
        }
    }

    public var plistURL: URL {
        launchAgentsDirectory.appendingPathComponent("\(label).plist", isDirectory: false)
    }

    public var isEnabled: Bool {
        guard let plist = try? loadLaunchAgentPlist(),
              plist["Label"] as? String == label,
              plist["ProgramArguments"] as? [String] == programArguments,
              plist["RunAtLoad"] as? Bool == true else {
            return false
        }
        return true
    }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try writeLaunchAgentPlist()
        } else if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    func loadLaunchAgentPlist() throws -> [String: Any] {
        let data = try Data(contentsOf: plistURL)
        let value = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return value as? [String: Any] ?? [:]
    }

    private func writeLaunchAgentPlist() throws {
        guard appBundleURL.pathExtension == "app" else {
            throw LaunchAtLoginError.requiresAppBundle(appBundleURL.path)
        }

        try FileManager.default.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": programArguments,
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
    }

    private var programArguments: [String] {
        ["/usr/bin/open", appBundleURL.path]
    }
}
