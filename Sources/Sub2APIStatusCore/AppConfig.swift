import Foundation

public enum AppLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto
    case zhHans
    case en

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto:
            return "简体中文"
        case .zhHans:
            return "简体中文"
        case .en:
            return "English"
        }
    }

    public static func fromEnvironment(_ value: String?) -> AppLanguage {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !value.isEmpty else {
            return .zhHans
        }

        switch value {
        case "zh", "zh-cn", "zh-hans", "cn", "chinese":
            return .zhHans
        case "en", "en-us", "english":
            return .en
        case "auto", "system":
            return .zhHans
        default:
            return .zhHans
        }
    }
}

public enum AppAppearance: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system:
            return "System"
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        }
    }

    public static func fromEnvironment(_ value: String?) -> AppAppearance {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !value.isEmpty else {
            return .system
        }

        switch value {
        case "light", "aqua":
            return .light
        case "dark", "dark-aqua", "darkaqua":
            return .dark
        case "system", "auto", "default", "macos", "mac":
            return .system
        default:
            return .system
        }
    }
}

public enum MonitorMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case user
    case admin

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .user:
            return "User"
        case .admin:
            return "Admin"
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let mode = MonitorMode(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid monitor mode: \(rawValue)"
            )
        }
        self = mode
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct MenuBarDateRange: Equatable, Sendable {
    public let start: String
    public let end: String

    public init(start: String, end: String) {
        self.start = start
        self.end = end
    }
}

public enum MenuBarUsageWindow: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    case last24Hours
    case today

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .last24Hours:
            return "Last 24 Hours"
        case .today:
            return "Today"
        }
    }

    public static func fromEnvironment(_ value: String?) -> MenuBarUsageWindow {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !value.isEmpty else {
            return .last24Hours
        }

        switch value {
        case "today":
            return .today
        case "last24hours", "last-24-hours", "last_24_hours", "24h", "last24h":
            return .last24Hours
        default:
            return .last24Hours
        }
    }

    public func dateRange(now: Date = Date(), calendar: Calendar = .current) -> MenuBarDateRange {
        let startDate: Date
        switch self {
        case .last24Hours:
            startDate = Date(timeInterval: -24 * 60 * 60, since: now)
        case .today:
            startDate = now
        }

        return MenuBarDateRange(
            start: Self.formatDate(startDate, calendar: calendar),
            end: Self.formatDate(now, calendar: calendar)
        )
    }

    private static func formatDate(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

public enum MenuBarDisplayItem: String, Codable, CaseIterable, Identifiable, Sendable, Hashable {
    case totalCost
    case totalRequests
    case model
    case reasoningEffort
    case contextLength
    case fast
    case inputPrice
    case outputPrice
    case rpm
    case realtimeConcurrency
    case normalAccounts

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .totalCost:
            return "Total Cost"
        case .totalRequests:
            return "Total Requests"
        case .model:
            return "Model"
        case .reasoningEffort:
            return "Reasoning Effort"
        case .contextLength:
            return "Context Length"
        case .fast:
            return "Fast Enabled"
        case .inputPrice:
            return "Input Price"
        case .outputPrice:
            return "Output Price"
        case .rpm:
            return "Realtime RPM"
        case .realtimeConcurrency:
            return "Realtime Concurrency"
        case .normalAccounts:
            return "Normal Accounts"
        }
    }

    public var isAdminOnly: Bool {
        switch self {
        case .realtimeConcurrency, .normalAccounts:
            return true
        default:
            return false
        }
    }

    public static let defaultSelection: [MenuBarDisplayItem] = [
        .totalCost,
        .model,
        .reasoningEffort,
        .contextLength,
        .fast,
        .rpm,
    ]

    public static var userVisibleCases: [MenuBarDisplayItem] {
        allCases.filter { !$0.isAdminOnly }
    }

    public static var adminVisibleCases: [MenuBarDisplayItem] {
        allCases
    }

    public static func fromEnvironment(_ value: String?) -> [MenuBarDisplayItem] {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return defaultSelection
        }

        let items = value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .compactMap(MenuBarDisplayItem.init(rawValue:))
        return items.isEmpty ? defaultSelection : items
    }
}

public struct AppConfig: Codable, Equatable, Sendable {
    public var baseURL: String
    public var authToken: String
    public var refreshToken: String
    public var refreshIntervalSeconds: Double
    public var language: AppLanguage
    public var appearance: AppAppearance
    public var monitorMode: MonitorMode
    public var showsMenuBarText: Bool
    public var launchAtLogin: Bool
    public var menuBarUsageWindow: MenuBarUsageWindow
    public var menuBarDisplayItems: [MenuBarDisplayItem]
    public var adminMonitoredUserID: Int64?

