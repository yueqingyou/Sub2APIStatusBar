import Foundation

public enum OpenAIQuotaWindow: String, Codable, Sendable {
    case fiveHour
    case sevenDay
}

public struct OpenAIAccountQuota: Identifiable, Equatable, Sendable {
    public var id: Int64 { account.id }

    public let account: AccountSummary
    public let usage: AccountUsageInfo

    public init(account: AccountSummary, usage: AccountUsageInfo) {
        self.account = account
        self.usage = usage
    }

    public var planLabel: String {
        account.planLabel ?? "OpenAI"
    }

    public var isSchedulable: Bool {
        account.status == "active" && account.schedulable && !usage.quotaAutoPaused
    }

    public var highestUtilization: Double {
        max(usage.fiveHour?.utilization ?? 0, usage.sevenDay?.utilization ?? 0)
    }

    public func progress(for window: OpenAIQuotaWindow) -> UsageProgress? {
        switch window {
        case .fiveHour:
            return usage.fiveHour
        case .sevenDay:
            return usage.sevenDay
        }
    }
}

public struct OpenAIAccountQuotaSnapshot: Equatable, Sendable {
    public let accounts: [OpenAIAccountQuota]
    public let history: OpenAIQuotaHistory

    public init(accounts: [OpenAIAccountQuota], history: OpenAIQuotaHistory) {
        self.accounts = accounts.sorted { lhs, rhs in
            if lhs.highestUtilization != rhs.highestUtilization {
                return lhs.highestUtilization > rhs.highestUtilization
            }
            return lhs.account.displayName.localizedStandardCompare(rhs.account.displayName) == .orderedAscending
        }
        self.history = history
    }

    public var summary: OpenAIQuotaPoolSummary {
        OpenAIQuotaPoolSummary(accounts: accounts)
    }

    public func forecast(
        for account: OpenAIAccountQuota,
        window: OpenAIQuotaWindow,
        now: Date = Date()
    ) -> OpenAIQuotaForecast? {
        guard let current = account.progress(for: window) else {
            return nil
        }
        return OpenAIQuotaForecaster.forecast(
            accountID: account.id,
            window: window,
            current: current,
            history: history,
            now: now
        )
    }
}

public struct OpenAIQuotaWindowSample: Codable, Equatable, Sendable {
    public let utilization: Double
    public let resetsAt: String?
    public let requests: Int64?
    public let tokens: Int64?
    public let standardCost: Double?

    public init(progress: UsageProgress) {
        utilization = progress.utilization
        resetsAt = progress.resetsAt
        requests = progress.windowStats?.requests
        tokens = progress.windowStats?.tokens
        standardCost = progress.windowStats?.standardCost
    }
}

public struct OpenAIQuotaSample: Codable, Equatable, Sendable {
    public let accountID: Int64
    public let planType: String
    public let capturedAt: Date
    public let sourceUpdatedAt: String?
    public let fiveHour: OpenAIQuotaWindowSample?
    public let sevenDay: OpenAIQuotaWindowSample?

    public init(account: OpenAIAccountQuota, capturedAt: Date) {
        accountID = account.id
        planType = account.planLabel
        self.capturedAt = capturedAt
        sourceUpdatedAt = account.usage.updatedAt
        fiveHour = account.usage.fiveHour.map(OpenAIQuotaWindowSample.init)
        sevenDay = account.usage.sevenDay.map(OpenAIQuotaWindowSample.init)
    }

    fileprivate func hasSameSnapshot(as other: OpenAIQuotaSample) -> Bool {
        accountID == other.accountID
            && planType == other.planType
            && sourceUpdatedAt == other.sourceUpdatedAt
            && fiveHour == other.fiveHour
            && sevenDay == other.sevenDay
    }

    fileprivate func progress(for window: OpenAIQuotaWindow) -> OpenAIQuotaWindowSample? {
        switch window {
        case .fiveHour:
            return fiveHour
        case .sevenDay:
            return sevenDay
        }
    }
}

public struct OpenAIQuotaHistory: Equatable, Sendable {
    public static let retentionInterval: TimeInterval = 30 * 24 * 60 * 60

    public private(set) var samples: [OpenAIQuotaSample]

    public init(samples: [OpenAIQuotaSample] = []) {
        self.samples = samples.sorted { $0.capturedAt < $1.capturedAt }
    }

    @discardableResult
    public mutating func record(accounts: [OpenAIAccountQuota], capturedAt: Date) -> Bool {
        var changed = prune(now: capturedAt)
        for account in accounts {
            let sample = OpenAIQuotaSample(account: account, capturedAt: capturedAt)
            guard sample.fiveHour != nil || sample.sevenDay != nil else {
                continue
            }
            if let previous = samples.last(where: { $0.accountID == account.id }),
               sample.hasSameSnapshot(as: previous) {
                continue
            }
            samples.append(sample)
            changed = true
        }
        if changed {
            samples.sort { $0.capturedAt < $1.capturedAt }
        }
        return changed
    }

