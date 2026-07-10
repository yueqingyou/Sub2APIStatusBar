import Foundation

public struct ModelPresentation: Equatable, Sendable {
    public let rawValue: String
    public let displayName: String
    public let compactName: String
    public let isLossy: Bool

    public init(rawValue: String, displayName: String, compactName: String, isLossy: Bool) {
        self.rawValue = rawValue
        self.displayName = displayName
        self.compactName = compactName
        self.isLossy = isLossy
    }
}

public struct ReasoningEffortPresentation: Equatable, Sendable {
    public let rawValue: String?
    public let displayName: String
    public let compactName: String
    public let isLossy: Bool
    public let isProvided: Bool

    public init(
        rawValue: String?,
        displayName: String,
        compactName: String,
        isLossy: Bool,
        isProvided: Bool
    ) {
        self.rawValue = rawValue
        self.displayName = displayName
        self.compactName = compactName
        self.isLossy = isLossy
        self.isProvided = isProvided
    }
}

public enum StatusFormatters {
    public static func modelDisplayName(_ model: String) -> String {
        modelPresentation(model).displayName
    }

    public static func menuBarModelName(_ model: String) -> String {
        modelPresentation(model).compactName
    }

    public static func modelPresentation(_ model: String) -> ModelPresentation {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ModelPresentation(rawValue: trimmed, displayName: trimmed, compactName: trimmed, isLossy: false)
        }

        let normalized = trimmed.lowercased()
        if normalized == "codex" || normalized.hasPrefix("codex-") || normalized.hasPrefix("codex_") {
            let descriptor = humanizedDescriptor(String(trimmed.dropFirst("codex".count)))
            let displayName = descriptor.isEmpty ? "Codex" : "Codex \(descriptor)"
            let compactName = descriptor.isEmpty ? "Codex" : descriptor
            return ModelPresentation(
                rawValue: trimmed,
                displayName: displayName,
                compactName: compactName,
                isLossy: false
            )
        }

        if let displayName = claudeModelName(trimmed, includesProvider: true),
           let compactName = claudeModelName(trimmed, includesProvider: false) {
            return ModelPresentation(
                rawValue: trimmed,
                displayName: displayName,
                compactName: compactName,
                isLossy: canonicalModelTokens(displayName) != canonicalModelTokens(trimmed)
            )
        }

        if normalized.hasPrefix("gpt-") {
            let descriptor = String(trimmed.dropFirst(4))
            let parts = descriptor.split(separator: "-", omittingEmptySubsequences: true).map(String.init)
            let version = parts.first ?? descriptor
            let qualifiers = parts.dropFirst().joined(separator: "-")
            let displayName = qualifiers.isEmpty ? "GPT-\(version)" : "GPT-\(version) \(qualifiers)"
            let fullCompactName = "GPT-\(descriptor)"
            let compactName = fullCompactName.count <= 8 ? fullCompactName : descriptor
            return ModelPresentation(
                rawValue: trimmed,
                displayName: displayName,
                compactName: compactName,
                isLossy: false
            )
        }

