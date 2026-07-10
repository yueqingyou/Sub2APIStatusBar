import SwiftUI
import Sub2APIStatusCore

struct MetricItem: Identifiable {
    let id: String
    let title: String
    let value: String
    let caption: String?
    let detail: String?
    let systemImage: String?
    let tint: Color

    init(title: String, value: String, caption: String? = nil, detail: String? = nil, systemImage: String? = nil, tint: Color = ClaudeTheme.accent) {
        id = "\(title)-\(systemImage ?? "")"
        self.title = title
        self.value = value
        self.caption = caption
        self.detail = detail
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
        HStack(spacing: 10) {
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
        .padding(10)
        .background(ClaudeTheme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(ClaudeTheme.warning.opacity(0.14))
                Image(systemName: "scope")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.warning)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(user.displayName)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(user.email)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            Spacer()

            if let concurrency {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(strings.phrase("并发占用", "Concurrency"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("\(concurrency.currentInUse)/\(concurrency.maxCapacity)")
                        .font(.system(size: 16, weight: .semibold).monospacedDigit())
                        .foregroundStyle(ClaudeTheme.warning)
                }
            }
        }
        .padding(10)
        .background(ClaudeTheme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(ClaudeTheme.avatarBackground)
            Text(initials)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(ClaudeTheme.avatarForeground)
        }
        .frame(width: 42, height: 42)
    }
}

struct MetricGrid: View {
    let items: [MetricItem]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(items) { item in
                HStack(spacing: 9) {
                    if let systemImage = item.systemImage {
                        SafeSystemImage(systemName: systemImage)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(item.tint)
                            .frame(width: 24, height: 24)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(item.value)
                            .font(.system(size: 16, weight: .semibold).monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        if let caption = item.caption {
                            Text(caption)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(ClaudeTheme.secondaryText)
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                        }
                        if let detail = item.detail {
                            Text(detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 58)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(ClaudeTheme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
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
                RoundedRectangle(cornerRadius: 8, style: .continuous)
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
                if let used, let limit {
                    Text("\(StatusFormatters.currency(used)) / \(StatusFormatters.currency(limit))")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
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
                    let presentation = StatusFormatters.modelPresentation(item.model)
                    VStack(spacing: 7) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(presentation.displayName)
                                    .font(.callout.weight(.medium))
                                    .lineLimit(1)
                                if presentation.isLossy {
                                    Text(item.model)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .help(item.model)
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