    public init(
        baseURL: String,
        authToken: String = "",
        refreshToken: String = "",
        refreshIntervalSeconds: Double = 15,
        language: AppLanguage = .zhHans,
        appearance: AppAppearance = .system,
        monitorMode: MonitorMode = .user,
        showsMenuBarText: Bool = false,
        launchAtLogin: Bool = false,
        menuBarUsageWindow: MenuBarUsageWindow = .last24Hours,
        menuBarDisplayItems: [MenuBarDisplayItem] = MenuBarDisplayItem.defaultSelection,
        adminMonitoredUserID: Int64? = nil
    ) {
        self.baseURL = baseURL
        self.authToken = authToken
        self.refreshToken = refreshToken
        self.refreshIntervalSeconds = refreshIntervalSeconds
        self.language = language
        self.appearance = appearance
        self.monitorMode = monitorMode
        self.showsMenuBarText = showsMenuBarText
        self.launchAtLogin = launchAtLogin
        self.menuBarUsageWindow = menuBarUsageWindow
        self.menuBarDisplayItems = menuBarDisplayItems
        self.adminMonitoredUserID = adminMonitoredUserID
        normalize()
    }

    private enum CodingKeys: String, CodingKey {
        case baseURL
        case authToken
        case refreshToken
        case refreshIntervalSeconds
        case language
        case appearance
        case monitorMode
        case showsMenuBarText
        case launchAtLogin
        case menuBarUsageWindow
        case menuBarDisplayItems
        case adminMonitoredUserID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? "http://127.0.0.1:8080"
        authToken = try container.decodeIfPresent(String.self, forKey: .authToken) ?? ""
        refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken) ?? ""
        refreshIntervalSeconds = try container.decodeIfPresent(Double.self, forKey: .refreshIntervalSeconds) ?? 15
        language = try container.decodeIfPresent(AppLanguage.self, forKey: .language) ?? .zhHans
        appearance = try container.decodeIfPresent(AppAppearance.self, forKey: .appearance) ?? .system
        monitorMode = try container.decodeIfPresent(MonitorMode.self, forKey: .monitorMode) ?? .user
        showsMenuBarText = try container.decodeIfPresent(Bool.self, forKey: .showsMenuBarText) ?? false
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        menuBarUsageWindow = try container.decodeIfPresent(MenuBarUsageWindow.self, forKey: .menuBarUsageWindow) ?? .last24Hours
        adminMonitoredUserID = try container.decodeIfPresent(Int64.self, forKey: .adminMonitoredUserID)
        if let rawItems = try container.decodeIfPresent([String].self, forKey: .menuBarDisplayItems) {
            menuBarDisplayItems = rawItems.compactMap(MenuBarDisplayItem.init(rawValue:))
        } else {
            menuBarDisplayItems = MenuBarDisplayItem.defaultSelection
        }
        normalize()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(refreshIntervalSeconds, forKey: .refreshIntervalSeconds)
        try container.encode(language, forKey: .language)
        try container.encode(appearance, forKey: .appearance)
        try container.encode(monitorMode, forKey: .monitorMode)
        try container.encode(showsMenuBarText, forKey: .showsMenuBarText)
        try container.encode(launchAtLogin, forKey: .launchAtLogin)
        try container.encode(menuBarUsageWindow, forKey: .menuBarUsageWindow)
        try container.encode(menuBarDisplayItems.map(\.rawValue), forKey: .menuBarDisplayItems)
        try container.encodeIfPresent(adminMonitoredUserID, forKey: .adminMonitoredUserID)
    }

    public static func defaults() -> AppConfig {
        let env = ProcessInfo.processInfo.environment
        return AppConfig(
            baseURL: env["SUB2API_BASE_URL"] ?? "http://127.0.0.1:8080",
            authToken: env["SUB2API_AUTH_TOKEN"] ?? "",
            refreshToken: env["SUB2API_REFRESH_TOKEN"] ?? "",
            refreshIntervalSeconds: Double(env["SUB2API_REFRESH_SECONDS"] ?? "") ?? 15,
            language: AppLanguage.fromEnvironment(env["SUB2API_LANGUAGE"]),
            appearance: AppAppearance.fromEnvironment(env["SUB2API_APPEARANCE"]),
            monitorMode: .user,
            showsMenuBarText: ["1", "true", "yes", "on"].contains((env["SUB2API_SHOW_MENU_BAR_TEXT"] ?? "").lowercased()),
            launchAtLogin: ["1", "true", "yes", "on"].contains((env["SUB2API_LAUNCH_AT_LOGIN"] ?? "").lowercased()),
            menuBarUsageWindow: MenuBarUsageWindow.fromEnvironment(env["SUB2API_MENU_BAR_USAGE_WINDOW"]),
            menuBarDisplayItems: MenuBarDisplayItem.fromEnvironment(env["SUB2API_MENU_BAR_ITEMS"])
        )
    }

    public mutating func normalize() {
        baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while baseURL.hasSuffix("/") {
            baseURL.removeLast()
        }
        if baseURL.hasSuffix("/api/v1") {
            baseURL.removeLast("/api/v1".count)
        }

        authToken = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        refreshToken = refreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
        refreshIntervalSeconds = min(max(refreshIntervalSeconds, 1), 300)
        if language == .auto {
            language = .zhHans
        }
        if monitorMode == .user {
            adminMonitoredUserID = nil
            menuBarDisplayItems.removeAll { $0.isAdminOnly }
        }
        var seen = Set<MenuBarDisplayItem>()
        menuBarDisplayItems = menuBarDisplayItems.filter { seen.insert($0).inserted }
    }

    public mutating func clearAuthTokens() {
        authToken = ""
        refreshToken = ""
    }

    public var apiBaseURL: URL? {
        var normalized = self
        normalized.normalize()
        return URL(string: normalized.baseURL)?
            .appendingPathComponent("api", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
    }
}

