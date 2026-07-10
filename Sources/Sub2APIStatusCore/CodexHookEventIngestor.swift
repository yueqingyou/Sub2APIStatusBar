import Foundation

public enum CodexHookIngestError: Error, Equatable {
    case unknownNode
    case nodeMismatch
    case invalidSignature
    case invalidTimestamp
    case timestampMismatch
    case replayRejected
    case unsupportedSchemaVersion(Int)
}

public struct CodexHookIngestResult: Sendable, Equatable {
    public let event: CodexHookEvent
    public let activities: [CodexTaskActivity]
}

public struct CodexHookEventIngestor: Sendable, Equatable {
    private let nodeSecrets: [String: String]
    private var replayGuard: CodexHookReplayGuard
    private var activityStore = CodexTaskActivityStore()

    public init(nodeSecrets: [String: String], allowedClockSkewSeconds: TimeInterval) {
        self.nodeSecrets = nodeSecrets
        replayGuard = CodexHookReplayGuard(allowedClockSkewSeconds: allowedClockSkewSeconds)
    }

    public mutating func ingest(
        body: Data,
        nodeIDHeader: String,
        timestampHeader: String,
        signatureHeader: String,
        now: Date
    ) throws -> CodexHookIngestResult {
        let nodeID = nodeIDHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let secret = nodeSecrets[nodeID], !nodeID.isEmpty else {
            throw CodexHookIngestError.unknownNode
        }
        guard try CodexHookSignatureVerifier.verify(body: body, signatureHeader: signatureHeader, secret: secret) else {
            throw CodexHookIngestError.invalidSignature
        }
        guard let headerTimestamp = Self.parseTimestamp(timestampHeader) else {
            throw CodexHookIngestError.invalidTimestamp
        }

        let event = try JSONDecoder.codexHook.decode(CodexHookEvent.self, from: body)
            .withRawPayloadJSON(String(data: body, encoding: .utf8) ?? "")
        guard event.schemaVersion == CodexHookEvent.currentSchemaVersion else {
            throw CodexHookIngestError.unsupportedSchemaVersion(event.schemaVersion)
        }
        guard abs(event.observedAt.timeIntervalSince(headerTimestamp)) < 1 else {
            throw CodexHookIngestError.timestampMismatch
        }
        guard event.nodeID == nodeID else {
            throw CodexHookIngestError.nodeMismatch
        }
        guard replayGuard.accepts(eventID: event.eventID, timestamp: event.observedAt, now: now) else {
            throw CodexHookIngestError.replayRejected
        }

        activityStore.apply(event)
        return CodexHookIngestResult(event: event, activities: activityStore.activities)
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return SharedISO8601DateParser.date(from: trimmed)
    }
}
