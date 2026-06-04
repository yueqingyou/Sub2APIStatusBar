import Foundation

public enum CodexNodeKind: String, Codable, Sendable, Equatable, CaseIterable, Identifiable {
    case local
    case remote

    public var id: String {
        rawValue
    }
}

public enum CodexNodeValidationError: Error, Sendable, Equatable {
    case emptyID
    case invalidID
    case emptyName
    case emptySecret
    case invalidLocalReceiverPort
    case invalidRemoteReceiverPort
    case missingRemoteReceiverPort
    case missingSSHConnection
    case emptySSHHost
}

public enum CodexNodeFormError: Error, Sendable, Equatable {
    case invalidLocalReceiverPort
    case invalidRemoteReceiverPort
    case invalidSSHPort
}

public struct SSHNodeConnection: Codable, Sendable, Equatable {
    public let host: String
    public let user: String?
    public let port: Int?
    public let identityFile: String?

    public init(
        host: String,
        user: String? = nil,
        port: Int? = nil,
        identityFile: String? = nil
    ) {
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.user = Self.normalizedOptional(user)
        self.port = port
        self.identityFile = Self.normalizedOptional(identityFile)
    }

    public var destination: String {
        if let user {
            return "\(user)@\(host)"
        }
        return host
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

public struct SSHConfigHost: Sendable, Equatable, Identifiable {
    public let alias: String
    public let hostName: String?
    public let user: String?
    public let port: Int?
    public let identityFile: String?

    public var id: String {
        alias
    }

    public init(
        alias: String,
        hostName: String? = nil,
        user: String? = nil,
        port: Int? = nil,
        identityFile: String? = nil
    ) {
        self.alias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        self.hostName = Self.normalizedOptional(hostName)
        self.user = Self.normalizedOptional(user)
        self.port = port
        self.identityFile = Self.normalizedOptional(identityFile)
    }

    public var displayDestination: String {
        let host = hostName ?? alias
        if let user {
            return "\(user)@\(host)"
        }
        return host
    }

    public var nodeConnection: SSHNodeConnection {
        SSHNodeConnection(host: hostName ?? alias, user: user, port: port, identityFile: identityFile)
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

public enum SSHConfigParser {
    public static func parse(_ rawConfig: String) -> [SSHConfigHost] {
        var blocks: [SSHConfigBlock] = []
        var currentPatterns: [String] = []
        var currentOptions = SSHConfigOptions()

        func flushCurrentBlock() {
            guard !currentPatterns.isEmpty else {
                currentOptions = SSHConfigOptions()
                return
            }
            blocks.append(SSHConfigBlock(patterns: currentPatterns, options: currentOptions))
            currentPatterns = []
            currentOptions = SSHConfigOptions()
        }

        for rawLine in rawConfig.split(whereSeparator: \.isNewline) {
            guard let parts = sshConfigDirectiveParts(String(rawLine)) else {
                continue
            }
            let key = parts.key.lowercased()
            if key == "host" {
                flushCurrentBlock()
                currentPatterns = parts.value
                    .split(whereSeparator: \.isWhitespace)
                    .map(String.init)
                    .filter { !$0.isEmpty }
                continue
            }
            guard !currentPatterns.isEmpty else {
                continue
            }
            currentOptions.apply(key: key, value: parts.value)
        }
        flushCurrentBlock()

        let aliases = blocks
            .flatMap(\.patterns)
            .filter { isConcreteHostAlias($0) }

        return aliases
            .reduce(into: [String: SSHConfigHost]()) { result, alias in
                guard result[alias] == nil else {
                    return
                }
                let effective = effectiveOptions(for: alias, blocks: blocks)
                result[alias] = SSHConfigHost(
                    alias: alias,
                    hostName: effective.hostName,
                    user: effective.user,
                    port: effective.port,
                    identityFile: effective.identityFile
                )
            }
            .values
            .sorted { $0.alias.localizedStandardCompare($1.alias) == .orderedAscending }
    }

    private static func effectiveOptions(for alias: String, blocks: [SSHConfigBlock]) -> SSHConfigOptions {
        blocks.reduce(into: SSHConfigOptions()) { result, block in
            guard block.patterns.contains(where: { patternMatches($0, alias: alias) }) else {
                return
            }
            result.mergeMissing(from: block.options)
        }
    }

    private static func sshConfigDirectiveParts(_ rawLine: String) -> (key: String, value: String)? {
        let trimmed = stripComment(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        if let equalsIndex = trimmed.firstIndex(of: "=") {
            let key = String(trimmed[..<equalsIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(trimmed[trimmed.index(after: equalsIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty else {
                return nil
            }
            return (key, unquote(value))
        }
        let pieces = trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard pieces.count == 2 else {
            return nil
        }
        return (String(pieces[0]), unquote(String(pieces[1]).trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    private static func stripComment(_ rawLine: String) -> String {
        var result = ""
        var isEscaped = false
        var quote: Character?
        for character in rawLine {
            if isEscaped {
                result.append(character)
                isEscaped = false
                continue
            }
            if character == "\\" {
                result.append(character)
                isEscaped = true
                continue
            }
            if character == "\"" || character == "'" {
                if quote == character {
                    quote = nil
                } else if quote == nil {
                    quote = character
                }
                result.append(character)
                continue
            }
            if character == "#", quote == nil {
                break
            }
            result.append(character)
        }
        return result
    }

    private static func unquote(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2,
              let first = trimmed.first,
              let last = trimmed.last,
              (first == "\"" || first == "'"),
              first == last else {
            return trimmed
        }
        return String(trimmed.dropFirst().dropLast())
    }

    private static func isConcreteHostAlias(_ pattern: String) -> Bool {
        !pattern.isEmpty
            && !pattern.hasPrefix("!")
            && !pattern.contains("*")
            && !pattern.contains("?")
    }

    private static func patternMatches(_ pattern: String, alias: String) -> Bool {
        guard !pattern.hasPrefix("!") else {
            return false
        }
        if isConcreteHostAlias(pattern) {
            return pattern == alias
        }
        return wildcardPattern(pattern, matches: alias)
    }

    private static func wildcardPattern(_ pattern: String, matches value: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
            .replacingOccurrences(of: "\\?", with: ".")
        return value.range(of: "^\(escaped)$", options: [.regularExpression]) != nil
    }
}

private struct SSHConfigBlock: Sendable, Equatable {
    let patterns: [String]
    let options: SSHConfigOptions
}

private struct SSHConfigOptions: Sendable, Equatable {
    var hostName: String?
    var user: String?
    var port: Int?
    var identityFile: String?

    mutating func apply(key: String, value: String) {
        switch key {
        case "hostname":
            hostName = hostName ?? normalize(value)
        case "user":
            user = user ?? normalize(value)
        case "port":
            port = port ?? Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        case "identityfile":
            identityFile = identityFile ?? normalize(value)
        default:
            break
        }
    }

    mutating func mergeMissing(from other: SSHConfigOptions) {
        hostName = hostName ?? other.hostName
        user = user ?? other.user
        port = port ?? other.port
        identityFile = identityFile ?? other.identityFile
    }

    private func normalize(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public struct CodexNode: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let kind: CodexNodeKind
    public let localReceiverPort: Int
    public let remoteReceiverPort: Int?
    public let ssh: SSHNodeConnection?
    public let codexHomeOverride: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case kind
        case localReceiverPort
        case remoteReceiverPort
        case ssh
        case codexHomeOverride
    }

    public init(
        id: String,
        name: String,
        kind: CodexNodeKind,
        localReceiverPort: Int,
        remoteReceiverPort: Int?,
        ssh: SSHNodeConnection?,
        codexHomeOverride: String?
    ) throws {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else {
            throw CodexNodeValidationError.emptyID
        }
        guard Self.isValidID(normalizedID) else {
            throw CodexNodeValidationError.invalidID
        }
        guard !normalizedName.isEmpty else {
            throw CodexNodeValidationError.emptyName
        }
        guard Self.isValidPort(localReceiverPort) else {
            throw CodexNodeValidationError.invalidLocalReceiverPort
        }
        if let remoteReceiverPort, !Self.isValidPort(remoteReceiverPort) {
            throw CodexNodeValidationError.invalidRemoteReceiverPort
        }
        if kind == .remote {
            guard remoteReceiverPort != nil else {
                throw CodexNodeValidationError.missingRemoteReceiverPort
            }
            guard let ssh else {
                throw CodexNodeValidationError.missingSSHConnection
            }
            guard !ssh.host.isEmpty else {
                throw CodexNodeValidationError.emptySSHHost
            }
        }

        self.id = normalizedID
        self.name = normalizedName
        self.kind = kind
        self.localReceiverPort = localReceiverPort
        self.remoteReceiverPort = remoteReceiverPort
        self.ssh = ssh
        self.codexHomeOverride = Self.normalizedOptional(codexHomeOverride)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: try container.decode(String.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            kind: try container.decode(CodexNodeKind.self, forKey: .kind),
            localReceiverPort: try container.decode(Int.self, forKey: .localReceiverPort),
            remoteReceiverPort: try container.decodeIfPresent(Int.self, forKey: .remoteReceiverPort),
            ssh: try container.decodeIfPresent(SSHNodeConnection.self, forKey: .ssh),
            codexHomeOverride: try container.decodeIfPresent(String.self, forKey: .codexHomeOverride)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(kind, forKey: .kind)
        try container.encode(localReceiverPort, forKey: .localReceiverPort)
        try container.encodeIfPresent(remoteReceiverPort, forKey: .remoteReceiverPort)
        try container.encodeIfPresent(ssh, forKey: .ssh)
        try container.encodeIfPresent(codexHomeOverride, forKey: .codexHomeOverride)
    }

    public var hookReceiverURL: URL {
        let port = kind == .remote ? remoteReceiverPort! : localReceiverPort
        return URL(string: "http://127.0.0.1:\(port)\(CodexHookHTTPReceiver.path)")!
    }

    public var localHookReceiverURL: URL {
        URL(string: "http://127.0.0.1:\(localReceiverPort)\(CodexHookHTTPReceiver.path)")!
    }

    static func isValidPort(_ port: Int) -> Bool {
        (1...65_535).contains(port)
    }

    public static func isValidID(_ value: String) -> Bool {
        let id = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = id.unicodeScalars.first,
              Self.firstIDScalars.contains(first) else {
            return false
        }
        return id.unicodeScalars.allSatisfy { Self.idScalars.contains($0) }
    }

    private static let firstIDScalars = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
    private static let idScalars = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")

    private static func normalizedOptional(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

public struct CodexNodeFormState: Sendable, Equatable {
    public var id: String
    public var name: String
    public var kind: CodexNodeKind
    public var localReceiverPort: String
    public var remoteReceiverPort: String
    public var sshHost: String
    public var sshUser: String
    public var sshPort: String
    public var sshIdentityFile: String
    public var codexHomeOverride: String
    public var secret: String

    public init(
        id: String = "",
        name: String = "",
        kind: CodexNodeKind = .local,
        localReceiverPort: String = "43210",
        remoteReceiverPort: String = "53210",
        sshHost: String = "",
        sshUser: String = "",
        sshPort: String = "",
        sshIdentityFile: String = "",
        codexHomeOverride: String = "",
        secret: String = ""
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.localReceiverPort = localReceiverPort
        self.remoteReceiverPort = remoteReceiverPort
        self.sshHost = sshHost
        self.sshUser = sshUser
        self.sshPort = sshPort
        self.sshIdentityFile = sshIdentityFile
        self.codexHomeOverride = codexHomeOverride
        self.secret = secret
    }

    public init(registeredNode: CodexRegisteredNode) {
        let node = registeredNode.node
        id = node.id
        name = node.name
        kind = node.kind
        localReceiverPort = String(node.localReceiverPort)
        remoteReceiverPort = node.remoteReceiverPort.map(String.init) ?? ""
        sshHost = node.ssh?.host ?? ""
        sshUser = node.ssh?.user ?? ""
        sshPort = node.ssh?.port.map(String.init) ?? ""
        sshIdentityFile = node.ssh?.identityFile ?? ""
        codexHomeOverride = node.codexHomeOverride ?? ""
        secret = registeredNode.secret
    }

    public static func localDefault(id: String = "local", name: String = "本机") -> CodexNodeFormState {
        CodexNodeFormState(
            id: id,
            name: name,
            kind: .local,
            localReceiverPort: "43210",
            remoteReceiverPort: "",
            secret: UUID().uuidString
        )
    }

    public func registeredNode() throws -> CodexRegisteredNode {
        let node = try CodexNode(
            id: id,
            name: name,
            kind: kind,
            localReceiverPort: try requiredPort(localReceiverPort, error: .invalidLocalReceiverPort),
            remoteReceiverPort: kind == .remote ? try requiredPort(remoteReceiverPort, error: .invalidRemoteReceiverPort) : nil,
            ssh: kind == .remote
                ? SSHNodeConnection(host: sshHost, user: sshUser, port: try optionalPort(sshPort), identityFile: sshIdentityFile)
                : nil,
            codexHomeOverride: codexHomeOverride
        )
        let trimmedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSecret.isEmpty else {
            throw CodexNodeValidationError.emptySecret
        }
        return CodexRegisteredNode(node: node, secret: trimmedSecret)
    }

    private func requiredPort(_ raw: String, error: CodexNodeFormError) throws -> Int {
        guard let port = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              CodexNode.isValidPort(port) else {
            throw error
        }
        return port
    }

    private func optionalPort(_ raw: String) throws -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        guard let port = Int(trimmed), CodexNode.isValidPort(port) else {
            throw CodexNodeFormError.invalidSSHPort
        }
        return port
    }
}

public struct ProcessCommand: Sendable, Equatable {
    public let executable: String
    public let arguments: [String]

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}

public struct CodexRegisteredNode: Sendable, Equatable {
    public let node: CodexNode
    public let secret: String

    public init(node: CodexNode, secret: String) {
        self.node = node
        self.secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct CodexNodeRegistry: Sendable, Equatable {
    private let nodesByID: [String: CodexRegisteredNode]

    public init(registeredNodes: [CodexRegisteredNode]) {
        nodesByID = Dictionary(uniqueKeysWithValues: registeredNodes.map { ($0.node.id, $0) })
    }

    public var nodes: [CodexNode] {
        nodesByID.values
            .map(\.node)
            .sorted { $0.id < $1.id }
    }

    public var registeredNodes: [CodexRegisteredNode] {
        nodesByID.values
            .sorted { $0.node.id < $1.node.id }
    }

    public var nodeSecrets: [String: String] {
        nodesByID.reduce(into: [:]) { result, pair in
            guard !pair.value.secret.isEmpty else {
                return
            }
            result[pair.key] = pair.value.secret
        }
    }

    public func node(id: String) -> CodexRegisteredNode? {
        nodesByID[id.trimmingCharacters(in: .whitespacesAndNewlines)]
    }
}

public enum SSHTunnelCommandError: Error, Sendable, Equatable {
    case nodeIsNotRemote
    case missingRemoteReceiverPort
    case missingSSHConnection
}

public struct SSHTunnelCommandBuilder {
    public static func buildCommand(for node: CodexNode, sshExecutable: String = "/usr/bin/ssh") throws -> ProcessCommand {
        guard node.kind == .remote else {
            throw SSHTunnelCommandError.nodeIsNotRemote
        }
        guard let remotePort = node.remoteReceiverPort else {
            throw SSHTunnelCommandError.missingRemoteReceiverPort
        }
        guard let ssh = node.ssh else {
            throw SSHTunnelCommandError.missingSSHConnection
        }

        var arguments = [
            "-N",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=2",
        ]
        if let port = ssh.port {
            arguments.append(contentsOf: ["-p", String(port)])
        }
        if let identityFile = ssh.identityFile {
            arguments.append(contentsOf: ["-i", identityFile])
        }
        arguments.append(contentsOf: [
            "-R", "127.0.0.1:\(remotePort):127.0.0.1:\(node.localReceiverPort)",
            ssh.destination,
        ])

        return ProcessCommand(executable: sshExecutable, arguments: arguments)
    }
}
