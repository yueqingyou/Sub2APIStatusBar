import SwiftUI
import Sub2APIStatusCore

struct OpenAIAccountsView: View {
    @ObservedObject var model: MonitorViewModel
    let strings: AppStrings
    @State private var selectedAccountID: Int64?

    var body: some View {
        if let account = selectedAccount {
            OpenAIAccountDetailView(
                account: account,
                snapshot: model.snapshot.openAIQuota,
                strings: strings,
                dismiss: { selectedAccountID = nil }
            )
        } else {
            accountList
        }
    }

    private var accountList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                PanelPageHeader(
                    title: strings.phrase("账号", "Accounts"),
                    subtitle: "OpenAI OAuth"
                )

                if let error = model.snapshot.openAIQuotaError {
                    MessageRow(message: error)
                }

                if let quota = model.snapshot.openAIQuota {
                    if quota.accounts.isEmpty {
                        emptyState
                    } else {
                        MetricGrid(items: summaryMetrics(quota.summary))
                        ForEach(quota.accounts) { account in
                            accountRow(account)
                        }
                    }
                } else if model.isRefreshing {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 120)
                }
            }
            .padding(16)
        }
    }

    private var emptyState: some View {
        Text(strings.phrase("暂无 OpenAI OAuth 账号", "No OpenAI OAuth accounts"))
            .font(.callout.weight(.medium))
            .foregroundStyle(ClaudeTheme.secondaryText)
            .frame(maxWidth: .infinity, minHeight: 120)
            .background(ClaudeTheme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func summaryMetrics(_ summary: OpenAIQuotaPoolSummary) -> [MetricItem] {
        [
            MetricItem(
                title: strings.phrase("账号", "Accounts"),
                value: String(summary.accountCount),
                caption: strings.phrase("可调度 \(summary.schedulableCount)", "\(summary.schedulableCount) schedulable"),
                systemImage: "person.2",
                tint: ClaudeTheme.accent
            ),
            MetricItem(
                title: strings.phrase("五小时剩余", "5-hour Remaining"),
                value: StatusFormatters.openAIQuotaRemaining(summary.capacities, window: .fiveHour),
                systemImage: "timer",
                tint: ClaudeTheme.success
            ),
            MetricItem(
                title: strings.phrase("七天剩余", "7-day Remaining"),
                value: StatusFormatters.openAIQuotaRemaining(summary.capacities, window: .sevenDay),
                systemImage: "calendar",
                tint: ClaudeTheme.success
            ),
            MetricItem(
                title: strings.phrase("风险账号", "At Risk"),
                value: String(summary.riskCount),
                systemImage: "exclamationmark.triangle",
                tint: summary.riskCount > 0 ? ClaudeTheme.warning : ClaudeTheme.success
            ),
        ]
    }

    private func accountRow(_ account: OpenAIAccountQuota) -> some View {
        Button {
            selectedAccountID = account.id
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.account.displayName)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(ClaudeTheme.primaryText)
                            .lineLimit(1)
                        if let email = account.account.email, email != account.account.displayName {
                            Text(email)
                                .font(.caption2)
                                .foregroundStyle(ClaudeTheme.secondaryText)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Text(account.planLabel)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(ClaudeTheme.accent)
                    if account.account.isPrivate {
                        Text(strings.phrase("隐私", "Private"))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(ClaudeTheme.success)
                    }
                    Text(strings.activeStatus(account.account.status))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(account.isSchedulable ? ClaudeTheme.success : ClaudeTheme.secondaryText)
                }

                if let expiresAt = account.account.subscriptionExpiresAt {
                    Text(subscriptionExpiryText(expiresAt, strings: strings))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(ClaudeTheme.secondaryText)
                }

                if let progress = account.usage.fiveHour {
                    OpenAIQuotaProgressRow(
                        title: strings.phrase("五小时", "5 hours"),
                        progress: progress,
                        strings: strings
                    )
                }
                if let progress = account.usage.sevenDay {
                    OpenAIQuotaProgressRow(
                        title: strings.phrase("七天", "7 days"),
                        progress: progress,
                        strings: strings
                    )
                }
            }
            .padding(12)
            .background(ClaudeTheme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var selectedAccount: OpenAIAccountQuota? {
        guard let selectedAccountID else {
            return nil
        }
        return model.snapshot.openAIQuota?.accounts.first { $0.id == selectedAccountID }
    }

}

private struct OpenAIAccountDetailView: View {
    let account: OpenAIAccountQuota
    let snapshot: OpenAIAccountQuotaSnapshot?
    let strings: AppStrings
    let dismiss: () -> Void
    @State private var selectedWindow: OpenAIQuotaWindow = .fiveHour

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: dismiss) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help(strings.phrase("返回", "Back"))

                VStack(alignment: .leading, spacing: 2) {
                    Text(account.account.displayName)
                        .font(.headline)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(account.planLabel)
                        if account.account.isPrivate {
                            Text(strings.phrase("隐私", "Private"))
                        }
                        Text(strings.activeStatus(account.account.status))
                    }
                    .font(.caption2)
                    .foregroundStyle(ClaudeTheme.secondaryText)
                    if let expiresAt = account.account.subscriptionExpiresAt {
                        Text(subscriptionExpiryText(expiresAt, strings: strings))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(ClaudeTheme.secondaryText)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("", selection: $selectedWindow) {
                        Text(strings.phrase("五小时", "5 hours")).tag(OpenAIQuotaWindow.fiveHour)
                        Text(strings.phrase("七天", "7 days")).tag(OpenAIQuotaWindow.sevenDay)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    if let progress = account.progress(for: selectedWindow) {
                        SectionBlock(title: windowTitle) {
                            VStack(alignment: .leading, spacing: 12) {
                                OpenAIQuotaProgressRow(title: windowTitle, progress: progress, strings: strings)
                                if let stats = progress.windowStats {
                                    InfoRow(label: strings.phrase("请求", "Requests"), value: StatusFormatters.compactNumber(stats.requests))
                                    InfoRow(label: "Token", value: StatusFormatters.compactNumber(stats.tokens))
                                    InfoRow(label: strings.phrase("标准价值", "Standard Value"), value: StatusFormatters.preciseCurrency(stats.standardCost))
                                }
                            }
                        }

                        if let forecast = snapshot?.forecast(for: account, window: selectedWindow) {
                            forecastSection(forecast, currentUtilization: progress.utilization)
                        }

                        SectionBlock(title: strings.phrase("趋势", "Trend")) {
                            OpenAIQuotaHistoryChart(
                                samples: snapshot?.history.samples ?? [],
                                accountID: account.id,
                                window: selectedWindow
                            )
                            .frame(height: 130)
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    private func forecastSection(_ forecast: OpenAIQuotaForecast, currentUtilization: Double) -> some View {
        SectionBlock(title: strings.phrase("预测", "Forecast")) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(forecastText(forecast))
                        .font(.callout.weight(.medium))
                    Spacer()
                    Text(confidenceText(forecast.confidence))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ClaudeTheme.secondaryText)
                }
                if let predicted = forecast.predictedUtilizationAtReset {
                    InfoRow(
                        label: strings.phrase("重置时预计", "At reset"),
                        value: String(format: "%.0f%%", predicted)
                    )
                }
                ForEach(forecast.thresholds.filter { Double($0.threshold) > currentUtilization }) { estimate in
                    InfoRow(
                        label: strings.phrase("达到 \(estimate.threshold)%", "Reach \(estimate.threshold)%"),
                        value: relativeTime(estimate.date)
                    )
                }
            }
        }
    }

    private var windowTitle: String {
        selectedWindow == .fiveHour
            ? strings.phrase("五小时", "5 hours")
            : strings.phrase("七天", "7 days")
    }

    private func forecastText(_ forecast: OpenAIQuotaForecast) -> String {
        switch forecast.trend {
        case .insufficient:
            return strings.phrase("数据不足", "Insufficient data")
        case .rising:
            return strings.phrase("用量上升", "Usage rising")
        case .stable:
            return strings.phrase("当前稳定", "Stable")
        case .falling:
            return strings.phrase("当前回落", "Falling")
        }
    }

    private func confidenceText(_ confidence: OpenAIQuotaForecastConfidence) -> String {
        switch confidence {
        case .insufficient:
            return ""
        case .low:
            return strings.phrase("低信心", "Low confidence")
        case .medium:
            return strings.phrase("中信心", "Medium confidence")
        case .high:
            return strings.phrase("高信心", "High confidence")
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let interval = date.timeIntervalSinceNow
        if interval <= 0 {
            return strings.phrase("已达到", "Reached")
        }
        return StatusFormatters.duration(seconds: interval)
    }
}

private struct OpenAIQuotaProgressRow: View {
    let title: String
    let progress: UsageProgress
    let strings: AppStrings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(strings.phrase("已用 \(usedText)", "Used \(usedText)"))
                .font(.caption.monospacedDigit())
                .foregroundStyle(ClaudeTheme.secondaryText)
            }
            ProgressView(value: progress.normalizedPercentage)
                .tint(progressTint)
            HStack {
                if progress.remainingSeconds > 0 {
                    Text(strings.phrase(
                        "\(quotaResetDuration(progress.remainingSeconds, language: .zhHans)) 后重置",
                        "Resets in \(quotaResetDuration(progress.remainingSeconds, language: .en))"
                    ))
                }
                Spacer()
                if let stats = progress.windowStats {
                    Text(StatusFormatters.preciseCurrency(stats.standardCost))
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(ClaudeTheme.secondaryText)
        }
    }

    private var usedText: String {
        String(format: "%.0f%%", progress.utilization)
    }

    private var progressTint: Color {
        switch progress.utilization {
        case 95...:
            return ClaudeTheme.danger
        case 85..<95:
            return ClaudeTheme.warning
        case 70..<85:
            return ClaudeTheme.gold
        default:
            return ClaudeTheme.success
        }
    }
}

private func subscriptionExpiryText(_ date: Date, strings: AppStrings) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return strings.phrase("到期 \(formatter.string(from: date))", "Expires \(formatter.string(from: date))")
}

