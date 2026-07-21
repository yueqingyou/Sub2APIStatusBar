import SwiftUI
import Sub2APIStatusCore

private struct GatewayInfoLine: Identifiable {
    let label: String
    let value: String

    var id: String {
        label
    }
}

struct CodexTaskConsoleView: View {
    private let consoleRows: [CodexTaskConsoleRow]
    private let gatewayUsage: CodexTaskGatewayUsageDetail?
    private let gatewayConcurrency: CodexTaskGatewayConcurrencyDetail?
    let timelineEventLimit: Int
    let strings: AppStrings
    let showsPageHeader: Bool
    @State private var expandedTaskIDs: Set<String> = []
    @State private var isGatewayExpanded = false

    init(
        activities: [CodexTaskActivity],
        latestUsage: UsageLog?,
        realtimeConcurrency: UserRealtimeConcurrency?,
        timelineEventLimit: Int,
        strings: AppStrings,
        showsPageHeader: Bool = true
    ) {
        consoleRows = CodexTaskConsoleModel.rows(activities: activities)
        gatewayUsage = CodexTaskConsoleModel.gatewayUsageDetail(latestUsage: latestUsage)
        gatewayConcurrency = CodexTaskConsoleModel.gatewayConcurrencyDetail(
            realtimeConcurrency: realtimeConcurrency
        )
        self.timelineEventLimit = timelineEventLimit
        self.strings = strings
        self.showsPageHeader = showsPageHeader
    }

