import Foundation

public struct CodexHookNodeConfig: Codable, Sendable, Equatable {
    public let nodeID: String
    public let receiverURL: URL
    public let secret: String

    private enum CodingKeys: String, CodingKey {
        case nodeID = "nodeId"
        case receiverURL = "receiverUrl"
        case secret
    }
}

public struct CodexHookInstallerPlan: Sendable, Equatable {
    public let kind: CodexNodeKind
    public let codexConfigPath: String
    public let codexConfigBackupPath: String
    public let nodeConfigPath: String
    public let nodeConfigJSON: String
    public let senderExecutablePayload: Data
    public let senderExecutableInstallPath: String
    public let updatedCodexConfig: String
    public let sshTunnelCommand: ProcessCommand?
}

public enum CodexHookInstallerPlanBuilder {
    public static func buildDryRun(
        node: CodexNode,
        codexHome: CodexHomeResolution,
        existingConfig: String,
        senderExecutablePayload: Data,
        senderExecutableInstallPath: String,
        nodeConfigPath: String,
        nodeSecret: String,
        timestamp: Date
    ) throws -> CodexHookInstallerPlan {
        let nodeConfig = CodexHookNodeConfig(
            nodeID: node.id,
            receiverURL: node.hookReceiverURL,
            secret: nodeSecret
        )
        let nodeConfigJSON = try renderNodeConfigJSON(nodeConfig)
        let updatedConfig = try CodexHookConfigWriter.renderConfig(
            existingConfig: existingConfig,
            senderCommand: senderExecutableInstallPath,
            nodeConfigPath: nodeConfigPath,
            timeoutSeconds: 5
        )
        try CodexHookConfigValidator.validateManagedHooks(updatedConfig)
        let tunnelCommand = node.kind == .remote ? try SSHTunnelCommandBuilder.buildCommand(for: node) : nil

        return CodexHookInstallerPlan(
            kind: node.kind,
            codexConfigPath: codexHome.configPath,
            codexConfigBackupPath: backupPath(for: codexHome.configPath, timestamp: timestamp),
            nodeConfigPath: nodeConfigPath,
            nodeConfigJSON: nodeConfigJSON,
            senderExecutablePayload: senderExecutablePayload,
            senderExecutableInstallPath: senderExecutableInstallPath,
            updatedCodexConfig: updatedConfig,
            sshTunnelCommand: tunnelCommand
        )
    }

    private static func renderNodeConfigJSON(_ config: CodexHookNodeConfig) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(data: try encoder.encode(config), encoding: .utf8) ?? ""
    }

    private static func backupPath(for configPath: String, timestamp: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return "\(configPath).sub2api-statusbar.\(formatter.string(from: timestamp)).bak"
    }
}

