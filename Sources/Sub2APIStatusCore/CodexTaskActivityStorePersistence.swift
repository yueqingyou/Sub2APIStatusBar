import Foundation

public final class CodexTaskActivityStorePersistence: @unchecked Sendable {
    private struct Archive: Codable {
        let schemaVersion: Int
        let savedAt: Date
        let activities: [CodexTaskActivity]

        private enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case savedAt = "saved_at"
            case activities
        }
    }

    private enum StoredPayload: Decodable {
        case archive(Archive)
        case legacy([CodexTaskActivity])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let archive = try? container.decode(Archive.self) {
                self = .archive(archive)
            } else {
                self = .legacy(try container.decode([CodexTaskActivity].self))
            }
        }
    }

    private enum PersistenceError: LocalizedError {
        case unsupportedSchemaVersion(Int)

        var errorDescription: String? {
            switch self {
            case let .unsupportedSchemaVersion(version):
                return "不支持的 Codex 任务日志版本：\(version)。"
            }
        }
    }

    private static let currentSchemaVersion = 2
    private let storageURL: URL
    private let fileManager: FileManager

    public init(
        storageURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        if let storageURL {
            self.storageURL = storageURL
            return
        }

        let baseDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
        self.storageURL = baseDir
            .appendingPathComponent("Sub2APIStatusBar", isDirectory: true)
            .appendingPathComponent("codex-task-activities.json")
    }

    public func load() throws -> CodexTaskActivityStore {
        guard fileManager.fileExists(atPath: storageURL.path) else {
            return CodexTaskActivityStore()
        }
        let data = try Data(contentsOf: storageURL)
        switch try JSONDecoder.codexHook.decode(StoredPayload.self, from: data) {
        case let .archive(archive):
            guard archive.schemaVersion == Self.currentSchemaVersion else {
                throw PersistenceError.unsupportedSchemaVersion(archive.schemaVersion)
            }
            var store = CodexTaskActivityStore(activities: archive.activities)
            store.prune(now: Date())
            return store
        case let .legacy(activities):
            var migratedStore = migrateLegacyActivities(activities)
            migratedStore.prune(now: Date())
            try save(migratedStore)
            return migratedStore
        }
    }

    public func save(_ store: CodexTaskActivityStore) throws {
        try save(store.activities)
    }

    public func save(_ activities: [CodexTaskActivity]) throws {
        try fileManager.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let normalizedActivities = CodexTaskActivityStore(activities: activities).activities
        let archive = Archive(
            schemaVersion: Self.currentSchemaVersion,
            savedAt: Date(),
            activities: normalizedActivities
        )
        let data = try JSONEncoder.codexHook.encode(archive)
        try data.write(to: storageURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
    }

    private func migrateLegacyActivities(_ activities: [CodexTaskActivity]) -> CodexTaskActivityStore {
        var retainedActivities: [CodexTaskActivity] = []
        var replayedStore = CodexTaskActivityStore()

        for activity in activities {
            let timelineTurnIDs = Set(activity.timeline.compactMap { event -> String? in
                let turnID = event.turnID.trimmingCharacters(in: .whitespacesAndNewlines)
                return turnID.isEmpty ? nil : turnID
            })
            guard timelineTurnIDs.count > 1 else {
                retainedActivities.append(activity)
                continue
            }

            for event in activity.timeline.sorted(by: Self.isEarlierTimelineEvent) {
                replayedStore.apply(CodexHookEvent(
                    eventID: event.eventID,
                    nodeID: activity.nodeID,
                    observedAt: event.observedAt,
                    hookEvent: event.hookEvent,
                    sessionID: event.sessionID.isEmpty ? activity.sessionID : event.sessionID,
                    turnID: event.turnID.isEmpty ? activity.turnID : event.turnID,
                    cwd: event.cwd,
                    model: event.model,
                    toolName: event.toolName,
                    statusHint: event.statusHint,
                    toolUseID: event.toolUseID,
                    errorMessage: event.errorMessage,
                    transcriptPath: event.transcriptPath,
                    userAgent: event.userAgent,
                    rawPayloadHash: event.rawPayloadHash
                ))
            }
        }

        return CodexTaskActivityStore(activities: retainedActivities + replayedStore.activities)
    }

    private static func isEarlierTimelineEvent(
        _ lhs: CodexTaskActivity.TimelineEvent,
        _ rhs: CodexTaskActivity.TimelineEvent
    ) -> Bool {
        if lhs.observedAt == rhs.observedAt {
            return lhs.eventID < rhs.eventID
        }
        return lhs.observedAt < rhs.observedAt
    }
}
