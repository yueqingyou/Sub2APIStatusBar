import Foundation

public struct CodexHomeResolution: Equatable, Sendable {
    public let codexHomePath: String
    public let configPath: String
    public let userHomePath: String?

    public init(codexHomePath: String, configPath: String, userHomePath: String? = nil) {
        self.codexHomePath = codexHomePath
        self.configPath = configPath
        self.userHomePath = Self.normalizedOptionalPath(userHomePath)
    }

    private static func normalizedOptionalPath(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            return nil
        }
        var normalized = trimmed
        while normalized.hasSuffix("/") && normalized.count > 1 {
            normalized.removeLast()
        }
        return normalized
    }
}

public enum CodexHomeResolutionError: Error, LocalizedError, Sendable, Equatable {
    case missingRemoteHomeDirectory

    public var errorDescription: String? {
        switch self {
        case .missingRemoteHomeDirectory:
            return "远端环境未返回 CODEX_HOME 或 HOME，无法确定用户级 Codex 配置目录。"
        }
    }
}

public struct CodexRemoteEnvironment: Equatable, Sendable {
    public static let codexHomeOutputPrefix = "SUB2API_STATUSBAR_CODEX_HOME="
    public static let homeDirectoryOutputPrefix = "SUB2API_STATUSBAR_HOME="

    public let codexHome: String?
    public let homeDirectory: String?

    public init(commandOutput: String) {
        let lines = commandOutput
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        let values = Self.markerValues(in: lines)
        codexHome = Self.normalized(values[Self.codexHomeOutputPrefix])
        homeDirectory = Self.normalized(values[Self.homeDirectoryOutputPrefix])
    }

