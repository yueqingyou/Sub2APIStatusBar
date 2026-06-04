import Foundation
import Sub2APIStatusCore

enum CodexHookInstallServiceError: LocalizedError {
    case missingNodeSecret
    case missingRemoteSSHConnection
    case remotePreviewFailed(exitCode: Int32, standardError: String)
    case remoteInstallFailed(exitCode: Int32, standardError: String)

    var errorDescription: String? {
        switch self {
        case .missingNodeSecret:
            return "节点 secret 不存在，请先保存节点。"
        case .missingRemoteSSHConnection:
            return "远端节点必须填写 SSH 连接信息。"
        case let .remotePreviewFailed(exitCode, standardError):
            let detail = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return "远端 hooks 预览准备失败，退出码 \(exitCode)。"
            }
            return "远端 hooks 预览准备失败，退出码 \(exitCode)：\(detail)"
        case let .remoteInstallFailed(exitCode, standardError):
            let detail = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return "远端 hooks 安装失败，退出码 \(exitCode)。"
            }
            return "远端 hooks 安装失败，退出码 \(exitCode)：\(detail)"
        }
    }

    func message(strings: AppStrings) -> String {
        switch self {
        case .missingNodeSecret:
            return strings.phrase("节点 secret 不存在，请先保存节点。", "Node secret is missing. Save the node first.")
        case .missingRemoteSSHConnection:
            return strings.phrase("远端节点必须填写 SSH 连接信息。", "Remote nodes require SSH connection settings.")
        case let .remotePreviewFailed(exitCode, standardError):
            let detail = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return strings.phrase(
                    "远端 hooks 预览准备失败，退出码 \(exitCode)。",
                    "Remote hooks preview preparation failed, exit code \(exitCode)."
                )
            }
            return strings.phrase(
                "远端 hooks 预览准备失败，退出码 \(exitCode)：\(detail)",
                "Remote hooks preview preparation failed, exit code \(exitCode): \(detail)"
            )
        case let .remoteInstallFailed(exitCode, standardError):
            let detail = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return strings.phrase(
                    "远端 hooks 安装失败，退出码 \(exitCode)。",
                    "Remote hooks installation failed, exit code \(exitCode)."
                )
            }
            return strings.phrase(
                "远端 hooks 安装失败，退出码 \(exitCode)：\(detail)",
                "Remote hooks installation failed, exit code \(exitCode): \(detail)"
            )
        }
    }
}

struct CodexHookInstallPreview: Sendable, Equatable {
    let nodeID: String
    let node: CodexNode
    let plan: CodexHookInstallerPlan
    let configDiff: String
}

struct CodexHookInstalledStatus: Sendable, Equatable {
    let nodeID: String
    let codexConfigPath: String
    let nodeConfigPath: String
}

struct CodexHookInstallService {
    private let localInstaller: CodexHookLocalInstaller
    private let remoteInstaller: CodexHookRemoteInstaller
    private let fileManager: FileManager
    private let environment: [String: String]

    init(
        localInstaller: CodexHookLocalInstaller = CodexHookLocalInstaller(),
        remoteInstaller: CodexHookRemoteInstaller = CodexHookRemoteInstaller(),
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.localInstaller = localInstaller
        self.remoteInstaller = remoteInstaller
        self.fileManager = fileManager
        self.environment = environment
    }

    func preview(registeredNode: CodexRegisteredNode) async throws -> CodexHookInstallPreview {
        guard !registeredNode.secret.isEmpty else {
            throw CodexHookInstallServiceError.missingNodeSecret
        }
        let built = try await buildPlan(registeredNode: registeredNode)
        return CodexHookInstallPreview(
            nodeID: registeredNode.node.id,
            node: registeredNode.node,
            plan: built.plan,
            configDiff: UnifiedTextDiff.renderRedactedConfigPreview(
                old: built.existingConfig,
                new: built.plan.updatedCodexConfig,
                fromPath: "\(built.plan.codexConfigPath) (current)",
                toPath: "\(built.plan.codexConfigPath) (updated)"
            )
        )
    }

    func install(preview: CodexHookInstallPreview) async throws -> CodexHookInstallerPlan {
        let plan = preview.plan
        if plan.kind == .remote {
            let result = try await remoteInstaller.apply(node: preview.node, plan: plan)
            guard result.exitCode == 0 else {
                throw CodexHookInstallServiceError.remoteInstallFailed(
                    exitCode: result.exitCode,
                    standardError: result.standardError
                )
            }
        } else {
            try localInstaller.apply(plan)
        }
        return plan
    }

