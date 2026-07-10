import Foundation

public struct TokenRouterRefreshPolicy: Sendable, Equatable {
    public let slowRefreshInterval: TimeInterval

    public init(slowRefreshInterval: TimeInterval = 60) {
        self.slowRefreshInterval = max(30, slowRefreshInterval)
    }

    public func shouldRefreshSlowData(
        lastAttemptAt: Date?,
        now: Date,
        isManualRefresh: Bool
    ) -> Bool {
        guard !isManualRefresh, let lastAttemptAt else {
            return true
        }
        return now.timeIntervalSince(lastAttemptAt) >= slowRefreshInterval
    }
}
