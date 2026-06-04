import Foundation

public enum SSHTunnelProcessState: Sendable, Equatable {
    case starting
    case running
    case failed(exitCode: Int32)
}

public struct SSHTunnelStatus: Sendable, Equatable {
    public let nodeID: String
    public let command: ProcessCommand
    public let state: SSHTunnelProcessState
    public let detail: String?

    public init(nodeID: String, command: ProcessCommand, state: SSHTunnelProcessState, detail: String? = nil) {
        self.nodeID = nodeID
        self.command = command
        self.state = state
        self.detail = Self.normalizedDetail(detail)
    }

    private static func normalizedDetail(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

public protocol SSHTunnelProcessHandle: AnyObject, Sendable {
    var isRunning: Bool { get }
    var terminationStatus: Int32 { get }
    var standardError: String { get }
    func terminate()
}

public protocol SSHTunnelProcessLaunching: Sendable {
    func launch(command: ProcessCommand) throws -> any SSHTunnelProcessHandle
}

public final class FoundationSSHTunnelProcessHandle: SSHTunnelProcessHandle, @unchecked Sendable {
    private let process: Process
    private let errorPipe: Pipe
    private var cachedStandardError: String?

    init(process: Process, errorPipe: Pipe) {
        self.process = process
        self.errorPipe = errorPipe
    }

    public var isRunning: Bool {
        process.isRunning
    }

    public var terminationStatus: Int32 {
        process.terminationStatus
    }

    public var standardError: String {
        if let cachedStandardError {
            return cachedStandardError
        }
        guard !process.isRunning else {
            return ""
        }
        let value = String(
            data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        cachedStandardError = value
        return value
    }

    public func terminate() {
        process.terminate()
    }
}

public struct FoundationSSHTunnelProcessLauncher: SSHTunnelProcessLaunching {
    public init() {}

    public func launch(command: ProcessCommand) throws -> any SSHTunnelProcessHandle {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.standardError = errorPipe
        try process.run()
        return FoundationSSHTunnelProcessHandle(process: process, errorPipe: errorPipe)
    }
}

public enum SSHTunnelManagerError: Error, Sendable, Equatable {
    case nodeIsNotRemote
}

public final class SSHTunnelManager: @unchecked Sendable {
    private let launcher: any SSHTunnelProcessLaunching
    private let startupGraceInterval: TimeInterval
    private let now: @Sendable () -> Date
    private var tunnels: [String: ManagedTunnel] = [:]

    private struct ManagedTunnel {
        let handle: any SSHTunnelProcessHandle
        let command: ProcessCommand
        let startedAt: Date
    }

    public init(
        launcher: any SSHTunnelProcessLaunching = FoundationSSHTunnelProcessLauncher(),
        startupGraceInterval: TimeInterval = 0.75,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.launcher = launcher
        self.startupGraceInterval = max(0, startupGraceInterval)
        self.now = now
    }

    @discardableResult
    public func start(node: CodexNode) throws -> SSHTunnelStatus {
        guard node.kind == .remote else {
            throw SSHTunnelManagerError.nodeIsNotRemote
        }
        stop(nodeID: node.id)
        let command = try SSHTunnelCommandBuilder.buildCommand(for: node)
        let handle = try launcher.launch(command: command)
        tunnels[node.id] = ManagedTunnel(handle: handle, command: command, startedAt: now())
        return status(nodeID: node.id) ?? SSHTunnelStatus(nodeID: node.id, command: command, state: .starting)
    }

    @discardableResult
    public func ensureStarted(node: CodexNode) throws -> SSHTunnelStatus {
        guard node.kind == .remote else {
            throw SSHTunnelManagerError.nodeIsNotRemote
        }
        if let current = status(nodeID: node.id) {
            switch current.state {
            case .starting, .running:
                return current
            case .failed:
                break
            }
        }
        return try start(node: node)
    }

    public func status(nodeID: String) -> SSHTunnelStatus? {
        guard let tunnel = tunnels[nodeID] else {
            return nil
        }
        let state: SSHTunnelProcessState
        let detail: String?
        if !tunnel.handle.isRunning {
            state = .failed(exitCode: tunnel.handle.terminationStatus)
            detail = tunnel.handle.standardError
        } else if now().timeIntervalSince(tunnel.startedAt) < startupGraceInterval {
            state = .starting
            detail = nil
        } else {
            state = .running
            detail = nil
        }
        return SSHTunnelStatus(nodeID: nodeID, command: tunnel.command, state: state, detail: detail)
    }

    public func stop(nodeID: String) {
        tunnels[nodeID]?.handle.terminate()
        tunnels[nodeID] = nil
    }

    public func stopAll() {
        for nodeID in Array(tunnels.keys) {
            stop(nodeID: nodeID)
        }
    }
}