    func installedStatus(registeredNode: CodexRegisteredNode) async throws -> CodexHookInstalledStatus {
        guard !registeredNode.secret.isEmpty else {
            throw CodexHookInstallServiceError.missingNodeSecret
        }
        let built = try await buildPlan(registeredNode: registeredNode)
        try CodexHookConfigValidator.validateManagedHooks(
            built.existingConfig,
            expectedNodeConfigPath: built.plan.nodeConfigPath
        )
        return CodexHookInstalledStatus(
            nodeID: registeredNode.node.id,
            codexConfigPath: built.plan.codexConfigPath,
            nodeConfigPath: built.plan.nodeConfigPath
        )
    }

    private func buildPlan(registeredNode: CodexRegisteredNode) async throws -> (plan: CodexHookInstallerPlan, existingConfig: String) {
        let node = registeredNode.node
        let codexHome = try await resolveCodexHome(node: node)
        let existingConfig = try await existingConfig(at: codexHome.configPath, node: node)
        let supportDirectory = applicationSupportDirectory()
        let plan = try CodexHookInstallerPlanBuilder.buildDryRun(
            node: node,
            codexHome: codexHome,
            existingConfig: existingConfig,
            senderExecutablePayload: CodexHookSenderScript.payload,
            senderExecutableInstallPath: try senderInstallPath(for: node, codexHome: codexHome, supportDirectory: supportDirectory),
            nodeConfigPath: try nodeConfigPath(for: node, codexHome: codexHome, supportDirectory: supportDirectory),
            nodeSecret: registeredNode.secret,
            timestamp: Date()
        )
        return (plan: plan, existingConfig: existingConfig)
    }

    private func resolveCodexHome(node: CodexNode) async throws -> CodexHomeResolution {
        if node.kind == .remote {
            guard node.ssh != nil else {
                throw CodexHookInstallServiceError.missingRemoteSSHConnection
            }
            let result = try await remoteInstaller.readRemoteCodexHomeEnvironment(node: node)
            guard result.exitCode == 0 else {
                throw CodexHookInstallServiceError.remotePreviewFailed(
                    exitCode: result.exitCode,
                    standardError: result.standardError
                )
            }
            return try CodexHomeResolver.resolve(
                remoteEnvironment: CodexRemoteEnvironment(commandOutput: result.standardOutput),
                override: node.codexHomeOverride
            )
        }
        if let codexHomeOverride = node.codexHomeOverride {
            return CodexHomeResolver.resolve(environmentValue: codexHomeOverride, homeDirectory: homeDirectory(for: node))
        }
        return CodexHomeResolver.resolve(
            environmentValue: environment["CODEX_HOME"],
            homeDirectory: homeDirectory(for: node)
        )
    }

    private func homeDirectory(for node: CodexNode) -> String {
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    private func existingConfig(at path: String, node: CodexNode) async throws -> String {
        if node.kind == .remote {
            let result = try await remoteInstaller.readExistingConfig(node: node, codexConfigPath: path)
            guard result.exitCode == 0 else {
                throw CodexHookInstallServiceError.remotePreviewFailed(
                    exitCode: result.exitCode,
                    standardError: result.standardError
                )
            }
            return result.standardOutput
        }
        guard fileManager.fileExists(atPath: path) else {
            return ""
        }
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    private func applicationSupportDirectory() -> URL {
        let baseDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
        return baseDir.appendingPathComponent("Sub2APIStatusBar", isDirectory: true)
    }

    private func senderInstallPath(for node: CodexNode, codexHome: CodexHomeResolution, supportDirectory: URL) throws -> String {
        if node.kind == .remote {
            return try remoteSupportPath(codexHome: codexHome, component: CodexHookSenderScript.executableName)
        }
        return supportDirectory
            .appendingPathComponent(CodexHookSenderScript.executableName)
            .path
    }

    private func nodeConfigPath(for node: CodexNode, codexHome: CodexHomeResolution, supportDirectory: URL) throws -> String {
        if node.kind == .remote {
            return try CodexHookSupportPathBuilder.remoteNodeConfigPath(codexHome: codexHome, nodeID: node.id)
        }
        return supportDirectory
            .appendingPathComponent(try CodexHookSupportPathBuilder.nodeConfigFileName(nodeID: node.id))
            .path
    }

    private func remoteSupportPath(codexHome: CodexHomeResolution, component: String) throws -> String {
        try CodexHookSupportPathBuilder.remoteSupportPath(codexHome: codexHome, component: component)
    }
}