public struct StoredAuthTokens: Codable, Equatable, Sendable {
    public var authToken: String
    public var refreshToken: String

    public init(authToken: String = "", refreshToken: String = "") {
        self.authToken = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        self.refreshToken = refreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isEmpty: Bool {
        authToken.isEmpty && refreshToken.isEmpty
    }
}

public protocol TokenStore: Sendable {
    func loadTokens() -> StoredAuthTokens
    func saveTokens(_ tokens: StoredAuthTokens) throws
}

public final class ConfigStore: Sendable {
    private let configURL: URL
    private let tokenStore: any TokenStore

    public init(configURL: URL? = nil, tokenStore: any TokenStore = KeychainTokenStore()) {
        self.tokenStore = tokenStore
        if let configURL {
            self.configURL = configURL
            return
        }

        let baseDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
        self.configURL = baseDir
            .appendingPathComponent("Sub2APIStatusBar", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    public func load() -> AppConfig {
        let storedTokens = tokenStore.loadTokens()
        guard let data = try? Data(contentsOf: configURL),
              var decoded = try? JSONDecoder.sub2api.decode(AppConfig.self, from: data) else {
            var defaults = AppConfig.defaults()
            if !storedTokens.authToken.isEmpty {
                defaults.authToken = storedTokens.authToken
            }
            if !storedTokens.refreshToken.isEmpty {
                defaults.refreshToken = storedTokens.refreshToken
            }
            defaults.normalize()
            return defaults
        }

        let legacyTokens = StoredAuthTokens(authToken: decoded.authToken, refreshToken: decoded.refreshToken)
        var runtimeTokens = storedTokens
        if runtimeTokens.authToken.isEmpty {
            runtimeTokens.authToken = legacyTokens.authToken
        }
        if runtimeTokens.refreshToken.isEmpty {
            runtimeTokens.refreshToken = legacyTokens.refreshToken
        }

        if !legacyTokens.isEmpty {
            do {
                try tokenStore.saveTokens(runtimeTokens)
                decoded.authToken = runtimeTokens.authToken
                decoded.refreshToken = runtimeTokens.refreshToken
                try writeConfig(decoded)
            } catch {
                decoded.authToken = legacyTokens.authToken
                decoded.refreshToken = legacyTokens.refreshToken
            }
        } else if !runtimeTokens.isEmpty {
            decoded.authToken = runtimeTokens.authToken
            decoded.refreshToken = runtimeTokens.refreshToken
        }

        decoded.normalize()
        return decoded
    }

    public func save(_ config: AppConfig) throws {
        var normalized = config
        normalized.normalize()
        try tokenStore.saveTokens(StoredAuthTokens(authToken: normalized.authToken, refreshToken: normalized.refreshToken))
        try writeConfig(normalized)
    }

    private func writeConfig(_ config: AppConfig) throws {
        var normalized = config
        normalized.normalize()
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(normalized).write(to: configURL, options: .atomic)
    }
}