public struct CodexHookLocalInstaller {
    private let fileManager: FileManager
    private let beforeWriteCodexConfig: (() throws -> Void)?

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        beforeWriteCodexConfig = nil
    }

    init(
        fileManager: FileManager = .default,
        beforeWriteCodexConfig: @escaping () throws -> Void
    ) {
        self.fileManager = fileManager
        self.beforeWriteCodexConfig = beforeWriteCodexConfig
    }

    public func apply(_ plan: CodexHookInstallerPlan) throws {
        let codexConfigSnapshot = try snapshotFile(at: plan.codexConfigPath)
        let senderSnapshot = try snapshotFile(at: plan.senderExecutableInstallPath)
        let nodeConfigSnapshot = try snapshotFile(at: plan.nodeConfigPath)
        try backupCodexConfig(plan)
        do {
            try installSenderExecutable(plan)
            try writeNodeConfig(plan)
            try writeCodexConfig(plan)
        } catch {
            restoreFile(at: plan.codexConfigPath, snapshot: codexConfigSnapshot)
            restoreFile(at: plan.senderExecutableInstallPath, snapshot: senderSnapshot)
            restoreFile(at: plan.nodeConfigPath, snapshot: nodeConfigSnapshot)
            throw error
        }
    }

    private func backupCodexConfig(_ plan: CodexHookInstallerPlan) throws {
        let configURL = URL(fileURLWithPath: plan.codexConfigPath)
        let backupURL = URL(fileURLWithPath: plan.codexConfigBackupPath)
        try fileManager.createDirectory(at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: configURL.path) {
            if fileManager.fileExists(atPath: backupURL.path) {
                try fileManager.removeItem(at: backupURL)
            }
            try fileManager.copyItem(at: configURL, to: backupURL)
        } else {
            try Data().write(to: backupURL, options: .atomic)
        }
    }

    private func writeNodeConfig(_ plan: CodexHookInstallerPlan) throws {
        let nodeConfigURL = URL(fileURLWithPath: plan.nodeConfigPath)
        try fileManager.createDirectory(at: nodeConfigURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(plan.nodeConfigJSON.utf8).write(to: nodeConfigURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: nodeConfigURL.path
        )
    }

    private func installSenderExecutable(_ plan: CodexHookInstallerPlan) throws {
        let installURL = URL(fileURLWithPath: plan.senderExecutableInstallPath)
        try fileManager.createDirectory(at: installURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try plan.senderExecutablePayload.write(to: installURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: installURL.path
        )
    }

    private func writeCodexConfig(_ plan: CodexHookInstallerPlan) throws {
        try beforeWriteCodexConfig?()
        let configURL = URL(fileURLWithPath: plan.codexConfigPath)
        try fileManager.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(plan.updatedCodexConfig.utf8).write(to: configURL, options: .atomic)
    }

    private func snapshotFile(at path: String) throws -> LocalInstallFileSnapshot {
        guard fileManager.fileExists(atPath: path) else {
            return LocalInstallFileSnapshot(existed: false, data: nil, posixPermissions: nil)
        }
        let attributes = try fileManager.attributesOfItem(atPath: path)
        return LocalInstallFileSnapshot(
            existed: true,
            data: try Data(contentsOf: URL(fileURLWithPath: path)),
            posixPermissions: attributes[.posixPermissions] as? NSNumber
        )
    }

    private func restoreFile(at path: String, snapshot: LocalInstallFileSnapshot) {
        let url = URL(fileURLWithPath: path)
        if snapshot.existed {
            do {
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try snapshot.data?.write(to: url, options: .atomic)
                if let posixPermissions = snapshot.posixPermissions {
                    try fileManager.setAttributes([.posixPermissions: posixPermissions], ofItemAtPath: path)
                }
            } catch {
                return
            }
        } else if fileManager.fileExists(atPath: path) {
            try? fileManager.removeItem(at: url)
        }
    }
}

private struct LocalInstallFileSnapshot {
    let existed: Bool
    let data: Data?
    let posixPermissions: NSNumber?
}

public struct CodexHookRemoteInstallerCommandPlan: Sendable, Equatable {
    public let sshExecutable: String
    public let sshArguments: [String]
    public let stdinScript: String
}

public struct CodexHookRemoteInstallResult: Sendable, Equatable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String

    public init(exitCode: Int32, standardOutput: String, standardError: String) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public protocol CodexHookRemoteInstallRunning: Sendable {
    func run(_ commandPlan: CodexHookRemoteInstallerCommandPlan) async throws -> CodexHookRemoteInstallResult
}

public struct CodexHookRemoteReadCommandPlan: Sendable, Equatable {
    public let sshExecutable: String
    public let sshArguments: [String]

    public init(sshExecutable: String, sshArguments: [String]) {
        self.sshExecutable = sshExecutable
        self.sshArguments = sshArguments
    }
}

public protocol CodexHookRemoteConfigReading: Sendable {
    func read(_ commandPlan: CodexHookRemoteReadCommandPlan) async throws -> CodexHookRemoteInstallResult
}

public struct FoundationCodexHookRemoteInstallRunner: CodexHookRemoteInstallRunning {
    public init() {}

    public func run(_ commandPlan: CodexHookRemoteInstallerCommandPlan) async throws -> CodexHookRemoteInstallResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: commandPlan.sshExecutable)
                    process.arguments = commandPlan.sshArguments

                    let inputPipe = Pipe()
                    let outputPipe = Pipe()
                    let errorPipe = Pipe()
                    process.standardInput = inputPipe
                    process.standardOutput = outputPipe
                    process.standardError = errorPipe

                    try process.run()
                    inputPipe.fileHandleForWriting.write(Data(commandPlan.stdinScript.utf8))
                    inputPipe.fileHandleForWriting.closeFile()
                    process.waitUntilExit()

                    let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    continuation.resume(returning: CodexHookRemoteInstallResult(
                        exitCode: process.terminationStatus,
                        standardOutput: output,
                        standardError: error
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

public struct FoundationCodexHookRemoteConfigReader: CodexHookRemoteConfigReading {
    public init() {}

    public func read(_ commandPlan: CodexHookRemoteReadCommandPlan) async throws -> CodexHookRemoteInstallResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: commandPlan.sshExecutable)
                    process.arguments = commandPlan.sshArguments

                    let outputPipe = Pipe()
                    let errorPipe = Pipe()
                    process.standardOutput = outputPipe
                    process.standardError = errorPipe

                    try process.run()
                    process.waitUntilExit()

                    let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    continuation.resume(returning: CodexHookRemoteInstallResult(
                        exitCode: process.terminationStatus,
                        standardOutput: output,
                        standardError: error
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

public struct CodexHookRemoteInstaller: Sendable {
    private let runner: any CodexHookRemoteInstallRunning
    private let configReader: any CodexHookRemoteConfigReading

    public init(
        runner: any CodexHookRemoteInstallRunning = FoundationCodexHookRemoteInstallRunner(),
        configReader: any CodexHookRemoteConfigReading = FoundationCodexHookRemoteConfigReader()
    ) {
        self.runner = runner
        self.configReader = configReader
    }

    public func readExistingConfig(node: CodexNode, codexConfigPath: String) async throws -> CodexHookRemoteInstallResult {
        let commandPlan = try CodexHookRemoteInstallerCommandBuilder.buildReadConfigCommandPlan(
            for: node,
            codexConfigPath: codexConfigPath
        )
        return try await configReader.read(commandPlan)
    }

    public func readRemoteCodexHomeEnvironment(node: CodexNode) async throws -> CodexHookRemoteInstallResult {
        let commandPlan = try CodexHookRemoteInstallerCommandBuilder.buildReadCodexHomeCommandPlan(for: node)
        return try await configReader.read(commandPlan)
    }

    @discardableResult
    public func apply(node: CodexNode, plan: CodexHookInstallerPlan) async throws -> CodexHookRemoteInstallResult {
        let commandPlan = try CodexHookRemoteInstallerCommandBuilder.buildCommandPlan(for: node, installPlan: plan)
        return try await runner.run(commandPlan)
    }
}

public enum CodexHookRemoteInstallerCommandError: Error, Sendable, Equatable {
    case nodeIsNotRemote
    case missingSSHConnection
}

public enum CodexHookRemoteInstallerCommandBuilder {
    public static func buildCommandPlan(
        for node: CodexNode,
        installPlan: CodexHookInstallerPlan,
        sshExecutable: String = "/usr/bin/ssh"
    ) throws -> CodexHookRemoteInstallerCommandPlan {
        guard node.kind == .remote else {
            throw CodexHookRemoteInstallerCommandError.nodeIsNotRemote
        }
        guard let ssh = node.ssh else {
            throw CodexHookRemoteInstallerCommandError.missingSSHConnection
        }

        var arguments: [String] = []
        if let port = ssh.port {
            arguments.append(contentsOf: ["-p", String(port)])
        }
        if let identityFile = ssh.identityFile {
            arguments.append(contentsOf: ["-i", identityFile])
        }
        arguments.append(contentsOf: [ssh.destination, "sh", "-s"])

        return CodexHookRemoteInstallerCommandPlan(
            sshExecutable: sshExecutable,
            sshArguments: arguments,
            stdinScript: shellScript(for: installPlan)
        )
    }

    public static func buildReadConfigCommandPlan(
        for node: CodexNode,
        codexConfigPath: String,
        sshExecutable: String = "/usr/bin/ssh"
    ) throws -> CodexHookRemoteReadCommandPlan {
        guard node.kind == .remote else {
            throw CodexHookRemoteInstallerCommandError.nodeIsNotRemote
        }
        guard let ssh = node.ssh else {
            throw CodexHookRemoteInstallerCommandError.missingSSHConnection
        }

        var arguments: [String] = []
        if let port = ssh.port {
            arguments.append(contentsOf: ["-p", String(port)])
        }
        if let identityFile = ssh.identityFile {
            arguments.append(contentsOf: ["-i", identityFile])
        }
        let readConfigCommand = "if [ -f \(shellQuote(codexConfigPath)) ]; then cat \(shellQuote(codexConfigPath)); elif [ -e \(shellQuote(codexConfigPath)) ]; then echo 'Codex config path exists but is not a regular file' >&2; exit 66; fi"
        arguments.append(contentsOf: [
            ssh.destination,
            remoteLoginShellCommand(readConfigCommand),
        ])
        return CodexHookRemoteReadCommandPlan(sshExecutable: sshExecutable, sshArguments: arguments)
    }

    public static func buildReadCodexHomeCommandPlan(
        for node: CodexNode,
        sshExecutable: String = "/usr/bin/ssh"
    ) throws -> CodexHookRemoteReadCommandPlan {
        guard node.kind == .remote else {
            throw CodexHookRemoteInstallerCommandError.nodeIsNotRemote
        }
        guard let ssh = node.ssh else {
            throw CodexHookRemoteInstallerCommandError.missingSSHConnection
        }

        var arguments: [String] = []
        if let port = ssh.port {
            arguments.append(contentsOf: ["-p", String(port)])
        }
        if let identityFile = ssh.identityFile {
            arguments.append(contentsOf: ["-i", identityFile])
        }
        arguments.append(contentsOf: [
            ssh.destination,
            remoteInteractiveShellCommand(
                "printf -- '%s%s\\n%s%s\\n' \(shellQuote(CodexRemoteEnvironment.codexHomeOutputPrefix)) \"${CODEX_HOME:-}\" \(shellQuote(CodexRemoteEnvironment.homeDirectoryOutputPrefix)) \"${HOME:-}\""
            ),
        ])
        return CodexHookRemoteReadCommandPlan(sshExecutable: sshExecutable, sshArguments: arguments)
    }

    private static func remoteLoginShellCommand(_ command: String) -> String {
        "sh -lc \(shellQuote(command))"
    }

    private static func remoteInteractiveShellCommand(_ command: String) -> String {
        "shell_path=${SHELL:-/bin/sh}; exec \"$shell_path\" -ic \(shellQuote(command))"
    }

    private static func shellScript(for plan: CodexHookInstallerPlan) -> String {
        let codexConfigDirectory = deletingLastPathComponent(plan.codexConfigPath)
        let nodeConfigDirectory = deletingLastPathComponent(plan.nodeConfigPath)
        let senderDirectory = deletingLastPathComponent(plan.senderExecutableInstallPath)
        let senderTempPath = plan.senderExecutableInstallPath + ".sub2api-statusbar.tmp"
        let nodeConfigTempPath = plan.nodeConfigPath + ".sub2api-statusbar.tmp"
        let codexConfigTempPath = plan.codexConfigPath + ".sub2api-statusbar.tmp"
        let senderRestorePath = plan.senderExecutableInstallPath + ".sub2api-statusbar.restore"
        let nodeConfigRestorePath = plan.nodeConfigPath + ".sub2api-statusbar.restore"
        return """
        set -eu
        sender_tmp=\(shellQuote(senderTempPath))
        node_config_tmp=\(shellQuote(nodeConfigTempPath))
        codex_config_tmp=\(shellQuote(codexConfigTempPath))
        sender_restore=\(shellQuote(senderRestorePath))
        node_config_restore=\(shellQuote(nodeConfigRestorePath))
        sender_existed=0
        node_config_existed=0
        codex_config_existed=0
        install_done=0
        cleanup() {
          status=$?
          if [ "$install_done" != "1" ]; then
            if [ "$sender_existed" = "1" ]; then
              cp -p "$sender_restore" \(shellQuote(plan.senderExecutableInstallPath)) 2>/dev/null || true
            else
              rm -f \(shellQuote(plan.senderExecutableInstallPath))
            fi
            if [ "$node_config_existed" = "1" ]; then
              cp -p "$node_config_restore" \(shellQuote(plan.nodeConfigPath)) 2>/dev/null || true
            else
              rm -f \(shellQuote(plan.nodeConfigPath))
            fi
            if [ "$codex_config_existed" = "1" ]; then
              cp -p \(shellQuote(plan.codexConfigBackupPath)) \(shellQuote(plan.codexConfigPath)) 2>/dev/null || true
            else
              rm -f \(shellQuote(plan.codexConfigPath))
            fi
          fi
          rm -f "$sender_tmp" "$node_config_tmp" "$codex_config_tmp" "$sender_restore" "$node_config_restore"
          exit "$status"
        }
        trap cleanup EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        if [ -e \(shellQuote(plan.codexConfigPath)) ] && [ ! -f \(shellQuote(plan.codexConfigPath)) ]; then
          echo 'Codex config path exists but is not a regular file' >&2
          exit 66
        fi
        if [ -e \(shellQuote(plan.senderExecutableInstallPath)) ] && [ ! -f \(shellQuote(plan.senderExecutableInstallPath)) ]; then
          echo 'Sender install path exists but is not a regular file' >&2
          exit 66
        fi
        if [ -e \(shellQuote(plan.nodeConfigPath)) ] && [ ! -f \(shellQuote(plan.nodeConfigPath)) ]; then
          echo 'Node config path exists but is not a regular file' >&2
          exit 66
        fi
        if [ -f \(shellQuote(plan.codexConfigPath)) ]; then
          codex_config_existed=1
        fi
        if [ -f \(shellQuote(plan.senderExecutableInstallPath)) ]; then
          sender_existed=1
        fi
        if [ -f \(shellQuote(plan.nodeConfigPath)) ]; then
          node_config_existed=1
        fi
        mkdir -p \(shellQuote(nodeConfigDirectory)) \(shellQuote(codexConfigDirectory)) \(shellQuote(senderDirectory))
        rm -f "$sender_tmp" "$node_config_tmp" "$codex_config_tmp"
        : > "$sender_tmp"
        \(binaryAppendCommands(data: plan.senderExecutablePayload, shellTarget: #""$sender_tmp""#))
        chmod 700 "$sender_tmp"
        : > "$node_config_tmp"
        \(binaryAppendCommands(data: Data(plan.nodeConfigJSON.utf8), shellTarget: #""$node_config_tmp""#))
        chmod 600 "$node_config_tmp"
        : > "$codex_config_tmp"
        \(binaryAppendCommands(data: Data(plan.updatedCodexConfig.utf8), shellTarget: #""$codex_config_tmp""#))
        chmod 600 "$codex_config_tmp"
        if [ -f \(shellQuote(plan.codexConfigPath)) ]; then
          cp \(shellQuote(plan.codexConfigPath)) \(shellQuote(plan.codexConfigBackupPath))
        else
          : > \(shellQuote(plan.codexConfigBackupPath))
        fi
        if [ -f \(shellQuote(plan.senderExecutableInstallPath)) ]; then
          cp -p \(shellQuote(plan.senderExecutableInstallPath)) "$sender_restore"
        fi
        if [ -f \(shellQuote(plan.nodeConfigPath)) ]; then
          cp -p \(shellQuote(plan.nodeConfigPath)) "$node_config_restore"
        fi
        mv -f "$sender_tmp" \(shellQuote(plan.senderExecutableInstallPath))
        mv -f "$node_config_tmp" \(shellQuote(plan.nodeConfigPath))
        mv -f "$codex_config_tmp" \(shellQuote(plan.codexConfigPath))
        install_done=1
        """
    }

    private static func deletingLastPathComponent(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        return url.deletingLastPathComponent().path
    }

    private static func binaryAppendCommands(data: Data, shellTarget: String) -> String {
        let bytes = [UInt8](data)
        let chunkSize = 256
        var commands: [String] = []
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + chunkSize, bytes.count)
            let escapedChunk = bytes[offset..<end]
                .map { String(format: "\\%03o", $0) }
                .joined()
            commands.append("printf -- '%b' '\(escapedChunk)' >> \(shellTarget)")
            offset = end
        }
        return commands.joined(separator: "\n")
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
