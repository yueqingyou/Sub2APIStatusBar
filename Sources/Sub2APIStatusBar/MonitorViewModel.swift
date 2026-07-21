import AppKit
import SwiftUI
import Sub2APIStatusCore

@MainActor
final class MonitorViewModel: ObservableObject {
    @Published var config: AppConfig
    @Published private(set) var resolvedAppearance: AppAppearance
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
    @Published var codexNodes: [CodexNode] = []
    @Published var codexNodeForm = CodexNodeFormState.localDefault()
    @Published var editingCodexNodeID: String?
    @Published var codexNodeError: String?
    @Published var codexNodeOperationMessages: [String: String] = [:]
    @Published var installingCodexNodeIDs: Set<String> = []
    @Published var preparingCodexNodeInstallPreviewIDs: Set<String> = []
    @Published var codexHookInstallPreview: CodexHookInstallPreview?
    @Published var codexTunnelStatuses: [String: SSHTunnelStatus] = [:]
    @Published var codexNodeHealthStatuses: [String: CodexNodeHealthStatus] = [:]
    @Published var sshConfigHosts: [SSHConfigHost] = []
    @Published var selectedSSHConfigHostID = ""

    var onSnapshotChange: ((MonitorSnapshot) -> Void)?
    var onAppearanceChange: ((AppAppearance) -> Void)?

    private let store = ConfigStore()
    private let updateChecker = GitHubUpdateChecker()
    private let updateInstaller = AppUpdateInstaller()
    private let codexNodeStore = CodexNodeStore()
    private let codexTaskActivityPersistence = CodexTaskActivityStorePersistence()
    private let openAIQuotaHistoryPersistence = OpenAIQuotaHistoryPersistence()
    private let codexHookInstallService = CodexHookInstallService()
    private let codexRemoteTestEventService = CodexHookRemoteTestEventService()
    private let sshTunnelManager = SSHTunnelManager()
    private let launchAtLoginManager = LaunchAtLoginManager(appBundleURL: Bundle.main.bundleURL)
    private let transientRefreshRetryPolicy = HTTPRetryPolicy.default
    private let tokenRouterRefreshPolicy = TokenRouterRefreshPolicy()
    private let codexTaskPersistenceQueue = DispatchQueue(label: "sub2api-statusbar.codex-task-persistence", qos: .utility)
    private let openAIQuotaPersistenceQueue = DispatchQueue(label: "sub2api-statusbar.openai-quota-persistence", qos: .utility)
    private var codexTaskActivityStore = CodexTaskActivityStore()
    private var lastPersistedCodexTaskActivities: [CodexTaskActivity] = []
    private var pendingPersistedCodexTaskActivities: [CodexTaskActivity]?
    private var codexTaskPersistenceWorkItem: DispatchWorkItem?
    private var hasLoadedCodexTaskActivities = false
    private var isLoadingCodexTaskActivities = false
    private var codexNodeHealthStore = CodexNodeHealthStore()
    private var codexNodeRegistry = CodexNodeRegistry(registeredNodes: [])
    private var codexHookReceiverServers: [UInt16: LocalCodexHookReceiverServer] = [:]
    private var refreshTimer: Timer?
    private var settingsAutosaveTask: Task<Void, Never>?
    private var pendingReasoningEffortRefreshTask: Task<Void, Never>?
    private var pendingReasoningEffortUsageID: Int64?
    private var codexTunnelStartupProbeTasks: [String: Task<Void, Never>] = [:]
    private var codexHookInstallStatusRefreshTask: Task<Void, Never>?
    private var probingRemoteTunnelNodeIDs: Set<String> = []
    private var lastRemoteTunnelPathProbeAtByNodeID: [String: Date] = [:]
    private var cachedAuthenticatedUser: CurrentUser?
    private var cachedAuthenticationBaseURL = ""
    private var cachedAuthenticationToken = ""
    private var lastSlowRefreshAttemptAt: Date?
    private var lastAccountUsageRefreshAttemptAt: Date?
    private var openAIQuotaHistory = OpenAIQuotaHistory()
    private let codexRuntimeStateRefresher = CodexRuntimeStateRefresher(
        taskStaleAfterSeconds: 30 * 60,
        nodeStaleAfterSeconds: 30 * 60
    )
    private let remoteTunnelPathProbeMinimumInterval: TimeInterval = 60

