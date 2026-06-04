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
    let activities: [CodexTaskActivity]
    let latestUsage: UsageLog?
    let realtimeConcurrency: UserRealtimeConcurrency?
    let timelineEventLimit: Int
    let strings: AppStrings
    @State private var expandedTimelineTaskIDs: Set<String> = []

    private var rows: [CodexTaskConsoleRow] {
        CodexTaskConsoleModel.rows(activities: activities)
    }

    private var gatewayUsage: CodexTaskGatewayUsageDetail? {
        CodexTaskConsoleModel.gatewayUsageDetail(latestUsage: latestUsage)
    }

    private var gatewayConcurrency: CodexTaskGatewayConcurrencyDetail? {
        CodexTaskConsoleModel.gatewayConcurrencyDetail(realtimeConcurrency: realtimeConcurrency)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                headerCard
                gatewayUsageCard
                gatewayConcurrencyCard

                if rows.isEmpty {
                    emptyCard
                } else {
                    ForEach(rows) { row in
                        taskCard(row)
                    }
                }
            }
            .padding(16)
        }
    }

    private var headerCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(strings.phrase("任务控制台", "Task Console"))
                    .font(.headline)
                Text(strings.phrase(
                    "这里显示 hooks 上报的 node_id、session_id 和 turn_id。事件时间线默认折叠，网关最近请求只作为费用、Token 与 User-Agent 辅助明细。",
                    "This page shows hook-reported node_id, session_id, and turn_id. The event timeline is collapsed by default; the latest gateway request is supplementary cost, token, and User-Agent detail only."
                ))
                .font(.callout)
                .foregroundStyle(ClaudeTheme.secondaryText)

                let summary = CodexMenuBarTaskSummary.make(activities: activities, maxTasks: 3)
                HStack(spacing: 8) {
                    badge(summary.topRow)
                    badge(summary.bottomRow)
                }
            }
        }
    }

    @ViewBuilder
    private var gatewayConcurrencyCard: some View {
        if let gatewayConcurrency {
            GlassCard {
                VStack(alignment: .leading, spacing: 2) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(strings.phrase("网关并发负载", "Gateway Concurrency Load"))
                            .font(.headline)
                        Text(strings.phrase(
                            "该分区展示管理员接口返回的所选用户占用并发槽位。它不是任务身份来源；如果这里有占用但下方没有任务，说明尚未收到可信 Codex hooks 事件。",
                            "This section shows selected-user occupied concurrency from admin APIs. It is not a task identity source; if it has usage but no task appears below, no trusted Codex hook event has been received yet."
                        ))
                        .font(.caption)
                        .foregroundStyle(ClaudeTheme.secondaryText)
                    }

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
        }
    }

    @ViewBuilder
    private var gatewayUsageCard: some View {
        if let gatewayUsage {
            GlassCard {
                gatewayUsageContent(gatewayUsage)
            }
        }
    }

    private func gatewayUsageContent(_ gatewayUsage: CodexTaskGatewayUsageDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(strings.phrase("最近网关请求", "Latest Gateway Request"))
                    .font(.headline)
                Text(strings.phrase(
                    "该分区只展示网关明细，不能作为 Codex session/turn 关联依据。",
                    "This section is gateway detail only and is not used to associate Codex sessions or turns."
                ))
                .font(.caption)
                .foregroundStyle(ClaudeTheme.secondaryText)
            }

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
        GlassCard {
            taskCardContent(row)
        }
    }

    private func taskCardContent(_ row: CodexTaskConsoleRow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                badge(row.badge)
                statusBadge(row.status)
                VStack(alignment: .leading, spacing: 10) {
                    Text(row.sessionID)
                        .font(.system(.callout, design: .monospaced).weight(.semibold))
                        .lineLimit(1)
                    Text("\(row.nodeID) · \(row.turnID)")
                        .font(.caption)
                        .foregroundStyle(ClaudeTheme.secondaryText)
                        .lineLimit(1)
                }
                Spacer()
            }

            taskDetailRows(row)

            if !row.events.isEmpty {
                Divider()
                    .overlay(ClaudeTheme.border)
                timelineSection(row)
            }
        }
    }

    private func timelineSection(_ row: CodexTaskConsoleRow) -> some View {
        let isExpanded = expandedTimelineTaskIDs.contains(row.id)
        let visibleEvents = row.latestEvents(limit: timelineEventLimit)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                toggleTimeline(row.id)
            } label: {
                HStack(spacing: 8) {
                    Label(
                        strings.phrase("事件时间线", "Event Timeline"),
                        systemImage: isExpanded ? "chevron.down.circle.fill" : "chevron.right.circle.fill"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ClaudeTheme.secondaryText)
                    Spacer()
                    if let latest = row.events.last {
                        Text(strings.phrase(
                            "最新 \(latest.eventName)",
                            "Latest \(latest.eventName)"
                        ))
                        .font(.caption2)
                        .foregroundStyle(ClaudeTheme.secondaryText)
                        .lineLimit(1)
                    }
                    Text(eventCountText(row.events.count))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(ClaudeTheme.primaryText)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(ClaudeTheme.elevatedCard, in: Capsule())
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                if row.events.count > visibleEvents.count {
                    Text(strings.phrase(
                        "仅显示最近 \(visibleEvents.count) 条事件，可在设置中调整。",
                        "Showing the latest \(visibleEvents.count) events. Change this in Settings."
                    ))
                    .font(.caption2)
                    .foregroundStyle(ClaudeTheme.secondaryText)
                }
                ForEach(visibleEvents) { event in
                    eventRow(event)
                }
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
                InfoRow(label: "model", value: model)
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
                Text(rawPayloadJSON)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(ClaudeTheme.secondaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(ClaudeTheme.textFieldBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(10)
        .background(ClaudeTheme.elevatedCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(ClaudeTheme.border, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func eventDetailRows(_ event: CodexTaskConsoleRow.EventRow) -> some View {
        ForEach(eventInfoLines(event)) { line in
            InfoRow(label: line.label, value: line.value)
        }
    }

    private func badge(_ value: String) -> some View {
        Text(value)
            .font(.system(.caption, design: .rounded).weight(.semibold))
            .foregroundStyle(ClaudeTheme.primaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(ClaudeTheme.elevatedCard, in: Capsule())
            .overlay(Capsule().stroke(ClaudeTheme.border, lineWidth: 1))
    }

    private func statusBadge(_ status: String) -> some View {
        Text(status)
            .font(.system(.caption, design: .rounded).weight(.bold))
            .foregroundStyle(statusColor(status))
            .frame(width: 24, height: 24)
            .background(statusColor(status).opacity(0.14), in: Circle())
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

    private func toggleTimeline(_ rowID: String) {
        if expandedTimelineTaskIDs.contains(rowID) {
            expandedTimelineTaskIDs.remove(rowID)
        } else {
            expandedTimelineTaskIDs.insert(rowID)
        }
    }

    private func eventCountText(_ count: Int) -> String {
        strings.phrase("\(count) 条", "\(count) events")
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

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

    private func gatewayInfoLines(_ usage: CodexTaskGatewayUsageDetail) -> [GatewayInfoLine] {
        var lines: [GatewayInfoLine] = []
        appendLine("request_id", usage.requestID, to: &lines)
        if let createdAt = usage.createdAt {
            lines.append(GatewayInfoLine(label: "created", value: Self.timestamp(createdAt)))
        }
        appendLine("model", usage.model, to: &lines)
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
        appendLine("model", row.model, to: &lines)
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
}
