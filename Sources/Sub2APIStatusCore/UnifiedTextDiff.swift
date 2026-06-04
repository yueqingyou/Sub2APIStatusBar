import Foundation

public enum UnifiedTextDiff {
    public static func render(old: String, new: String, fromPath: String, toPath: String) -> String {
        if old == new {
            return """
            --- \(fromPath)
            +++ \(toPath)
            @@
            """
        }

        let oldLines = old.diffLines()
        let newLines = new.diffLines()
        let matrix = lcsMatrix(oldLines: oldLines, newLines: newLines)
        let body = backtrackDiff(oldLines: oldLines, newLines: newLines, matrix: matrix)
        return ([
            "--- \(fromPath)",
            "+++ \(toPath)",
            "@@",
        ] + body).joined(separator: "\n")
    }

    public static func renderRedactedConfigPreview(old: String, new: String, fromPath: String, toPath: String) -> String {
        render(
            old: ConfigPreviewRedactor.redact(old),
            new: ConfigPreviewRedactor.redact(new),
            fromPath: fromPath,
            toPath: toPath
        )
    }

    private static func lcsMatrix(oldLines: [String], newLines: [String]) -> [[Int]] {
        var matrix = Array(
            repeating: Array(repeating: 0, count: newLines.count + 1),
            count: oldLines.count + 1
        )
        guard !oldLines.isEmpty, !newLines.isEmpty else {
            return matrix
        }
        for oldIndex in stride(from: oldLines.count - 1, through: 0, by: -1) {
            for newIndex in stride(from: newLines.count - 1, through: 0, by: -1) {
                if oldLines[oldIndex] == newLines[newIndex] {
                    matrix[oldIndex][newIndex] = matrix[oldIndex + 1][newIndex + 1] + 1
                } else {
                    matrix[oldIndex][newIndex] = max(matrix[oldIndex + 1][newIndex], matrix[oldIndex][newIndex + 1])
                }
            }
        }
        return matrix
    }

    private static func backtrackDiff(oldLines: [String], newLines: [String], matrix: [[Int]]) -> [String] {
        var oldIndex = 0
        var newIndex = 0
        var result: [String] = []
        while oldIndex < oldLines.count || newIndex < newLines.count {
            if oldIndex < oldLines.count,
               newIndex < newLines.count,
               oldLines[oldIndex] == newLines[newIndex] {
                result.append(" " + oldLines[oldIndex])
                oldIndex += 1
                newIndex += 1
            } else if newIndex < newLines.count,
                      (oldIndex == oldLines.count || matrix[oldIndex][newIndex + 1] >= matrix[oldIndex + 1][newIndex]) {
                result.append("+" + newLines[newIndex])
                newIndex += 1
            } else if oldIndex < oldLines.count {
                result.append("-" + oldLines[oldIndex])
                oldIndex += 1
            }
        }
        return result
    }
}

public enum ConfigPreviewRedactor {
    public static let redactedValue = "<redacted>"

    private static let sensitiveKeyFragments = [
        "api_key",
        "apikey",
        "auth",
        "bearer",
        "credential",
        "key",
        "password",
        "secret",
        "token",
    ]

    public static func redact(_ text: String) -> String {
        text
            .splitKeepingLineEndings()
            .map(redactLine)
            .joined()
    }

    private static func redactLine(_ line: String) -> String {
        let lineEnding: String
        let content: String
        if line.hasSuffix("\r\n") {
            lineEnding = "\r\n"
            content = String(line.dropLast(2))
        } else if line.hasSuffix("\n") {
            lineEnding = "\n"
            content = String(line.dropLast())
        } else if line.hasSuffix("\r") {
            lineEnding = "\r"
            content = String(line.dropLast())
        } else {
            lineEnding = ""
            content = line
        }

        guard let equalsIndex = content.firstIndex(of: "=") else {
            return line
        }

        let key = content[..<equalsIndex]
        guard isSensitiveKey(String(key)) else {
            return line
        }

        let indentation = key.prefix { $0 == " " || $0 == "\t" }
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(indentation)\(normalizedKey) = \"\(redactedValue)\"\(lineEnding)"
    }

    private static func isSensitiveKey(_ rawKey: String) -> Bool {
        let key = rawKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .lowercased()
        guard !key.isEmpty else {
            return false
        }
        return sensitiveKeyFragments.contains { key.contains($0) }
    }
}

private extension String {
    func diffLines() -> [String] {
        replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }

    func splitKeepingLineEndings() -> [String] {
        var lines: [String] = []
        var current = ""
        var index = startIndex
        while index < endIndex {
            let character = self[index]
            current.append(character)
            if character == "\n" {
                lines.append(current)
                current = ""
            } else if character == "\r" {
                let nextIndex = self.index(after: index)
                if nextIndex < endIndex, self[nextIndex] == "\n" {
                    index = nextIndex
                    current.append("\n")
                }
                lines.append(current)
                current = ""
            }
            index = self.index(after: index)
        }
        if !current.isEmpty {
            lines.append(current)
        }
        return lines
    }
}