    var body: some View {
        let groupedRows = consoleRows.reduce(
            into: (active: [CodexTaskConsoleRow](), recent: [CodexTaskConsoleRow]())
        ) { result, row in
            if row.isActive {
                result.active.append(row)
            } else {
                result.recent.append(row)
            }
        }
        let activeRows = groupedRows.active
        let recentRows = groupedRows.recent

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                consoleHeader(activeCount: activeRows.count, recentCount: recentRows.count)

                if consoleRows.isEmpty {
                    emptyCard
                } else {
                    if !activeRows.isEmpty {
                        sectionHeader(
                            strings.phrase("活动中", "Active"),
                            count: activeRows.count,
                            systemImage: "bolt.fill"
                        )
                        ForEach(activeRows) { row in
                            taskCard(row)
                        }
                    }

                    if !recentRows.isEmpty {
                        sectionHeader(
                            strings.phrase("最近完成", "Recent"),
                            count: recentRows.count,
                            systemImage: "clock"
                        )
                        ForEach(recentRows) { row in
                            taskCard(row)
                        }
                    }
                }

                gatewaySection
            }
            .padding(16)
        }
    }

    private func consoleHeader(activeCount: Int, recentCount: Int) -> some View {
        HStack(spacing: 12) {
            if showsPageHeader {
                PanelPageHeader(
                    title: strings.phrase("任务", "Tasks"),
                    subtitle: strings.phrase("Codex hooks 实时状态", "Live Codex hook status")
                )
            }
            Spacer()
            HStack(spacing: 6) {
                summaryBadge(value: activeCount, label: strings.phrase("活动", "active"), tint: ClaudeTheme.success)
                summaryBadge(value: recentCount, label: strings.phrase("历史", "recent"), tint: ClaudeTheme.slate)
            }
        }
    }

    @ViewBuilder
    private var gatewaySection: some View {
        if gatewayUsage != nil || gatewayConcurrency != nil {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        isGatewayExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "network")
                            .foregroundStyle(ClaudeTheme.secondaryText)
                        Text(strings.phrase("网关明细", "Gateway Details"))
                            .font(.callout.weight(.semibold))
                        if let gatewayConcurrency {
                            Text(gatewayConcurrency.capacityText)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(ClaudeTheme.secondaryText)
                        }
                        Spacer()
                        SafeSystemImage(
                            systemName: isGatewayExpanded ? "chevron.down" : "chevron.right",
                            fallbackName: "chevron.right"
                        )
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(ClaudeTheme.secondaryText)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isGatewayExpanded {
                    if let gatewayConcurrency {
                        gatewayConcurrencyContent(gatewayConcurrency)
                    }
                    if gatewayConcurrency != nil, gatewayUsage != nil {
                        Divider()
                    }
                    if let gatewayUsage {
                        gatewayUsageContent(gatewayUsage)
                    }
                }
            }
            .padding(12)
            .glassSurface(cornerRadius: 11)
        }
    }

    private func gatewayConcurrencyContent(_ gatewayConcurrency: CodexTaskGatewayConcurrencyDetail) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            InfoRow(label: "user_id", value: String(gatewayConcurrency.userID))
            if let userEmail = gatewayConcurrency.userEmail {
                InfoRow(label: "email", value: userEmail)
            }
            if let username = gatewayConcurrency.username {
                InfoRow(label: "username", value: username)
            }
            InfoRow(label: "in_use", value: gatewayConcurrency.capacityText)
            InfoRow(label: "waiting", value: String(gatewayConcurrency.waitingInQueue))
            InfoRow(label: "load", value: StatusFormatters.percent(gatewayConcurrency.loadPercentage / 100))
        }
    }

    private func gatewayUsageContent(_ gatewayUsage: CodexTaskGatewayUsageDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(strings.phrase("最近请求", "Latest Request"))
                .font(.callout.weight(.semibold))

            ForEach(gatewayInfoLines(gatewayUsage)) { line in
                InfoRow(label: line.label, value: line.value)
            }
        }
    }

    private var emptyCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(strings.phrase("暂无 hook 事件", "No hook events"))
                    .font(.headline)
                Text(strings.phrase(
                    "安装并启用节点 hooks 后，这里会按最近更新时间显示 Codex session/turn。",
                    "After node hooks are installed and enabled, Codex sessions and turns appear here by recent update time."
                ))
                .font(.callout)
                .foregroundStyle(ClaudeTheme.secondaryText)
                if let gatewayConcurrency, gatewayConcurrency.currentInUse > 0 {
                    Text(strings.phrase(
                        "当前网关并发为 \(gatewayConcurrency.capacityText)，但任务列表仍为空。这表示网关有占用槽位，但本机还没有收到可用于锁定 session/turn 的真实 hooks 事件。",
                        "Gateway concurrency is currently \(gatewayConcurrency.capacityText), but the task list is empty. This means the gateway has occupied slots, but the app has not received a real hook event that can identify a session or turn."
                    ))
                    .font(.caption)
                    .foregroundStyle(ClaudeTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func taskCard(_ row: CodexTaskConsoleRow) -> some View {
        taskCardContent(row)
            .padding(12)
            .glassSurface(cornerRadius: 11)
    }

    private func taskCardContent(_ row: CodexTaskConsoleRow) -> some View {
        let isExpanded = expandedTaskIDs.contains(row.id)
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                toggleTask(row.id)
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    Circle()
                        .fill(statusColor(row.status))
                        .frame(width: 8, height: 8)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(taskTitle(row))
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(ClaudeTheme.primaryText)
                            .lineLimit(1)
                        Text(taskSubtitle(row))
                            .font(.caption)
                            .foregroundStyle(ClaudeTheme.secondaryText)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 4) {
                        statusBadge(row.status)
                        Text(Self.relativeTimestamp(row.updatedAt))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(ClaudeTheme.secondaryText)
                    }
                    SafeSystemImage(
                        systemName: isExpanded ? "chevron.down" : "chevron.right",
                        fallbackName: "chevron.right"
                    )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ClaudeTheme.secondaryText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                    .overlay(ClaudeTheme.border)
                taskDetailRows(row)

                if !row.events.isEmpty {
                    Divider()
                        .overlay(ClaudeTheme.border)
                    timelineSection(row)
                }
            }
        }
    }

    private func timelineSection(_ row: CodexTaskConsoleRow) -> some View {
        let visibleEvents = row.latestEvents(limit: timelineEventLimit)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(strings.phrase("事件", "Events"), systemImage: "list.bullet.rectangle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ClaudeTheme.secondaryText)
                Spacer()
                Text(eventCountText(row.events.count))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(ClaudeTheme.secondaryText)
            }
            if row.events.count > visibleEvents.count {
                Text(strings.phrase(
                    "显示最近 \(visibleEvents.count) 条",
                    "Latest \(visibleEvents.count) shown"
                ))
                .font(.caption2)
                .foregroundStyle(ClaudeTheme.secondaryText)
            }
            ForEach(visibleEvents) { event in
                eventRow(event)
            }
        }
    }

    @ViewBuilder
    private func taskDetailRows(_ row: CodexTaskConsoleRow) -> some View {
        ForEach(taskInfoLines(row)) { line in
            InfoRow(label: line.label, value: line.value)
        }
    }

    private func eventRow(_ event: CodexTaskConsoleRow.EventRow) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(Self.timestamp(event.observedAt))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(ClaudeTheme.secondaryText)
                Text(event.eventName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ClaudeTheme.primaryText)
                Spacer()
            }
            InfoRow(label: "event_id", value: event.eventID)
            if !event.turnID.isEmpty {
                InfoRow(label: "turn_id", value: event.turnID)
            }
            if let model = event.model, !model.isEmpty {
                InfoRow(label: "model", value: Self.modelDetail(model))
            }
            if let toolName = event.toolName, !toolName.isEmpty {
                InfoRow(label: "tool", value: toolName)
            }
            eventDetailRows(event)
            if let cwd = event.cwd, !cwd.isEmpty {
                InfoRow(label: "cwd", value: cwd)
            }
            if let rawPayloadJSON = event.rawPayloadJSON, !rawPayloadJSON.isEmpty {
                Text(strings.phrase("原始 JSON", "Raw JSON"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(ClaudeTheme.secondaryText)
                Text(Self.prettyJSON(rawPayloadJSON))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(ClaudeTheme.secondaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .glassSurface(cornerRadius: 8)
            }
        }
        .padding(.leading, 10)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(ClaudeTheme.border)
                .frame(width: 2)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func eventDetailRows(_ event: CodexTaskConsoleRow.EventRow) -> some View {
        ForEach(eventInfoLines(event)) { line in
            InfoRow(label: line.label, value: line.value)
        }
    }

    private func sectionHeader(_ title: String, count: Int, systemImage: String) -> some View {
        HStack(spacing: 6) {
            SafeSystemImage(systemName: systemImage, fallbackName: "circle")
                .font(.caption)
            Text(title)
                .font(.callout.weight(.semibold))
            Text(String(count))
                .font(.caption.monospacedDigit())
                .foregroundStyle(ClaudeTheme.secondaryText)
            Spacer()
        }
        .foregroundStyle(ClaudeTheme.primaryText)
        .padding(.top, 4)
    }

    private func summaryBadge(value: Int, label: String, tint: Color) -> some View {
        StatusPill(
            title: "\(value) \(label)",
            tint: tint
        )
    }

    private func statusBadge(_ status: String) -> some View {
        StatusPill(
            title: statusText(status),
            tint: statusColor(status),
            systemImage: statusIcon(status)
        )
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "R":
            return ClaudeTheme.success
        case "Q":
            return ClaudeTheme.warning
        case "D":
            return ClaudeTheme.slate
        case "E", "S":
            return ClaudeTheme.danger
        default:
            return ClaudeTheme.secondaryText
        }
    }

    private func statusText(_ status: String) -> String {
        switch status {
        case "R":
            return strings.phrase("运行中", "Running")
        case "Q":
            return strings.phrase("等待中", "Waiting")
        case "D":
            return strings.phrase("已完成", "Done")
        case "E":
            return strings.phrase("失败", "Failed")
        case "S":
            return strings.phrase("已失联", "Stale")
        default:
            return strings.phrase("未知", "Unknown")
        }
    }

    private func statusIcon(_ status: String) -> String {
        switch status {
        case "R":
            return "play.fill"
        case "Q":
            return "pause.fill"
        case "D":
            return "checkmark"
        case "E":
            return "xmark"
        case "S":
            return "exclamationmark.circle"
        default:
            return "questionmark"
        }
    }

    private func taskTitle(_ row: CodexTaskConsoleRow) -> String {
        if let cwd = row.cwd?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty {
            let name = URL(fileURLWithPath: cwd).lastPathComponent
            if !name.isEmpty {
                return name
            }
        }
        return strings.phrase("Codex 任务", "Codex Task")
    }

    private func taskSubtitle(_ row: CodexTaskConsoleRow) -> String {
        var parts = [row.nodeID]
        if let model = row.model, !model.isEmpty {
            parts.append(StatusFormatters.modelPresentation(model).compactName)
        }
        if let toolName = row.toolName, !toolName.isEmpty {
            parts.append(toolName)
        }
        return parts.joined(separator: " · ")
    }

    private func toggleTask(_ rowID: String) {
        if expandedTaskIDs.contains(rowID) {
            expandedTaskIDs.remove(rowID)
        } else {
            expandedTaskIDs.insert(rowID)
        }
    }

    private func eventCountText(_ count: Int) -> String {
        strings.phrase("\(count) 条", "\(count) events")
    }

    private static func timestamp(_ date: Date) -> String {
        timestampFormatter.string(from: date)
    }

    private static func relativeTimestamp(_ date: Date) -> String {
        relativeTimestampFormatter.localizedString(for: date, relativeTo: Date())
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let relativeTimestampFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private static func tokenSummary(_ usage: CodexTaskGatewayUsageDetail) -> String {
        [
            "in \(StatusFormatters.compactNumber(usage.inputTokens))",
            "out \(StatusFormatters.compactNumber(usage.outputTokens))",
            "cache \(StatusFormatters.compactNumber(usage.cacheCreationTokens + usage.cacheReadTokens))",
            "total \(StatusFormatters.compactNumber(usage.totalTokens))",
        ].joined(separator: " | ")
    }

    private static func milliseconds(_ value: Double) -> String {
        if value.rounded() == value {
            return String(format: "%.0fms", value)
        }
        return String(format: "%.1fms", value)
    }

    private static func prettyJSON(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let prettyData = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let pretty = String(data: prettyData, encoding: .utf8) else {
            return raw
        }
        return pretty
    }

    private func gatewayInfoLines(_ usage: CodexTaskGatewayUsageDetail) -> [GatewayInfoLine] {
        var lines: [GatewayInfoLine] = []
        appendLine("request_id", usage.requestID, to: &lines)
        if let createdAt = usage.createdAt {
            lines.append(GatewayInfoLine(label: "created", value: Self.timestamp(createdAt)))
        }
        appendModelLine(usage.model, to: &lines)
        appendLine("upstream_model", usage.upstreamModel.map(Self.modelDetail), to: &lines)
        appendLine("model_mapping", usage.modelMappingChain, to: &lines)
        appendLine("service_tier", usage.serviceTier, to: &lines)
        appendLine("reasoning", usage.reasoningEffort, to: &lines)
        appendLine("inbound", usage.inboundEndpoint, to: &lines)
        appendLine("upstream", usage.upstreamEndpoint, to: &lines)
        appendLine("request_type", usage.requestType, to: &lines)
        if let stream = usage.stream {
            lines.append(GatewayInfoLine(label: "stream", value: stream ? "true" : "false"))
        }
        lines.append(GatewayInfoLine(label: "tokens", value: Self.tokenSummary(usage)))
        lines.append(GatewayInfoLine(label: "actual_cost", value: StatusFormatters.preciseCurrency(usage.actualCost)))
        lines.append(GatewayInfoLine(label: "total_cost", value: StatusFormatters.preciseCurrency(usage.totalCost)))
        lines.append(GatewayInfoLine(label: "duration", value: Self.milliseconds(usage.durationMs)))
        if let firstTokenMs = usage.firstTokenMs {
            lines.append(GatewayInfoLine(label: "first_token", value: Self.milliseconds(firstTokenMs)))
        }
        appendLine("billing", usage.billingMode, to: &lines)
        appendLine("user_agent", usage.userAgent, to: &lines)
        return lines
    }

    private func taskInfoLines(_ row: CodexTaskConsoleRow) -> [GatewayInfoLine] {
        var lines: [GatewayInfoLine] = [
            GatewayInfoLine(label: "session_id", value: row.sessionID),
            GatewayInfoLine(label: "turn_id", value: row.turnID),
            GatewayInfoLine(label: "node_id", value: row.nodeID),
        ]
        appendLine("cwd", row.cwd, to: &lines)
        appendModelLine(row.model, to: &lines)
        appendLine("tool", row.toolName, to: &lines)
        appendLine("tool_use_id", row.toolUseID, to: &lines)
        appendLine("status_hint", row.statusHint, to: &lines)
        appendLine("error", row.errorMessage, to: &lines)
        appendLine("transcript", row.transcriptPath, to: &lines)
        appendLine("user_agent", row.userAgent, to: &lines)
        appendLine("payload_hash", row.rawPayloadHash, to: &lines)
        lines.append(GatewayInfoLine(label: "updated", value: Self.timestamp(row.updatedAt)))
        return lines
    }

    private func eventInfoLines(_ event: CodexTaskConsoleRow.EventRow) -> [GatewayInfoLine] {
        var lines: [GatewayInfoLine] = []
        appendLine("session_id", event.sessionID, to: &lines)
        appendLine("tool_use_id", event.toolUseID, to: &lines)
        appendLine("status_hint", event.statusHint, to: &lines)
        appendLine("error", event.errorMessage, to: &lines)
        appendLine("transcript", event.transcriptPath, to: &lines)
        appendLine("user_agent", event.userAgent, to: &lines)
        appendLine("payload_hash", event.rawPayloadHash, to: &lines)
        return lines
    }

    private func appendLine(_ label: String, _ value: String?, to lines: inout [GatewayInfoLine]) {
        guard let value, !value.isEmpty else {
            return
        }
        lines.append(GatewayInfoLine(label: label, value: value))
    }

    private func appendModelLine(_ value: String?, to lines: inout [GatewayInfoLine]) {
        guard let value, !value.isEmpty else {
            return
        }
        lines.append(GatewayInfoLine(label: "model", value: Self.modelDetail(value)))
    }

    private static func modelDetail(_ model: String) -> String {
        let presentation = StatusFormatters.modelPresentation(model)
        guard presentation.isLossy else {
            return presentation.displayName
        }
        return "\(presentation.displayName) (\(presentation.rawValue))"
    }
}
