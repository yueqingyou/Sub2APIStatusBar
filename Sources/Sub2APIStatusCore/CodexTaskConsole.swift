import Foundation

public struct CodexTaskConsoleRow: Identifiable, Sendable, Equatable {
    public struct EventRow: Identifiable, Sendable, Equatable {
        public let id: String
        public let eventID: String
        public let eventName: String
        public let observedAt: Date
        public let sessionID: String
        public let turnID: String
        public let cwd: String?
        public let model: String?
        public let toolName: String?
        public let statusHint: String?
        public let toolUseID: String?
        public let errorMessage: String?
        public let transcriptPath: String?
        public let userAgent: String?
        public let rawPayloadHash: String?
        public let rawPayloadJSON: String?

        init(event: CodexTaskActivity.TimelineEvent) {
            id = event.eventID
            eventID = event.eventID
            eventName = event.hookEvent.rawValue
            observedAt = event.observedAt
            sessionID = event.sessionID
            turnID = event.turnID
            cwd = event.cwd
            model = event.model
            toolName = event.toolName
            statusHint = event.statusHint
            toolUseID = event.toolUseID
            errorMessage = event.errorMessage
            transcriptPath = event.transcriptPath
            userAgent = event.userAgent
            rawPayloadHash = event.rawPayloadHash
            rawPayloadJSON = event.rawPayloadJSON
        }
    }

    public let id: String
    public let badge: String
    public let status: String
    public let isActive: Bool
    public let nodeID: String
    public let sessionID: String
    public let turnID: String
    public let cwd: String?
    public let model: String?
    public let toolName: String?
    public let statusHint: String?
    public let toolUseID: String?
    public let errorMessage: String?
    public let transcriptPath: String?
    public let userAgent: String?
    public let rawPayloadHash: String?
    public let updatedAt: Date
    public let events: [EventRow]

    public init(activity: CodexTaskActivity) {
        let eventRows = activity.timeline
            .sorted { lhs, rhs in
                if lhs.observedAt == rhs.observedAt {
                    return lhs.eventID < rhs.eventID
                }
                return lhs.observedAt < rhs.observedAt
            }
            .map(EventRow.init(event:))

        id = activity.id
        badge = activity.badge
        status = Self.statusCode(activity.status)
        isActive = activity.status == .running || activity.status == .waiting
        nodeID = activity.nodeID
        sessionID = activity.sessionID
        turnID = activity.turnID
        cwd = activity.cwd
        model = activity.model
        toolName = activity.toolName
        statusHint = activity.statusHint
        toolUseID = activity.toolUseID
        errorMessage = activity.errorMessage
        transcriptPath = activity.transcriptPath
        userAgent = activity.userAgent ?? eventRows.reversed().compactMap(\.userAgent).first
        rawPayloadHash = activity.rawPayloadHash
        updatedAt = activity.updatedAt
        events = eventRows
    }

    public func latestEvents(limit: Int) -> [EventRow] {
        let boundedLimit = min(max(limit, 1), AppConfig.codexTaskTimelineEventLimitRange.upperBound)
        return Array(events.suffix(boundedLimit).reversed())
    }

    private static func statusCode(_ status: CodexTaskActivity.Status) -> String {
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
}

public struct CodexTaskGatewayUsageDetail: Sendable, Equatable {
    public let requestID: String?
    public let model: String?
    public let upstreamModel: String?
    public let modelMappingChain: String?
    public let serviceTier: String?
    public let reasoningEffort: String?
    public let inboundEndpoint: String?
    public let upstreamEndpoint: String?
    public let requestType: String?
    public let stream: Bool?
    public let inputTokens: Int64
    public let outputTokens: Int64
    public let cacheCreationTokens: Int64
    public let cacheReadTokens: Int64
    public let actualCost: Double
    public let totalCost: Double
    public let durationMs: Double
    public let firstTokenMs: Double?
    public let userAgent: String?
    public let billingMode: String?
    public let createdAt: Date?

    public init(usage: UsageLog) {
        requestID = Self.nonEmpty(usage.requestID)
        model = Self.nonEmpty(usage.model)
        upstreamModel = Self.nonEmpty(usage.upstreamModel)
        modelMappingChain = Self.nonEmpty(usage.modelMappingChain)
        serviceTier = Self.nonEmpty(usage.serviceTier)
        reasoningEffort = Self.nonEmpty(usage.reasoningEffort)
        inboundEndpoint = Self.nonEmpty(usage.inboundEndpoint)
        upstreamEndpoint = Self.nonEmpty(usage.upstreamEndpoint)
        requestType = Self.nonEmpty(usage.requestType)
        stream = usage.stream
        inputTokens = usage.inputTokens
        outputTokens = usage.outputTokens
        cacheCreationTokens = usage.cacheCreationTokens
        cacheReadTokens = usage.cacheReadTokens
        actualCost = usage.actualCost
        totalCost = usage.totalCost
        durationMs = usage.durationMs
        firstTokenMs = usage.firstTokenMs
        userAgent = Self.nonEmpty(usage.userAgent)
        billingMode = Self.nonEmpty(usage.billingMode)
        createdAt = usage.createdAt
    }

    public var totalTokens: Int64 {
        inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public struct CodexTaskGatewayConcurrencyDetail: Sendable, Equatable {
    public let userID: Int64
    public let userEmail: String?
    public let username: String?
    public let currentInUse: Int64
    public let maxCapacity: Int64
    public let waitingInQueue: Int64
    public let loadPercentage: Double

    public init(concurrency: UserRealtimeConcurrency) {
        userID = concurrency.userID
        userEmail = Self.nonEmpty(concurrency.userEmail)
        username = Self.nonEmpty(concurrency.username)
        currentInUse = concurrency.currentInUse
        maxCapacity = concurrency.maxCapacity
        waitingInQueue = concurrency.waitingInQueue
        loadPercentage = concurrency.loadPercentage
    }

    public var capacityText: String {
        "\(currentInUse)/\(maxCapacity)"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public enum CodexTaskConsoleModel {
    public static func rows(activities: [CodexTaskActivity]) -> [CodexTaskConsoleRow] {
        activities
            .sorted { lhs, rhs in
                let lhsIsActive = lhs.status == .running || lhs.status == .waiting
                let rhsIsActive = rhs.status == .running || rhs.status == .waiting
                if lhsIsActive != rhsIsActive {
                    return lhsIsActive
                }
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.id < rhs.id
                }
                return lhs.updatedAt > rhs.updatedAt
            }
            .map(CodexTaskConsoleRow.init(activity:))
    }

    public static func gatewayUsageDetail(latestUsage: UsageLog?) -> CodexTaskGatewayUsageDetail? {
        latestUsage.map(CodexTaskGatewayUsageDetail.init(usage:))
    }

    public static func gatewayConcurrencyDetail(
        realtimeConcurrency: UserRealtimeConcurrency?
    ) -> CodexTaskGatewayConcurrencyDetail? {
        realtimeConcurrency.map(CodexTaskGatewayConcurrencyDetail.init(concurrency:))
    }
}
