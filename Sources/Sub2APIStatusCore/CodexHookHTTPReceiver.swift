import Foundation

public struct CodexHookHTTPRequest: Sendable, Equatable {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data

    public init(method: String, path: String, headers: [String: String], body: Data) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }

    func header(_ name: String) -> String? {
        let target = name.lowercased()
        return headers.first { key, _ in
            key.lowercased() == target
        }?.value
    }
}

public struct CodexHookHTTPResponse: Sendable, Equatable {
    public let statusCode: Int
    public let result: CodexHookIngestResult?
    public let error: CodexHookIngestError?

    public init(statusCode: Int, result: CodexHookIngestResult? = nil, error: CodexHookIngestError? = nil) {
        self.statusCode = statusCode
        self.result = result
        self.error = error
    }
}

public struct CodexHookHTTPReceiver: Sendable, Equatable {
    public static let path = "/codex-hooks/events"
    public static let nodeIDHeader = "x-s2sb-node-id"
    public static let timestampHeader = "x-s2sb-timestamp"
    public static let signatureHeader = "x-s2sb-signature"

    private var ingestor: CodexHookEventIngestor

    public init(ingestor: CodexHookEventIngestor) {
        self.ingestor = ingestor
    }

    public mutating func handle(_ request: CodexHookHTTPRequest, now: Date) -> CodexHookHTTPResponse {
        guard request.method.uppercased() == "POST", request.path == Self.path else {
            return CodexHookHTTPResponse(statusCode: 404)
        }
        guard let nodeID = request.header(Self.nodeIDHeader),
              let timestamp = request.header(Self.timestampHeader),
              let signature = request.header(Self.signatureHeader) else {
            return CodexHookHTTPResponse(statusCode: 401, error: .invalidSignature)
        }

        do {
            let result = try ingestor.ingest(
                body: request.body,
                nodeIDHeader: nodeID,
                timestampHeader: timestamp,
                signatureHeader: signature,
                now: now
            )
            return CodexHookHTTPResponse(statusCode: 202, result: result)
        } catch let error as CodexHookIngestError {
            return CodexHookHTTPResponse(statusCode: Self.statusCode(for: error), error: error)
        } catch {
            return CodexHookHTTPResponse(statusCode: 400)
        }
    }

    private static func statusCode(for error: CodexHookIngestError) -> Int {
        switch error {
        case .unknownNode, .invalidSignature:
            return 401
        case .replayRejected:
            return 409
        case .invalidTimestamp, .timestampMismatch, .nodeMismatch, .unsupportedSchemaVersion:
            return 400
        }
    }
}
