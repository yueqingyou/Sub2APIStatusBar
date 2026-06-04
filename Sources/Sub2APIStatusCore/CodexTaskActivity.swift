import Foundation

public enum CodexHookEventName: String, Codable, Sendable, Equatable {
    case userPromptSubmit = "UserPromptSubmit"
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"
    case permissionRequest = "PermissionRequest"
    case stop = "Stop"
    case preCompact = "PreCompact"
    case postCompact = "PostCompact"
    case subagentStart = "SubagentStart"
    case subagentStop = "SubagentStop"
}

public struct CodexHookEvent: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1
    private static let localSyntheticTestSessionID = "sub2api-statusbar-test-session"
    private static let localSyntheticTestTurnIDPrefix = "sub2api-statusbar-test-turn-"
    private static let remoteSyntheticTestSessionID = "sub2api-statusbar-remote-test-session"
    private static let remoteSyntheticTestTurnIDPrefix = "sub2api-statusbar-remote-test-turn-"

    public let schemaVersion: Int
    public let eventID: String
    public let nodeID: String
    public let observedAt: Date
    public let hookEvent: CodexHookEventName
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

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case eventID = "event_id"
        case nodeID = "node_id"
        case observedAt = "observed_at"
        case hookEvent = "hook_event"
        case sessionID = "session_id"
        case turnID = "turn_id"
        case cwd
        case model
        case toolName = "tool_name"
        case statusHint = "status_hint"
        case toolUseID = "tool_use_id"
        case errorMessage = "error_message"
        case transcriptPath = "transcript_path"
        case userAgent = "user_agent"
        case rawPayloadHash = "raw_payload_hash"
    }

    public init(
        schemaVersion: Int = CodexHookEvent.currentSchemaVersion,
        eventID: String,
        nodeID: String,
        observedAt: Date,
        hookEvent: CodexHookEventName,
        sessionID: String,
        turnID: String,
        cwd: String?,
        model: String?,
        toolName: String?,
        statusHint: String? = nil,
        toolUseID: String? = nil,
        errorMessage: String? = nil,
        transcriptPath: String? = nil,
        userAgent: String? = nil,
        rawPayloadHash: String? = nil,
        rawPayloadJSON: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.eventID = eventID
        self.nodeID = nodeID
        self.observedAt = observedAt
        self.hookEvent = hookEvent
        self.sessionID = sessionID
        self.turnID = turnID
        self.cwd = cwd
        self.model = model
        self.toolName = toolName
        self.statusHint = Self.nonEmpty(statusHint)
        self.toolUseID = Self.nonEmpty(toolUseID)
        self.errorMessage = Self.nonEmpty(errorMessage)
        self.transcriptPath = Self.nonEmpty(transcriptPath)
        self.userAgent = Self.nonEmpty(userAgent)
        self.rawPayloadHash = Self.nonEmpty(rawPayloadHash)
        self.rawPayloadJSON = rawPayloadJSON
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        eventID = try container.decode(String.self, forKey: .eventID)
        nodeID = try container.decode(String.self, forKey: .nodeID)
        observedAt = try container.decode(Date.self, forKey: .observedAt)
        hookEvent = try container.decode(CodexHookEventName.self, forKey: .hookEvent)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        turnID = try container.decode(String.self, forKey: .turnID)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
        statusHint = Self.nonEmpty(try container.decodeIfPresent(String.self, forKey: .statusHint))
        toolUseID = Self.nonEmpty(try container.decodeIfPresent(String.self, forKey: .toolUseID))
        errorMessage = Self.nonEmpty(try container.decodeIfPresent(String.self, forKey: .errorMessage))
        transcriptPath = Self.nonEmpty(try container.decodeIfPresent(String.self, forKey: .transcriptPath))
        userAgent = Self.nonEmpty(try container.decodeIfPresent(String.self, forKey: .userAgent))
        rawPayloadHash = Self.nonEmpty(try container.decodeIfPresent(String.self, forKey: .rawPayloadHash))
        rawPayloadJSON = nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(eventID, forKey: .eventID)
        try container.encode(nodeID, forKey: .nodeID)
        try container.encode(observedAt, forKey: .observedAt)
        try container.encode(hookEvent, forKey: .hookEvent)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(turnID, forKey: .turnID)
        try container.encodeIfPresent(cwd, forKey: .cwd)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(toolName, forKey: .toolName)
        try container.encodeIfPresent(statusHint, forKey: .statusHint)
        try container.encodeIfPresent(toolUseID, forKey: .toolUseID)
        try container.encodeIfPresent(errorMessage, forKey: .errorMessage)
        try container.encodeIfPresent(transcriptPath, forKey: .transcriptPath)
        try container.encodeIfPresent(userAgent, forKey: .userAgent)
        try container.encodeIfPresent(rawPayloadHash, forKey: .rawPayloadHash)
    }

    public func withRawPayloadJSON(_ rawPayloadJSON: String) -> CodexHookEvent {
        CodexHookEvent(
            schemaVersion: schemaVersion,
            eventID: eventID,
            nodeID: nodeID,
            observedAt: observedAt,
            hookEvent: hookEvent,
            sessionID: sessionID,
            turnID: turnID,
            cwd: cwd,
            model: model,
            toolName: toolName,
            statusHint: statusHint,
            toolUseID: toolUseID,
            errorMessage: errorMessage,
            transcriptPath: transcriptPath,
            userAgent: userAgent,
            rawPayloadHash: rawPayloadHash,
            rawPayloadJSON: rawPayloadJSON
        )
    }

    public var isSyntheticTestEvent: Bool {
        switch sessionID {
        case Self.localSyntheticTestSessionID:
            return turnID.hasPrefix(Self.localSyntheticTestTurnIDPrefix)
        case Self.remoteSyntheticTestSessionID:
            return turnID.hasPrefix(Self.remoteSyntheticTestTurnIDPrefix)
        default:
            return false
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public struct CodexTaskActivity: Identifiable, Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable, Equatable {
        case running
        case waiting
        case done
        case error
        case stale
    }

    public enum Phase: String, Codable, Sendable, Equatable {
        case prompt
        case tooling
        case completed
    }

    public struct TimelineEvent: Identifiable, Codable, Sendable, Equatable {
        public var id: String { eventID }
        public let eventID: String
        public let hookEvent: CodexHookEventName
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

        public init(
            eventID: String,
            hookEvent: CodexHookEventName,
            observedAt: Date,
            sessionID: String = "",
            turnID: String = "",
            cwd: String?,
            model: String?,
            toolName: String?,
            statusHint: String? = nil,
            toolUseID: String? = nil,
            errorMessage: String? = nil,
            transcriptPath: String? = nil,
            userAgent: String? = nil,
            rawPayloadHash: String? = nil,
            rawPayloadJSON: String? = nil
        ) {
            self.eventID = eventID
            self.hookEvent = hookEvent
            self.observedAt = observedAt
            self.sessionID = sessionID
            self.turnID = turnID
            self.cwd = cwd
            self.model = model
            self.toolName = toolName
            self.statusHint = statusHint
            self.toolUseID = toolUseID
            self.errorMessage = errorMessage
            self.transcriptPath = transcriptPath
            self.userAgent = userAgent
            self.rawPayloadHash = rawPayloadHash
            self.rawPayloadJSON = rawPayloadJSON
        }
    }

    public var id: String { "\(nodeID)|\(sessionID)" }
    public let nodeID: String
    public let sessionID: String
    public var turnID: String
    public let badge: String
    public var cwd: String?
    public var model: String?
    public var status: Status
    public var phase: Phase
    public var toolName: String?
    public var statusHint: String? = nil
    public var toolUseID: String? = nil
    public var errorMessage: String? = nil
    public var transcriptPath: String? = nil
    public var userAgent: String? = nil
    public var rawPayloadHash: String? = nil
    public let startedAt: Date
    public var updatedAt: Date
    public var completedAt: Date?
    public var timeline: [TimelineEvent]

    public var isTerminal: Bool {
        status == .done || status == .error
    }
}

public struct CodexTaskActivityStore: Sendable, Equatable {
    private var activityByKey: [String: CodexTaskActivity] = [:]
    private var seenEventIDs = Set<String>()
    private var badgeByKey: [String: String] = [:]

    public init() {}

    public init(activities: [CodexTaskActivity]) {
        let sortedActivities = activities.sorted { lhs, rhs in
            if lhs.startedAt == rhs.startedAt {
                return lhs.id < rhs.id
            }
            return lhs.startedAt < rhs.startedAt
        }
        for activity in sortedActivities {
            activityByKey[activity.id] = activity
            badgeByKey[activity.id] = activity.badge
            seenEventIDs.formUnion(activity.timeline.map(\.eventID))
        }
    }

    public mutating func keepOnlyActivities(forNodeIDs nodeIDs: Set<String>) {
        let normalizedNodeIDs = Set(nodeIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        activityByKey = activityByKey.filter { _, activity in
            normalizedNodeIDs.contains(activity.nodeID)
        }
        badgeByKey = badgeByKey.filter { key, _ in
            activityByKey[key] != nil
        }
        seenEventIDs = Set(activityByKey.values.flatMap { $0.timeline.map(\.eventID) })
    }

    public var activities: [CodexTaskActivity] {
        activityByKey.values.sorted { lhs, rhs in
            if lhs.startedAt == rhs.startedAt {
                return lhs.id < rhs.id
            }
            return lhs.startedAt < rhs.startedAt
        }
    }

    public mutating func apply(_ event: CodexHookEvent) {
        guard !event.isSyntheticTestEvent else {
            return
        }
        guard seenEventIDs.insert(event.eventID).inserted else {
            return
        }

        let key = activityKey(for: event)
        let badge = badgeByKey[key] ?? nextBadge()
        badgeByKey[key] = badge

        let existingActivity = activityByKey[key]
        var activity = existingActivity ?? CodexTaskActivity(
            nodeID: event.nodeID,
            sessionID: event.sessionID,
            turnID: event.turnID,
            badge: badge,
            cwd: event.cwd,
            model: event.model,
            status: .running,
            phase: .prompt,
            toolName: event.toolName,
            statusHint: event.statusHint,
            toolUseID: event.toolUseID,
            errorMessage: event.errorMessage,
            transcriptPath: event.transcriptPath,
            userAgent: event.userAgent,
            rawPayloadHash: event.rawPayloadHash,
            startedAt: event.observedAt,
            updatedAt: event.observedAt,
            completedAt: nil,
            timeline: []
        )

        activity.timeline.append(Self.timelineEvent(from: event))

        let updatesCurrentTurn = existingActivity.map { Self.updatesCurrentTurn($0, with: event) } ?? true
        if updatesCurrentTurn {
            activity.turnID = event.turnID
            activity.updatedAt = event.observedAt
        }

        let explicitStatus = Self.explicitStatus(from: event)

        guard updatesCurrentTurn else {
            activityByKey[key] = activity
            return
        }

        if activity.cwd == nil {
            activity.cwd = event.cwd
        }
        if activity.model == nil {
            activity.model = event.model
        }
        if let statusHint = event.statusHint {
            activity.statusHint = statusHint
        }
        if let toolUseID = event.toolUseID {
            activity.toolUseID = toolUseID
        }
        if let errorMessage = event.errorMessage {
            activity.errorMessage = errorMessage
        }
        if let transcriptPath = event.transcriptPath {
            activity.transcriptPath = transcriptPath
        }
        if let userAgent = event.userAgent {
            activity.userAgent = userAgent
        }
        if let rawPayloadHash = event.rawPayloadHash {
            activity.rawPayloadHash = rawPayloadHash
        }

        switch event.hookEvent {
        case .userPromptSubmit:
            activity.status = Self.nonTerminalStatus(explicitStatus)
            activity.phase = .prompt
            activity.completedAt = nil
        case .preToolUse, .postToolUse, .postCompact:
            activity.status = Self.nonTerminalStatus(explicitStatus)
            activity.phase = .tooling
            activity.toolName = event.toolName
            activity.completedAt = nil
        case .permissionRequest, .preCompact:
            activity.status = explicitStatus ?? .waiting
            activity.phase = event.hookEvent == .permissionRequest ? .prompt : .tooling
            activity.toolName = event.toolName
            activity.completedAt = nil
        case .subagentStart:
            activity.status = Self.nonTerminalStatus(explicitStatus)
            activity.phase = .tooling
            activity.toolName = event.toolName
            activity.completedAt = nil
        case .stop:
            activity.status = explicitStatus == .error ? .error : .done
            activity.phase = .completed
            activity.completedAt = event.observedAt
        case .subagentStop:
            activity.status = Self.nonTerminalStatus(explicitStatus)
            activity.phase = .tooling
            activity.toolName = event.toolName
            activity.completedAt = nil
        }

        activityByKey[key] = activity
    }

    private static func updatesCurrentTurn(_ activity: CodexTaskActivity, with event: CodexHookEvent) -> Bool {
        let sameTurn = activity.turnID == event.turnID
        if !sameTurn {
            return event.hookEvent == .userPromptSubmit
        }

        if activity.isTerminal, event.hookEvent != .stop {
            return false
        }

        return true
    }

    public mutating func markStale(now: Date, staleAfter seconds: TimeInterval) {
        guard seconds > 0 else {
            return
        }

        for key in activityByKey.keys {
            guard var activity = activityByKey[key],
                  activity.status == .running,
                  now.timeIntervalSince(activity.updatedAt) >= seconds else {
                continue
            }
            activity.status = .stale
            activityByKey[key] = activity
        }
    }

    private func activityKey(for event: CodexHookEvent) -> String {
        "\(event.nodeID)|\(event.sessionID)"
    }

    private func nextBadge() -> String {
        let nextNumber = badgeByKey.values.reduce(0) { partialResult, badge in
            guard badge.hasPrefix("A"),
                  let number = Int(badge.dropFirst()) else {
                return partialResult
            }
            return max(partialResult, number)
        } + 1
        return "A\(nextNumber)"
    }

    private static func explicitStatus(from event: CodexHookEvent) -> CodexTaskActivity.Status? {
        if event.errorMessage != nil {
            return .error
        }

        guard let hint = event.statusHint else {
            return nil
        }

        let normalized = hint
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")

        switch normalized {
        case "error", "errored", "failed", "failure", "cancelled", "canceled":
            return .error
        case "waiting", "queued", "queue", "paused", "pause", "approval", "blocked":
            return .waiting
        case "running", "active", "started", "in_progress", "thinking":
            return .running
        case "done", "complete", "completed", "success", "succeeded":
            return .done
        default:
            return nil
        }
    }

    private static func nonTerminalStatus(_ status: CodexTaskActivity.Status?) -> CodexTaskActivity.Status {
        guard let status, status != .done else {
            return .running
        }
        return status
    }

    private static func timelineEvent(from event: CodexHookEvent) -> CodexTaskActivity.TimelineEvent {
        CodexTaskActivity.TimelineEvent(
            eventID: event.eventID,
            hookEvent: event.hookEvent,
            observedAt: event.observedAt,
            sessionID: event.sessionID,
            turnID: event.turnID,
            cwd: event.cwd,
            model: event.model,
            toolName: event.toolName,
            statusHint: event.statusHint,
            toolUseID: event.toolUseID,
            errorMessage: event.errorMessage,
            transcriptPath: event.transcriptPath,
            userAgent: event.userAgent,
            rawPayloadHash: event.rawPayloadHash,
            rawPayloadJSON: event.rawPayloadJSON
        )
    }
}
