import AppKit
import SwiftUI
import Sub2APIStatusCore

@main
enum Sub2APIStatusBarApp {
    private static var appDelegate: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        appDelegate = delegate
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let model = MonitorViewModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            setStatusImage("antenna.radiowaves.left.and.right", description: "Sub2API", fallbackTitle: " Sub2API")
            button.action = #selector(togglePopover)
            button.target = self
        }

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 520, height: 680)
        popover.delegate = self
        applyAppearance(model.config.appearance)
        popover.contentViewController = NSHostingController(
            rootView: MonitorPanel(model: model)
            .environment(\.appLanguage, model.config.language)
            .appAppearance(model.config.appearance)
            .tint(ClaudeTheme.accent)
        )

        model.onSnapshotChange = { [weak self] snapshot in
            self?.updateStatusItem(snapshot)
        }
        model.onAppearanceChange = { [weak self] appearance in
            self?.applyAppearance(appearance)
        }
        model.start()
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else {
            return
        }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            DispatchQueue.main.async { [weak self] in
                self?.popover.contentViewController?.view.window?.makeKey()
            }
        }
    }

    private func updateStatusItem(_ snapshot: MonitorSnapshot) {
        guard let button = statusItem?.button else {
            return
        }

        let strings = AppStrings(model.config.language)
        let localizedStatus = strings.statusLabel(for: snapshot)
        let presentation = snapshot.menuBarStatusPresentation(config: model.config)
        switch snapshot.severity {
        case .healthy:
            if presentation.hidesHealthyStatusImage {
                button.image = nil
            } else {
                setStatusImage("checkmark.circle", description: "Sub2API OK", fallbackTitle: " OK")
            }
        case .warning:
            setStatusImage("exclamationmark.triangle", description: "Sub2API Warning", fallbackTitle: " Warn")
        case .error:
            setStatusImage("xmark.octagon", description: "Sub2API Error", fallbackTitle: " Error")
        }
        button.imagePosition = .imageLeading
        if button.image == nil && presentation.title.isEmpty {
            button.title = " \(localizedStatus)"
        } else {
            button.title = presentation.title
        }

        if snapshot.connected {
            let summary = snapshot.menuBarSummary(config: model.config)
            button.toolTip = summary.isEmpty ? "Sub2API \(localizedStatus)" : "Sub2API \(localizedStatus) - \(summary)"
        } else {
            button.toolTip = "Sub2API \(localizedStatus)"
        }
    }

    private func setStatusImage(_ systemName: String, description: String, fallbackTitle: String) {
        guard let button = statusItem?.button else {
            return
        }

        if let image = NSImage(systemSymbolName: systemName, accessibilityDescription: description) {
            image.isTemplate = true
            button.image = image
            return
        }

        button.image = nil
        button.title = fallbackTitle
    }

    private func applyAppearance(_ appearance: AppAppearance) {
        let nsAppearance = appearance.nsAppearance
        NSApp.appearance = nsAppearance
        popover.appearance = nsAppearance
    }
}

@MainActor
final class MonitorViewModel: ObservableObject {
    @Published var config: AppConfig
    @Published var snapshot: MonitorSnapshot
    @Published var isRefreshing = false
    @Published var isLoggingIn = false
    @Published var loginEmail = ""
    @Published var loginPassword = ""
    @Published var settingsDraft: AppConfig
    @Published var settingsError: String?
    @Published var updateInfo: UpdateInfo?
    @Published var isCheckingForUpdates = false
    @Published var isInstallingUpdate = false
    @Published var updateStatusMessage: String?
    @Published var adminUsers: [AdminUserSummary] = []

    var onSnapshotChange: ((MonitorSnapshot) -> Void)?
    var onAppearanceChange: ((AppAppearance) -> Void)?

    private let store = ConfigStore()
    private let updateChecker = GitHubUpdateChecker()
    private let updateInstaller = AppUpdateInstaller()
    private let launchAtLoginManager = LaunchAtLoginManager(appBundleURL: Bundle.main.bundleURL)
    private var refreshTimer: Timer?
    private var settingsAutosaveTask: Task<Void, Never>?

    init() {
        var loaded = store.load()
        if loaded.launchAtLogin {
            do {
                try launchAtLoginManager.setEnabled(true)
            } catch {
                loaded.launchAtLogin = launchAtLoginManager.isEnabled
            }
        } else if launchAtLoginManager.isEnabled {
            loaded.launchAtLogin = true
        }
        config = loaded
        settingsDraft = loaded
        snapshot = .idle(mode: loaded.monitorMode)
    }

    func start() {
        refresh()
        scheduleTimer()
        checkForUpdates(silent: true)
    }

    func refresh() {
        Task {
            await refreshNow()
        }
    }

