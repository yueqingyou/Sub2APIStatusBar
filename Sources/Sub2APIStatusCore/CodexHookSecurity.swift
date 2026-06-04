import CryptoKit
import Foundation

public enum CodexHookSignatureError: Error, Equatable {
    case invalidSecret
    case invalidHeader
}

public enum CodexHookSignatureVerifier {
    private static let headerPrefix = "hmac-sha256="

    public static func signatureHeader(for body: Data, secret: String) -> String {
        headerPrefix + signatureHex(for: body, secret: secret)
    }

    public static func verify(body: Data, signatureHeader: String, secret: String) throws -> Bool {
        guard !secret.isEmpty else {
            throw CodexHookSignatureError.invalidSecret
        }
        guard signatureHeader.hasPrefix(headerPrefix) else {
            return false
        }
        let expected = Self.signatureHeader(for: body, secret: secret)
        return constantTimeEquals(signatureHeader, expected)
    }

    private static func signatureHex(for body: Data, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let code = HMAC<SHA256>.authenticationCode(for: body, using: key)
        return code.map { String(format: "%02x", $0) }.joined()
    }

    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        var diff = left.count ^ right.count
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            diff |= Int(l ^ r)
        }
        return diff == 0
    }
}

public struct CodexHookReplayGuard: Equatable, Sendable {
    public let allowedClockSkewSeconds: TimeInterval
    private var seenEventIDs = Set<String>()

    public init(allowedClockSkewSeconds: TimeInterval) {
        self.allowedClockSkewSeconds = allowedClockSkewSeconds
    }

    public mutating func accepts(eventID: String, timestamp: Date, now: Date) -> Bool {
        guard !eventID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        guard abs(now.timeIntervalSince(timestamp)) <= allowedClockSkewSeconds else {
            return false
        }
        return seenEventIDs.insert(eventID).inserted
    }
}
