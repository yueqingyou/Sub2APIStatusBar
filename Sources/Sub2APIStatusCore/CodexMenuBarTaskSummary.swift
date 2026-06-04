import Foundation

public struct CodexMenuBarTaskSummary: Sendable, Equatable {
    public static let defaultRecentWindow: TimeInterval = 3600

    public let topRow: String
    public let bottomRow: String
    public let tooltip: String

    public static func make(
        activities: [CodexTaskActivity],
        maxTasks: Int,
        now: Date = Date(),
        recentWindow: TimeInterval = defaultRecentWindow
    ) -> CodexMenuBarTaskSummary {
        let visibleLimit = max(maxTasks, 0)
        let sortedActivities = activities
            .sorted { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.id < rhs.id
                }
                return lhs.updatedAt > rhs.updatedAt
            }
        let menuBarActivities = sortedActivities.filter { $0.status != .stale }
        let visibleActivities = Array(menuBarActivities.prefix(visibleLimit))
        let hiddenCount = max(menuBarActivities.count - visibleActivities.count, 0)

        var topRowItems = visibleActivities
            .map { "\($0.badge)\(badge(for: $0.status))" }
        if hiddenCount > 0 {
            topRowItems.append("+\(hiddenCount)")
        }
        let topRow = topRowItems.joined(separator: " ")
        let counts = statusCounts(activities, now: now, recentWindow: recentWindow)
        let bottomRow = [
            "T\(activities.count)",
            "R\(counts.running)",
            "Q\(counts.waiting)",
            "D\(counts.done)",
            "E\(counts.error)",
        ].joined()

        return CodexMenuBarTaskSummary(
            topRow: topRow.isEmpty ? emptyTopRow(totalCount: activities.count) : topRow,
            bottomRow: bottomRow,
            tooltip: tooltip(for: activities)
        )
    }

    private static func emptyTopRow(totalCount: Int) -> String {
        totalCount == 0 ? "0" : "T\(totalCount)"
    }

    private static func badge(for status: CodexTaskActivity.Status) -> String {
        switch status {
        case .running:
            return "R"
        case .waiting:
            return "Q"
        case .done:
            return "D"
        case .error:
            return "E"
        case .stale:
            return "S"
        }
    }

    private static func statusCounts(
        _ activities: [CodexTaskActivity],
        now: Date,
        recentWindow: TimeInterval
    ) -> (running: Int, waiting: Int, done: Int, error: Int) {
        activities.reduce(into: (running: 0, waiting: 0, done: 0, error: 0)) { counts, activity in
            switch activity.status {
            case .running:
                counts.running += 1
            case .waiting:
                counts.waiting += 1
            case .done:
                if isRecentTerminalActivity(activity, now: now, recentWindow: recentWindow) {
                    counts.done += 1
                }
            case .error:
                if isRecentTerminalActivity(activity, now: now, recentWindow: recentWindow) {
                    counts.error += 1
                }
            case .stale:
                break
            }
        }
    }

    private static func isRecentTerminalActivity(
        _ activity: CodexTaskActivity,
        now: Date,
        recentWindow: TimeInterval
    ) -> Bool {
        guard recentWindow > 0 else {
            return false
        }
        let terminalAt = activity.completedAt ?? activity.updatedAt
        return now.timeIntervalSince(terminalAt) <= recentWindow
    }

    private static func tooltip(for activities: [CodexTaskActivity]) -> String {
        guard !activities.isEmpty else {
            return "No Codex task activity"
        }
        return activities
            .sorted { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.id < rhs.id
                }
                return lhs.updatedAt > rhs.updatedAt
            }
            .map { activity in
                [
                    activity.badge,
                    activity.nodeID,
                    activity.sessionID,
                    activity.turnID,
                    activity.status.rawValue,
                    activity.phase.rawValue,
                    activity.toolName,
                ]
                .compactMap { value in
                    guard let value, !value.isEmpty else {
                        return nil
                    }
                    return value
                }
                .joined(separator: " ")
            }
            .joined(separator: "\n")
    }
}