    @discardableResult
    public mutating func prune(now: Date) -> Bool {
        let cutoff = now.addingTimeInterval(-Self.retentionInterval)
        let previousCount = samples.count
        samples.removeAll { $0.capturedAt < cutoff }
        return samples.count != previousCount
    }
}

public final class OpenAIQuotaHistoryPersistence: @unchecked Sendable {
    private struct Archive: Codable {
        let schemaVersion: Int
        let samples: [OpenAIQuotaSample]
    }

    private enum PersistenceError: LocalizedError {
        case unsupportedSchemaVersion(Int)

        var errorDescription: String? {
            switch self {
            case let .unsupportedSchemaVersion(version):
                return "不支持的额度历史版本：\(version)。"
            }
        }
    }

    private static let schemaVersion = 1
    private let storageURL: URL
    private let fileManager: FileManager

    public init(storageURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let storageURL {
            self.storageURL = storageURL
            return
        }
        let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
        self.storageURL = baseDirectory
            .appendingPathComponent("Sub2APIStatusBar", isDirectory: true)
            .appendingPathComponent("openai-account-quota-history.json")
    }

    public func load(now: Date = Date()) throws -> OpenAIQuotaHistory {
        guard fileManager.fileExists(atPath: storageURL.path) else {
            return OpenAIQuotaHistory()
        }
        let archive = try JSONDecoder.codexHook.decode(Archive.self, from: Data(contentsOf: storageURL))
        guard archive.schemaVersion == Self.schemaVersion else {
            throw PersistenceError.unsupportedSchemaVersion(archive.schemaVersion)
        }
        var history = OpenAIQuotaHistory(samples: archive.samples)
        if history.prune(now: now) {
            try save(history)
        }
        return history
    }

    public func save(_ history: OpenAIQuotaHistory) throws {
        try fileManager.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let archive = Archive(schemaVersion: Self.schemaVersion, samples: history.samples)
        try JSONEncoder.codexHook.encode(archive).write(to: storageURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
    }
}

public enum OpenAIQuotaForecastConfidence: String, Equatable, Sendable {
    case insufficient
    case low
    case medium
    case high
}

public enum OpenAIQuotaTrend: String, Equatable, Sendable {
    case insufficient
    case rising
    case stable
    case falling
}

public struct OpenAIQuotaForecast: Equatable, Sendable {
    public let confidence: OpenAIQuotaForecastConfidence
    public let trend: OpenAIQuotaTrend
    public let predictedUtilizationAtReset: Double?
    public let thresholds: [OpenAIQuotaThresholdEstimate]

    public func estimatedAt(_ threshold: Int) -> Date? {
        thresholds.first { $0.threshold == threshold }?.date
    }
}

public struct OpenAIQuotaThresholdEstimate: Identifiable, Equatable, Sendable {
    public var id: Int { threshold }

    public let threshold: Int
    public let date: Date
}

public enum OpenAIQuotaForecaster {
    public static func forecast(
        accountID: Int64,
        window: OpenAIQuotaWindow,
        current: UsageProgress,
        history: OpenAIQuotaHistory,
        now: Date
    ) -> OpenAIQuotaForecast {
        guard let currentReset = current.resetsAt,
              let resetAt = SharedISO8601DateParser.date(from: currentReset),
              resetAt > now else {
            return OpenAIQuotaForecast(
                confidence: .insufficient,
                trend: .insufficient,
                predictedUtilizationAtReset: nil,
                thresholds: []
            )
        }
        let samples = history.samples.compactMap { sample -> (Date, OpenAIQuotaWindowSample)? in
            guard sample.accountID == accountID,
                  let progress = sample.progress(for: window),
                  progress.resetsAt == currentReset else {
                return nil
            }
            return (sample.capturedAt, progress)
        }
        guard samples.count >= 3,
              let first = samples.first,
              let last = samples.last,
              last.0.timeIntervalSince(first.0) >= 20 * 60,
              let slope = regressionSlope(samples) else {
            return OpenAIQuotaForecast(
                confidence: .insufficient,
                trend: .insufficient,
                predictedUtilizationAtReset: nil,
                thresholds: []
            )
        }

        let slopePerHour = slope * 3600
        let trend: OpenAIQuotaTrend
        if slopePerHour > 0.1 {
            trend = .rising
        } else if slopePerHour < -0.1 {
            trend = .falling
        } else {
            trend = .stable
        }

        let span = last.0.timeIntervalSince(first.0)
        var confidence = confidenceLevel(window: window, sampleCount: samples.count, span: span)
        if zip(samples, samples.dropFirst()).contains(where: { lhs, rhs in
            rhs.1.utilization < lhs.1.utilization - 5
        }) {
            confidence = lower(confidence)
        }

        guard slope > 0 else {
            return OpenAIQuotaForecast(
                confidence: confidence,
                trend: trend,
                predictedUtilizationAtReset: resetPrediction(
                    current: current,
                    slope: slope,
                    now: now,
                    resetAt: resetAt
                ),
                thresholds: []
            )
        }

        let thresholds = [70, 85, 95, 100].compactMap { threshold -> OpenAIQuotaThresholdEstimate? in
            guard let date = thresholdDate(
                Double(threshold),
                current: current,
                slope: slope,
                now: now,
                resetAt: resetAt
            ) else {
                return nil
            }
            return OpenAIQuotaThresholdEstimate(threshold: threshold, date: date)
        }
        return OpenAIQuotaForecast(
            confidence: confidence,
            trend: trend,
            predictedUtilizationAtReset: resetPrediction(
                current: current,
                slope: slope,
                now: now,
                resetAt: resetAt
            ),
            thresholds: thresholds
        )
    }