    func refreshNow() async {
        guard !isRefreshing else {
            return
        }

        if config.authToken.isEmpty {
            publish(.idle(mode: config.monitorMode))
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        let client = Sub2APIClient(config: config)
        do {
            publish(try await userSnapshot(client: client))
        } catch {
            if await refreshAuthTokenIfNeeded(after: error) {
                do {
                    publish(try await userSnapshot(client: Sub2APIClient(config: config)))
                    return
                } catch {
                    publishDisconnected(error)
                    return
                }
            }
            publishDisconnected(error)
        }
    }

    private func userSnapshot(client: Sub2APIClient) async throws -> MonitorSnapshot {
        let currentUser = try await client.currentUser().user
        if currentUser.isAdmin {
            return try await adminSnapshot(currentUser: currentUser, client: client)
        }

        clearAdminSettingsForNormalUserIfNeeded()
        async let summaryTask = client.subscriptionSummary()
        async let statsTask = client.usageDashboardStats()
        let timezone = TimeZone.current.identifier
        async let menuBarStatsTask = menuBarUsageStats(client: client, timezone: timezone)
        async let latestUsageTask = client.usageLogs(page: 1, pageSize: 1, sortBy: "created_at", sortOrder: "desc")
        let range = Self.lastSevenDayRange()
        async let trendTask = client.usageDashboardTrend(startDate: range.start, endDate: range.end, granularity: "day")
        async let modelsTask = client.usageDashboardModels(startDate: range.start, endDate: range.end)

        let summary = try await summaryTask
        let stats = try? await statsTask
        let menuBarStats = try? await menuBarStatsTask
        let latestUsage = try? await latestUsageTask
        let trend = try? await trendTask
        let models = try? await modelsTask
        return MonitorSnapshot(
            mode: .user,
            connected: true,
            currentUser: currentUser,
            stats: stats,
            menuBarUsageStats: menuBarStats,
            latestUsage: latestUsage?.items.first,
            trend: trend?.trend,
            modelDistribution: models?.models,
            realtime: nil,
            monitoredUser: nil,
            realtimeConcurrency: nil,
            adminDashboardStats: nil,
            accountHealth: nil,
            subscriptionSummary: summary,
            lastUpdatedAt: Date(),
            message: nil
        )
    }

    private func adminSnapshot(currentUser: CurrentUser, client: Sub2APIClient) async throws -> MonitorSnapshot {
        let timezone = TimeZone.current.identifier
        let selectedUserID = config.adminMonitoredUserID ?? currentUser.id

        async let usersTask = client.allAdminUsers()
        async let selectedUserTask = client.adminUser(id: selectedUserID)
        async let concurrencyTask = client.adminUserConcurrencyStats()
        async let adminStatsTask = client.adminDashboardStats()
        async let menuBarStatsTask = adminMenuBarUsageStats(client: client, userID: selectedUserID, timezone: timezone)
        async let latestUsageTask = client.adminUsageLogs(userID: selectedUserID, page: 1, pageSize: 1, sortBy: "created_at", sortOrder: "desc", timezone: timezone)
        let today = Self.todayString()
        let range = Self.lastSevenDayRange()
        async let dayStatsTask = client.adminUsageStats(userID: selectedUserID, startDate: today, endDate: today, timezone: timezone)
        async let trendTask = client.adminDashboardTrend(userID: selectedUserID, startDate: range.start, endDate: range.end, granularity: "day", timezone: timezone)
        async let modelsTask = client.adminDashboardModels(userID: selectedUserID, startDate: range.start, endDate: range.end, timezone: timezone)
        async let subscriptionsTask = client.adminUserSubscriptions(userID: selectedUserID)

        var messages: [String] = []

        do {
            adminUsers = try await usersTask
        } catch {
            adminUsers = []
            messages.append(error.localizedDescription)
        }

        let target: AdminUserSummary
        do {
            target = try await selectedUserTask
        } catch {
            _ = try? await concurrencyTask
            _ = try? await adminStatsTask
            _ = try? await menuBarStatsTask
            _ = try? await latestUsageTask
            _ = try? await dayStatsTask
            _ = try? await trendTask
            _ = try? await modelsTask
            _ = try? await subscriptionsTask
            throw error
        }

        let adminStats: AdminDashboardStats?
        do {
            adminStats = try await adminStatsTask
        } catch {
            adminStats = nil
            messages.append(error.localizedDescription)
        }

        let concurrency: UserRealtimeConcurrency?
        do {
            let stats = try await concurrencyTask
            concurrency = stats.concurrency(
                forUserID: target.id,
                userEmail: target.email,
                username: target.username,
                maxCapacity: target.concurrency
            )
            if concurrency == nil {
                messages.append(AppStrings(config.language).phrase("实时并发监控未启用。", "Realtime concurrency monitoring is disabled."))
            }
        } catch {
            concurrency = nil
            messages.append(error.localizedDescription)
        }

        let dayStats = try? await dayStatsTask
        let menuBarStats = try? await menuBarStatsTask
        let latestUsage = try? await latestUsageTask
        let trend = try? await trendTask
        let models = try? await modelsTask
        let subscriptions = try? await subscriptionsTask
        return MonitorSnapshot(
            mode: .admin,
            connected: true,
            currentUser: currentUser,
            stats: dayStats.map(DashboardStats.init(monitoredUsageStats:)),
            menuBarUsageStats: menuBarStats,
            latestUsage: latestUsage?.items.first,
            trend: trend?.trend,
            modelDistribution: models?.models,
            realtime: nil,
            monitoredUser: target,
            realtimeConcurrency: concurrency,
            adminDashboardStats: adminStats,
            accountHealth: nil,
            subscriptionSummary: subscriptions.map { SubscriptionSummary(adminSubscriptions: $0) },
            lastUpdatedAt: Date(),
            message: messages.first
        )
    }

    private func clearAdminSettingsForNormalUserIfNeeded() {
        guard config.monitorMode != .user ||
              config.adminMonitoredUserID != nil ||
              config.menuBarDisplayItems.contains(where: \.isAdminOnly) else {
            return
        }

        var next = config
        next.monitorMode = .user
        next.adminMonitoredUserID = nil
        next.menuBarDisplayItems.removeAll { $0.isAdminOnly }
        do {
            try store.save(next)
            config = next
            settingsDraft = next
        } catch {
            settingsError = error.localizedDescription
        }
    }

    private func menuBarUsageStats(client: Sub2APIClient, timezone: String, now: Date = Date()) async throws -> UsagePeriodStats {
        let range = config.menuBarUsageWindow.dateRange(now: now)
        return try await client.usageStats(startDate: range.start, endDate: range.end, timezone: timezone)
    }

    private func adminMenuBarUsageStats(client: Sub2APIClient, userID: Int64, timezone: String, now: Date = Date()) async throws -> UsagePeriodStats {
        let range = config.menuBarUsageWindow.dateRange(now: now)
        return try await client.adminUsageStats(userID: userID, startDate: range.start, endDate: range.end, timezone: timezone)
    }

    private func refreshAuthTokenIfNeeded(after error: Error) async -> Bool {
        guard let apiError = error as? Sub2APIError,
              apiError.isUnauthorized,
              !config.refreshToken.isEmpty else {
            return false
        }

        var refreshConfig = config
        refreshConfig.authToken = ""
        do {
            let response = try await Sub2APIClient(config: refreshConfig).refreshToken(config.refreshToken)
            var next = config
            next.authToken = response.accessToken
            next.refreshToken = response.refreshToken ?? config.refreshToken
            try store.save(next)
            config = next
            settingsDraft = next
            return true
        } catch {
            return false
        }
    }

    private func publishDisconnected(_ error: Error) {
        publish(MonitorSnapshot(
            mode: config.monitorMode,
            connected: false,
            stats: nil,
            realtime: nil,
            accountHealth: nil,
            subscriptionSummary: nil,
            lastUpdatedAt: snapshot.lastUpdatedAt,
            message: error.localizedDescription
        ))
    }

    @discardableResult
    func saveSettings() -> Bool {
        persistSettingsDraft(refreshAfterSave: true)
    }

    func applySettingsChange(refreshAfterSave: Bool = true, _ change: (inout AppConfig) -> Void) {
        settingsAutosaveTask?.cancel()
        settingsError = nil
        change(&settingsDraft)
        persistSettingsDraft(refreshAfterSave: refreshAfterSave)
    }

    func scheduleSettingsAutosave(refreshAfterSave: Bool = false) {
        settingsAutosaveTask?.cancel()
        settingsAutosaveTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 550_000_000)
            } catch {
                return
            }
            self?.persistSettingsDraft(refreshAfterSave: refreshAfterSave)
        }
    }

    @discardableResult
    private func persistSettingsDraft(refreshAfterSave: Bool) -> Bool {
        settingsError = nil
        var next = settingsDraft
        next.normalize()
        settingsDraft = next
        let previousConfig = config
        let previousLaunchAtLogin = launchAtLoginManager.isEnabled
        do {
            try launchAtLoginManager.setEnabled(next.launchAtLogin)
            do {
                try store.save(next)
            } catch {
                try? launchAtLoginManager.setEnabled(previousLaunchAtLogin)
                throw error
            }
            config = next
            settingsDraft = next
            relocalizeUpdateStatusIfNeeded(previousLanguage: previousConfig.language, nextLanguage: next.language)
            scheduleTimer()
            onSnapshotChange?(snapshot)
            onAppearanceChange?(next.appearance)
            if refreshAfterSave {
                refresh()
            }
            return true
        } catch {
            settingsError = error.localizedDescription
            return false
        }
    }

    private func relocalizeUpdateStatusIfNeeded(previousLanguage: AppLanguage, nextLanguage: AppLanguage) {
        guard previousLanguage != nextLanguage,
              let info = updateInfo else {
            return
        }

        let previousStatus = AppStrings(previousLanguage).updateStatus(info)
        guard updateStatusMessage == nil ||
              updateStatusMessage == previousStatus ||
              updateStatusMessage == info.statusText else {
            return
        }
        updateStatusMessage = AppStrings(nextLanguage).updateStatus(info)
    }

    func disconnect() {
        settingsError = nil
        var next = config
        next.clearAuthTokens()
        do {
            try store.save(next)
            config = next
            settingsDraft = next
            loginEmail = ""
            loginPassword = ""
            publish(.idle(mode: next.monitorMode))
        } catch {
            settingsError = error.localizedDescription
        }
    }

    func loginAndSave() {
        settingsError = nil
        var draft = settingsDraft
        draft.authToken = ""
        let client = Sub2APIClient(config: draft)
        Task { @MainActor in
            isLoggingIn = true
            do {
                let response = try await client.login(email: loginEmail, password: loginPassword)
                settingsDraft.authToken = response.accessToken
                settingsDraft.refreshToken = response.refreshToken ?? ""
                loginPassword = ""
                saveSettings()
            } catch {
                settingsError = error.localizedDescription
            }
            isLoggingIn = false
        }
    }

    func resetSettingsDraftFromConfig() {
        guard settingsDraft != config else {
            return
        }
        settingsDraft = config
    }

    func openDashboard() {
        openURL(config.baseURL)
    }

    func checkForUpdates(silent: Bool = false) {
        Task {
            await checkForUpdatesNow(silent: silent)
        }
    }

    func checkForUpdatesNow(silent: Bool = false) async {
        guard !isCheckingForUpdates else {
            return
        }

        isCheckingForUpdates = true
        if !silent {
            updateStatusMessage = nil
        }
        defer { isCheckingForUpdates = false }

        do {
            let info = try await updateChecker.check(currentVersion: currentAppVersion)
            updateInfo = info
            if info.isUpdateAvailable || !silent {
                updateStatusMessage = AppStrings(config.language).updateStatus(info)
            }
        } catch {
            if !silent {
                updateStatusMessage = error.localizedDescription
            }
        }
    }

    func openLatestRelease() {
        if let releaseURL = updateInfo?.latestRelease.releaseURL {
            NSWorkspace.shared.open(releaseURL)
            return
        }
        openURL("https://github.com/\(AppBuildInfo.repositoryOwner)/\(AppBuildInfo.repositoryName)/releases")
    }

    func installUpdate() {
        Task {
            await installUpdateNow()
        }
    }

    func installUpdateNow() async {
        guard !isInstallingUpdate else {
            return
        }
        guard let info = updateInfo, info.isUpdateAvailable else {
            updateStatusMessage = AppStrings(config.language).phrase("没有可用更新。", "No update is available.")
            return
        }
        guard info.latestRelease.installArchiveAsset() != nil else {
            updateStatusMessage = AppUpdateInstallerError.missingInstallArchiveAsset.localizedDescription
            return
        }

        let currentAppURL = Bundle.main.bundleURL
        guard currentAppURL.pathExtension == "app" else {
            updateStatusMessage = AppStrings(config.language).phrase("直接更新需要已打包的 App。", "Direct update requires the packaged app bundle.")
            return
        }

        isInstallingUpdate = true
        updateStatusMessage = AppStrings(config.language).phrase("正在下载更新...", "Downloading update...")

        do {
            let bundleIdentifier = Bundle.main.bundleIdentifier ?? AppBuildInfo.bundleIdentifier
            let prepared = try await updateInstaller.downloadAndExtract(
                release: info.latestRelease,
                expectedBundleIdentifier: bundleIdentifier
            )
            updateStatusMessage = AppStrings(config.language).phrase("正在安装更新，应用将重新启动。", "Installing update. The app will restart.")
            try updateInstaller.startInstall(
                extractedAppURL: prepared.appURL,
                targetAppURL: currentAppURL,
                currentProcessID: ProcessInfo.processInfo.processIdentifier
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NSApp.terminate(nil)
            }
        } catch {
            isInstallingUpdate = false
            updateStatusMessage = error.localizedDescription
        }
    }

    func openURL(_ value: String) {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func quit() {
        NSApp.terminate(nil)
    }

    private func publish(_ next: MonitorSnapshot) {
        snapshot = next
        onSnapshotChange?(next)
    }

    private var currentAppVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? AppBuildInfo.fallbackVersion
    }

    private func scheduleTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: config.refreshIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    private static func lastSevenDayRange() -> (start: String, end: String) {
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return (formatter.string(from: start), formatter.string(from: today))
    }

    private static func todayString() -> String {
        lastSevenDayRange().end
    }
}

