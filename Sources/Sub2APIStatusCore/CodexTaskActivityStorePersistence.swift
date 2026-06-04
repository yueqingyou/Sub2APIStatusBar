import Foundation

public final class CodexTaskActivityStorePersistence: @unchecked Sendable {
    private let storageURL: URL
    private let fileManager: FileManager
    private let maxStoredActivities: Int

    public init(
        storageURL: URL? = nil,
        fileManager: FileManager = .default,
        maxStoredActivities: Int = 200
    ) {
        self.fileManager = fileManager
        self.maxStoredActivities = max(1, maxStoredActivities)
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
        let activities = try JSONDecoder.codexHook.decode([CodexTaskActivity].self, from: data)
        return CodexTaskActivityStore(activities: activities)
    }

    public func save(_ store: CodexTaskActivityStore) throws {
        try save(store.activities)
    }

    public func save(_ activities: [CodexTaskActivity]) throws {
        try fileManager.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let trimmedActivities = Array(
            activities
                .sorted { lhs, rhs in
                    if lhs.updatedAt == rhs.updatedAt {
                        return lhs.id < rhs.id
                    }
                    return lhs.updatedAt < rhs.updatedAt
                }
                .suffix(maxStoredActivities)
        )
        let data = try JSONEncoder.codexHook.encode(trimmedActivities)
        try data.write(to: storageURL, options: .atomic)
    }
}
