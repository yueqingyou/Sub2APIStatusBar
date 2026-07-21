import SwiftUI
import Sub2APIStatusCore

struct OpenAIQuotaOverviewView: View {
    let snapshot: OpenAIAccountQuotaSnapshot
    let strings: AppStrings
    @State private var window: OpenAIQuotaWindow = .fiveHour

    var body: some View {
        SectionBlock(title: strings.phrase("账号额度", "Account Quota")) {
            VStack(alignment: .leading, spacing: 12) {
                GlassSegmentedControl(
                    selection: $window,
                    items: quotaWindowItems
                )

                HStack(alignment: .top, spacing: 12) {
                    overviewValue(
                        title: strings.phrase("剩余账号当量", "Remaining Capacity"),
                        value: capacityText
                    )
                    overviewValue(
                        title: strings.phrase("风险账号", "At Risk"),
                        value: String(riskCount)
                    )
                }

                OpenAIQuotaPoolTrendChart(
                    samples: snapshot.history.samples,
                    currentAccounts: snapshot.accounts,
                    window: window
                )
                .frame(height: 105)

                if snapshot.summary.capacities.count > 1 {
                    HStack(spacing: 10) {
                        ForEach(Array(snapshot.summary.capacities.enumerated()), id: \.element.plan) { index, capacity in
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(planColor(index))
                                    .frame(width: 7, height: 7)
                                Text(capacity.plan)
                            }
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(ClaudeTheme.secondaryText)
                }

                if let focus = focusAccount,
                   let progress = focus.account.progress(for: window) {
                    Divider()
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(focus.account.account.displayName)
                                .font(.callout.weight(.semibold))
                                .lineLimit(1)
                            Text(forecastText(focus.forecast))
                                .font(.caption2)
                                .foregroundStyle(ClaudeTheme.secondaryText)
                        }
                        Spacer()
                        Text(String(format: "%.0f%%", progress.utilization))
                            .font(.system(size: 17, weight: .semibold).monospacedDigit())
                            .foregroundStyle(utilizationColor(progress.utilization))
                    }
                }
            }
        }
    }

    private func overviewValue(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(ClaudeTheme.secondaryText)
            Text(value)
                .font(.system(size: 16, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var capacityText: String {
        StatusFormatters.openAIQuotaRemaining(snapshot.summary.capacities, window: window)
    }

    private var quotaWindowItems: [GlassSegmentedItem<OpenAIQuotaWindow>] {
        [
            GlassSegmentedItem(
                value: .fiveHour,
                title: strings.phrase("五小时", "5 hours"),
                systemImage: "clock"
            ),
            GlassSegmentedItem(
                value: .sevenDay,
                title: strings.phrase("七天", "7 days"),
                systemImage: "calendar"
            ),
        ]
    }

    private var focusAccount: (account: OpenAIAccountQuota, forecast: OpenAIQuotaForecast?)? {
        let forecasted = snapshot.accounts.compactMap { account -> (OpenAIAccountQuota, OpenAIQuotaForecast, Date)? in
            guard let forecast = snapshot.forecast(for: account, window: window),
                  let date = forecast.estimatedAt(85) else {
                return nil
            }
            return (account, forecast, date)
        }
        if let earliest = forecasted.min(by: { $0.2 < $1.2 }) {
            return (earliest.0, earliest.1)
        }
        guard let account = snapshot.accounts.max(by: { lhs, rhs in
            (lhs.progress(for: window)?.utilization ?? 0) < (rhs.progress(for: window)?.utilization ?? 0)
        }) else {
            return nil
        }
        return (account, snapshot.forecast(for: account, window: window))
    }

    private var riskCount: Int {
        snapshot.accounts.filter {
            $0.account.status == "active" && ($0.progress(for: window)?.utilization ?? 0) >= 70
        }.count
    }

    private func forecastText(_ forecast: OpenAIQuotaForecast?) -> String {
        guard let forecast else {
            return ""
        }
        if let highRiskAt = forecast.estimatedAt(85) {
            let interval = highRiskAt.timeIntervalSinceNow
            if interval <= 0 {
                return strings.phrase("已达高风险", "High risk")
            }
            return strings.phrase(
                "预计 \(StatusFormatters.duration(seconds: interval)) 后达到 85%",
                "85% in \(StatusFormatters.duration(seconds: interval))"
            )
        }
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

    private func utilizationColor(_ value: Double) -> Color {
        switch value {
        case 95...:
            return ClaudeTheme.danger
        case 70...:
            return ClaudeTheme.warning
        default:
            return ClaudeTheme.success
        }
    }

    private func planColor(_ index: Int) -> Color {
        [ClaudeTheme.accent, ClaudeTheme.warm, ClaudeTheme.sand, ClaudeTheme.gold, ClaudeTheme.slate][index % 5]
    }
}

private struct OpenAIQuotaPoolTrendChart: View {
    @Environment(\.appLanguage) private var language

    private struct Point {
        let date: Date
        let plan: String
        let remaining: Double
        let resetSignature: String
    }

    private struct Series {
        let pointsByPlan: [String: [Point]]
        let plans: [String]
        let firstDate: Date?
        let lastDate: Date?
        let maximum: Double
        let hasTrend: Bool
    }

    let samples: [OpenAIQuotaSample]
    let currentAccounts: [OpenAIAccountQuota]
    let window: OpenAIQuotaWindow

    var body: some View {
        let series = makeSeries()

        if !series.hasTrend {
            Text(strings.phrase("数据不足", "Insufficient data"))
                .font(.caption)
                .foregroundStyle(ClaudeTheme.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { proxy in
                ZStack {
                    grid(in: proxy.size)
                        .stroke(ClaudeTheme.border, lineWidth: 1)
                    ForEach(Array(series.plans.enumerated()), id: \.element) { index, plan in
                        path(for: plan, in: proxy.size, series: series)
                            .stroke(color(index), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    }
                }
            }
        }
    }

    private var strings: AppStrings {
        AppStrings(language)
    }

    private func makeSeries() -> Series {
        let currentAccountIDs = Set(currentAccounts.filter(\.isSchedulable).map(\.id))
        let groupedByCapture = Dictionary(
            grouping: samples.filter { currentAccountIDs.contains($0.accountID) },
            by: \.capturedAt
        )
        let points: [Point] = groupedByCapture.flatMap { entry -> [Point] in
            let (capturedAt, capturedSamples) = entry
            let groupedByPlan: [String: [OpenAIQuotaSample]] = Dictionary(
                grouping: capturedSamples,
                by: \.planType
            )
            return groupedByPlan.compactMap { planEntry -> Point? in
                let (plan, planSamples) = planEntry
                let progress = planSamples.compactMap { sample -> (Int64, OpenAIQuotaWindowSample, String)? in
                    guard let value = window == .fiveHour ? sample.fiveHour : sample.sevenDay,
                          let resetsAt = value.resetsAt else {
                        return nil
                    }
                    return (sample.accountID, value, resetsAt)
                }
                guard !progress.isEmpty else {
                    return nil
                }
                let remaining = progress.reduce(0) { $0 + max(0, 1 - min(max($1.1.utilization, 0), 100) / 100) }
                let signature = progress
                    .map { "\($0.0):\($0.2)" }
                    .sorted()
                    .joined(separator: "|")
                return Point(date: capturedAt, plan: plan, remaining: remaining, resetSignature: signature)
            }
        }.sorted { $0.date < $1.date }

        let pointsByPlan = Dictionary(grouping: points, by: \.plan)
        let plans = pointsByPlan.keys.sorted()
        let hasTrend = plans.contains { plan in
            guard let planPoints = pointsByPlan[plan] else {
                return false
            }
            return zip(planPoints, planPoints.dropFirst()).contains { previous, current in
                previous.resetSignature == current.resetSignature
            }
        }
        return Series(
            pointsByPlan: pointsByPlan,
            plans: plans,
            firstDate: points.first?.date,
            lastDate: points.last?.date,
            maximum: max(points.map(\.remaining).max() ?? 0, 1),
            hasTrend: hasTrend
        )
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

    private func path(for plan: String, in size: CGSize, series: Series) -> Path {
        guard let planPoints = series.pointsByPlan[plan],
              let first = series.firstDate,
              let last = series.lastDate else {
            return Path()
        }
        let duration = max(last.timeIntervalSince(first), 1)
        var path = Path()
        var previousSignature: String?
        var hasPoint = false
        for point in planPoints {
            let x = size.width * CGFloat(point.date.timeIntervalSince(first) / duration)
            let y = size.height * CGFloat(1 - point.remaining / series.maximum)
            if hasPoint, previousSignature == point.resetSignature {
                path.addLine(to: CGPoint(x: x, y: y))
            } else {
                path.move(to: CGPoint(x: x, y: y))
            }
            previousSignature = point.resetSignature
            hasPoint = true
        }
        return path
    }

    private func color(_ index: Int) -> Color {
        [ClaudeTheme.accent, ClaudeTheme.warm, ClaudeTheme.sand, ClaudeTheme.gold, ClaudeTheme.slate][index % 5]
    }
}