struct MonitorPanel: View {
    @ObservedObject var model: MonitorViewModel
    @State private var selectedPage: PanelPage = .overview

    var body: some View {
        Group {
            if model.config.authToken.isEmpty {
                LoginPanel(model: model)
            } else {
                VStack(spacing: 0) {
                    header
                    Divider()

                    content

                    Divider()
                    PanelFooter(model: model, strings: strings)
                }
            }
        }
        .frame(width: 520, height: 680)
        .background(PanelBackground())
        .environment(\.appLanguage, model.config.language)
        .appAppearance(activeAppearance)
    }

    private var header: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(iconColor.opacity(0.13))
                    Image(systemName: iconName)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(iconColor)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Sub2API")
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                    Text(model.snapshot.connected ? lastUpdatedText : strings.phrase("未连接", "Disconnected"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    model.refresh()
                } label: {
                    Image(systemName: model.isRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                }
                .disabled(model.isRefreshing)
                .help(strings.phrase("刷新", "Refresh"))
            }
            .buttonStyle(.borderless)

            PanelPageTabs(selection: $selectedPage, strings: strings)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .background(ClaudeTheme.header)
    }

    @ViewBuilder
    private var content: some View {
        switch selectedPage {
        case .overview:
            overviewContent
        case .settings:
            SettingsView(model: model)
        }
    }

    private var overviewContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                statusSection

                if let updateInfo = model.updateInfo, updateInfo.isUpdateAvailable {
                    UpdateAvailableBanner(
                        info: updateInfo,
                        isInstalling: model.isInstallingUpdate,
                        statusMessage: model.updateStatusMessage,
                        installUpdate: {
                            model.installUpdate()
                        },
                        openRelease: {
                            model.openLatestRelease()
                        }
                    )
                }

                userSection