    private enum CodexTestEventContext {
        case manual
        case afterInstall(configPath: String)
    }

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
        resolvedAppearance = loaded.appearance == .dark ? .dark : .light
        settingsDraft = loaded
        snapshot = .idle(mode: loaded.monitorMode)
        do {
            openAIQuotaHistory = try openAIQuotaHistoryPersistence.load()
        } catch {
            settingsError = error.localizedDescription
        }
        loadCodexNodeRegistry()
    }

    func updateResolvedAppearance(_ appearance: AppAppearance) {
        guard appearance != .system, resolvedAppearance != appearance else {
            return
        }
        resolvedAppearance = appearance
    }

    func start() {
        loadCodexTaskActivities()
        syncCodexHookReceivers()
        ensureRemoteCodexTunnels()
        refresh(manual: true)
        scheduleTimer()
        checkForUpdates(silent: true)
    }

    func refresh(manual: Bool = false) {
        Task {
            await refreshNow(forceSlowRefresh: manual)
        }
    }

    func refreshNow(forceSlowRefresh: Bool = false) async {
        guard !isRefreshing else {
            return
        }

        ensureRemoteCodexTunnels()

        if config.authToken.isEmpty {
            let activities = refreshCodexRuntimeState()
            publish(.idle(mode: config.monitorMode).withCodexTaskActivities(activities))
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        let client = TokenRouterClient(config: config)
        let now = Date()
        let shouldRefreshSlowData = tokenRouterRefreshPolicy.shouldRefreshSlowData(
            lastAttemptAt: lastSlowRefreshAttemptAt,
            now: now,
            isManualRefresh: forceSlowRefresh
        )
        let shouldRefreshAccountUsage = tokenRouterRefreshPolicy.shouldRefreshAccountUsage(
            lastAttemptAt: lastAccountUsageRefreshAttemptAt,
            now: now,
            isManualRefresh: forceSlowRefresh
        )
        do {
            let next = try await userSnapshot(
                client: client,
                refreshSlowData: shouldRefreshSlowData,
                refreshAccountUsage: shouldRefreshAccountUsage
            )
            publish(next)
            if shouldRefreshSlowData {
                lastSlowRefreshAttemptAt = now
            }
            if next.mode == .admin, shouldRefreshAccountUsage {
                lastAccountUsageRefreshAttemptAt = now
            }
        } catch {
            if await refreshAuthTokenIfNeeded(after: error) {
                do {
                    resetTokenRouterRefreshState(clearIdentity: true)
                    let next = try await userSnapshot(
                        client: TokenRouterClient(config: config),
                        refreshSlowData: true,
                        refreshAccountUsage: true
                    )
                    publish(next)
                    lastSlowRefreshAttemptAt = now
                    if next.mode == .admin {
                        lastAccountUsageRefreshAttemptAt = now
                    }
                    return
                } catch {
                    publishDisconnected(error)
                    return
                }
            }
            publishDisconnected(error)
        }
    }

    private func userSnapshot(
        client: TokenRouterClient,
        refreshSlowData: Bool,
        refreshAccountUsage: Bool
    ) async throws -> MonitorSnapshot {
        let currentUser = try await authenticatedUser(client: client)
        applyCapabilityPolicyForCurrentUser(currentUser)
        if currentUser.isAdmin {
            return try await adminSnapshot(
                currentUser: currentUser,
                client: client,
                refreshSlowData: refreshSlowData,
                refreshAccountUsage: refreshAccountUsage
            )
        }

        let timezone = TimeZone.current.identifier
        let canReuseUserSnapshot = snapshot.mode == .user && snapshot.currentUser?.id == currentUser.id
        var stats = canReuseUserSnapshot ? snapshot.stats : nil
        var summary = canReuseUserSnapshot ? snapshot.subscriptionSummary : nil
        var trend = canReuseUserSnapshot ? snapshot.trend : nil
        var modelDistribution = canReuseUserSnapshot ? snapshot.modelDistribution : nil
        let menuBarStats = try await menuBarUsageStats(client: client, timezone: timezone)
        let latestUsagePage = try? await client.usageLogs(
            page: 1,
            pageSize: 1,
            sortBy: "created_at",
            sortOrder: "desc"
        )

        if refreshSlowData {
            let range = Self.lastSevenDayRange()
            if let refreshedSummary = try? await client.subscriptionSummary() {
                summary = refreshedSummary
            }
            if let refreshedStats = try? await client.usageDashboardStats() {
                stats = refreshedStats
            }
            if let dashboardSnapshot = try? await client.usageDashboardSnapshot(
                startDate: range.start,
                endDate: range.end
            ) {
                trend = dashboardSnapshot.trend
                modelDistribution = dashboardSnapshot.models
            }
        }

        let latestUsage = latestUsagePage?.items.first ?? (canReuseUserSnapshot ? snapshot.latestUsage : nil)
        let codexActivities = refreshCodexRuntimeState()
        return MonitorSnapshot(
            mode: .user,
            connected: true,
            currentUser: currentUser,
            stats: stats,
            menuBarUsageStats: menuBarStats,
            latestUsage: latestUsage,
            trend: trend,
            modelDistribution: modelDistribution,
            realtime: nil,
            monitoredUser: nil,
            realtimeConcurrency: nil,
            accountHealth: nil,
            subscriptionSummary: summary,
            codexTaskActivities: codexActivities,
            lastUpdatedAt: Date(),
            message: nil
        )
    }

    private func adminSnapshot(
        currentUser: CurrentUser,
        client: TokenRouterClient,
        refreshSlowData: Bool,
        refreshAccountUsage: Bool
    ) async throws -> MonitorSnapshot {
        let timezone = TimeZone.current.identifier
        let selectedUserID = config.adminMonitoredUserID ?? currentUser.id
        let canReuseAdminSnapshot = snapshot.mode == .admin && snapshot.monitoredUser?.id == selectedUserID

        var target = canReuseAdminSnapshot ? snapshot.monitoredUser : nil
        if refreshSlowData || target == nil {
            if let refreshedTarget = try? await client.adminUser(id: selectedUserID) {
                target = refreshedTarget
            }
        }
        guard let target else {
            throw TokenRouterError.missingData
        }

        var stats = canReuseAdminSnapshot ? snapshot.stats : nil
        var modelDistribution = canReuseAdminSnapshot ? snapshot.modelDistribution : nil
        var normalAccountComposition = canReuseAdminSnapshot ? snapshot.adminNormalAccountComposition : nil
        var subscriptionSummary = canReuseAdminSnapshot ? snapshot.subscriptionSummary : nil
        var openAIQuota = canReuseAdminSnapshot ? snapshot.openAIQuota : nil
        var openAIQuotaError = canReuseAdminSnapshot ? snapshot.openAIQuotaError : nil
        let menuBarStats = try await adminMenuBarUsageStats(
            client: client,
            userID: selectedUserID,
            timezone: timezone
        )
        let latestUsagePage = try? await client.adminUsageLogs(
            userID: selectedUserID,
            page: 1,
            pageSize: 1,
            sortBy: "created_at",
            sortOrder: "desc",
            timezone: timezone
        )
        let concurrencyStats = try? await client.adminUserConcurrencyStats()

        if refreshSlowData {
            let today = Self.todayString()
            let range = Self.lastSevenDayRange()
            if let users = try? await client.allAdminUsers() {
                adminUsers = users
            }
            if let composition = try? await client.adminNormalAccountComposition() {
                normalAccountComposition = composition
            }
            if let dayStats = try? await client.adminUsageStats(
                userID: selectedUserID,
                startDate: today,
                endDate: today,
                timezone: timezone
            ) {
                stats = DashboardStats(monitoredUsageStats: dayStats)
            }
            if let dashboardSnapshot = try? await client.adminDashboardSnapshot(
                userID: selectedUserID,
                startDate: range.start,
                endDate: range.end,
                timezone: timezone
            ) {
                modelDistribution = dashboardSnapshot.models
            }
            if let subscriptions = try? await client.adminUserSubscriptions(userID: selectedUserID) {
                subscriptionSummary = SubscriptionSummary(adminSubscriptions: subscriptions)
            }
        }

        if refreshAccountUsage {
            do {
                let accounts = try await client.adminOpenAIOAuthAccountQuotas()
                let capturedAt = Date()
                if openAIQuotaHistory.record(accounts: accounts, capturedAt: capturedAt) {
                    persistOpenAIQuotaHistory(openAIQuotaHistory)
                }
                openAIQuota = OpenAIAccountQuotaSnapshot(
                    accounts: accounts,
                    history: openAIQuotaHistory
                )
                openAIQuotaError = nil
            } catch {
                openAIQuotaError = error.localizedDescription
            }
        }

        let latestUsage = latestUsagePage?.items.first ?? (canReuseAdminSnapshot ? snapshot.latestUsage : nil)
        let concurrency = concurrencyStats?.concurrency(
                forUserID: target.id,
                userEmail: target.email,
                username: target.username,
                maxCapacity: target.concurrency
            ) ?? (canReuseAdminSnapshot ? snapshot.realtimeConcurrency : nil)
        let codexActivities = refreshCodexRuntimeState()
        return MonitorSnapshot(
            mode: .admin,
            connected: true,
            currentUser: currentUser,
            stats: stats,
            menuBarUsageStats: menuBarStats,
            latestUsage: latestUsage,
            trend: nil,
            modelDistribution: modelDistribution,
            realtime: nil,
            monitoredUser: target,
            realtimeConcurrency: concurrency,
            adminNormalAccountCount: normalAccountComposition?.total,
            adminNormalAccountComposition: normalAccountComposition,
            openAIQuota: openAIQuota,
            openAIQuotaError: openAIQuotaError,
            accountHealth: nil,
            subscriptionSummary: subscriptionSummary,
            codexTaskActivities: codexActivities,
            lastUpdatedAt: Date(),
            message: nil
        )
    }

    private func authenticatedUser(client: TokenRouterClient) async throws -> CurrentUser {
        if let cachedAuthenticatedUser,
           cachedAuthenticationBaseURL == config.baseURL,
           cachedAuthenticationToken == config.authToken {
            return cachedAuthenticatedUser
        }

        let user = try await client.currentUser().user
        cachedAuthenticatedUser = user
        cachedAuthenticationBaseURL = config.baseURL
        cachedAuthenticationToken = config.authToken
        return user
    }

    private func resetTokenRouterRefreshState(clearIdentity: Bool) {
        lastSlowRefreshAttemptAt = nil
        lastAccountUsageRefreshAttemptAt = nil
        if clearIdentity {
            cachedAuthenticatedUser = nil
            cachedAuthenticationBaseURL = ""
            cachedAuthenticationToken = ""
        }
    }

    private func persistOpenAIQuotaHistory(_ history: OpenAIQuotaHistory) {
        let persistence = openAIQuotaHistoryPersistence
        openAIQuotaPersistenceQueue.async { [weak self] in
            do {
                try persistence.save(history)
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.settingsError = error.localizedDescription
                }
            }
        }
    }

    private func applyCapabilityPolicyForCurrentUser(_ currentUser: CurrentUser) {
        var next = config
        next.applyCapabilityPolicy(CapabilityPolicy(isAdminAccount: currentUser.isAdmin))
        guard next != config else {
            return
        }
        do {
            try store.save(next)
            config = next
            settingsDraft = next
        } catch {
            settingsError = error.localizedDescription
        }
    }

    private func menuBarUsageStats(client: TokenRouterClient, timezone: String, now: Date = Date()) async throws -> UsagePeriodStats {
        let range = config.menuBarUsageWindow.dateRange(now: now)
        return try await client.usageStats(startDate: range.start, endDate: range.end, timezone: timezone)
    }

    private func adminMenuBarUsageStats(client: TokenRouterClient, userID: Int64, timezone: String, now: Date = Date()) async throws -> UsagePeriodStats {
        let range = config.menuBarUsageWindow.dateRange(now: now)
        return try await client.adminUsageStats(userID: userID, startDate: range.start, endDate: range.end, timezone: timezone)
    }

    private func refreshAuthTokenIfNeeded(after error: Error) async -> Bool {
        guard let apiError = error as? TokenRouterError,
              apiError.isUnauthorized,
              !config.refreshToken.isEmpty else {
            return false
        }

        var refreshConfig = config
        refreshConfig.authToken = ""
        do {
            let response = try await TokenRouterClient(config: refreshConfig).refreshToken(config.refreshToken)
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
        let codexActivities = refreshCodexRuntimeState()
        if snapshot.connected, isTransientRefreshFailure(error) {
            publish(snapshot
                .withCodexTaskActivities(codexActivities)
                .retainingDataAfterRefreshFailure(staleRefreshMessage(error)))
            return
        }

        publish(MonitorSnapshot(
            mode: config.monitorMode,
            connected: false,
            stats: nil,
            realtime: nil,
            accountHealth: nil,
            subscriptionSummary: nil,
            codexTaskActivities: codexActivities,
            lastUpdatedAt: snapshot.lastUpdatedAt,
            message: error.localizedDescription
        ))
    }

    func applyCodexHookEvent(_ event: CodexHookEvent) {
        codexTaskActivityStore.apply(event)
        codexNodeHealthStore.markEventReceived(event, now: Date())
        let activities = refreshCodexRuntimeState()
        publish(snapshot.withCodexTaskActivities(activities))
    }

    func configureCodexNodeRegistry(_ registry: CodexNodeRegistry) {
        codexNodeRegistry = registry
        codexNodes = registry.nodes
        codexNodeHealthStore.configure(nodes: registry.nodes, now: Date())
        codexTaskActivityStore.keepOnlyActivities(forNodeIDs: Set(registry.nodes.map(\.id)))
        let activities = refreshCodexRuntimeState()
        publish(snapshot.withCodexTaskActivities(activities))
        publishCodexNodeHealthStatuses()
        syncCodexHookReceivers()
        ensureRemoteCodexTunnels()
        scheduleCodexHookInstallStatusRefresh()
    }

    @discardableResult
    func saveCodexNodeForm() -> Bool {
        codexNodeError = nil
        do {
            codexNodeForm = preparedCodexNodeFormForSave(codexNodeForm)
            let registeredNode = try codexNodeForm.registeredNode()
            let nodeID = registeredNode.node.id
            let replacingNodeID = editingCodexNodeID?.trimmingCharacters(in: .whitespacesAndNewlines)
            if codexNodeRegistry.node(id: nodeID) != nil, replacingNodeID != nodeID {
                codexNodeError = AppStrings(config.language).phrase(
                    "节点 ID 已存在：\(nodeID)。请更换 ID，或点击该节点的编辑后再保存。",
                    "Node ID already exists: \(nodeID). Use a different ID, or edit that node before saving."
                )
                return false
            }
            let replacementIDs = Set([nodeID, replacingNodeID].compactMap { value -> String? in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? nil : trimmed
            })
            var nextRegisteredNodes = codexNodeRegistry.registeredNodes
                .filter { !replacementIDs.contains($0.node.id) }
            nextRegisteredNodes.append(registeredNode)
            let nextRegistry = CodexNodeRegistry(registeredNodes: nextRegisteredNodes)
            try codexNodeStore.saveRegistry(nextRegistry)
            if let replacingNodeID, replacingNodeID != nodeID {
                stopCodexTunnel(id: replacingNodeID)
                codexNodeOperationMessages[replacingNodeID] = nil
            }
            configureCodexNodeRegistry(nextRegistry)
            editingCodexNodeID = nodeID
            codexNodeOperationMessages[nodeID] = AppStrings(config.language).phrase(
                "节点已保存：\(registeredNode.node.name)（\(nodeID)）。已登记 \(nextRegistry.nodes.count) 个节点，等待安装 hooks。",
                "Node saved: \(registeredNode.node.name) (\(nodeID)). \(nextRegistry.nodes.count) nodes registered; waiting for hook installation."
            )
            codexNodeForm = CodexNodeFormState(registeredNode: registeredNode)
            return true
        } catch {
            codexNodeError = codexNodeErrorMessage(error)
            return false
        }
    }

    func editCodexNode(id: String) {
        guard let registeredNode = codexNodeRegistry.node(id: id) else {
            return
        }
        codexNodeError = nil
        editingCodexNodeID = registeredNode.node.id
        codexNodeForm = CodexNodeFormState(registeredNode: registeredNode)
    }

    func setCodexNodeFormKind(_ kind: CodexNodeKind) {
        guard codexNodeForm.kind != kind else {
            return
        }
        resetCodexNodeForm(kind: kind)
    }

    func resetCodexNodeForm(kind: CodexNodeKind = .local) {
        codexNodeError = nil
        editingCodexNodeID = nil
        selectedSSHConfigHostID = ""
        if kind == .remote {
            let identity = nextRemoteNodeIdentity()
            codexNodeForm = CodexNodeFormState(
                id: identity.id,
                name: identity.name,
                kind: .remote,
                localReceiverPort: "43210",
                remoteReceiverPort: defaultRemoteReceiverPort(),
                secret: UUID().uuidString
            )
            return
        }
        let identity = nextLocalNodeIdentity()
        codexNodeForm = CodexNodeFormState.localDefault(
            id: identity.id,
            name: identity.name
        )
    }

    func loadSSHConfigHosts() {
        codexNodeError = nil
        do {
            let configURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".ssh")
                .appendingPathComponent("config")
            let rawConfig = try String(contentsOf: configURL, encoding: .utf8)
            sshConfigHosts = SSHConfigParser.parse(rawConfig)
            if sshConfigHosts.isEmpty {
                selectedSSHConfigHostID = ""
                codexNodeError = AppStrings(config.language).phrase(
                    "未在 ~/.ssh/config 中找到可直接选择的具体 Host。",
                    "No concrete Host entries were found in ~/.ssh/config."
                )
            } else if !sshConfigHosts.contains(where: { $0.id == selectedSSHConfigHostID }) {
                selectedSSHConfigHostID = sshConfigHosts[0].id
            }
        } catch {
            sshConfigHosts = []
            selectedSSHConfigHostID = ""
            codexNodeError = AppStrings(config.language).phrase(
                "无法读取 ~/.ssh/config：\(error.localizedDescription)",
                "Could not read ~/.ssh/config: \(error.localizedDescription)"
            )
        }
    }

    func applySelectedSSHConfigHost() {
        codexNodeError = nil
        guard let host = sshConfigHosts.first(where: { $0.id == selectedSSHConfigHostID }) else {
            codexNodeError = AppStrings(config.language).phrase(
                "请先选择一个 SSH Host。",
                "Select an SSH Host first."
            )
            return
        }
        codexNodeForm.kind = .remote
        if shouldReplaceNodeIDForSSHHost(codexNodeForm.id) {
            codexNodeForm.id = uniqueNodeID(fromSSHHostAlias: host.alias)
        }
        if shouldReplaceNodeNameForSSHHost(codexNodeForm.name) {
            codexNodeForm.name = host.alias
        }
        if !isValidPortText(codexNodeForm.remoteReceiverPort) {
            codexNodeForm.remoteReceiverPort = defaultRemoteReceiverPort()
        }
        codexNodeForm.sshHost = host.hostName ?? host.alias
        codexNodeForm.sshUser = host.user ?? ""
        codexNodeForm.sshPort = host.port.map(String.init) ?? ""
        codexNodeForm.sshIdentityFile = host.identityFile ?? ""
    }

    private func nextLocalNodeIdentity() -> (id: String, name: String) {
        let baseName = AppStrings(config.language).phrase("本机", "Local")
        guard codexNodes.contains(where: { $0.id == "local" }) else {
            return ("local", baseName)
        }
        var suffix = 2
        while codexNodes.contains(where: { $0.id == "local-\(suffix)" }) {
            suffix += 1
        }
        return ("local-\(suffix)", "\(baseName) \(suffix)")
    }

    private func nextRemoteNodeIdentity() -> (id: String, name: String) {
        let baseName = AppStrings(config.language).phrase("远端", "Remote")
        var suffix = 1
        while codexNodes.contains(where: { $0.id == "remote-\(suffix)" }) {
            suffix += 1
        }
        return ("remote-\(suffix)", "\(baseName) \(suffix)")
    }

    private func defaultRemoteReceiverPort() -> String {
        let usedPorts = Set(codexNodes.compactMap(\.remoteReceiverPort))
        var candidate = 53_210
        while usedPorts.contains(candidate), candidate < 65_535 {
            candidate += 1
        }
        return String(candidate)
    }

    private func isValidPortText(_ raw: String) -> Bool {
        guard let port = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        return (1...65_535).contains(port)
    }

    private func shouldReplaceNodeIDForSSHHost(_ rawID: String) -> Bool {
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard editingCodexNodeID == nil else {
            return id.isEmpty
        }
        return id.isEmpty
            || id == "local"
            || id.hasPrefix("local-")
            || id.hasPrefix("remote-")
    }

    private func shouldReplaceNodeNameForSSHHost(_ rawName: String) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard editingCodexNodeID == nil else {
            return name.isEmpty
        }
        let localName = AppStrings(config.language).phrase("本机", "Local")
        let remoteName = AppStrings(config.language).phrase("远端", "Remote")
        return name.isEmpty
            || name == localName
            || name.hasPrefix("\(localName) ")
            || name == remoteName
            || name.hasPrefix("\(remoteName) ")
    }

    private func uniqueNodeID(fromSSHHostAlias alias: String) -> String {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        let scalars = trimmed.unicodeScalars.map { scalar -> Character in
            if CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-").contains(scalar) {
                return Character(scalar)
            }
            return "-"
        }
        var candidate = String(scalars)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
        if candidate.isEmpty || !CodexNode.isValidID(candidate) {
            candidate = "remote-\(codexNodes.count + 1)"
        }
        if !codexNodes.contains(where: { $0.id == candidate }) {
            return candidate
        }
        var suffix = 2
        while codexNodes.contains(where: { $0.id == "\(candidate)-\(suffix)" }) {
            suffix += 1
        }
        return "\(candidate)-\(suffix)"
    }

    private func preparedCodexNodeFormForSave(_ rawForm: CodexNodeFormState) -> CodexNodeFormState {
        guard rawForm.kind == .remote else {
            return rawForm
        }
        var form = rawForm
        let sshHost = form.sshHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sshHost.isEmpty {
            if shouldReplaceNodeIDForSSHHost(form.id) {
                form.id = uniqueNodeID(fromSSHHostAlias: sshHost)
            }
            if shouldReplaceNodeNameForSSHHost(form.name) {
                form.name = sshHost
            }
        }
        if !isValidPortText(form.localReceiverPort) {
            form.localReceiverPort = "43210"
        }
        if !isValidPortText(form.remoteReceiverPort) {
            form.remoteReceiverPort = defaultRemoteReceiverPort()
        }
        if form.secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            form.secret = UUID().uuidString
        }
        form.codexHomeOverride = ""
        return form
    }

    func removeCodexNode(id: String) {
        codexNodeError = nil
        do {
            stopCodexTunnel(id: id)
            let nextRegistry = CodexNodeRegistry(
                registeredNodes: codexNodeRegistry.registeredNodes.filter { $0.node.id != id }
            )
            try codexNodeStore.saveRegistry(nextRegistry)
            configureCodexNodeRegistry(nextRegistry)
            if codexNodeForm.id.trimmingCharacters(in: .whitespacesAndNewlines) == id
                || editingCodexNodeID == id {
                resetCodexNodeForm()
            }
        } catch {
            codexNodeError = codexNodeErrorMessage(error)
        }
    }

    func prepareCodexHookInstallPreview(nodeID: String) {
        guard let registeredNode = codexNodeRegistry.node(id: nodeID),
              !preparingCodexNodeInstallPreviewIDs.contains(nodeID) else {
            return
        }
        preparingCodexNodeInstallPreviewIDs.insert(nodeID)
        codexNodeOperationMessages[nodeID] = AppStrings(config.language).phrase("正在生成 hooks diff 预览...", "Preparing hooks diff preview...")
        Task { @MainActor in
            do {
                codexHookInstallPreview = try await codexHookInstallService.preview(registeredNode: registeredNode)
                codexNodeOperationMessages[nodeID] = AppStrings(config.language).phrase(
                    "hooks diff 预览已生成，请确认后写入。",
                    "Hooks diff preview is ready; confirm before writing."
                )
            } catch {
                let message = codexNodeErrorMessage(error)
                codexNodeHealthStore.markInstallFailed(
                    nodeID: nodeID,
                    state: .configWriteFailed,
                    detail: message,
                    now: Date()
                )
                publishCodexNodeHealthStatuses()
                codexNodeOperationMessages[nodeID] = message
            }
            preparingCodexNodeInstallPreviewIDs.remove(nodeID)
        }
    }

    func confirmCodexHookInstallPreview() {
        guard let preview = codexHookInstallPreview,
              !installingCodexNodeIDs.contains(preview.nodeID) else {
            return
        }
        installingCodexNodeIDs.insert(preview.nodeID)
        codexNodeOperationMessages[preview.nodeID] = AppStrings(config.language).phrase("正在写入 hooks...", "Writing hooks...")
        Task { @MainActor in
            do {
                let plan = try await codexHookInstallService.install(preview: preview)
                codexNodeHealthStore.markHooksInstalled(
                    nodeID: preview.nodeID,
                    detail: AppStrings(config.language).phrase(
                        "hooks 已写入。请在 Codex 中打开 /hooks 信任 Sub2APIStatusBar task monitor，然后运行一个 turn。",
                        "Hooks installed. Open /hooks in Codex, trust Sub2APIStatusBar task monitor, then run a turn."
                    ),
                    now: Date()
                )
                publishCodexNodeHealthStatuses()
                codexNodeOperationMessages[preview.nodeID] = AppStrings(config.language).phrase(
                    "hooks 已写入 \(plan.codexConfigPath)，正在执行测试事件。",
                    "Hooks installed at \(plan.codexConfigPath); running a test event."
                )
                if let registeredNode = codexNodeRegistry.node(id: preview.nodeID) {
                    await sendCodexTestEvent(
                        registeredNode: registeredNode,
                        context: .afterInstall(configPath: plan.codexConfigPath)
                    )
                } else {
                    codexNodeOperationMessages[preview.nodeID] = AppStrings(config.language).phrase(
                        "hooks 已写入 \(plan.codexConfigPath)，但节点记录已不存在，无法发送测试事件。",
                        "Hooks installed at \(plan.codexConfigPath), but the node record no longer exists, so the test event could not be sent."
                    )
                }
                codexHookInstallPreview = nil
            } catch {
                let message = codexNodeErrorMessage(error)
                codexNodeHealthStore.markInstallFailed(
                    nodeID: preview.nodeID,
                    detail: message,
                    now: Date()
                )
                publishCodexNodeHealthStatuses()
                codexNodeOperationMessages[preview.nodeID] = message
            }
            installingCodexNodeIDs.remove(preview.nodeID)
        }
    }

    func cancelCodexHookInstallPreview() {
        codexHookInstallPreview = nil
    }

    func startCodexTunnel(nodeID: String) {
        guard let registeredNode = codexNodeRegistry.node(id: nodeID) else {
            return
        }
        do {
            let status = try sshTunnelManager.start(node: registeredNode.node)
            codexTunnelStatuses[nodeID] = status
            applyTunnelHealth(status)
            switch status.state {
            case .starting:
                codexNodeOperationMessages[nodeID] = AppStrings(config.language).phrase(
                    "SSH-R 隧道正在启动，正在确认 remote forwarding。",
                    "SSH-R tunnel is starting; confirming remote forwarding."
                )
                scheduleCodexTunnelStartupProbe(nodeID: nodeID)
            case .running:
                codexNodeOperationMessages[nodeID] = AppStrings(config.language).phrase("SSH-R 隧道已启动。", "SSH-R tunnel started.")
                scheduleRemoteTunnelPathProbeIfNeeded(registeredNode: registeredNode)
            case .failed:
                codexNodeOperationMessages[nodeID] = sshTunnelFailedMessage(status)
            }
        } catch {
            codexNodeHealthStore.markTunnelFailed(nodeID: nodeID, detail: error.localizedDescription, now: Date())
            publishCodexNodeHealthStatuses()
            codexNodeOperationMessages[nodeID] = error.localizedDescription
        }
    }

    private func ensureRemoteCodexTunnels() {
        for registeredNode in codexNodeRegistry.registeredNodes where registeredNode.node.kind == .remote {
            ensureCodexTunnel(registeredNode: registeredNode, announce: false)
        }
    }

    private func ensureCodexTunnel(registeredNode: CodexRegisteredNode, announce: Bool) {
        let nodeID = registeredNode.node.id
        do {
            let status = try sshTunnelManager.ensureStarted(node: registeredNode.node)
            codexTunnelStatuses[nodeID] = status
            applyTunnelHealth(status)
            switch status.state {
            case .starting:
                if announce {
                    codexNodeOperationMessages[nodeID] = AppStrings(config.language).phrase("SSH-R 正在启动。", "SSH-R is starting.")
                }
                scheduleCodexTunnelStartupProbe(nodeID: nodeID)
            case .running:
                if announce {
                    codexNodeOperationMessages[nodeID] = AppStrings(config.language).phrase("SSH-R 已就绪。", "SSH-R is ready.")
                }
                scheduleRemoteTunnelPathProbeIfNeeded(registeredNode: registeredNode)
            case .failed:
                codexNodeOperationMessages[nodeID] = sshTunnelFailedMessage(status)
            }
        } catch {
            codexNodeHealthStore.markTunnelFailed(nodeID: nodeID, detail: error.localizedDescription, now: Date())
            publishCodexNodeHealthStatuses()
            codexNodeOperationMessages[nodeID] = error.localizedDescription
        }
    }

    func stopCodexTunnel(id nodeID: String) {
        codexTunnelStartupProbeTasks[nodeID]?.cancel()
        codexTunnelStartupProbeTasks[nodeID] = nil
        probingRemoteTunnelNodeIDs.remove(nodeID)
        lastRemoteTunnelPathProbeAtByNodeID.removeValue(forKey: nodeID)
        sshTunnelManager.stop(nodeID: nodeID)
        codexTunnelStatuses[nodeID] = nil
        codexNodeHealthStore.markTunnelStopped(
            nodeID: nodeID,
            detail: AppStrings(config.language).phrase("SSH-R 隧道已停止。", "SSH-R tunnel stopped."),
            now: Date()
        )
        publishCodexNodeHealthStatuses()
    }

    func stopAllCodexTunnels() {
        for task in codexTunnelStartupProbeTasks.values {
            task.cancel()
        }
        codexTunnelStartupProbeTasks.removeAll()
        probingRemoteTunnelNodeIDs.removeAll()
        lastRemoteTunnelPathProbeAtByNodeID.removeAll()
        sshTunnelManager.stopAll()
        codexTunnelStatuses.removeAll()
    }

    func refreshCodexTunnelStatus(nodeID: String) {
        guard let registeredNode = codexNodeRegistry.node(id: nodeID) else {
            return
        }
        ensureCodexTunnel(registeredNode: registeredNode, announce: true)
    }

    private func scheduleCodexTunnelStartupProbe(nodeID: String) {
        codexTunnelStartupProbeTasks[nodeID]?.cancel()
        codexTunnelStartupProbeTasks[nodeID] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return
            }
            self?.codexTunnelStartupProbeTasks[nodeID] = nil
            self?.refreshCodexTunnelStatus(nodeID: nodeID)
        }
    }

    private func scheduleRemoteTunnelPathProbeIfNeeded(registeredNode: CodexRegisteredNode) {
        let nodeID = registeredNode.node.id
        guard !probingRemoteTunnelNodeIDs.contains(nodeID),
              CodexRemoteTunnelPathProbePolicy.shouldProbe(
                  status: codexTunnelStatuses[nodeID],
                  lastProbeAt: lastRemoteTunnelPathProbeAtByNodeID[nodeID],
                  now: Date(),
                  minimumInterval: remoteTunnelPathProbeMinimumInterval
              ) else {
            return
        }

        probingRemoteTunnelNodeIDs.insert(nodeID)
        lastRemoteTunnelPathProbeAtByNodeID[nodeID] = Date()
        Task { @MainActor in
            await probeRemoteTunnelPath(registeredNode: registeredNode)
        }
    }

    private func probeRemoteTunnelPath(registeredNode: CodexRegisteredNode) async {
        let nodeID = registeredNode.node.id
        defer {
            probingRemoteTunnelNodeIDs.remove(nodeID)
        }

        guard isCurrentRegisteredCodexNode(registeredNode) else {
            return
        }
        do {
            let result = try await codexRemoteTestEventService.send(registeredNode: registeredNode)
            guard result.exitCode == 0 else {
                let failure = CodexHookTestEventFailureClassifier.classifyRemoteResult(result)
                if failure.kind == .transportFailed {
                    await restartRemoteTunnelAfterPathProbeFailure(
                        registeredNode: registeredNode,
                        detail: failure.detail
                    )
                    return
                }
                applyCodexTestEventFailure(
                    failure,
                    nodeID: nodeID,
                    receiverPort: registeredNode.node.localReceiverPort,
                    operationPrefix: AppStrings(config.language).phrase(
                        "SSH-R 路径探测失败",
                        "SSH-R path probe failed"
                    )
                )
                publishCodexNodeHealthStatuses()
                return
            }
        } catch {
            await restartRemoteTunnelAfterPathProbeFailure(
                registeredNode: registeredNode,
                detail: error.localizedDescription
            )
        }
    }

    private func restartRemoteTunnelAfterPathProbeFailure(
        registeredNode: CodexRegisteredNode,
        detail: String
    ) async {
        let nodeID = registeredNode.node.id
        guard isCurrentRegisteredCodexNode(registeredNode) else {
            return
        }

        let failureDetail = AppStrings(config.language).phrase(
            "SSH-R 路径探测失败，正在重建隧道：\(detail)",
            "SSH-R path probe failed; rebuilding tunnel: \(detail)"
        )
        codexNodeHealthStore.markTunnelFailed(nodeID: nodeID, detail: failureDetail, now: Date())
        publishCodexNodeHealthStatuses()
        sshTunnelManager.stop(nodeID: nodeID)
        codexTunnelStatuses[nodeID] = nil
        codexTunnelStartupProbeTasks[nodeID]?.cancel()
        codexTunnelStartupProbeTasks[nodeID] = nil
        ensureCodexTunnel(registeredNode: registeredNode, announce: false)
    }

    private func isCurrentRegisteredCodexNode(_ registeredNode: CodexRegisteredNode) -> Bool {
        codexNodeRegistry.node(id: registeredNode.node.id) == registeredNode
    }

    func sendCodexTestEvent(nodeID: String) {
        guard let registeredNode = codexNodeRegistry.node(id: nodeID) else {
            return
        }
        Task { @MainActor in
            await sendCodexTestEvent(registeredNode: registeredNode, context: .manual)
        }
    }

    private func sendCodexTestEvent(
        registeredNode: CodexRegisteredNode,
        context: CodexTestEventContext
    ) async {
        if registeredNode.node.kind == .remote {
            await sendRemoteCodexTestEvent(registeredNode: registeredNode, context: context)
            return
        }
        let nodeID = registeredNode.node.id
        let startMessage = codexTestEventStartMessage(context, remote: false)
        codexNodeOperationMessages[nodeID] = AppStrings(config.language).phrase(startMessage.zh, startMessage.en)
        do {
            let request = try CodexHookTestEventRequestBuilder.build(
                registeredNode: registeredNode,
                now: Date(),
                receiverURL: registeredNode.node.localHookReceiverURL
            )
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw TokenRouterError.badStatus(0, "Invalid test event response.")
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                let failurePrefix = codexTestEventFailurePrefix(context, remote: false)
                applyCodexTestEventFailure(
                    CodexHookTestEventFailureClassifier.classifyLocalHTTPStatus(httpResponse.statusCode),
                    nodeID: nodeID,
                    receiverPort: registeredNode.node.localReceiverPort,
                    operationPrefix: AppStrings(config.language).phrase(failurePrefix.zh, failurePrefix.en)
                )
                publishCodexNodeHealthStatuses()
                let message = codexTestEventHTTPFailureMessage(context, statusCode: httpResponse.statusCode)
                codexNodeOperationMessages[nodeID] = AppStrings(config.language).phrase(message.zh, message.en)
                return
            }
            let message = codexTestEventSuccessMessage(context, remote: false)
            codexNodeOperationMessages[nodeID] = AppStrings(config.language).phrase(message.zh, message.en)
        } catch {
            codexNodeHealthStore.markReceiverFailed(
                port: registeredNode.node.localReceiverPort,
                nodes: codexNodeRegistry.nodes,
                detail: error.localizedDescription,
                now: Date()
            )
            publishCodexNodeHealthStatuses()
            let message = codexTestEventThrownErrorMessage(context, remote: false, detail: error.localizedDescription)
            codexNodeOperationMessages[nodeID] = AppStrings(config.language).phrase(message.zh, message.en)
        }
    }

    private func sendRemoteCodexTestEvent(
        registeredNode: CodexRegisteredNode,
        context: CodexTestEventContext
    ) async {
        guard await ensureRemoteTunnelReady(registeredNode: registeredNode, context: context) else {
            return
        }
        let nodeID = registeredNode.node.id
        let startMessage = codexTestEventStartMessage(context, remote: true)
        codexNodeOperationMessages[nodeID] = AppStrings(config.language).phrase(startMessage.zh, startMessage.en)
        do {
            let result = try await codexRemoteTestEventService.send(registeredNode: registeredNode)
            guard result.exitCode == 0 else {
                let failure = CodexHookTestEventFailureClassifier.classifyRemoteResult(result)
                let failurePrefix = codexTestEventFailurePrefix(context, remote: true)
                applyCodexTestEventFailure(
                    failure,
                    nodeID: nodeID,
                    receiverPort: registeredNode.node.localReceiverPort,
                    operationPrefix: AppStrings(config.language).phrase(failurePrefix.zh, failurePrefix.en)
                )
                publishCodexNodeHealthStatuses()
                let message = codexTestEventRemoteFailureMessage(context, detail: failure.detail)
                codexNodeOperationMessages[nodeID] = AppStrings(config.language).phrase(message.zh, message.en)
                return
            }
            let message = codexTestEventSuccessMessage(context, remote: true)
            codexNodeOperationMessages[nodeID] = AppStrings(config.language).phrase(message.zh, message.en)
        } catch {
            codexNodeHealthStore.markTunnelFailed(nodeID: nodeID, detail: error.localizedDescription, now: Date())
            publishCodexNodeHealthStatuses()
            let message = codexTestEventThrownErrorMessage(context, remote: true, detail: error.localizedDescription)
            codexNodeOperationMessages[nodeID] = AppStrings(config.language).phrase(message.zh, message.en)
        }
    }

    private func ensureRemoteTunnelReady(
        registeredNode: CodexRegisteredNode,
        context: CodexTestEventContext
    ) async -> Bool {
        let node = registeredNode.node
        let nodeID = node.id
        if let status = sshTunnelManager.status(nodeID: nodeID) {
            codexTunnelStatuses[nodeID] = status
            applyTunnelHealth(status)
            switch CodexRemoteTestEventTunnelGate.decideBeforeSending(currentStatus: status) {
            case .ready:
                return true
            case .waitForRunning:
                let message = codexRemoteTunnelPreparingMessage(context)
                codexNodeOperationMessages[nodeID] = AppStrings(config.language).phrase(message.zh, message.en)
                return await waitForRemoteTunnelRunning(nodeID: nodeID, context: context)
            case .startTunnel:
                break
            }
        }

        do {
            let status = try sshTunnelManager.start(node: node)
            codexTunnelStatuses[nodeID] = status
            applyTunnelHealth(status)
            switch CodexRemoteTestEventTunnelGate.decideAfterStart(startStatus: status) {
            case .ready:
                return true
            case .notReady(.stillStarting):
                let message = codexRemoteTunnelPreparingMessage(context)
                codexNodeOperationMessages[nodeID] = AppStrings(config.language).phrase(message.zh, message.en)
                return await waitForRemoteTunnelRunning(nodeID: nodeID, context: context)
            case let .notReady(reason):
                let message = codexRemoteTunnelNotReadyMessage(
                    context,
                    state: codexRemoteTunnelStateDescription(reason)
                )
                codexNodeOperationMessages[nodeID] = AppStrings(config.language).phrase(message.zh, message.en)
                return false
            }
        } catch {
            codexNodeHealthStore.markTunnelFailed(nodeID: nodeID, detail: error.localizedDescription, now: Date())
            publishCodexNodeHealthStatuses()
            let message = codexRemoteTunnelStartFailureMessage(context, detail: error.localizedDescription)
            codexNodeOperationMessages[nodeID] = AppStrings(config.language).phrase(message.zh, message.en)
            return false
        }
    }

    private func waitForRemoteTunnelRunning(
        nodeID: String,
        context: CodexTestEventContext
    ) async -> Bool {
        do {
            try await Task.sleep(nanoseconds: 1_000_000_000)
        } catch {
            return false
        }
        let waitedStatus = sshTunnelManager.status(nodeID: nodeID)
        guard let status = waitedStatus else {
            codexNodeHealthStore.markTunnelFailed(
                nodeID: nodeID,
                detail: AppStrings(config.language).phrase("SSH-R 隧道状态丢失。", "SSH-R tunnel status is missing."),
                now: Date()
            )
            publishCodexNodeHealthStatuses()
            let message = codexRemoteTunnelNotReadyMessage(context, state: "missing")
            codexNodeOperationMessages[nodeID] = AppStrings(config.language).phrase(message.zh, message.en)
            return false
        }
        codexTunnelStatuses[nodeID] = status
        applyTunnelHealth(status)
        switch CodexRemoteTestEventTunnelGate.decideAfterWait(waitedStatus: waitedStatus) {
        case .ready:
            return true
        case let .notReady(reason):
            let message = codexRemoteTunnelNotReadyMessage(
                context,
                state: codexRemoteTunnelStateDescription(reason)
            )
            codexNodeOperationMessages[nodeID] = AppStrings(config.language).phrase(message.zh, message.en)
            return false
        }
    }

    private func codexRemoteTunnelStateDescription(
        _ reason: CodexRemoteTestEventTunnelNotReadyReason
    ) -> String {
        switch reason {
        case .missingStatus:
            return "missing"
        case .stillStarting:
            return AppStrings(config.language).phrase("仍在启动", "still starting")
        case let .failed(exitCode):
            return "exit \(exitCode)"
        }
    }

    private func codexRemoteTunnelPreparingMessage(
        _ context: CodexTestEventContext
    ) -> (zh: String, en: String) {
        switch context {
        case .manual:
            return (
                "远端测试事件需要 SSH-R 隧道，正在启动并确认隧道。",
                "Remote test event requires SSH-R; starting and confirming the tunnel."
            )
        case let .afterInstall(configPath):
            return (
                "hooks 已写入 \(configPath)，正在启动并确认 SSH-R 隧道，然后发送远端测试事件。",
                "Hooks installed at \(configPath); starting and confirming SSH-R before sending the remote test event."
            )
        }
    }

    private func codexRemoteTunnelNotReadyMessage(
        _ context: CodexTestEventContext,
        state: String
    ) -> (zh: String, en: String) {
        switch context {
        case .manual:
            return (
                "远端测试事件未发送：SSH-R 隧道未进入运行中状态（\(state)）。",
                "Remote test event was not sent: SSH-R tunnel is not running (\(state))."
            )
        case let .afterInstall(configPath):
            return (
                "hooks 已写入 \(configPath)，但远端测试事件未发送：SSH-R 隧道未进入运行中状态（\(state)）。",
                "Hooks installed at \(configPath), but the remote test event was not sent: SSH-R tunnel is not running (\(state))."
            )
        }
    }

    private func codexRemoteTunnelStartFailureMessage(
        _ context: CodexTestEventContext,
        detail: String
    ) -> (zh: String, en: String) {
        switch context {
        case .manual:
            return (
                "远端测试事件未发送：SSH-R 隧道启动失败：\(detail)",
                "Remote test event was not sent: SSH-R tunnel failed to start: \(detail)"
            )
        case let .afterInstall(configPath):
            return (
                "hooks 已写入 \(configPath)，但远端测试事件未发送：SSH-R 隧道启动失败：\(detail)",
                "Hooks installed at \(configPath), but the remote test event was not sent: SSH-R tunnel failed to start: \(detail)"
            )
        }
    }

    private func codexTestEventStartMessage(
        _ context: CodexTestEventContext,
        remote: Bool
    ) -> (zh: String, en: String) {
        switch context {
        case .manual:
            if remote {
                return (
                    "正在通过 SSH-R 发送远端测试事件...",
                    "Sending remote test event through SSH-R..."
                )
            }
            return (
                "正在向本机 receiver 发送测试事件...",
                "Sending test event to the local receiver..."
            )
        case let .afterInstall(configPath):
            if remote {
                return (
                    "hooks 已写入 \(configPath)，正在通过 SSH-R 发送远端测试事件。",
                    "Hooks installed at \(configPath); sending a remote test event through SSH-R."
                )
            }
            return (
                "hooks 已写入 \(configPath)，正在向本机 receiver 发送测试事件。",
                "Hooks installed at \(configPath); sending a test event to the local receiver."
            )
        }
    }

    private func codexTestEventSuccessMessage(
        _ context: CodexTestEventContext,
        remote: Bool
    ) -> (zh: String, en: String) {
        switch context {
        case .manual:
            if remote {
                return (
                    "远端测试事件已到达，等待真实任务事件。",
                    "Remote test event received; waiting for real task events."
                )
            }
            return (
                "测试事件已到达，等待真实任务事件。",
                "Test event received; waiting for real task events."
            )
        case let .afterInstall(configPath):
            if remote {
                return (
                    "hooks 已写入 \(configPath)，远端测试事件已到达。",
                    "Hooks installed at \(configPath); remote test event received."
                )
            }
            return (
                "hooks 已写入 \(configPath)，测试事件已到达。",
                "Hooks installed at \(configPath); test event received."
            )
        }
    }

    private func codexTestEventFailurePrefix(
        _ context: CodexTestEventContext,
        remote: Bool
    ) -> (zh: String, en: String) {
        switch context {
        case .manual:
            return remote ? ("远端测试事件失败", "Remote test event failed") : ("测试事件被拒绝", "Test event rejected")
        case .afterInstall:
            return remote ? ("安装后的远端测试事件失败", "Post-install remote test event failed") : ("安装后的测试事件被拒绝", "Post-install test event rejected")
        }
    }

    private func codexTestEventHTTPFailureMessage(
        _ context: CodexTestEventContext,
        statusCode: Int
    ) -> (zh: String, en: String) {
        let prefix = codexTestEventFailurePrefix(context, remote: false)
        return (
            "\(prefix.zh)，HTTP \(statusCode)。",
            "\(prefix.en), HTTP \(statusCode)."
        )
    }

    private func codexTestEventRemoteFailureMessage(
        _ context: CodexTestEventContext,
        detail: String
    ) -> (zh: String, en: String) {
        let prefix = codexTestEventFailurePrefix(context, remote: true)
        return (
            "\(prefix.zh)：\(detail)",
            "\(prefix.en): \(detail)"
        )
    }

    private func codexTestEventThrownErrorMessage(
        _ context: CodexTestEventContext,
        remote: Bool,
        detail: String
    ) -> (zh: String, en: String) {
        switch context {
        case .manual:
            return (detail, detail)
        case let .afterInstall(configPath):
            if remote {
                return (
                    "hooks 已写入 \(configPath)，但安装后的远端测试事件发送失败：\(detail)",
                    "Hooks installed at \(configPath), but the post-install remote test event failed: \(detail)"
                )
            }
            return (
                "hooks 已写入 \(configPath)，但安装后的测试事件发送失败：\(detail)",
                "Hooks installed at \(configPath), but the post-install test event failed: \(detail)"
            )
        }
    }

    private func applyCodexTestEventFailure(
        _ failure: CodexHookTestEventFailure,
        nodeID: String,
        receiverPort: Int,
        operationPrefix: String
    ) {
        let detail = [operationPrefix, failure.detail]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: ": ")
        switch failure.kind {
        case .invalidSignature:
            codexNodeHealthStore.markInvalidSignature(nodeID: nodeID, detail: detail, now: Date())
        case .replayRejected, .receiverRejected, .receiverUnavailable:
            codexNodeHealthStore.markReceiverFailed(
                port: receiverPort,
                nodes: codexNodeRegistry.nodes,
                detail: detail,
                now: Date()
            )
        case .transportFailed:
            codexNodeHealthStore.markTunnelFailed(nodeID: nodeID, detail: detail, now: Date())
        }
    }

    private func syncCodexHookReceivers() {
        let requiredPorts = Set(codexNodeRegistry.nodes.compactMap { UInt16(exactly: $0.localReceiverPort) })
        let obsoletePorts = codexHookReceiverServers.keys.filter { !requiredPorts.contains($0) }
        for port in obsoletePorts {
            codexHookReceiverServers[port]?.stop()
            codexHookReceiverServers.removeValue(forKey: port)
        }
        for server in codexHookReceiverServers.values {
            server.updateNodeSecrets(codexNodeRegistry.nodeSecrets)
        }
        for port in requiredPorts where codexHookReceiverServers[port] == nil {
            startCodexHookReceiver(port: port)
        }
    }

    private func startCodexHookReceiver(port: UInt16) {
        let server = LocalCodexHookReceiverServer(
            port: port,
            nodeSecrets: codexNodeRegistry.nodeSecrets,
            onStateChange: { [weak self] state in
                self?.applyReceiverState(state, port: Int(port))
            },
            onEvent: { [weak self] event in
                self?.applyCodexHookEvent(event)
            }
        )
        do {
            try server.start()
            codexHookReceiverServers[port] = server
        } catch {
            codexNodeHealthStore.markReceiverFailed(
                port: Int(port),
                nodes: codexNodeRegistry.nodes,
                detail: error.localizedDescription,
                now: Date()
            )
            publishCodexNodeHealthStatuses()
            settingsError = error.localizedDescription
        }
    }

    private func applyReceiverState(_ state: LocalCodexHookReceiverState, port: Int) {
        switch state {
        case .ready:
            codexNodeHealthStore.markReceiverReady(port: port, nodes: codexNodeRegistry.nodes, now: Date())
        case let .failed(detail):
            codexNodeHealthStore.markReceiverFailed(port: port, nodes: codexNodeRegistry.nodes, detail: detail, now: Date())
        case let .invalidSignature(nodeID):
            codexNodeHealthStore.markInvalidSignature(
                nodeID: nodeID,
                detail: AppStrings(config.language).phrase("hook 签名无效。", "Invalid hook signature."),
                now: Date()
            )
        case .stopped:
            return
        }
        publishCodexNodeHealthStatuses()
    }

    private func applyTunnelHealth(_ status: SSHTunnelStatus) {
        switch status.state {
        case .starting:
            break
        case .running:
            codexNodeHealthStore.markTunnelRunning(nodeID: status.nodeID, now: Date())
        case .failed:
            codexNodeHealthStore.markTunnelFailed(
                nodeID: status.nodeID,
                detail: sshTunnelFailureDetail(status),
                now: Date()
            )
        }
        publishCodexNodeHealthStatuses()
    }

    private func sshTunnelFailedMessage(_ status: SSHTunnelStatus) -> String {
        AppStrings(config.language).phrase(
            "SSH-R 隧道启动失败：\(sshTunnelFailureDetail(status))。",
            "SSH-R tunnel failed to start: \(sshTunnelFailureDetail(status))."
        )
    }

    private func sshTunnelFailureDetail(_ status: SSHTunnelStatus) -> String {
        let exitText: String
        switch status.state {
        case let .failed(exitCode):
            exitText = "exit \(exitCode)"
        case .starting:
            exitText = AppStrings(config.language).phrase("启动中", "starting")
        case .running:
            exitText = AppStrings(config.language).phrase("运行中", "running")
        }
        guard let detail = status.detail?.trimmingCharacters(in: .whitespacesAndNewlines),
              !detail.isEmpty else {
            return exitText
        }
        return "\(exitText) · \(detail)"
    }

    private func publishCodexNodeHealthStatuses() {
        codexNodeHealthStatuses = codexNodeHealthStore.statuses
    }

    private func scheduleCodexHookInstallStatusRefresh() {
        codexHookInstallStatusRefreshTask?.cancel()
        let registeredNodes = codexNodeRegistry.registeredNodes
        guard !registeredNodes.isEmpty else {
            codexHookInstallStatusRefreshTask = nil
            return
        }
        codexHookInstallStatusRefreshTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            await self.refreshCodexHookInstallStatuses(registeredNodes: registeredNodes)
        }
    }

    private func refreshCodexHookInstallStatuses(registeredNodes: [CodexRegisteredNode]) async {
        for registeredNode in registeredNodes {
            guard !Task.isCancelled,
                  codexNodeRegistry.node(id: registeredNode.node.id) == registeredNode else {
                continue
            }
            do {
                _ = try await codexHookInstallService.installedStatus(registeredNode: registeredNode)
                codexNodeHealthStore.markHooksConfigured(
                    nodeID: registeredNode.node.id,
                    detail: AppStrings(config.language).phrase(
                        "hooks 已验证",
                        "Hooks verified"
                    ),
                    now: Date()
                )
                if registeredNode.node.kind == .remote {
                    ensureCodexTunnel(registeredNode: registeredNode, announce: false)
                }
            } catch let validationError as CodexHookConfigValidationError {
                guard codexNodeHealthStore.status(nodeID: registeredNode.node.id)?.state == .configWriteFailed else {
                    continue
                }
                codexNodeHealthStore.markInstallFailed(
                    nodeID: registeredNode.node.id,
                    state: .unconfigured,
                    detail: validationError.localizedDescription,
                    now: Date()
                )
            } catch {
                codexNodeHealthStore.markInstallFailed(
                    nodeID: registeredNode.node.id,
                    state: .configWriteFailed,
                    detail: codexNodeErrorMessage(error),
                    now: Date()
                )
            }
        }
        publishCodexNodeHealthStatuses()
    }

    private func refreshCodexRuntimeState(now: Date = Date()) -> [CodexTaskActivity] {
        let activities = codexRuntimeStateRefresher.refresh(
            activityStore: &codexTaskActivityStore,
            nodeHealthStore: &codexNodeHealthStore,
            now: now
        )
        publishCodexNodeHealthStatuses()
        persistCodexTaskActivities(activities)
        return activities
    }

    private func codexNodeErrorMessage(_ error: Error) -> String {
        let strings = AppStrings(config.language)
        if let installError = error as? CodexHookInstallServiceError {
            return installError.message(strings: strings)
        }
        if let homeError = error as? CodexHomeResolutionError {
            switch homeError {
            case .missingRemoteHomeDirectory:
                return strings.phrase(
                    "远端环境未返回 CODEX_HOME 或 HOME，无法确定用户级 Codex 配置目录。",
                    "The remote environment did not return CODEX_HOME or HOME, so the user-level Codex config directory cannot be resolved."
                )
            }
        }
        if let validationError = error as? CodexNodeValidationError {
            switch validationError {
            case .emptyID:
                return strings.phrase("节点 ID 不能为空。", "Node ID is required.")
            case .invalidID:
                return strings.phrase(
                    "节点 ID 只能使用英文字母、数字、点、下划线和短横线，并且必须以英文字母或数字开头。",
                    "Node ID must start with a letter or number and only contain letters, numbers, dots, underscores, and hyphens."
                )
            case .emptyName:
                return strings.phrase("显示名称不能为空。", "Display name is required.")
            case .emptySecret:
                return strings.phrase("节点密钥不能为空。", "Secret is required.")
            case .invalidLocalReceiverPort:
                return strings.phrase("本机监听端口必须是 1 到 65535。", "Local receiver port must be between 1 and 65535.")
            case .invalidRemoteReceiverPort:
                return strings.phrase("远端转发端口自动生成失败，请重置表单后重新保存。", "Remote forwarding port generation failed. Reset the form and save again.")
            case .missingRemoteReceiverPort:
                return strings.phrase("远端节点缺少自动生成的远端转发端口，请重置表单后重新保存。", "Remote node is missing its generated remote forwarding port. Reset the form and save again.")
            case .missingSSHConnection:
                return strings.phrase("远端节点必须填写 SSH 连接信息。", "Remote nodes require SSH connection settings.")
            case .emptySSHHost:
                return strings.phrase("SSH 主机不能为空。", "SSH host is required.")
            }
        }
        if let formError = error as? CodexNodeFormError {
            switch formError {
            case .invalidLocalReceiverPort:
                return strings.phrase("本机监听端口必须是 1 到 65535。", "Local receiver port must be between 1 and 65535.")
            case .invalidRemoteReceiverPort:
                return strings.phrase("远端转发端口自动生成失败，请重置表单后重新保存。", "Remote forwarding port generation failed. Reset the form and save again.")
            case .invalidSSHPort:
                return strings.phrase("SSH 端口必须留空或填写 1 到 65535。", "SSH port must be empty or between 1 and 65535.")
            }
        }
        return error.localizedDescription
    }

    private func loadCodexNodeRegistry() {
        do {
            codexNodeRegistry = try codexNodeStore.loadRegistry()
            codexNodes = codexNodeRegistry.nodes
            codexNodeHealthStore.configure(nodes: codexNodeRegistry.nodes, now: Date())
            codexTaskActivityStore.keepOnlyActivities(forNodeIDs: Set(codexNodeRegistry.nodes.map(\.id)))
            let activities = refreshCodexRuntimeState()
            publish(snapshot.withCodexTaskActivities(activities))
            publishCodexNodeHealthStatuses()
            scheduleCodexHookInstallStatusRefresh()
        } catch {
            settingsError = error.localizedDescription
        }
    }

    private func loadCodexTaskActivities() {
        guard !hasLoadedCodexTaskActivities, !isLoadingCodexTaskActivities else {
            return
        }
        isLoadingCodexTaskActivities = true
        let persistence = codexTaskActivityPersistence

        Task { @MainActor [weak self] in
            do {
                let loadedStore = try await Task.detached(priority: .utility) {
                    try persistence.load()
                }.value
                guard let self else {
                    return
                }
                self.isLoadingCodexTaskActivities = false
                self.hasLoadedCodexTaskActivities = true
                self.lastPersistedCodexTaskActivities = loadedStore.activities
                self.codexTaskActivityStore.merge(activities: loadedStore.activities)
                self.codexTaskActivityStore.keepOnlyActivities(
                    forNodeIDs: Set(self.codexNodeRegistry.nodes.map(\.id))
                )
                let activities = self.refreshCodexRuntimeState()
                self.publish(self.snapshot.withCodexTaskActivities(activities))
            } catch {
                guard let self else {
                    return
                }
                self.isLoadingCodexTaskActivities = false
                self.hasLoadedCodexTaskActivities = true
                self.settingsError = error.localizedDescription
                let activities = self.refreshCodexRuntimeState()
                self.publish(self.snapshot.withCodexTaskActivities(activities))
            }
        }
    }

    private func persistCodexTaskActivities(_ activities: [CodexTaskActivity]) {
        guard hasLoadedCodexTaskActivities,
              activities != lastPersistedCodexTaskActivities,
              activities != pendingPersistedCodexTaskActivities else {
            return
        }
        pendingPersistedCodexTaskActivities = activities
        codexTaskPersistenceWorkItem?.cancel()

        let persistence = codexTaskActivityPersistence
        let workItem = DispatchWorkItem { [weak self] in
            let result: Result<Void, Error>
            do {
                try persistence.save(activities)
                result = .success(())
            } catch {
                result = .failure(error)
            }

            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                if self.pendingPersistedCodexTaskActivities == activities {
                    self.pendingPersistedCodexTaskActivities = nil
                }
                switch result {
                case .success:
                    self.lastPersistedCodexTaskActivities = activities
                case let .failure(error):
                    self.settingsError = error.localizedDescription
                }
            }
        }
        codexTaskPersistenceWorkItem = workItem
        codexTaskPersistenceQueue.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }

    private func isTransientRefreshFailure(_ error: Error) -> Bool {
        transientRefreshRetryPolicy.shouldRetry(error: error, attempt: 0)
    }

    private func staleRefreshMessage(_ error: Error) -> String {
        let detail = error.localizedDescription
        return AppStrings(config.language).phrase(
            "本次刷新失败，已保留上次成功数据并将按刷新间隔重试。\(detail)",
            "Refresh failed. Keeping the last successful data and retrying on the next interval. \(detail)"
        )
    }

    @discardableResult
    func saveSettings() -> Bool {
        persistSettingsDraft(refreshAfterSave: true)
    }

    func applySettingsChange(refreshAfterSave: Bool = true, _ change: (inout AppConfig) -> Void) {
        let previousDraft = settingsDraft
        change(&settingsDraft)
        guard settingsDraft != previousDraft else {
            return
        }
        settingsAutosaveTask?.cancel()
        settingsError = nil
        persistSettingsDraft(refreshAfterSave: refreshAfterSave)
    }

    func scheduleSettingsAutosave(refreshAfterSave: Bool = false) {
        settingsAutosaveTask?.cancel()
        guard hasPendingSettingsChange else {
            return
        }
        settingsAutosaveTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 550_000_000)
            } catch {
                return
            }
            self?.persistSettingsDraft(refreshAfterSave: refreshAfterSave)
        }
    }

    private var hasPendingSettingsChange: Bool {
        var next = settingsDraft
        next.applyCapabilityPolicy(currentCapabilityPolicy)
        return next != config
    }

    @discardableResult
    private func persistSettingsDraft(refreshAfterSave: Bool) -> Bool {
        settingsError = nil
        var next = settingsDraft
        next.applyCapabilityPolicy(currentCapabilityPolicy)
        settingsDraft = next
        guard next != config else {
            return true
        }
        let previousConfig = config
        let launchAtLoginChanged = next.launchAtLogin != previousConfig.launchAtLogin
        var previousLaunchAtLogin: Bool?
        do {
            if launchAtLoginChanged {
                previousLaunchAtLogin = launchAtLoginManager.isEnabled
                try launchAtLoginManager.setEnabled(next.launchAtLogin)
            }
            do {
                try store.save(next)
            } catch {
                if let previousLaunchAtLogin {
                    try? launchAtLoginManager.setEnabled(previousLaunchAtLogin)
                }
                throw error
            }
            config = next
            settingsDraft = next
            let authenticationChanged = previousConfig.baseURL != next.baseURL || previousConfig.authToken != next.authToken
            let monitoredUserChanged = previousConfig.adminMonitoredUserID != next.adminMonitoredUserID
            if previousConfig.baseURL != next.baseURL {
                openAIQuotaHistory = OpenAIQuotaHistory()
                persistOpenAIQuotaHistory(openAIQuotaHistory)
            }
            if authenticationChanged || monitoredUserChanged {
                resetTokenRouterRefreshState(clearIdentity: authenticationChanged)
            }
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

    private var currentCapabilityPolicy: CapabilityPolicy {
        CapabilityPolicy(isAdminAccount: snapshot.currentUser?.isAdmin == true)
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
            resetTokenRouterRefreshState(clearIdentity: true)
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
        let client = TokenRouterClient(config: draft)
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
        stopAllCodexTunnels()
        NSApp.terminate(nil)
    }

    private func publish(_ next: MonitorSnapshot) {
        snapshot = next
        onSnapshotChange?(next)
        scheduleReasoningEffortRefreshIfNeeded(for: next)
    }

    private func scheduleReasoningEffortRefreshIfNeeded(for snapshot: MonitorSnapshot) {
        guard config.menuBarDisplayItems.contains(.reasoningEffort),
              let latestUsage = snapshot.latestUsage,
              Self.hasMenuBarReasoningEffort(latestUsage.reasoningEffort) == false,
              latestUsage.id > 0 else {
            pendingReasoningEffortRefreshTask?.cancel()
            pendingReasoningEffortRefreshTask = nil
            pendingReasoningEffortUsageID = nil
            return
        }
        guard pendingReasoningEffortUsageID != latestUsage.id else {
            return
        }

        pendingReasoningEffortRefreshTask?.cancel()
        pendingReasoningEffortUsageID = latestUsage.id
        pendingReasoningEffortRefreshTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 2_500_000_000)
            } catch {
                return
            }
            self?.pendingReasoningEffortRefreshTask = nil
            self?.refresh()
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func hasMenuBarReasoningEffort(_ value: String?) -> Bool {
        StatusFormatters.reasoningEffortPresentation(value).isProvided
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
