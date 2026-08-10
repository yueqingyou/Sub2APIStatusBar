import SwiftUI
import Sub2APIStatusCore

struct MonitorPanel: View {
    @ObservedObject var model: MonitorViewModel
    @State private var selectedPage: PanelPage = .overview

    var body: some View {
        Group {
            if model.config.menuBarStatusDisplayMode == .signedOut {
                LoginPanel(model: model)
            } else {
                VStack(spacing: 0) {
                    header

                    content

                    PanelFooter(model: model, strings: strings)
                }
            }
        }
        .frame(width: 520, height: 680)
        .background(PanelBackground())
        .environment(\.appLanguage, model.config.language)
        .appAppearance(activeAppearance)
        .onChange(of: isAdminAccount) { _ in
            if !availablePages.contains(selectedPage) {
                selectedPage = .overview
            }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                PanelBrandMark(statusTint: iconColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text("TokenRouter")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                    Text(model.snapshot.connected ? lastUpdatedText : strings.phrase("未连接", "Disconnected"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                RefreshActionButton(
                    isRefreshing: model.isRefreshing,
                    label: strings.phrase("刷新", "Refresh")
                ) {
                    model.refresh(manual: true)
                }
            }
            .buttonStyle(.borderless)

            PanelPageTabs(selection: $selectedPage, pages: availablePages, strings: strings)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background(ClaudeTheme.header)
    }

    @ViewBuilder
    private var content: some View {
        switch selectedPage {
        case .overview:
            overviewContent
        case .accounts:
            OpenAIAccountsView(model: model, strings: strings)
        case .tasks:
            CodexWorkspaceView(model: model, strings: strings)
        case .settings:
            SettingsView(model: model)
        }
    }

    private var overviewContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if model.snapshot.isStale || !model.snapshot.connected {
                    statusSection
                }

                if let updateInfo = model.updateInfo, updateInfo.isUpdateAvailable {
                    UpdateAvailableBanner(
                        info: updateInfo,
                        isInstalling: model.isInstallingUpdate,
                        isHardwareFirmwareUpdating: model.hardwareFirmwareUpdateState.isInProgress,
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
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
        }
    }

    private var statusSection: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(iconColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(strings.statusLabel(for: model.snapshot))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(ClaudeTheme.primaryText)
                Text(statusDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .glassSurface(cornerRadius: 11)
    }

    private var userSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.snapshot.mode != .admin, let user = model.snapshot.currentUser {
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

            if model.snapshot.mode == .admin {
                if let quota = model.snapshot.openAIQuota {
                    if quota.accounts.isEmpty {
                        GlassEmptyState(
                            title: strings.phrase("暂无 OpenAI OAuth 账号", "No OpenAI OAuth accounts"),
                            systemImage: "person.crop.circle.badge.xmark",
                            minHeight: 90
                        )
                    } else {
                        OpenAIQuotaOverviewView(snapshot: quota, strings: strings)
                    }
                }
                if let error = model.snapshot.openAIQuotaError {
                    MessageRow(message: error)
                }
            } else if let trend = model.snapshot.trend, trend.count > 1 {
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
        if let normalAccountComposition = model.snapshot.adminNormalAccountComposition {
            items.append(normalAccountsMetric(normalAccountComposition))
        }
        items.append(contentsOf: [
            balanceMetric(),
            userAPIKeysMetric(stats),
            MetricItem(title: strings.phrase("今日请求", "Today Requests"), value: StatusFormatters.menuBarCount(stats.todayRequests), caption: requestCaption(stats), systemImage: "chart.bar", tint: ClaudeTheme.accent),
            MetricItem(title: strings.phrase("今日费用", "Today Cost"), value: StatusFormatters.preciseCurrency(stats.todayActualCost), caption: costCaption(stats), systemImage: "dollarsign.circle", tint: ClaudeTheme.accent),
            MetricItem(title: strings.phrase("今日 Token", "Today Tokens"), value: StatusFormatters.compactNumber(stats.todayTokens), caption: tokenBreakdown(input: stats.todayInputTokens, output: stats.todayOutputTokens), systemImage: "cube", tint: ClaudeTheme.accent),
            MetricItem(title: totalTokenTitle, value: StatusFormatters.compactNumber(stats.totalTokens), caption: tokenBreakdown(input: stats.totalInputTokens, output: stats.totalOutputTokens), systemImage: "archivebox.fill", tint: ClaudeTheme.accent),
            performanceMetric(stats),
            MetricItem(title: strings.phrase("平均响应", "Avg Response"), value: latencyText(milliseconds: stats.averageDurationMs), systemImage: "clock", tint: ClaudeTheme.accent),
        ].compactMap { $0 })
        return items
    }

    private func fallbackMetrics(summary: SubscriptionSummary) -> [MetricItem] {
        var items: [MetricItem] = []
        if let concurrency = model.snapshot.realtimeConcurrency {
            items.append(realtimeConcurrencyMetric(concurrency))
        }
        if let normalAccountComposition = model.snapshot.adminNormalAccountComposition {
            items.append(normalAccountsMetric(normalAccountComposition))
        }
        items.append(contentsOf: [
            balanceMetric(),
            MetricItem(title: strings.phrase("活跃订阅", "Active Subs"), value: "\(summary.activeCount)", systemImage: "checkmark.seal", tint: ClaudeTheme.accent),
            MetricItem(title: strings.phrase("峰值用量", "Peak Usage"), value: StatusFormatters.percent(summary.highestProgress), systemImage: "gauge.with.dots.needle.67percent", tint: ClaudeTheme.warning),
            MetricItem(title: strings.phrase("已用总额", "Total Used"), value: StatusFormatters.preciseCurrency(summary.totalUsedUSD), systemImage: "dollarsign.circle", tint: ClaudeTheme.gold),
        ].compactMap { $0 })
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

    private func normalAccountsMetric(_ composition: NormalAccountComposition) -> MetricItem {
        MetricItem(
            title: strings.phrase("正常账号", "Normal Accounts"),
            value: StatusFormatters.menuBarCount(Int64(composition.total)),
            caption: composition.compactLine(language: model.config.language),
            systemImage: "checkmark.seal",
            tint: ClaudeTheme.success
        )
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

    private var statusDescription: String {
        if model.snapshot.isStale {
            return strings.phrase(
                "本次刷新失败，仍显示上次成功数据，并会按刷新间隔自动重试。",
                "Refresh failed. Showing the last successful data and retrying on the refresh interval."
            )
        }
        return strings.phrase(
            "当前无法连接服务，检查网络或登录状态。",
            "The server is not reachable. Check network or login state."
        )
    }

    private func balanceMetric() -> MetricItem? {
        let balance: Double?
        if model.snapshot.mode == .admin,
           let monitoredUser = model.snapshot.monitoredUser {
            balance = monitoredUser.balance
        } else {
            balance = model.snapshot.currentUser?.balance
        }

        guard let balance else {
            return nil
        }
        return MetricItem(
            title: strings.phrase("余额", "Balance"),
            value: StatusFormatters.currency(balance),
            systemImage: "banknote",
            tint: ClaudeTheme.accent
        )
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

    private func requestCaption(_ stats: DashboardStats) -> String? {
        if model.snapshot.mode == .admin {
            return nil
        }
        return strings.phrase("总计 \(StatusFormatters.compactNumber(stats.totalRequests))", "Total \(StatusFormatters.compactNumber(stats.totalRequests))")
    }

    private func costCaption(_ stats: DashboardStats) -> String? {
        if model.snapshot.mode == .admin {
            return nil
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
        model.resolvedAppearance
    }

    private var isAdminAccount: Bool {
        model.snapshot.currentUser?.isAdmin == true
    }

    private var availablePages: [PanelPage] {
        PanelPage.availablePages(isAdmin: isAdminAccount)
    }
}
