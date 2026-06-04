import Foundation

public enum CodexHookTestEventRequestBuilder {
    public static func build(
        registeredNode: CodexRegisteredNode,
        now: Date,
        receiverURL: URL
    ) throws -> URLRequest {
        let event = CodexHookEvent(
            eventID: UUID().uuidString,
            nodeID: registeredNode.node.id,
            observedAt: now,
            hookEvent: .userPromptSubmit,
            sessionID: "sub2api-statusbar-test-session",
            turnID: "sub2api-statusbar-test-turn-\(Int(now.timeIntervalSince1970))",
            cwd: nil,
            model: "test",
            toolName: nil
        )
        let body = try JSONEncoder.codexHook.encode(event)
        var request = URLRequest(url: receiverURL)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(registeredNode.node.id, forHTTPHeaderField: CodexHookHTTPReceiver.nodeIDHeader)
        request.setValue(codexHookTimestamp(now), forHTTPHeaderField: CodexHookHTTPReceiver.timestampHeader)
        request.setValue(
            CodexHookSignatureVerifier.signatureHeader(for: body, secret: registeredNode.secret),
            forHTTPHeaderField: CodexHookHTTPReceiver.signatureHeader
        )
        return request
    }

    private static func codexHookTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
