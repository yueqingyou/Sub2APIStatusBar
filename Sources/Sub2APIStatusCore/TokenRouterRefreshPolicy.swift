import Foundation

public struct TokenRouterRefreshPolicy: Sendable, Equatable {
    public let slowRefreshInterval: TimeInterval
    public let accountUsageRefreshInterval: TimeInterval

    public init(
        slowRefreshInterval: TimeInterval = 60,
        accountUsageRefreshInterval: TimeInterval = 10 * 60
    ) {
        self.slowRefreshInterval = max(30, slowRefreshInterval)
        self.accountUsageRefreshInterval = max(60, accountUsageRefreshInterval)
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

    public func shouldRefreshAccountUsage(
        lastAttemptAt: Date?,
        now: Date,
        isManualRefresh: Bool
    ) -> Bool {
        guard !isManualRefresh, let lastAttemptAt else {
            return true
        }
        return now.timeIntervalSince(lastAttemptAt) >= accountUsageRefreshInterval
    }
}
