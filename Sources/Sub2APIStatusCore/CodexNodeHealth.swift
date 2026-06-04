import Foundation

public enum CodexNodeHealthState: String, Codable, Sendable, Equatable, CaseIterable {
    case unconfigured
    case installed
    case waitingForTrust
    case healthy
    case receiverFailed
    case tunnelFailed
    case installFailed
    case configWriteFailed
    case invalidSignature
    case stale
}

public struct CodexNodeHealthStatus: Identifiable, Codable, Sendable, Equatable {
    public var id: String { nodeID }
    public let nodeID: String
    public var state: CodexNodeHealthState
    public var detail: String?
    public var updatedAt: Date
    public var lastSeenAt: Date?
    public var lastTestEventAt: Date?

    public init(
        nodeID: String,
        state: CodexNodeHealthState,
        detail: String? = nil,
        updatedAt: Date,
        lastSeenAt: Date? = nil,
        lastTestEventAt: Date? = nil
    ) {
        self.nodeID = nodeID
        self.state = state
        self.detail = Self.normalizedDetail(detail)
        self.updatedAt = updatedAt
        self.lastSeenAt = lastSeenAt
        self.lastTestEventAt = lastTestEventAt
    }

    private static func normalizedDetail(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

public struct CodexNodeHealthStore: Sendable, Equatable {
    private var statusesByNodeID: [String: CodexNodeHealthStatus] = [:]

    public init() {}

    public var statuses: [String: CodexNodeHealthStatus] {
        statusesByNodeID
    }

    public func status(nodeID: String) -> CodexNodeHealthStatus? {
        statusesByNodeID[nodeID.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    public mutating func configure(nodes: [CodexNode], now: Date) {
        let nodeIDs = Set(nodes.map(\.id))
        statusesByNodeID = statusesByNodeID.filter { nodeIDs.contains($0.key) }
        for node in nodes where statusesByNodeID[node.id] == nil {
            statusesByNodeID[node.id] = CodexNodeHealthStatus(
                nodeID: node.id,
                state: .unconfigured,
                updatedAt: now
            )
        }
    }

    public mutating func markReceiverReady(port: Int, nodes: [CodexNode], now: Date) {
        for node in nodes where node.localReceiverPort == port {
            update(nodeID: node.id, now: now) { status in
                if status.state == .receiverFailed {
                    status.state = .unconfigured
                    status.detail = nil
                }
            }
        }
    }

    public mutating func markReceiverFailed(port: Int, nodes: [CodexNode], detail: String?, now: Date) {
        for node in nodes where node.localReceiverPort == port {
            update(nodeID: node.id, now: now) { status in
                status.state = .receiverFailed
                status.detail = Self.normalizedDetail(detail)
            }
        }
    }

    public mutating func markHooksInstalled(nodeID: String, detail: String? = nil, now: Date) {
        update(nodeID: nodeID, now: now) { status in
            status.state = .waitingForTrust
            status.detail = Self.normalizedDetail(detail)
        }
    }

    public mutating func markHooksConfigured(nodeID: String, detail: String? = nil, now: Date) {
        update(nodeID: nodeID, now: now) { status in
            switch status.state {
            case .unconfigured, .configWriteFailed, .installFailed, .tunnelFailed:
                status.state = .installed
            case .installed, .waitingForTrust:
                break
            default:
                return
            }
            status.detail = Self.normalizedDetail(detail)
        }
    }

    public mutating func markInstallFailed(
        nodeID: String,
        state: CodexNodeHealthState = .installFailed,
        detail: String?,
        now: Date
    ) {
        update(nodeID: nodeID, now: now) { status in
            status.state = state
            status.detail = Self.normalizedDetail(detail)
        }
    }

    public mutating func markTunnelRunning(nodeID: String, now: Date) {
        update(nodeID: nodeID, now: now) { status in
            if status.state == .tunnelFailed {
                status.state = .unconfigured
                status.detail = nil
            }
        }
    }

    public mutating func markTunnelStopped(nodeID: String, detail: String?, now: Date) {
        update(nodeID: nodeID, now: now) { status in
            switch status.state {
            case .healthy, .stale:
                status.state = .installed
            case .installed, .waitingForTrust:
                break
            default:
                status.detail = Self.normalizedDetail(detail)
                return
            }
            status.detail = Self.normalizedDetail(detail)
        }
    }

    public mutating func markTunnelFailed(nodeID: String, detail: String?, now: Date) {
        update(nodeID: nodeID, now: now) { status in
            status.state = .tunnelFailed
            status.detail = Self.normalizedDetail(detail)
        }
    }

    public mutating func markInvalidSignature(nodeID: String, detail: String?, now: Date) {
        update(nodeID: nodeID, now: now) { status in
            status.state = .invalidSignature
            status.detail = Self.normalizedDetail(detail)
        }
    }

    public mutating func markEventReceived(_ event: CodexHookEvent, now: Date) {
        update(nodeID: event.nodeID, now: now) { status in
            if event.isSyntheticTestEvent {
                status.lastTestEventAt = event.observedAt
                switch status.state {
                case .receiverFailed, .tunnelFailed, .invalidSignature:
                    status.state = .unconfigured
                    status.detail = nil
                default:
                    break
                }
            } else {
                status.lastSeenAt = event.observedAt
                status.state = .healthy
                status.detail = nil
            }
        }
    }

    public mutating func markStale(now: Date, staleAfter seconds: TimeInterval) {
        for nodeID in statusesByNodeID.keys {
            update(nodeID: nodeID, now: now) { status in
                guard let lastSeenAt = status.lastSeenAt,
                      [.installed, .healthy].contains(status.state),
                      now.timeIntervalSince(lastSeenAt) > seconds else {
                    return
                }
                status.state = .stale
            }
        }
    }

    private mutating func update(
        nodeID rawNodeID: String,
        now: Date,
        _ change: (inout CodexNodeHealthStatus) -> Void
    ) {
        let nodeID = rawNodeID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nodeID.isEmpty else {
            return
        }
        var status = statusesByNodeID[nodeID] ?? CodexNodeHealthStatus(
            nodeID: nodeID,
            state: .unconfigured,
            updatedAt: now
        )
        change(&status)
        status.detail = Self.normalizedDetail(status.detail)
        status.updatedAt = now
        statusesByNodeID[nodeID] = status
    }

    private static func normalizedDetail(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