    private static func markerValues(in lines: [String]) -> [String: String] {
        var values: [String: String] = [:]
        for line in lines {
            if line.hasPrefix(codexHomeOutputPrefix) {
                values[codexHomeOutputPrefix] = String(line.dropFirst(codexHomeOutputPrefix.count))
            } else if line.hasPrefix(homeDirectoryOutputPrefix) {
                values[homeDirectoryOutputPrefix] = String(line.dropFirst(homeDirectoryOutputPrefix.count))
            }
        }
        return values
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

public enum CodexHomeResolver {
    public static func resolve(environmentValue: String?, homeDirectory: String) -> CodexHomeResolution {
        let trimmedEnvironment = environmentValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedHome = normalizedOptionalPath(homeDirectory)
        let home = normalizedPath(
            trimmedEnvironment.isEmpty
                ? joinPath(normalizedHome ?? homeDirectory.trimmingCharacters(in: .whitespacesAndNewlines), ".codex")
                : trimmedEnvironment
        )
        return CodexHomeResolution(codexHomePath: home, configPath: joinPath(home, "config.toml"), userHomePath: normalizedHome)
    }

    public static func resolve(remoteEnvironment: CodexRemoteEnvironment) throws -> CodexHomeResolution {
        if let codexHome = remoteEnvironment.codexHome {
            return resolve(environmentValue: codexHome, homeDirectory: remoteEnvironment.homeDirectory ?? "")
        }
        guard let homeDirectory = remoteEnvironment.homeDirectory else {
            throw CodexHomeResolutionError.missingRemoteHomeDirectory
        }
        return resolve(environmentValue: nil, homeDirectory: homeDirectory)
    }

    public static func resolve(remoteEnvironment: CodexRemoteEnvironment, override: String?) throws -> CodexHomeResolution {
        let normalizedOverride = normalizedOptionalPath(override ?? "")
        guard let normalizedOverride else {
            return try resolve(remoteEnvironment: remoteEnvironment)
        }
        guard let homeDirectory = remoteEnvironment.homeDirectory else {
            throw CodexHomeResolutionError.missingRemoteHomeDirectory
        }
        return resolve(environmentValue: normalizedOverride, homeDirectory: homeDirectory)
    }

    private static func joinPath(_ base: String, _ component: String) -> String {
        let normalizedBase = normalizedPath(base)
        return normalizedBase + "/" + component
    }

    private static func normalizedPath(_ path: String) -> String {
        var normalizedBase = path
        while normalizedBase.hasSuffix("/") && normalizedBase.count > 1 {
            normalizedBase.removeLast()
        }
        return normalizedBase
    }

    private static func normalizedOptionalPath(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        return normalizedPath(trimmed)
    }
}

public enum CodexHookSupportPathBuilder {
    public static func nodeConfigFileName(nodeID: String) throws -> String {
        let normalizedID = nodeID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CodexNode.isValidID(normalizedID) else {
            throw CodexNodeValidationError.invalidID
        }
        return "codex-hook-node-\(normalizedID).json"
    }

    public static func remoteNodeConfigPath(codexHome: CodexHomeResolution, nodeID: String) throws -> String {
        try remoteSupportPath(codexHome: codexHome, component: nodeConfigFileName(nodeID: nodeID))
    }

    public static func remoteSupportPath(codexHome: CodexHomeResolution, component: String) throws -> String {
        guard let basePath = codexHome.userHomePath else {
            throw CodexHomeResolutionError.missingRemoteHomeDirectory
        }
        return URL(fileURLWithPath: basePath)
            .appendingPathComponent(".sub2api-statusbar", isDirectory: true)
            .appendingPathComponent(component)
            .path
    }
}

public enum CodexHookConfigWriter {
    public static let managedMarker = "Sub2APIStatusBar task monitor"
    static let managedHookEvents: [(name: String, matcher: String?)] = [
        ("UserPromptSubmit", nil),
        ("PreToolUse", ".*"),
        ("PostToolUse", ".*"),
        ("PermissionRequest", ".*"),
        ("Stop", nil),
        ("PreCompact", nil),
        ("PostCompact", nil),
        ("SubagentStart", ".*"),
        ("SubagentStop", ".*"),
    ]
    private static let managedByFlag = "--managed-by"
    private static let managedByValue = "Sub2APIStatusBar"

    public static func renderConfig(
        existingConfig: String,
        senderCommand: String,
        nodeConfigPath: String,
        timeoutSeconds: Int
    ) throws -> String {
        var lines = existingConfig.normalizedLineArray()
        lines = removeManagedHookEntries(from: lines)
        lines = upsertHooksFeature(in: lines)
        let insertionIndex = trustStateHeaderIndex(in: lines) ?? lines.endIndex
        lines.insert(contentsOf: managedHookLines(
            senderCommand: senderCommand,
            nodeConfigPath: nodeConfigPath,
            timeoutSeconds: timeoutSeconds
        ), at: insertionIndex)
        return lines.joined(separator: "\n").trimmedTrailingBlankLines() + "\n"
    }

    private static func upsertHooksFeature(in lines: [String]) -> [String] {
        var result = lines
        guard let featureHeaderIndex = result.firstIndex(where: { tableHeaderToken($0) == "[features]" }) else {
            return featureLines() + result.withLeadingBlankLineIfNeeded()
        }

        let sectionEnd = firstSectionHeaderIndex(in: result, after: featureHeaderIndex + 1) ?? result.endIndex
        if let hooksIndex = result[featureHeaderIndex + 1..<sectionEnd].firstIndex(where: { isHooksFeatureLine($0) }) {
            result[hooksIndex] = "hooks = true"
        } else {
            result.insert("hooks = true", at: featureHeaderIndex + 1)
        }
        return result
    }

    private static func removeManagedHookEntries(from lines: [String]) -> [String] {
        var result: [String] = []
        var index = 0
        while index < lines.count {
            if isHookGroupHeader(lines[index]),
               let groupEnd = hookGroupEndIndex(in: lines, startingAt: index),
               containsManagedMarker(lines[index..<groupEnd]) {
                let cleanedGroup = removeManagedHandlers(from: Array(lines[index..<groupEnd]))
                if !cleanedGroup.isEmpty {
                    result.append(contentsOf: cleanedGroup)
                }
                index = groupEnd
                while cleanedGroup.isEmpty,
                      index < lines.count,
                      lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    index += 1
                }
                continue
            }

            result.append(lines[index])
            index += 1
        }
        return result.trimmedTrailingBlankLines()
    }

    private static func removeManagedHandlers(from groupLines: [String]) -> [String] {
        guard let firstLine = groupLines.first else {
            return []
        }

        var result: [String] = [firstLine]
        var index = 1
        var removedManagedHandler = false

        while index < groupLines.count {
            if isHookHandlerHeader(groupLines[index]) {
                let handlerEnd = hookHandlerEndIndex(in: groupLines, startingAt: index)
                let handlerLines = groupLines[index..<handlerEnd]
                if containsManagedMarker(handlerLines) {
                    removedManagedHandler = true
                    index = handlerEnd
                    continue
                }
                result.append(contentsOf: handlerLines)
                index = handlerEnd
                continue
            }

            result.append(groupLines[index])
            index += 1
        }

        let cleaned = result.trimmedTrailingBlankLines()
        guard removedManagedHandler else {
            return cleaned
        }
        if cleaned.dropFirst().contains(where: isHookHandlerHeader) {
            return cleaned
        }
        return []
    }

    private static func managedHookLines(
        senderCommand: String,
        nodeConfigPath: String,
        timeoutSeconds: Int
    ) -> [String] {
        var lines: [String] = [""]
        for event in managedHookEvents {
            lines.append("[[hooks.\(event.name)]]")
            if let matcher = event.matcher {
                lines.append("matcher = \(tomlString(matcher))")
            }
            lines.append("")
            lines.append("[[hooks.\(event.name).hooks]]")
            lines.append("type = \"command\"")
            let hookCommand = command(
                senderCommand: senderCommand,
                eventName: event.name,
                nodeConfigPath: nodeConfigPath
            )
            lines.append("command = \(tomlString(hookCommand))")
            lines.append("timeout = \(max(timeoutSeconds, 1))")
            lines.append("statusMessage = \(tomlString(managedMarker))")
            lines.append("")
        }
        return lines.trimmedTrailingBlankLines()
    }

    private static func command(senderCommand: String, eventName: String, nodeConfigPath: String) -> String {
        [
            senderCommand,
            managedByFlag,
            managedByValue,
            "--event",
            eventName,
            "--config",
            nodeConfigPath,
        ].map(shellQuote).joined(separator: " ")
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func featureLines() -> [String] {
        [
            "[features]",
            "hooks = true",
        ]
    }

    private static func isHooksFeatureLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let equalsIndex = trimmed.firstIndex(of: "=") else {
            return false
        }
        let key = trimmed[..<equalsIndex].trimmingCharacters(in: .whitespaces)
        return key == "hooks"
    }

    private static func isHookGroupHeader(_ line: String) -> Bool {
        guard let token = tableHeaderToken(line) else {
            return false
        }
        return token.hasPrefix("[[hooks.") && token.hasSuffix("]]") && !token.contains(".hooks]]")
    }

    private static func isHookHandlerHeader(_ line: String) -> Bool {
        guard let token = tableHeaderToken(line) else {
            return false
        }
        return token.hasPrefix("[[hooks.") && token.hasSuffix(".hooks]]")
    }

    private static func trustStateHeaderIndex(in lines: [String]) -> Int? {
        lines.firstIndex { line in
            guard let token = tableHeaderToken(line) else {
                return false
            }
            return token == "[hooks.state]" || token.hasPrefix("[hooks.state.")
        }
    }

    private static func hookGroupEndIndex(in lines: [String], startingAt start: Int) -> Int? {
        var index = start + 1
        while index < lines.count {
            if isHookGroupHeader(lines[index]) || isNonHookSectionHeader(lines[index]) {
                return index
            }
            index += 1
        }
        return lines.count
    }

    private static func hookHandlerEndIndex(in lines: [String], startingAt start: Int) -> Int {
        var index = start + 1
        while index < lines.count {
            if isHookHandlerHeader(lines[index]) || isHookGroupHeader(lines[index]) || isNonHookSectionHeader(lines[index]) {
                return index
            }
            index += 1
        }
        return lines.count
    }

    private static func isNonHookSectionHeader(_ line: String) -> Bool {
        guard let token = tableHeaderToken(line) else {
            return false
        }
        return !token.hasPrefix("[[hooks.")
    }

    private static func firstSectionHeaderIndex(in lines: [String], after start: Int) -> Int? {
        var index = start
        while index < lines.count {
            if tableHeaderToken(lines[index]) != nil {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func tableHeaderToken(_ line: String) -> String? {
        CodexHookTomlScanner.tableHeaderToken(line)
    }

    private static func containsManagedMarker(_ lines: ArraySlice<String>) -> Bool {
        lines.contains {
            $0.contains(managedMarker)
                || ($0.contains(managedByFlag) && $0.contains(managedByValue))
        }
    }

    private static func tomlString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

public enum CodexHookConfigValidationError: LocalizedError, Equatable, Sendable {
    case missingHooksFeature
    case missingHookGroup(String)
    case unexpectedMatcher(event: String, expected: String?)
    case missingManagedHandler(String)
    case invalidHandlerField(event: String, field: String)

    public var errorDescription: String? {
        switch self {
        case .missingHooksFeature:
            return "Codex hooks feature flag is missing or not enabled."
        case let .missingHookGroup(event):
            return "Codex hook group is missing for \(event)."
        case let .unexpectedMatcher(event, expected):
            return "Codex hook matcher for \(event) does not match \(expected ?? "no matcher")."
        case let .missingManagedHandler(event):
            return "Managed Codex hook handler is missing for \(event)."
        case let .invalidHandlerField(event, field):
            return "Managed Codex hook handler field \(field) is invalid for \(event)."
        }
    }
}

public enum CodexHookConfigValidator {
    public static func validateManagedHooks(_ config: String, expectedNodeConfigPath: String? = nil) throws {
        let lines = config.normalizedLineArray()
        guard hasEnabledHooksFeature(in: lines) else {
            throw CodexHookConfigValidationError.missingHooksFeature
        }

        let groups = hookGroups(in: lines)
        for event in CodexHookConfigWriter.managedHookEvents {
            guard let group = groups[event.name] else {
                throw CodexHookConfigValidationError.missingHookGroup(event.name)
            }
            guard group.matcher == event.matcher else {
                throw CodexHookConfigValidationError.unexpectedMatcher(
                    event: event.name,
                    expected: event.matcher
                )
            }
            guard let handler = group.handlers.first(where: isManagedHandler) else {
                throw CodexHookConfigValidationError.missingManagedHandler(event.name)
            }
            try validate(handler: handler, eventName: event.name, expectedNodeConfigPath: expectedNodeConfigPath)
        }
    }

    private static func hasEnabledHooksFeature(in lines: [String]) -> Bool {
        guard let featureHeaderIndex = lines.firstIndex(where: { CodexHookTomlScanner.tableHeaderToken($0) == "[features]" }) else {
            return false
        }
        let sectionEnd = firstSectionHeaderIndex(in: lines, after: featureHeaderIndex + 1) ?? lines.endIndex
        return lines[featureHeaderIndex + 1..<sectionEnd].contains { line in
            keyValue(line).map { key, value in
                key == "hooks" && value == "true"
            } ?? false
        }
    }

    private static func hookGroups(in lines: [String]) -> [String: HookGroup] {
        var groups: [String: HookGroup] = [:]
        var currentEvent: String?
        var currentHandlerFields: [String: String]?

        func finishHandler() {
            guard let event = currentEvent,
                  let handlerFields = currentHandlerFields else {
                currentHandlerFields = nil
                return
            }
            var group = groups[event] ?? HookGroup(matcher: nil, handlers: [])
            group.handlers.append(handlerFields)
            groups[event] = group
            currentHandlerFields = nil
        }

        for line in lines {
            if let token = CodexHookTomlScanner.tableHeaderToken(line) {
                finishHandler()
                if let event = hookEventName(fromGroupHeader: token) {
                    currentEvent = event
                    if groups[event] == nil {
                        groups[event] = HookGroup(matcher: nil, handlers: [])
                    }
                    continue
                }
                if let event = hookEventName(fromHandlerHeader: token) {
                    currentEvent = event
                    if groups[event] == nil {
                        groups[event] = HookGroup(matcher: nil, handlers: [])
                    }
                    currentHandlerFields = [:]
                    continue
                }
                currentEvent = nil
                continue
            }

            guard let event = currentEvent,
                  let (key, value) = keyValue(line) else {
                continue
            }
            if currentHandlerFields != nil {
                currentHandlerFields?[key] = value
            } else {
                var group = groups[event] ?? HookGroup(matcher: nil, handlers: [])
                if key == "matcher" {
                    group.matcher = unquoted(value)
                    groups[event] = group
                }
            }
        }
        finishHandler()
        return groups
    }

    private static func validate(
        handler: [String: String],
        eventName: String,
        expectedNodeConfigPath: String?
    ) throws {
        guard handler["type"].map(unquoted) == "command" else {
            throw CodexHookConfigValidationError.invalidHandlerField(event: eventName, field: "type")
        }
        guard let command = handler["command"].map(unquoted),
              command.contains("'--managed-by' 'Sub2APIStatusBar'"),
              command.contains("'--event' '\(eventName)'"),
              command.contains("'--config' ") else {
            throw CodexHookConfigValidationError.invalidHandlerField(event: eventName, field: "command")
        }
        if let expectedNodeConfigPath {
            guard command.contains("'--config' \(shellQuote(expectedNodeConfigPath))") else {
                throw CodexHookConfigValidationError.invalidHandlerField(event: eventName, field: "command")
            }
        }
        guard let timeout = handler["timeout"].flatMap(Int.init),
              timeout > 0 else {
            throw CodexHookConfigValidationError.invalidHandlerField(event: eventName, field: "timeout")
        }
        guard handler["statusMessage"].map(unquoted) == CodexHookConfigWriter.managedMarker else {
            throw CodexHookConfigValidationError.invalidHandlerField(event: eventName, field: "statusMessage")
        }
    }

    private static func firstSectionHeaderIndex(in lines: [String], after start: Int) -> Int? {
        var index = start
        while index < lines.count {
            if CodexHookTomlScanner.tableHeaderToken(lines[index]) != nil {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func hookEventName(fromGroupHeader token: String) -> String? {
        guard token.hasPrefix("[[hooks."),
              token.hasSuffix("]]"),
              !token.hasSuffix(".hooks]]") else {
            return nil
        }
        let start = token.index(token.startIndex, offsetBy: "[[hooks.".count)
        let end = token.index(token.endIndex, offsetBy: -"]]".count)
        return String(token[start..<end])
    }

    private static func hookEventName(fromHandlerHeader token: String) -> String? {
        guard token.hasPrefix("[[hooks."),
              token.hasSuffix(".hooks]]") else {
            return nil
        }
        let start = token.index(token.startIndex, offsetBy: "[[hooks.".count)
        let end = token.index(token.endIndex, offsetBy: -".hooks]]".count)
        return String(token[start..<end])
    }

    private static func isManagedHandler(_ fields: [String: String]) -> Bool {
        fields["statusMessage"].map(unquoted) == CodexHookConfigWriter.managedMarker
            || fields["command"].map(unquoted)?.contains("'--managed-by' 'Sub2APIStatusBar'") == true
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func keyValue(_ line: String) -> (String, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("#"),
              let equalsIndex = trimmed.firstIndex(of: "=") else {
            return nil
        }
        let key = trimmed[..<equalsIndex].trimmingCharacters(in: .whitespaces)
        let value = trimmed[trimmed.index(after: equalsIndex)...].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !value.isEmpty else {
            return nil
        }
        return (key, value)
    }

    private static func unquoted(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2 else {
            return trimmed
        }
        let start = trimmed.index(after: trimmed.startIndex)
        let end = trimmed.index(before: trimmed.endIndex)
        var result = ""
        var escaping = false
        for character in trimmed[start..<end] {
            if escaping {
                result.append(character)
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                result.append(character)
            }
        }
        if escaping {
            result.append("\\")
        }
        return result
    }

    private struct HookGroup: Equatable {
        var matcher: String?
        var handlers: [[String: String]]
    }
}

private enum CodexHookTomlScanner {
    static func tableHeaderToken(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[") else {
            return nil
        }

        let closingDelimiter = trimmed.hasPrefix("[[") ? "]]" : "]"
        guard let closingRange = trimmed.range(of: closingDelimiter) else {
            return nil
        }

        let token = String(trimmed[..<closingRange.upperBound])
        let trailing = trimmed[closingRange.upperBound...].trimmingCharacters(in: .whitespaces)
        guard trailing.isEmpty || trailing.hasPrefix("#") else {
            return nil
        }
        return token
    }
}

private extension String {
    func normalizedLineArray() -> [String] {
        replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }

    func trimmedTrailingBlankLines() -> String {
        var lines = normalizedLineArray()
        lines = lines.trimmedTrailingBlankLines()
        return lines.joined(separator: "\n")
    }
}

private extension Array where Element == String {
    func trimmedTrailingBlankLines() -> [String] {
        var copy = self
        while let last = copy.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            copy.removeLast()
        }
        return copy
    }

    func withLeadingBlankLineIfNeeded() -> [String] {
        guard let first, !first.trimmingCharacters(in: .whitespaces).isEmpty else {
            return self
        }
        return [""] + self
    }
}