        return ModelPresentation(rawValue: trimmed, displayName: trimmed, compactName: trimmed, isLossy: false)
    }

    public static func reasoningEffortPresentation(_ effort: String?) -> ReasoningEffortPresentation {
        let trimmed = effort?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawValue = trimmed.flatMap { $0.isEmpty ? nil : $0 }
        let normalized = normalizedReasoningEffort(rawValue)

        switch normalized {
        case "", "none", "no":
            return ReasoningEffortPresentation(
                rawValue: rawValue,
                displayName: "None",
                compactName: "no",
                isLossy: false,
                isProvided: false
            )
        case "minimal":
            return ReasoningEffortPresentation(rawValue: rawValue, displayName: "Minimal", compactName: "min", isLossy: false, isProvided: true)
        case "low":
            return ReasoningEffortPresentation(rawValue: rawValue, displayName: "Low", compactName: "lo", isLossy: false, isProvided: true)
        case "medium":
            return ReasoningEffortPresentation(rawValue: rawValue, displayName: "Medium", compactName: "med", isLossy: false, isProvided: true)
        case "high":
            return ReasoningEffortPresentation(rawValue: rawValue, displayName: "High", compactName: "hi", isLossy: false, isProvided: true)
        case "xhigh", "extrahigh":
            return ReasoningEffortPresentation(rawValue: rawValue, displayName: "Extra High", compactName: "xh", isLossy: false, isProvided: true)
        case "max":
            return ReasoningEffortPresentation(rawValue: rawValue, displayName: "Max", compactName: "max", isLossy: false, isProvided: true)
        default:
            let value = rawValue ?? ""
            return ReasoningEffortPresentation(rawValue: rawValue, displayName: value, compactName: value, isLossy: false, isProvided: true)
        }
    }

    public static func compactNumber(_ value: Int64) -> String {
        let number = Double(value)
        if number >= 1_000_000 {
            return String(format: "%.1fM", number / 1_000_000)
        }
        if number >= 1_000 {
            return String(format: "%.1fK", number / 1_000)
        }
        return String(value)
    }

    public static func menuBarCount(_ value: Int64) -> String {
        if value < 10_000 {
            return String(value)
        }
        return compactNumber(value)
    }

    public static func menuBarRate(_ value: Double) -> String {
        if value.rounded() == value {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }

    public static func currency(_ value: Double) -> String {
        if value < 0.01, value > 0 {
            return String(format: "$%.4f", value)
        }
        return String(format: "$%.2f", value)
    }

    public static func menuBarCurrency(_ value: Double) -> String {
        let absValue = abs(value)
        let sign = value < 0 ? "-" : ""
        if absValue >= 1_000_000 {
            return String(format: "%@$%.2fM", sign, absValue / 1_000_000)
        }
        if absValue >= 1_000 {
            return String(format: "%@$%.2fK", sign, absValue / 1_000)
        }
        if absValue < 0.01, absValue > 0 {
            return String(format: "%@$%.4f", sign, absValue)
        }
        return String(format: "%@$%.2f", sign, absValue)
    }

    public static func preciseCurrency(_ value: Double) -> String {
        String(format: "$%.4f", value)
    }

    public static func tokenPricePerMillion(_ value: Double) -> String {
        String(format: "$%.4f", value)
    }

    public static func menuBarTokenPricePerMillion(_ value: Double) -> String {
        let formatted: String
        let absValue = abs(value)
        if absValue >= 1 {
            formatted = String(format: "$%.2f", value)
        } else {
            formatted = String(format: "$%.4f", value)
        }
        return formatted
            .replacingOccurrences(of: #"(\.\d*?)0+$"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    }

    public static func contextLength(_ value: Int64) -> String {
        "\(compactNumber(value)) ctx"
    }

    public static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", min(max(value, 0), 1) * 100)
    }

    public static func duration(seconds: Double) -> String {
        let seconds = Int(seconds)
        if seconds >= 86_400 {
            return "\(seconds / 86_400)d"
        }
        if seconds >= 3_600 {
            return "\(seconds / 3_600)h"
        }
        if seconds >= 60 {
            return "\(seconds / 60)m"
        }
        return "\(seconds)s"
    }

    private static func claudeModelName(_ model: String, includesProvider: Bool) -> String? {
        guard let claudeRange = model.range(of: "claude", options: [.caseInsensitive]) else {
            return nil
        }

        let claudePart = String(model[claudeRange.lowerBound...])
        let tokens = claudePart
            .split { !$0.isLetter && !$0.isNumber }
            .map { String($0).lowercased() }
        guard tokens.first == "claude" else {
            return nil
        }

        let descriptorTokens = Array(tokens.dropFirst())
        let familyNames = [
            "opus": "Opus",
            "sonnet": "Sonnet",
            "haiku": "Haiku",
            "instant": "Instant",
        ]

        if let familyIndex = descriptorTokens.firstIndex(where: { familyNames[$0] != nil }),
           let familyName = familyNames[descriptorTokens[familyIndex]] {
            let beforeFamily = Array(descriptorTokens[..<familyIndex])
            let afterFamily = Array(descriptorTokens.dropFirst(familyIndex + 1))
            let version = claudeVersion(from: beforeFamily) ?? claudeVersion(from: afterFamily)
            let modelName = [familyName, version].compactMap { $0 }.joined(separator: " ")
            return includesProvider ? "Claude \(modelName)" : modelName
        }

        if let version = claudeVersion(from: descriptorTokens) {
            return "Claude \(version)"
        }

        return "Claude"
    }

    private static func claudeVersion(from tokens: [String]) -> String? {
        let versionTokens = tokens
            .filter { token in
                token.allSatisfy(\.isNumber) && token.count != 8
            }
            .prefix(2)
        guard !versionTokens.isEmpty else {
            return nil
        }
        return versionTokens.joined(separator: ".")
    }

    private static func humanizedDescriptor(_ descriptor: String) -> String {
        descriptor
            .split { !$0.isLetter && !$0.isNumber }
            .map { token in
                let value = String(token)
                return value.prefix(1).uppercased() + value.dropFirst().lowercased()
            }
            .joined(separator: " ")
    }

    private static func canonicalModelTokens(_ value: String) -> [String] {
        value
            .split { !$0.isLetter && !$0.isNumber }
            .map { String($0).lowercased() }
            .filter { token in
                !(token.count == 8 && token.allSatisfy(\.isNumber))
            }
    }

    private static func normalizedReasoningEffort(_ effort: String?) -> String {
        guard let effort else {
            return ""
        }
        if effort == "-" {
            return ""
        }
        return effort
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
    }
}
