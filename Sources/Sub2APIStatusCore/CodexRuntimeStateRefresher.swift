import Foundation

public struct CodexRuntimeStateRefresher: Sendable, Equatable {
    public let taskStaleAfterSeconds: TimeInterval
    public let nodeStaleAfterSeconds: TimeInterval

    public init(
        taskStaleAfterSeconds: TimeInterval,
        nodeStaleAfterSeconds: TimeInterval
    ) {
        self.taskStaleAfterSeconds = taskStaleAfterSeconds
        self.nodeStaleAfterSeconds = nodeStaleAfterSeconds
    }

    public func refresh(
        activityStore: inout CodexTaskActivityStore,
        nodeHealthStore: inout CodexNodeHealthStore,
        now: Date
    ) -> [CodexTaskActivity] {
        activityStore.markStale(now: now, staleAfter: taskStaleAfterSeconds)
        nodeHealthStore.markStale(now: now, staleAfter: nodeStaleAfterSeconds)
        return activityStore.activities
    }
}
