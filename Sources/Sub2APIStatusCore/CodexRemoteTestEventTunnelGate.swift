import Foundation

public enum CodexRemoteTestEventTunnelAction: Sendable, Equatable {
    case ready
    case startTunnel
    case waitForRunning
}

public enum CodexRemoteTestEventTunnelReadiness: Sendable, Equatable {
    case ready
    case notReady(CodexRemoteTestEventTunnelNotReadyReason)
}

public enum CodexRemoteTestEventTunnelNotReadyReason: Sendable, Equatable {
    case missingStatus
    case stillStarting
    case failed(exitCode: Int32)

    public var statusDescription: String {
        switch self {
        case .missingStatus:
            return "missing"
        case .stillStarting:
            return "still starting"
        case let .failed(exitCode):
            return "exit \(exitCode)"
        }
    }
}

public enum CodexRemoteTestEventTunnelGate {
    public static func decideBeforeSending(currentStatus: SSHTunnelStatus?) -> CodexRemoteTestEventTunnelAction {
        guard let currentStatus else {
            return .startTunnel
        }
        switch currentStatus.state {
        case .running:
            return .ready
        case .starting:
            return .waitForRunning
        case .failed:
            return .startTunnel
        }
    }

    public static func decideAfterStart(startStatus: SSHTunnelStatus) -> CodexRemoteTestEventTunnelReadiness {
        switch startStatus.state {
        case .running:
            return .ready
        case .starting:
            return .notReady(.stillStarting)
        case let .failed(exitCode):
            return .notReady(.failed(exitCode: exitCode))
        }
    }

    public static func decideAfterWait(waitedStatus: SSHTunnelStatus?) -> CodexRemoteTestEventTunnelReadiness {
        guard let waitedStatus else {
            return .notReady(.missingStatus)
        }
        switch waitedStatus.state {
        case .running:
            return .ready
        case .starting:
            return .notReady(.stillStarting)
        case let .failed(exitCode):
            return .notReady(.failed(exitCode: exitCode))
        }
    }
}