private func quotaResetDuration(_ seconds: Int, language: AppLanguage) -> String {
    let days = seconds / 86_400
    let hours = seconds % 86_400 / 3_600
    let minutes = seconds % 3_600 / 60
    let values = [(days, language == .en ? "d" : "天"), (hours, language == .en ? "h" : "小时"), (minutes, language == .en ? "m" : "分钟")]
    let duration = values
        .filter { $0.0 > 0 }
        .prefix(2)
        .map { "\($0.0)\($0.1)" }
        .joined(separator: " ")
    return duration.isEmpty ? (language == .en ? "<1m" : "不到 1 分钟") : duration
}

private struct OpenAIQuotaHistoryChart: View {
    @Environment(\.appLanguage) private var language

    let samples: [OpenAIQuotaSample]
    let accountID: Int64
    let window: OpenAIQuotaWindow

    private var points: [(Date, OpenAIQuotaWindowSample)] {
        samples.compactMap { sample in
            guard sample.accountID == accountID else {
                return nil
            }
            let progress = window == .fiveHour ? sample.fiveHour : sample.sevenDay
            guard let progress, progress.resetsAt != nil else {
                return nil
            }
            return (sample.capturedAt, progress)
        }
    }

    var body: some View {
        if points.count < 2 {
            Text(strings.phrase("数据不足", "Insufficient data"))
                .font(.caption)
                .foregroundStyle(ClaudeTheme.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { proxy in
                ZStack {
                    grid(in: proxy.size)
                        .stroke(ClaudeTheme.border, lineWidth: 1)
                    line(in: proxy.size)
                        .stroke(ClaudeTheme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }

    private var strings: AppStrings {
        AppStrings(language)
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

    private func line(in size: CGSize) -> Path {
        guard let firstDate = points.first?.0, let lastDate = points.last?.0 else {
            return Path()
        }
        let duration = max(lastDate.timeIntervalSince(firstDate), 1)
        var path = Path()
        var previousReset: String?
        var hasPoint = false
        for point in points {
            let x = size.width * CGFloat(point.0.timeIntervalSince(firstDate) / duration)
            let y = size.height * CGFloat(1 - min(max(point.1.utilization, 0), 100) / 100)
            if hasPoint, previousReset == point.1.resetsAt {
                path.addLine(to: CGPoint(x: x, y: y))
            } else {
                path.move(to: CGPoint(x: x, y: y))
            }
            previousReset = point.1.resetsAt
            hasPoint = true
        }
        return path
    }
}
