import Foundation

public enum CodexHookTestEventFailureKind: Sendable, Equatable {
    case invalidSignature
    case receiverRejected
    case replayRejected
    case receiverUnavailable
    case transportFailed
}

public struct CodexHookTestEventFailure: Sendable, Equatable {
    public let kind: CodexHookTestEventFailureKind
    public let detail: String

    public init(kind: CodexHookTestEventFailureKind, detail: String) {
        self.kind = kind
        self.detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum CodexHookTestEventFailureClassifier {
    private static let remoteHTTPPrefix = "S2SB_REMOTE_TEST_EVENT_HTTP_"
    private static let remoteTransportPrefix = "S2SB_REMOTE_TEST_EVENT_TRANSPORT"

    public static func classifyLocalHTTPStatus(_ statusCode: Int) -> CodexHookTestEventFailure {
        let detail = "HTTP \(statusCode)"
        switch statusCode {
        case 401:
            return CodexHookTestEventFailure(kind: .invalidSignature, detail: detail)
        case 409:
            return CodexHookTestEventFailure(kind: .replayRejected, detail: detail)
        case 400, 404:
            return CodexHookTestEventFailure(kind: .receiverRejected, detail: detail)
        default:
            return CodexHookTestEventFailure(kind: .receiverUnavailable, detail: detail)
        }
    }

    public static func classifyRemoteResult(_ result: CodexHookRemoteInstallResult) -> CodexHookTestEventFailure {
        let detail = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        if let statusCode = remoteReceiverStatusCode(from: detail) {
            let local = classifyLocalHTTPStatus(statusCode)
            return CodexHookTestEventFailure(kind: local.kind, detail: local.detail)
        }
        if detail.contains(remoteTransportPrefix) {
            return CodexHookTestEventFailure(kind: .transportFailed, detail: normalizedRemoteDetail(detail, fallback: "exit \(result.exitCode)"))
        }
        return CodexHookTestEventFailure(kind: .transportFailed, detail: normalizedRemoteDetail(detail, fallback: "exit \(result.exitCode)"))
    }

    private static func remoteReceiverStatusCode(from detail: String) -> Int? {
        guard let range = detail.range(of: remoteHTTPPrefix) else {
            return nil
        }
        let suffix = detail[range.upperBound...]
            .prefix { $0.isNumber }
        return Int(suffix)
    }

    private static func normalizedRemoteDetail(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}
