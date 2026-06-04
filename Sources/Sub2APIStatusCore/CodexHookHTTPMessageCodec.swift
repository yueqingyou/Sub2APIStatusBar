import Foundation

public enum CodexHookHTTPMessageCodecError: Error, Sendable, Equatable {
    case invalidRequest
    case invalidHeaderEncoding
    case invalidContentLength
}

public enum CodexHookHTTPMessageCodec {
    public static func completeRequestLength(in data: Data) throws -> Int? {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else {
            return nil
        }
        let headerData = data[..<separator.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw CodexHookHTTPMessageCodecError.invalidHeaderEncoding
        }

        let headers = headerLines(from: headerText)
        let bodyStart = separator.upperBound
        guard let contentLength = headers.first(where: { $0.key.lowercased() == "content-length" })?.value else {
            return data.count
        }
        guard let expectedLength = Int(contentLength), expectedLength >= 0 else {
            throw CodexHookHTTPMessageCodecError.invalidContentLength
        }
        let completeLength = bodyStart + expectedLength
        return data.count >= completeLength ? completeLength : nil
    }

    public static func parseRequest(_ data: Data) throws -> CodexHookHTTPRequest {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else {
            throw CodexHookHTTPMessageCodecError.invalidRequest
        }
        let headerData = data[..<separator.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw CodexHookHTTPMessageCodecError.invalidHeaderEncoding
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            throw CodexHookHTTPMessageCodecError.invalidRequest
        }
        let requestLineParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestLineParts.count >= 2 else {
            throw CodexHookHTTPMessageCodecError.invalidRequest
        }

        let headers = headerLines(from: headerText)

        let bodyStart = separator.upperBound
        let body = data[bodyStart..<data.endIndex]
        if let contentLength = headers.first(where: { $0.key.lowercased() == "content-length" })?.value {
            guard let expectedLength = Int(contentLength), expectedLength >= 0 else {
                throw CodexHookHTTPMessageCodecError.invalidContentLength
            }
            guard body.count >= expectedLength else {
                throw CodexHookHTTPMessageCodecError.invalidRequest
            }
            return CodexHookHTTPRequest(
                method: requestLineParts[0],
                path: requestLineParts[1],
                headers: headers,
                body: Data(body.prefix(expectedLength))
            )
        }

        return CodexHookHTTPRequest(
            method: requestLineParts[0],
            path: requestLineParts[1],
            headers: headers,
            body: Data(body)
        )
    }

    public static func serializeResponse(statusCode: Int) -> Data {
        let reason = reasonPhrase(for: statusCode)
        let body = Data()
        let header = [
            "HTTP/1.1 \(statusCode) \(reason)",
            "Content-Length: \(body.count)",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")
        return Data(header.utf8) + body
    }

    private static func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 202:
            return "Accepted"
        case 400:
            return "Bad Request"
        case 401:
            return "Unauthorized"
        case 404:
            return "Not Found"
        case 409:
            return "Conflict"
        default:
            return "OK"
        }
    }

    private static func headerLines(from headerText: String) -> [String: String] {
        let lines = headerText.components(separatedBy: "\r\n")
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                continue
            }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }
        return headers
    }
}