                if let message = model.snapshot.message, !message.isEmpty {
                    MessageRow(message: message)
                }
            }
            .padding(16)
        }
    }

    private var statusSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(strings.phrase("状态概览", "Status Overview"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(strings.statusLabel(for: model.snapshot))
                            .font(.system(size: 32, weight: .semibold, design: .rounded))
                            .foregroundStyle(iconColor)
                    }
                    Spacer()
                    Text(statusScopeLabel)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(iconColor.opacity(0.16), in: Capsule())
                        .foregroundStyle(iconColor)
                }

                if model.config.authToken.isEmpty {
                    Text(strings.phrase("设置服务地址和令牌后开始监控。", "Set Base URL and token to start monitoring."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text(model.snapshot.connected ? strings.phrase("监控已连接，数据会按刷新间隔自动更新。", "Monitoring is connected and updates on your refresh interval.") : strings.phrase("当前无法连接服务，检查网络或登录状态。", "The server is not reachable. Check network or login state."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var userSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let user = model.snapshot.currentUser {
                UserAccountCard(user: user)
            }

            if model.snapshot.mode == .admin,
               let monitoredUser = model.snapshot.monitoredUser {
                MonitoredUserCard(user: monitoredUser, concurrency: model.snapshot.realtimeConcurrency)
            }

            if let stats = model.snapshot.stats {
                MetricGrid(items: primaryMetrics(stats: stats))
            }

            if let summary = model.snapshot.subscriptionSummary {
                if model.snapshot.stats == nil {
                    MetricGrid(items: fallbackMetrics(summary: summary))
                }

                SubscriptionSection(summary: summary)
            }

            if let models = model.snapshot.modelDistribution, !models.isEmpty {
                ModelDistributionView(models: models)
            }

            if let trend = model.snapshot.trend, trend.count > 1 {
                SectionBlock(title: strings.phrase("Token 趋势", "Token Trend")) {
                    TokenTrendView(points: trend)
                        .frame(height: 150)
                }
            }
        }
    }

    private func primaryMetrics(stats: DashboardStats) -> [MetricItem] {
        var items: [MetricItem] = []
        if let concurrency = model.snapshot.realtimeConcurrency {
            items.append(realtimeConcurrencyMetric(concurrency))
        }
        if let adminStats = model.snapshot.adminDashboardStats {
            items.append(normalAccountsMetric(adminStats))
        }
        items.append(contentsOf: [
            MetricItem(title: strings.phrase("余额", "Balance"), value: balanceText, caption: strings.phrase("可用", "Available"), systemImage: "banknote", tint: ClaudeTheme.accent),
            userAPIKeysMetric(stats),
            MetricItem(title: strings.phrase("今日请求", "Today Requests"), value: StatusFormatters.menuBarCount(stats.todayRequests), caption: requestCaption(stats), systemImage: "chart.bar", tint: ClaudeTheme.accent),
            MetricItem(title: strings.phrase("今日费用", "Today Cost"), value: StatusFormatters.preciseCurrency(stats.todayActualCost), caption: costCaption(stats), systemImage: "dollarsign.circle", tint: ClaudeTheme.gold),
            MetricItem(title: strings.phrase("今日 Token", "Today Tokens"), value: StatusFormatters.compactNumber(stats.todayTokens), caption: tokenBreakdown(input: stats.todayInputTokens, output: stats.todayOutputTokens), systemImage: "cube", tint: ClaudeTheme.warm),
            MetricItem(title: totalTokenTitle, value: StatusFormatters.compactNumber(stats.totalTokens), caption: tokenBreakdown(input: stats.totalInputTokens, output: stats.totalOutputTokens), systemImage: "archivebox.fill", tint: ClaudeTheme.ink),
            performanceMetric(stats),
            MetricItem(title: strings.phrase("平均响应", "Avg Response"), value: latencyText(milliseconds: stats.averageDurationMs), caption: strings.phrase("平均耗时", "Average time"), systemImage: "clock", tint: ClaudeTheme.danger),
        ].compactMap { $0 })
        return items
    }

    private func fallbackMetrics(summary: SubscriptionSummary) -> [MetricItem] {
        var items: [MetricItem] = []
        if let concurrency = model.snapshot.realtimeConcurrency {
            items.append(realtimeConcurrencyMetric(concurrency))
        }
        if let adminStats = model.snapshot.adminDashboardStats {
            items.append(normalAccountsMetric(adminStats))
        }
        items.append(contentsOf: [
            MetricItem(title: strings.phrase("余额", "Balance"), value: balanceText, systemImage: "banknote", tint: ClaudeTheme.accent),
            MetricItem(title: strings.phrase("活跃订阅", "Active Subs"), value: "\(summary.activeCount)", systemImage: "checkmark.seal", tint: ClaudeTheme.accent),
            MetricItem(title: strings.phrase("峰值用量", "Peak Usage"), value: StatusFormatters.percent(summary.highestProgress), systemImage: "gauge.with.dots.needle.67percent", tint: ClaudeTheme.warning),
            MetricItem(title: strings.phrase("已用总额", "Total Used"), value: StatusFormatters.preciseCurrency(summary.totalUsedUSD), systemImage: "dollarsign.circle", tint: ClaudeTheme.gold),
        ])
        return items
    }

    private func realtimeConcurrencyMetric(_ concurrency: UserRealtimeConcurrency) -> MetricItem {
        MetricItem(
            title: strings.phrase("实时并发", "Realtime Concurrency"),
            value: StatusFormatters.menuBarCount(concurrency.currentInUse),
            caption: strings.phrase(
                "等待 \(concurrency.waitingInQueue) / 上限 \(concurrency.maxCapacity)",
                "Waiting \(concurrency.waitingInQueue) / Cap \(concurrency.maxCapacity)"
            ),
            systemImage: "arrow.triangle.2.circlepath.circle",
            tint: ClaudeTheme.warning
        )
    }

    private func normalAccountsMetric(_ stats: AdminDashboardStats) -> MetricItem {
        MetricItem(
            title: strings.phrase("正常账号", "Normal Accounts"),
            value: StatusFormatters.menuBarCount(Int64(stats.normalAccounts)),
            caption: strings.phrase(
                "总计 \(stats.totalAccounts) / 异常 \(stats.errorAccounts + stats.ratelimitAccounts + stats.overloadAccounts)",
                "Total \(stats.totalAccounts) / Other \(stats.errorAccounts + stats.ratelimitAccounts + stats.overloadAccounts)"
            ),
            systemImage: "checkmark.seal",
            tint: ClaudeTheme.success
        )
    }

    private var iconName: String {
        switch model.snapshot.severity {
        case .healthy:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .error:
            return "xmark.octagon.fill"
        }
    }

    private var iconColor: Color {
        switch model.snapshot.severity {
        case .healthy:
            return ClaudeTheme.success
        case .warning:
            return ClaudeTheme.warning
        case .error:
            return ClaudeTheme.danger
        }
    }

    private var lastUpdatedText: String {
        strings.updated(at: model.snapshot.lastUpdatedAt)
    }

    private var balanceText: String {
        let balance: Double?
        if model.snapshot.mode == .admin,
           let monitoredUser = model.snapshot.monitoredUser {
            balance = monitoredUser.balance
        } else {
            balance = model.snapshot.currentUser?.balance
        }

        guard let balance else {
            return "--"
        }
        return StatusFormatters.currency(balance)
    }

    private var statusScopeLabel: String {
        if model.snapshot.mode == .admin {
            return strings.phrase("管理员监控", "Admin Monitor")
        }
        return strings.phrase("用户用量", "User Usage")
    }

    private var totalTokenTitle: String {
        if model.snapshot.mode == .admin {
            return strings.phrase("窗口 Token", "Window Tokens")
        }
        return strings.phrase("总 Token", "Total Tokens")
    }

    private func userAPIKeysMetric(_ stats: DashboardStats) -> MetricItem? {
        guard model.snapshot.mode != .admin else {
            return nil
        }
        return MetricItem(title: "API Keys", value: "\(stats.totalAPIKeys)", caption: strings.phrase("\(stats.activeAPIKeys) 个活跃", "\(stats.activeAPIKeys) active"), systemImage: "key", tint: ClaudeTheme.slate)
    }

    private func performanceMetric(_ stats: DashboardStats) -> MetricItem? {
        guard model.snapshot.mode != .admin else {
            return nil
        }
        return MetricItem(title: strings.phrase("性能", "Performance"), value: "\(StatusFormatters.menuBarRate(stats.rpm)) RPM", caption: "\(StatusFormatters.compactNumber(Int64(stats.tpm))) TPM", systemImage: "bolt", tint: ClaudeTheme.gold)
    }

    private func requestCaption(_ stats: DashboardStats) -> String {
        if model.snapshot.mode == .admin {
            return strings.phrase("所选用户", "Selected user")
        }
        return strings.phrase("总计 \(StatusFormatters.compactNumber(stats.totalRequests))", "Total \(StatusFormatters.compactNumber(stats.totalRequests))")
    }

    private func costCaption(_ stats: DashboardStats) -> String {
        if model.snapshot.mode == .admin {
            return strings.phrase("所选用户", "Selected user")
        }
        return strings.phrase("总计 \(StatusFormatters.preciseCurrency(stats.totalActualCost))", "Total \(StatusFormatters.preciseCurrency(stats.totalActualCost))")
    }

    private func tokenBreakdown(input: Int64, output: Int64) -> String {
        strings.phrase(
            "入 \(StatusFormatters.compactNumber(input)) / 出 \(StatusFormatters.compactNumber(output))",
            "In \(StatusFormatters.compactNumber(input)) / Out \(StatusFormatters.compactNumber(output))"
        )
    }

    private func latencyText(milliseconds: Double) -> String {
        if milliseconds >= 1_000 {
            return String(format: "%.2fs", milliseconds / 1_000)
        }
        return "\(Int(milliseconds))ms"
    }

    private var strings: AppStrings {
        AppStrings(model.config.language)
    }

    private var activeAppearance: AppAppearance {
        model.config.authToken.isEmpty ? model.settingsDraft.appearance : model.config.appearance
    }
}

private struct PanelFooter: View {
    @ObservedObject var model: MonitorViewModel
    let strings: AppStrings

    var body: some View {
        HStack(spacing: 12) {
            Button {
                model.openDashboard()
            } label: {
                Label(strings.phrase("打开控制台", "Open"), systemImage: "safari")
            }
            .disabled(model.config.baseURL.isEmpty)

            Spacer()

            Button {
                model.quit()
            } label: {
                Label(strings.phrase("退出", "Quit"), systemImage: "power")
            }
        }
        .buttonStyle(.borderless)
        .padding(12)
        .background(ClaudeTheme.footer)
    }
}

private enum PanelPage: String, CaseIterable, Identifiable, Equatable {
    case overview
    case settings

    var id: String { rawValue }

    func title(strings: AppStrings) -> String {
        switch self {
        case .overview:
            return strings.phrase("概览", "Overview")
        case .settings:
            return strings.phrase("设置", "Settings")
        }
    }
}

private struct PanelPageTabs: View {
    @Binding var selection: PanelPage
    let strings: AppStrings
    @State private var hoveredPage: PanelPage?

    private let tabHeight: CGFloat = 34
    private let cornerRadius: CGFloat = 10

    var body: some View {
        HStack(spacing: 6) {
            ForEach(PanelPage.allCases) { page in
                tabButton(for: page)
            }
        }
        .padding(4)
        .frame(height: tabHeight + 8)
        .background(ClaudeTheme.tabBackground, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(ClaudeTheme.border, lineWidth: 1)
        )
        .fixedSize(horizontal: false, vertical: true)
        .animation(.easeOut(duration: 0.16), value: selection)
        .animation(.easeOut(duration: 0.12), value: hoveredPage)
    }

    private func tabButton(for page: PanelPage) -> some View {
        let isSelected = selection == page
        let isHovered = hoveredPage == page

        return Button {
            guard selection != page else {
                return
            }
            selection = page
        } label: {
            Text(page.title(strings: strings))
                .font(.callout.weight(.semibold))
                .foregroundStyle(isSelected ? ClaudeTheme.primaryText : ClaudeTheme.secondaryText)
                .frame(maxWidth: .infinity)
                .frame(height: tabHeight)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(tabFill(isSelected: isSelected, isHovered: isHovered))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(isSelected ? ClaudeTheme.border : Color.clear, lineWidth: 1)
                )
                .overlay(alignment: .bottom) {
                    if isSelected {
                        Capsule()
                            .fill(ClaudeTheme.accent.opacity(0.72))
                            .frame(width: 26, height: 2)
                            .padding(.bottom, 4)
                    }
                }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .onHover { isHovered in
            hoveredPage = isHovered ? page : nil
        }
        .accessibilityLabel(page.title(strings: strings))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func tabFill(isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected {
            return ClaudeTheme.tabSelected
        }
        if isHovered {
            return ClaudeTheme.elevatedCard.opacity(0.55)
        }
        return .clear
    }
}

struct LoginPanel: View {
    @ObservedObject var model: MonitorViewModel
    @FocusState private var focusedField: LoginField?

    private var formState: LoginFormState {
        LoginFormState(
            baseURL: model.settingsDraft.baseURL,
            email: model.loginEmail,
            password: model.loginPassword
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(ClaudeTheme.accent.opacity(0.16))
                    Image(systemName: "antenna.radiowaves.left.and.right.circle.fill")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(ClaudeTheme.accent)
                }
                .frame(width: 54, height: 54)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Sub2API")
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                    Text(strings.phrase("连接你的服务", "Connect your server"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    Picker(strings.phrase("语言", "Language"), selection: languageBinding) {
                        ForEach([AppLanguage.zhHans, .en]) { language in
                            Text(strings.languageName(language)).tag(language)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker(strings.phrase("外观", "Appearance"), selection: appearanceBinding) {
                        ForEach(AppAppearance.allCases) { appearance in
                            Text(strings.appearanceName(appearance)).tag(appearance)
                        }
                    }
                    .pickerStyle(.segmented)

                    TextField(strings.phrase("服务地址", "Server URL"), text: $model.settingsDraft.baseURL)
                        .themedTextField()
                        .focused($focusedField, equals: .baseURL)
                        .onChange(of: model.settingsDraft.baseURL) { _ in
                            model.scheduleSettingsAutosave(refreshAfterSave: false)
                        }

                    TextField(strings.phrase("账号", "Account"), text: $model.loginEmail)
                        .themedTextField()
                        .focused($focusedField, equals: .email)

                    SecureField(strings.phrase("密码", "Password"), text: $model.loginPassword)
                        .themedTextField()
                        .focused($focusedField, equals: .password)

                    HStack {
                        Text(strings.phrase("刷新", "Refresh"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Slider(value: $model.settingsDraft.refreshIntervalSeconds, in: 1...300, step: 1)
                            .onChange(of: model.settingsDraft.refreshIntervalSeconds) { _ in
                                model.scheduleSettingsAutosave(refreshAfterSave: false)
                            }
                        Text("\(Int(model.settingsDraft.refreshIntervalSeconds))s")
                            .font(.callout.monospacedDigit())
                            .frame(width: 42, alignment: .trailing)
                    }
                }
            }

            if let error = model.settingsError {
                MessageRow(message: error)
            }

            Button {
                model.loginAndSave()
            } label: {
                HStack {
                    if model.isLoggingIn {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "key.fill")
                    }
                    Text(model.isLoggingIn ? strings.phrase("连接中...", "Connecting...") : strings.phrase("登录", "Login"))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!formState.canSubmit || model.isLoggingIn)

            GlassCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text(strings.phrase("手动令牌", "Manual token"))
                        .font(.headline)
                    SecureField("Bearer Token", text: $model.settingsDraft.authToken)
                        .themedTextField()
                        .focused($focusedField, equals: .authToken)
                        .onChange(of: model.settingsDraft.authToken) { _ in
                            model.scheduleSettingsAutosave(refreshAfterSave: false)
                        }
                    Button {
                        model.saveSettings()
                    } label: {
                        Label(strings.phrase("保存令牌", "Save Token"), systemImage: "square.and.arrow.down")
                    }
                    .disabled(model.settingsDraft.authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            Spacer()

            HStack {
                Button {
                    model.openURL(model.settingsDraft.baseURL)
                } label: {
                    Label(strings.phrase("打开服务", "Open Server"), systemImage: "safari")
                }
                .disabled(model.settingsDraft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Spacer()

                Button {
                    model.quit()
                } label: {
                    Label(strings.phrase("退出", "Quit"), systemImage: "power")
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(20)
        .frame(width: 520, height: 680)
        .background(PanelBackground())
        .environment(\.appLanguage, model.settingsDraft.language)
        .appAppearance(model.settingsDraft.appearance)
        .onAppear {
            DispatchQueue.main.async {
                focusedField = model.settingsDraft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .baseURL : .email
            }
        }
    }

    private var strings: AppStrings {
        AppStrings(model.settingsDraft.language)
    }

    private var languageBinding: Binding<AppLanguage> {
        Binding(
            get: { model.settingsDraft.language },
            set: { value in
                model.applySettingsChange(refreshAfterSave: false) { $0.language = value }
            }
        )
    }

    private var appearanceBinding: Binding<AppAppearance> {
        Binding(
            get: { model.settingsDraft.appearance },
            set: { value in
                model.applySettingsChange(refreshAfterSave: false) { $0.appearance = value }
            }
        )
    }
}

struct SettingsView: View {
    @ObservedObject var model: MonitorViewModel
    @FocusState private var focusedField: SettingsField?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                settingsHeader

                settingsFields

                UpdateSettingsSection(model: model)

                loginSection

                if let error = model.settingsError {
                    MessageRow(message: error)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .environment(\.appLanguage, model.settingsDraft.language)
        .appAppearance(model.settingsDraft.appearance)
        .onChange(of: focusedField) { focus in
            if focus == nil {
                model.scheduleSettingsAutosave(refreshAfterSave: true)
            }
        }
    }

    private var settingsHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(ClaudeTheme.accent.opacity(0.16))
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.accent)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text(strings.phrase("设置", "Settings"))
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                Text(strings.phrase("语言、外观、连接、菜单栏显示和更新在同一控制台中管理。", "Manage language, appearance, connection, menu bar display, and updates in this console."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var settingsFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(strings.phrase("基础", "General"))
                        .font(.headline)

                    settingsRow(strings.phrase("语言", "Language")) {
                        Picker("", selection: languageBinding) {
                            ForEach([AppLanguage.zhHans, .en]) { language in
                                Text(strings.languageName(language)).tag(language)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }

                    settingsRow(strings.phrase("外观", "Appearance")) {
                        Picker("", selection: appearanceBinding) {
                            ForEach(AppAppearance.allCases) { appearance in
                                Text(strings.appearanceName(appearance)).tag(appearance)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }

                    settingsRow("Base URL") {
                        TextField("https://codex.lyhbio.cn", text: $model.settingsDraft.baseURL)
                            .themedTextField()
                            .focused($focusedField, equals: .baseURL)
                            .onChange(of: model.settingsDraft.baseURL) { _ in
                                model.scheduleSettingsAutosave(refreshAfterSave: false)
                            }
                    }

                    settingsRow(strings.phrase("刷新", "Refresh")) {
                        HStack {
                            Slider(value: $model.settingsDraft.refreshIntervalSeconds, in: 1...300, step: 1)
                                .onChange(of: model.settingsDraft.refreshIntervalSeconds) { _ in
                                    model.scheduleSettingsAutosave(refreshAfterSave: false)
                                }
                            Text("\(Int(model.settingsDraft.refreshIntervalSeconds))s")
                                .font(.callout.monospacedDigit())
                                .frame(width: 42, alignment: .trailing)
                        }
                    }

                    settingsRow("Bearer Token") {
                        SecureField("", text: $model.settingsDraft.authToken)
                            .themedTextField()
                            .focused($focusedField, equals: .authToken)
                            .onChange(of: model.settingsDraft.authToken) { _ in
                                model.scheduleSettingsAutosave(refreshAfterSave: false)
                            }
                    }
                }
            }

            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(strings.phrase("菜单栏", "Menu Bar"))
                        .font(.headline)

                    Toggle(strings.phrase("在菜单栏显示文字", "Show text in menu bar"), isOn: showsMenuBarTextBinding)

                    settingsRow(strings.phrase("统计窗口", "Usage window")) {
                        Picker("", selection: menuBarUsageWindowBinding) {
                            ForEach(MenuBarUsageWindow.allCases) { window in
                                Text(strings.usageWindowName(window)).tag(window)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }

                    VStack(alignment: .leading, spacing: 9) {
                        Text(strings.phrase("显示项目", "Menu bar items"))
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                            ForEach(availableMenuBarDisplayItems) { item in
                                Toggle(strings.menuBarItemName(item), isOn: menuBarItemBinding(item))
                            }
                        }
                    }
                }
            }

            if isAdminAccount {
                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(strings.phrase("管理员监控", "Admin Monitoring"))
                            .font(.headline)

                        Text(strings.phrase("使用当前管理员账号权限选择要监控的用户。普通用户账号不会显示这些项目。", "Use the current admin account to choose which user to monitor. Normal user accounts do not show these items."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        settingsRow(strings.phrase("监控用户", "Monitor User")) {
                            Picker("", selection: adminMonitoredUserBinding) {
                                ForEach(adminUserOptions) { user in
                                    Text(userOptionTitle(user))
                                        .tag(user.id)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .controlSize(.regular)
                            .disabled(adminUserOptions.isEmpty)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if adminUserOptions.isEmpty {
                            Text(strings.phrase("未获取到管理员用户列表，刷新后重试。", "Admin user list is unavailable. Refresh and try again."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if model.snapshot.realtimeConcurrency != nil {
                            Text(strings.phrase("实时并发来自管理员运维接口。", "Realtime concurrency comes from the admin ops endpoint."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            GlassCard {
                Toggle(strings.phrase("登录时打开", "Open at Login"), isOn: launchAtLoginBinding)
            }
        }
    }

    private var loginSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(strings.phrase("登录", "Login"))
                    .font(.headline)
                TextField("Email", text: $model.loginEmail)
                    .themedTextField()
                SecureField(strings.phrase("密码", "Password"), text: $model.loginPassword)
                    .themedTextField()
                Button {
                    model.loginAndSave()
                } label: {
                    Label(strings.phrase("登录并保存令牌", "Login and Save Token"), systemImage: "key")
                }
                .disabled(!LoginFormState(baseURL: model.settingsDraft.baseURL, email: model.loginEmail, password: model.loginPassword).canSubmit || model.isLoggingIn)

                Button(role: .destructive) {
                    model.disconnect()
                } label: {
                    Label(strings.phrase("断开连接", "Disconnect"), systemImage: "person.crop.circle.badge.xmark")
                }
                .disabled(model.config.authToken.isEmpty && model.settingsDraft.authToken.isEmpty)
            }
        }
    }

    private func settingsRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.callout.weight(.semibold))
                .opacity(label.isEmpty ? 0 : 1)
                .frame(width: 100, alignment: .trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
            content()
        }
    }

    private var strings: AppStrings {
        AppStrings(model.settingsDraft.language)
    }

    private var languageBinding: Binding<AppLanguage> {
        Binding(
            get: { model.settingsDraft.language },
            set: { value in
                model.applySettingsChange(refreshAfterSave: false) { $0.language = value }
            }
        )
    }

    private var appearanceBinding: Binding<AppAppearance> {
        Binding(
            get: { model.settingsDraft.appearance },
            set: { value in
                model.applySettingsChange(refreshAfterSave: false) { $0.appearance = value }
            }
        )
    }

    private var showsMenuBarTextBinding: Binding<Bool> {
        Binding(
            get: { model.settingsDraft.showsMenuBarText },
            set: { value in
                model.applySettingsChange(refreshAfterSave: false) { $0.showsMenuBarText = value }
            }
        )
    }

    private var menuBarUsageWindowBinding: Binding<MenuBarUsageWindow> {
        Binding(
            get: { model.settingsDraft.menuBarUsageWindow },
            set: { value in
                model.applySettingsChange(refreshAfterSave: true) { $0.menuBarUsageWindow = value }
            }
        )
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { model.settingsDraft.launchAtLogin },
            set: { value in
                model.applySettingsChange(refreshAfterSave: false) { $0.launchAtLogin = value }
            }
        )
    }

    private var isAdminAccount: Bool {
        model.snapshot.currentUser?.isAdmin == true
    }

    private var availableMenuBarDisplayItems: [MenuBarDisplayItem] {
        isAdminAccount ? MenuBarDisplayItem.adminVisibleCases : MenuBarDisplayItem.userVisibleCases
    }

    private var adminUserOptions: [AdminUserSummary] {
        return model.adminUsers
    }

    private var adminMonitoredUserBinding: Binding<Int64> {
        Binding(
            get: {
                model.settingsDraft.adminMonitoredUserID
                    ?? model.snapshot.currentUser?.id
                    ?? adminUserOptions.first?.id
                    ?? 0
            },
            set: { value in
                model.applySettingsChange(refreshAfterSave: true) { draft in
                    draft.monitorMode = .admin
                    draft.adminMonitoredUserID = value
                }
            }
        )
    }

    private func userOptionTitle(_ user: AdminUserSummary) -> String {
        let name = user.displayName
        if name == user.email {
            return user.email
        }
        return "\(name) <\(user.email)>"
    }

    private func menuBarItemBinding(_ item: MenuBarDisplayItem) -> Binding<Bool> {
        Binding(
            get: {
                model.settingsDraft.menuBarDisplayItems.contains(item)
            },
            set: { isEnabled in
                model.applySettingsChange(refreshAfterSave: false) { draft in
                    if item.isAdminOnly {
                        guard isAdminAccount else {
                            draft.menuBarDisplayItems.removeAll { $0 == item }
                            return
                        }
                        draft.monitorMode = .admin
                    }
                    if isEnabled {
                        if !draft.menuBarDisplayItems.contains(item) {
                            draft.menuBarDisplayItems.append(item)
                        }
                    } else {
                        draft.menuBarDisplayItems.removeAll { $0 == item }
                    }
                }
            }
        )
    }
}

private enum SettingsField: Hashable {
    case baseURL
    case authToken
}

private enum LoginField: Hashable {
    case baseURL
    case email
    case password
    case authToken
}

struct UpdateSettingsSection: View {
    @ObservedObject var model: MonitorViewModel

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(strings.phrase("更新", "Updates"))
                        .font(.headline)
                    Spacer()
                    if model.isCheckingForUpdates || model.isInstallingUpdate {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if let updateInfo = model.updateInfo, updateInfo.isUpdateAvailable {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(ClaudeTheme.success)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(strings.updateStatus(updateInfo))
                                .font(.callout.weight(.medium))
                            Text(updateInfo.latestRelease.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            if let message = model.updateStatusMessage,
                               message != strings.updateStatus(updateInfo),
                               message != updateInfo.statusText {
                                Text(message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                } else if let message = model.updateStatusMessage {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(strings.phrase("检查 GitHub Releases 中的新版本。", "Checks GitHub Releases for newer versions."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 14) {
                    Button {
                        model.checkForUpdates()
                    } label: {
                        Label(strings.phrase("立即检查", "Check Now"), systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isCheckingForUpdates || model.isInstallingUpdate)

                    if model.updateInfo?.isUpdateAvailable == true {
                        if model.updateInfo?.latestRelease.installArchiveAsset() != nil {
                            Button {
                                model.installUpdate()
                            } label: {
                                Label(strings.phrase("安装更新", "Install Update"), systemImage: "arrow.down.circle")
                            }
                            .disabled(model.isCheckingForUpdates || model.isInstallingUpdate)
                        }

                        Button {
                            model.openLatestRelease()
                        } label: {
                            Label(strings.phrase("打开发布页", "Open Release"), systemImage: "safari")
                        }
                        .disabled(model.isInstallingUpdate)
                    }
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private var strings: AppStrings {
        AppStrings(model.settingsDraft.language)
    }
}

struct UpdateAvailableBanner: View {
    @Environment(\.appLanguage) private var language

    let info: UpdateInfo
    let isInstalling: Bool
    let statusMessage: String?
    let installUpdate: () -> Void
    let openRelease: () -> Void

    private var canInstallDirectly: Bool {
        info.latestRelease.installArchiveAsset() != nil
    }

    private var detailText: String {
        if let statusMessage,
           statusMessage != info.statusText,
           statusMessage != strings.updateStatus(info) {
            return statusMessage
        }
        return canInstallDirectly
            ? strings.phrase("可直接安装，也可以打开 GitHub 发布页。", "Install directly or open the GitHub release.")
            : strings.phrase("从 GitHub 下载最新版本。", "Download the latest release from GitHub.")
    }

    var body: some View {
        HStack(spacing: 10) {
            if isInstalling {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.success)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(strings.updateStatus(info))
                    .font(.callout.weight(.semibold))
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if canInstallDirectly {
                Button {
                    installUpdate()
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .buttonStyle(.borderless)
                .disabled(isInstalling)
                .help(strings.phrase("安装更新", "Install update"))
            }
            Button {
                openRelease()
            } label: {
                Image(systemName: "safari")
            }
            .buttonStyle(.borderless)
            .disabled(isInstalling)
            .help(strings.phrase("打开发布页", "Open release"))
        }
        .padding(12)
        .background(ClaudeTheme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(ClaudeTheme.accent.opacity(0.18), lineWidth: 1)
        )
    }

    private var strings: AppStrings {
        AppStrings(language)
    }
}

struct MetricItem: Identifiable {
    let id: String
    let title: String
    let value: String
    let caption: String?
    let systemImage: String?
    let tint: Color

    init(title: String, value: String, caption: String? = nil, systemImage: String? = nil, tint: Color = ClaudeTheme.accent) {
        id = "\(title)-\(systemImage ?? "")"
        self.title = title
        self.value = value
        self.caption = caption
        self.systemImage = systemImage
        self.tint = tint
    }
}

struct UserAccountCard: View {
    @Environment(\.appLanguage) private var language

    let user: CurrentUser

    private var displayName: String {
        guard let username = user.username, !username.isEmpty else {
            return user.email
        }
        return username
    }

    var body: some View {
        HStack(spacing: 12) {
            DefaultAvatar(name: displayName, email: user.email)

            VStack(alignment: .leading, spacing: 4) {
                Text(displayName)
                    .font(.headline)
                    .lineLimit(1)
                Text(user.email)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            Spacer()

            if let status = user.status, !status.isEmpty {
                Text(strings.activeStatus(status))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(status.lowercased() == "active" ? ClaudeTheme.success : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background((status.lowercased() == "active" ? ClaudeTheme.success : ClaudeTheme.muted).opacity(0.14), in: Capsule())
            }
        }
        .padding(12)
        .background(ClaudeTheme.elevatedCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var strings: AppStrings {
        AppStrings(language)
    }
}

struct MonitoredUserCard: View {
    @Environment(\.appLanguage) private var language

    let user: AdminUserSummary
    let concurrency: UserRealtimeConcurrency?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(ClaudeTheme.warning.opacity(0.16))
                Image(systemName: "scope")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.warning)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 4) {
                Text(strings.phrase("监控用户", "Monitored User"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(user.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Text(user.email)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(strings.phrase("并发占用", "Concurrency"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(concurrencyText)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(ClaudeTheme.warning)
            }
        }
        .padding(12)
        .background(ClaudeTheme.elevatedCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(ClaudeTheme.warning.opacity(0.2), lineWidth: 1)
        )
    }

    private var concurrencyText: String {
        guard let concurrency else {
            return "--"
        }
        return "\(concurrency.currentInUse)/\(concurrency.maxCapacity)"
    }

    private var strings: AppStrings {
        AppStrings(language)
    }
}

struct DefaultAvatar: View {
    let name: String
    let email: String

    private var initials: String {
        let source = name.isEmpty ? email : name
        let parts = source
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        let letters = parts.prefix(2).compactMap { $0.first }
        if letters.isEmpty {
            return "S"
        }
        return String(letters).uppercased()
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(ClaudeTheme.avatarBackground)
            Text(initials)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(ClaudeTheme.avatarForeground)
        }
        .frame(width: 42, height: 42)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(ClaudeTheme.border, lineWidth: 1)
        )
    }
}

struct MetricGrid: View {
    let items: [MetricItem]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(items) { item in
                HStack(spacing: 10) {
                    if let systemImage = item.systemImage {
                        SafeSystemImage(systemName: systemImage)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(item.tint)
                            .frame(width: 32, height: 32)
                            .background(item.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(item.value)
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        if let caption = item.caption {
                            Text(caption)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(ClaudeTheme.elevatedCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(ClaudeTheme.border, lineWidth: 1)
                )
            }
        }
    }
}

struct SafeSystemImage: View {
    let systemName: String
    var fallbackName = "circle.grid.3x3.fill"

    var body: some View {
        if let image = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: fallbackName, accessibilityDescription: nil) {
            Image(nsImage: image)
                .renderingMode(.template)
        } else {
            Image(systemName: "questionmark.circle")
        }
    }
}

struct SubscriptionQuotaCard: View {
    @Environment(\.appLanguage) private var language

    let item: SubscriptionSummaryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Circle()
                    .fill(item.status == "active" ? ClaudeTheme.success : ClaudeTheme.muted)
                    .frame(width: 7, height: 7)
                Text(item.groupName)
                    .font(.headline)
                Spacer()
                Text(strings.activeStatus(item.status))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(item.status == "active" ? ClaudeTheme.success : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background((item.status == "active" ? ClaudeTheme.success : ClaudeTheme.muted).opacity(0.14), in: Capsule())
            }

            if let days = item.daysRemaining {
                HStack {
                    Text(strings.phrase("到期", "Expires"))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(strings.phrase("剩余 \(days) 天", "Remaining \(days)d"))
                }
                .font(.caption)
            }

            QuotaProgressRow(
                title: strings.phrase("每日", "Daily"),
                used: item.dailyUsedUSD,
                limit: item.dailyLimitUSD,
                progress: item.dailyProgress,
                resetInSeconds: item.dailyResetInSeconds
            )
            QuotaProgressRow(
                title: strings.phrase("每周", "Weekly"),
                used: item.weeklyUsedUSD,
                limit: item.weeklyLimitUSD,
                progress: item.weeklyProgress,
                resetInSeconds: item.weeklyResetInSeconds
            )
            QuotaProgressRow(
                title: strings.phrase("每月", "Monthly"),
                used: item.monthlyUsedUSD,
                limit: item.monthlyLimitUSD,
                progress: item.monthlyProgress,
                resetInSeconds: item.monthlyResetInSeconds
            )
        }
    }

    private var strings: AppStrings {
        AppStrings(language)
    }
}

struct SubscriptionSection: View {
    @Environment(\.appLanguage) private var language

    let summary: SubscriptionSummary

    private var visibleSubscriptions: [SubscriptionSummaryItem] {
        Array(summary.subscriptions.prefix(5))
    }

    var body: some View {
        SectionBlock(title: strings.phrase("订阅", "Subscriptions")) {
            if visibleSubscriptions.isEmpty {
                SubscriptionEmptyState(activeCount: summary.activeCount)
            } else {
                VStack(spacing: 10) {
                    ForEach(visibleSubscriptions) { item in
                        SubscriptionQuotaCard(item: item)
                    }
                }
            }
        }
    }

    private var strings: AppStrings {
        AppStrings(language)
    }
}

struct SubscriptionEmptyState: View {
    @Environment(\.appLanguage) private var language

    let activeCount: Int

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(ClaudeTheme.slate.opacity(0.14))
                Image(systemName: "tray")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.slate)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 4) {
                Text(strings.phrase("暂无订阅", "No Subscriptions"))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(ClaudeTheme.primaryText)
                Text(emptyDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if activeCount > 0 {
                Text(strings.phrase("\(activeCount) 个活跃", "\(activeCount) active"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(ClaudeTheme.success)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(ClaudeTheme.success.opacity(0.14), in: Capsule())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private var emptyDescription: String {
        if activeCount > 0 {
            return strings.phrase(
                "服务返回了活跃数量，但没有订阅明细。",
                "The service returned active counts but no subscription details."
            )
        }
        return strings.phrase(
            "该账号当前没有可展示的订阅配额。",
            "This account has no subscription quotas to display."
        )
    }

    private var strings: AppStrings {
        AppStrings(language)
    }
}

struct QuotaProgressRow: View {
    @Environment(\.appLanguage) private var language

    let title: String
    let used: Double?
    let limit: Double?
    let progress: Double?
    let resetInSeconds: Double?

    private var normalizedProgress: Double {
        min(max(progress ?? 0, 0), 1)
    }

    private var tint: Color {
        normalizedProgress >= 0.95 ? ClaudeTheme.danger : ClaudeTheme.success
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.callout.weight(.semibold))
                Spacer()
                Text(amountText)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            ProgressView(value: normalizedProgress)
                .tint(tint)

            if let resetInSeconds {
                Text(strings.phrase(
                    "\(StatusFormatters.duration(seconds: resetInSeconds)) 后重置",
                    "\(StatusFormatters.duration(seconds: resetInSeconds)) until reset"
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var amountText: String {
        guard let used, let limit else {
            return "--"
        }
        return "\(StatusFormatters.currency(used)) / \(StatusFormatters.currency(limit))"
    }

    private var strings: AppStrings {
        AppStrings(language)
    }
}

struct ModelDistributionView: View {
    @Environment(\.appLanguage) private var language

    let models: [ModelUsageSummary]

    private var visibleModels: [ModelUsageSummary] {
        Array(models.prefix(5))
    }

    private var maximumTokens: Double {
        max(Double(visibleModels.map(\.totalTokens).max() ?? 0), 1)
    }

    var body: some View {
        SectionBlock(title: strings.phrase("模型分布", "Model Distribution")) {
            VStack(spacing: 10) {
                ForEach(visibleModels) { item in
                    VStack(spacing: 7) {
                        HStack {
                            Text(item.model)
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                            Spacer()
                            Text(StatusFormatters.preciseCurrency(item.actualCost))
                                .font(.callout.weight(.medium))
                                .foregroundStyle(ClaudeTheme.accent)
                        }
                        HStack {
                            Text(strings.phrase(
                                "\(StatusFormatters.menuBarCount(item.requests)) 次请求",
                                "\(StatusFormatters.menuBarCount(item.requests)) requests"
                            ))
                            Spacer()
                            Text(StatusFormatters.compactNumber(item.totalTokens))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        ProgressView(value: Double(item.totalTokens) / maximumTokens)
                            .tint(ClaudeTheme.slate)
                    }
                    if item.id != visibleModels.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    private var strings: AppStrings {
        AppStrings(language)
    }
}

struct TokenTrendView: View {
    @Environment(\.appLanguage) private var language

    let points: [TrendDataPoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                ZStack {
                    trendPath(values: points.map { Double($0.cacheReadTokens) }, in: proxy.size)
                        .fill(ClaudeTheme.sand.opacity(0.24))
                    trendPath(values: points.map { Double($0.cacheReadTokens) }, in: proxy.size)
                        .stroke(ClaudeTheme.sand, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    trendPath(values: points.map { Double($0.inputTokens) }, in: proxy.size)
                        .stroke(ClaudeTheme.slate, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    trendPath(values: points.map { Double($0.outputTokens) }, in: proxy.size)
                        .stroke(ClaudeTheme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }

            HStack(spacing: 12) {
                LegendDot(color: ClaudeTheme.slate, label: strings.phrase("输入", "Input"))
                LegendDot(color: ClaudeTheme.accent, label: strings.phrase("输出", "Output"))
                LegendDot(color: ClaudeTheme.sand, label: strings.phrase("缓存读取", "Cache Read"))
                Spacer()
                Text(points.last?.date ?? "")
                    .foregroundStyle(.secondary)
            }
            .font(.caption2)
        }
    }

    private func trendPath(values: [Double], in size: CGSize) -> Path {
        let maximum = max(values.max() ?? 0, 1)
        var path = Path()
        for index in values.indices {
            let x = size.width * CGFloat(index) / CGFloat(max(values.count - 1, 1))
            let y = size.height - (size.height * CGFloat(values[index] / maximum))
            if index == values.startIndex {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
    }

    private var strings: AppStrings {
        AppStrings(language)
    }
}

struct LegendDot: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
        }
    }
}

struct SectionBlock<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            GlassCard {
                content
            }
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
        .font(.callout)
    }
}

extension AppAppearance {
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system:
            return nil
        case .light:
            return NSAppearance(named: .aqua)
        case .dark:
            return NSAppearance(named: .darkAqua)
        }
    }
}

enum ClaudeTheme {
    static let background = LinearGradient(
        colors: [
            adaptive(light: rgb(0.992, 0.970, 0.930), dark: rgb(0.055, 0.060, 0.064)),
            adaptive(light: rgb(0.965, 0.925, 0.858), dark: rgb(0.090, 0.086, 0.078)),
            adaptive(light: rgb(0.940, 0.868, 0.780), dark: rgb(0.130, 0.106, 0.086)),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let header = adaptive(light: rgb(0.982, 0.950, 0.900), dark: rgb(0.105, 0.104, 0.098))
    static let footer = adaptive(light: rgb(0.965, 0.930, 0.878), dark: rgb(0.085, 0.082, 0.076))
    static let card = adaptive(light: rgb(1.000, 0.978, 0.934), dark: rgb(0.150, 0.143, 0.132))
    static let elevatedCard = adaptive(light: rgb(0.992, 0.950, 0.880), dark: rgb(0.180, 0.170, 0.156))
    static let tabBackground = adaptive(light: rgb(0.930, 0.875, 0.790), dark: rgb(0.115, 0.110, 0.102))
    static let tabSelected = adaptive(light: rgb(1.000, 0.970, 0.905), dark: rgb(0.245, 0.222, 0.196))
    static let border = adaptive(light: rgb(0.55, 0.44, 0.31), dark: rgb(0.82, 0.76, 0.66)).opacity(0.22)
    static let primaryText = adaptive(light: rgb(0.180, 0.145, 0.105), dark: rgb(0.94, 0.91, 0.86))
    static let secondaryText = adaptive(light: rgb(0.460, 0.395, 0.310), dark: rgb(0.66, 0.62, 0.55))
    static let muted = adaptive(light: rgb(0.560, 0.480, 0.380), dark: rgb(0.62, 0.59, 0.52))
    static let accent = adaptive(light: rgb(0.760, 0.310, 0.145), dark: rgb(0.86, 0.38, 0.19))
    static let success = adaptive(light: rgb(0.500, 0.410, 0.245), dark: rgb(0.71, 0.58, 0.38))
    static let slate = adaptive(light: rgb(0.400, 0.470, 0.480), dark: rgb(0.55, 0.60, 0.60))
    static let sand = adaptive(light: rgb(0.650, 0.500, 0.315), dark: rgb(0.72, 0.62, 0.48))
    static let gold = adaptive(light: rgb(0.760, 0.450, 0.160), dark: rgb(0.84, 0.58, 0.29))
    static let warm = adaptive(light: rgb(0.760, 0.340, 0.160), dark: rgb(0.82, 0.45, 0.25))
    static let ink = adaptive(light: rgb(0.410, 0.320, 0.245), dark: rgb(0.64, 0.55, 0.46))
    static let warning = adaptive(light: rgb(0.780, 0.440, 0.120), dark: rgb(0.86, 0.58, 0.22))
    static let danger = adaptive(light: rgb(0.760, 0.190, 0.160), dark: rgb(0.86, 0.31, 0.25))
    static let textFieldBackground = adaptive(light: rgb(1.000, 0.988, 0.952), dark: rgb(0.060, 0.058, 0.054))
    static let avatarBackground = LinearGradient(
        colors: [
            adaptive(light: rgb(0.880, 0.570, 0.330), dark: rgb(0.70, 0.48, 0.30)),
            adaptive(light: rgb(0.650, 0.350, 0.210), dark: rgb(0.42, 0.30, 0.22)),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let avatarForeground = adaptive(light: rgb(1.000, 0.955, 0.880), dark: rgb(0.98, 0.90, 0.78))

    private static func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return dark
            }
            return light
        })
    }
}

extension View {
    func appAppearance(_ appearance: AppAppearance) -> some View {
        preferredColorScheme(appearance.preferredColorScheme)
    }

    func themedTextField() -> some View {
        self
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(ClaudeTheme.textFieldBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(ClaudeTheme.border, lineWidth: 1)
            )
    }
}

struct PanelBackground: View {
    var body: some View {
        ZStack {
            ClaudeTheme.background

            Circle()
                .fill(ClaudeTheme.accent.opacity(0.12))
                .frame(width: 150, height: 150)
                .offset(x: 250, y: -255)

            Circle()
                .fill(ClaudeTheme.sand.opacity(0.10))
                .frame(width: 130, height: 130)
                .offset(x: -250, y: 255)
        }
        .ignoresSafeArea()
    }
}

struct GlassCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(ClaudeTheme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(ClaudeTheme.border, lineWidth: 1)
            )
    }
}

struct MessageRow: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(ClaudeTheme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(ClaudeTheme.border, lineWidth: 1)
        )
    }
}