    private static func regressionSlope(_ samples: [(Date, OpenAIQuotaWindowSample)]) -> Double? {
        guard let origin = samples.first?.0 else {
            return nil
        }
        let points = samples.map { ($0.0.timeIntervalSince(origin), $0.1.utilization) }
        let meanX = points.reduce(0) { $0 + $1.0 } / Double(points.count)
        let meanY = points.reduce(0) { $0 + $1.1 } / Double(points.count)
        let numerator = points.reduce(0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) }
        let denominator = points.reduce(0) { $0 + pow($1.0 - meanX, 2) }
        guard denominator > 0 else {
            return nil
        }
        return numerator / denominator
    }

    private static func confidenceLevel(
        window: OpenAIQuotaWindow,
        sampleCount: Int,
        span: TimeInterval
    ) -> OpenAIQuotaForecastConfidence {
        switch window {
        case .fiveHour:
            if sampleCount >= 12, span >= 2 * 60 * 60 { return .high }
            if sampleCount >= 6, span >= 60 * 60 { return .medium }
        case .sevenDay:
            if sampleCount >= 24, span >= 24 * 60 * 60 { return .high }
            if sampleCount >= 12, span >= 12 * 60 * 60 { return .medium }
        }
        return .low
    }

    private static func lower(_ confidence: OpenAIQuotaForecastConfidence) -> OpenAIQuotaForecastConfidence {
        switch confidence {
        case .high:
            return .medium
        case .medium:
            return .low
        case .low, .insufficient:
            return confidence
        }
    }

    private static func resetPrediction(
        current: UsageProgress,
        slope: Double,
        now: Date,
        resetAt: Date
    ) -> Double {
        max(0, current.utilization + slope * resetAt.timeIntervalSince(now))
    }

    private static func thresholdDate(
        _ threshold: Double,
        current: UsageProgress,
        slope: Double,
        now: Date,
        resetAt: Date
    ) -> Date? {
        if current.utilization >= threshold {
            return now
        }
        let estimate = now.addingTimeInterval((threshold - current.utilization) / slope)
        return estimate <= resetAt ? estimate : nil
    }
}

public struct OpenAIQuotaPlanCapacity: Equatable, Sendable {
    public let plan: String
    public let fiveHourRemaining: Double
    public let sevenDayRemaining: Double
}

public struct OpenAIQuotaPoolSummary: Equatable, Sendable {
    public let accountCount: Int
    public let schedulableCount: Int
    public let riskCount: Int
    public let capacities: [OpenAIQuotaPlanCapacity]

    public init(accounts: [OpenAIAccountQuota]) {
        accountCount = accounts.count
        schedulableCount = accounts.filter(\.isSchedulable).count
        riskCount = accounts.filter {
            $0.account.status == "active" && $0.highestUtilization >= 70
        }.count

        let grouped = Dictionary(grouping: accounts.filter(\.isSchedulable), by: \.planLabel)
        capacities = grouped.map { plan, planAccounts in
            OpenAIQuotaPlanCapacity(
                plan: plan,
                fiveHourRemaining: Self.remainingEquivalent(planAccounts, window: .fiveHour),
                sevenDayRemaining: Self.remainingEquivalent(planAccounts, window: .sevenDay)
            )
        }.sorted { $0.plan.localizedStandardCompare($1.plan) == .orderedAscending }
    }

    private static func remainingEquivalent(
        _ accounts: [OpenAIAccountQuota],
        window: OpenAIQuotaWindow
    ) -> Double {
        accounts.reduce(0) { total, account in
            guard let progress = account.progress(for: window) else {
                return total
            }
            return total + max(0, 1 - progress.normalizedPercentage)
        }
    }
}
