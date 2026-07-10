import Foundation

public final class CodexNodeStore {
    private let nodesURL: URL
    private let secretsURL: URL
    private let fileManager: FileManager

    public init(nodesURL: URL? = nil, secretsURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let nodesURL {
            self.nodesURL = nodesURL
            self.secretsURL = secretsURL ?? nodesURL.deletingLastPathComponent().appendingPathComponent("codex-node-secrets.json")
            return
        }

        let baseDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
        self.nodesURL = baseDir
            .appendingPathComponent("Sub2APIStatusBar", isDirectory: true)
            .appendingPathComponent("codex-nodes.json")
        self.secretsURL = secretsURL ?? baseDir
            .appendingPathComponent("Sub2APIStatusBar", isDirectory: true)
            .appendingPathComponent("codex-node-secrets.json")
    }

    public func load() throws -> [CodexNode] {
        guard fileManager.fileExists(atPath: nodesURL.path) else {
            return []
        }
        let data = try Data(contentsOf: nodesURL)
        return try JSONDecoder.tokenRouter.decode([CodexNode].self, from: data)
    }

    public func save(_ nodes: [CodexNode]) throws {
        try fileManager.createDirectory(at: nodesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(nodes)
        try data.write(to: nodesURL, options: .atomic)
    }

    public func loadRegistry() throws -> CodexNodeRegistry {
        let nodes = try load()
        let secrets = try loadSecrets()
        return CodexNodeRegistry(registeredNodes: nodes.map { node in
            CodexRegisteredNode(node: node, secret: secrets[node.id] ?? "")
        })
    }

    public func saveRegistry(_ registry: CodexNodeRegistry) throws {
        try save(registry.nodes)
        try saveSecrets(registry.nodeSecrets)
    }

    public func loadSecrets() throws -> [String: String] {
        guard fileManager.fileExists(atPath: secretsURL.path) else {
            return [:]
        }
        let data = try Data(contentsOf: secretsURL)
        return try JSONDecoder.tokenRouter.decode([String: String].self, from: data)
    }

    public func saveSecrets(_ secrets: [String: String]) throws {
        try fileManager.createDirectory(at: secretsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(secrets)
        try data.write(to: secretsURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: secretsURL.path
        )
    }
}
