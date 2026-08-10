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
                if displayName != user.email {
                    Text(user.email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }

            Spacer()

            if let status = user.status, !status.isEmpty {
                StatusPill(
                    title: strings.activeStatus(status),
                    tint: status.lowercased() == "active" ? ClaudeTheme.success : ClaudeTheme.slate,
                    systemImage: status.lowercased() == "active" ? "checkmark" : nil
                )
            }
        }
        .padding(12)
        .glassSurface(cornerRadius: 12)
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
                    .fill(ClaudeTheme.warning.opacity(0.08))
                Image(systemName: "scope")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.warning)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(user.displayName)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                if user.displayName != user.email {
                    Text(user.email)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
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
        .padding(12)
        .glassSurface(cornerRadius: 12)
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
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [ClaudeTheme.avatarBackground, ClaudeTheme.ink],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Text(initials)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(ClaudeTheme.avatarForeground)
        }
        .frame(width: 42, height: 42)
        .shadow(color: ClaudeTheme.accent.opacity(0.16), radius: 5, y: 2)
    }
}

struct MetricGrid: View {
    let items: [MetricItem]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(items) { item in
                HStack(spacing: 9) {
                    if let systemImage = item.systemImage {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(item.tint.opacity(0.075))
                            SafeSystemImage(systemName: systemImage)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(item.tint)
                        }
                        .frame(width: 28, height: 28)
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
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .glassSurface(cornerRadius: 12)
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
                Text(item.groupName)
                    .font(.headline)
                Spacer()
                StatusPill(
                    title: strings.activeStatus(item.status),
                    tint: item.status == "active" ? ClaudeTheme.success : ClaudeTheme.slate,
                    systemImage: item.status == "active" ? "checkmark" : nil
                )
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
                    .fill(ClaudeTheme.slate.opacity(0.08))
                Image(systemName: "tray")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(ClaudeTheme.slate)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 4) {
                Text(strings.phrase("暂无订阅", "No Subscriptions"))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(ClaudeTheme.primaryText)
                if activeCount > 0 {
                    Text(emptyDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            if activeCount > 0 {
                StatusPill(
                    title: strings.phrase("\(activeCount) 个活跃", "\(activeCount) active"),
                    tint: ClaudeTheme.success,
                    systemImage: "checkmark"
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private var emptyDescription: String {
        strings.phrase(
            "服务返回了活跃数量，但没有订阅明细。",
            "The service returned active counts but no subscription details."
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

            GlassProgressBar(value: normalizedProgress, tint: tint)

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
                        GlassProgressBar(
                            value: Double(item.totalTokens) / maximumTokens,
                            tint: ClaudeTheme.slate,
                            height: 5
                        )
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
    private enum Metric: String, CaseIterable, Identifiable {
        case total
        case input
        case output
        case cacheCreation
        case cacheRead

        var id: String { rawValue }
    }

    @Environment(\.appLanguage) private var language

    let points: [TrendDataPoint]
    @State private var metric: Metric = .total

    var body: some View {
        let metricValues = values
        let maximumValue = max(metricValues.max() ?? 0, 1)
        let chartPoints = parsedPoints(values: metricValues)

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("", selection: $metric) {
                    ForEach(Metric.allCases) { metric in
                        Text(metricTitle(metric)).tag(metric)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 150)
            }

            HStack(spacing: 6) {
                VStack(alignment: .trailing) {
                    Text(StatusFormatters.compactNumber(Int64(maximumValue)))
                    Spacer()
                    Text(StatusFormatters.compactNumber(Int64(maximumValue / 2)))
                    Spacer()
                    Text("0")
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(ClaudeTheme.secondaryText)
                .frame(width: 42, alignment: .trailing)

                GeometryReader { proxy in
                    ZStack {
                        grid(in: proxy.size)
                            .stroke(ClaudeTheme.border, lineWidth: 1)
                        trendPath(in: proxy.size, points: chartPoints, maximum: maximumValue)
                            .stroke(metricColor, style: StrokeStyle(lineWidth: 2.25, lineCap: .round, lineJoin: .round))
                    }
                }
            }

            HStack {
                Text(chartPoints.first?.label ?? "")
                Spacer()
                Text(chartPoints.last?.label ?? "")
            }
            .font(.caption2)
            .foregroundStyle(ClaudeTheme.secondaryText)
            .padding(.leading, 48)
        }
    }

    private var values: [Double] {
        points.map { point in
            switch metric {
            case .total:
                return Double(point.totalTokens)
            case .input:
                return Double(point.inputTokens)
            case .output:
                return Double(point.outputTokens)
            case .cacheCreation:
                return Double(point.cacheCreationTokens)
            case .cacheRead:
                return Double(point.cacheReadTokens)
            }
        }
    }

    private func grid(in size: CGSize) -> Path {
        var path = Path()
        for ratio in [0.0, 0.5, 1.0] {
            let y = size.height * CGFloat(ratio)
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
        }
        return path
    }

    private func trendPath(
        in size: CGSize,
        points: [(date: Date, value: Double, label: String)],
        maximum: Double
    ) -> Path {
        guard let firstDate = points.first?.date,
              let lastDate = points.last?.date else {
            return Path()
        }
        let duration = max(lastDate.timeIntervalSince(firstDate), 1)
        var path = Path()
        var previousDate: Date?
        for point in points {
            let x = size.width * CGFloat(point.date.timeIntervalSince(firstDate) / duration)
            let y = size.height - size.height * CGFloat(point.value / maximum)
            if let previousDate, point.date.timeIntervalSince(previousDate) <= 36 * 60 * 60 {
                path.addLine(to: CGPoint(x: x, y: y))
            } else {
                path.move(to: CGPoint(x: x, y: y))
            }
            previousDate = point.date
        }
        return path
    }

    private func parsedPoints(values: [Double]) -> [(date: Date, value: Double, label: String)] {
        zip(points, values).compactMap { point, value in
            Self.dateFormatter.date(from: point.date).map { ($0, value, point.date) }
        }.sorted { $0.date < $1.date }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private var metricColor: Color {
        switch metric {
        case .total:
            return ClaudeTheme.accent
        case .input:
            return ClaudeTheme.slate
        case .output:
            return ClaudeTheme.warm
        case .cacheCreation:
            return ClaudeTheme.gold
        case .cacheRead:
            return ClaudeTheme.sand
        }
    }

    private func metricTitle(_ metric: Metric) -> String {
        switch metric {
        case .total:
            return strings.phrase("总量", "Total")
        case .input:
            return strings.phrase("输入", "Input")
        case .output:
            return strings.phrase("输出", "Output")
        case .cacheCreation:
            return strings.phrase("缓存写入", "Cache Write")
        case .cacheRead:
            return strings.phrase("缓存读取", "Cache Read")
        }
    }

    private var strings: AppStrings {
        AppStrings(language)
    }
}
