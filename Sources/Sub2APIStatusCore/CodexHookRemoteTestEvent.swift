import Foundation

public struct CodexHookRemoteTestEventCommandPlan: Sendable, Equatable {
    public let sshExecutable: String
    public let sshArguments: [String]
    public let stdinScript: String
}

public protocol CodexHookRemoteTestEventRunning: Sendable {
    func run(_ commandPlan: CodexHookRemoteTestEventCommandPlan) async throws -> CodexHookRemoteInstallResult
}

public struct FoundationCodexHookRemoteTestEventRunner: CodexHookRemoteTestEventRunning {
    public init() {}

    public func run(_ commandPlan: CodexHookRemoteTestEventCommandPlan) async throws -> CodexHookRemoteInstallResult {
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

public struct CodexHookRemoteTestEventService: Sendable {
    private let runner: any CodexHookRemoteTestEventRunning

    public init(runner: any CodexHookRemoteTestEventRunning = FoundationCodexHookRemoteTestEventRunner()) {
        self.runner = runner
    }

    public func send(
        registeredNode: CodexRegisteredNode,
        sshExecutable: String = "/usr/bin/ssh"
    ) async throws -> CodexHookRemoteInstallResult {
        let commandPlan = try CodexHookRemoteTestEventCommandBuilder.buildCommandPlan(
            registeredNode: registeredNode,
            sshExecutable: sshExecutable
        )
        return try await runner.run(commandPlan)
    }
}

public enum CodexHookRemoteTestEventCommandBuilder {
    public static func buildCommandPlan(
        registeredNode: CodexRegisteredNode,
        sshExecutable: String = "/usr/bin/ssh"
    ) throws -> CodexHookRemoteTestEventCommandPlan {
        let node = registeredNode.node
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
        arguments.append(contentsOf: [ssh.destination, "python3", "-"])

        return CodexHookRemoteTestEventCommandPlan(
            sshExecutable: sshExecutable,
            sshArguments: arguments,
            stdinScript: pythonScript(node: node, secret: registeredNode.secret)
        )
    }

    private static func pythonScript(node: CodexNode, secret: String) -> String {
        """
        import datetime
        import hashlib
        import hmac
        import json
        import sys
        import urllib.request
        import urllib.error
        import uuid

        receiver_url = \(pythonString(node.hookReceiverURL.absoluteString))
        node_id = \(pythonString(node.id))
        secret = \(pythonString(secret))
        observed_at = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
        event = {
            "schema_version": 1,
            "event_id": str(uuid.uuid4()),
            "node_id": node_id,
            "observed_at": observed_at,
            "hook_event": "UserPromptSubmit",
            "session_id": "sub2api-statusbar-remote-test-session",
            "turn_id": "sub2api-statusbar-remote-test-turn-" + str(int(datetime.datetime.now(datetime.timezone.utc).timestamp())),
            "model": "test",
        }
        body = json.dumps(event, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        signature = hmac.new(secret.encode("utf-8"), body, hashlib.sha256).hexdigest()
        request = urllib.request.Request(
            receiver_url,
            data=body,
            headers={
                "Content-Type": "application/json",
                "X-S2SB-Node-ID": node_id,
                "X-S2SB-Timestamp": observed_at,
                "X-S2SB-Signature": "hmac-sha256=" + signature,
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=5) as response:
                status = response.getcode()
        except urllib.error.HTTPError as error:
            status = error.code
        except Exception as error:
            print("S2SB_REMOTE_TEST_EVENT_TRANSPORT " + str(error), file=sys.stderr)
            raise SystemExit(67)
        if status < 200 or status >= 300:
            print("S2SB_REMOTE_TEST_EVENT_HTTP_" + str(status), file=sys.stderr)
            raise SystemExit(66)
        print("remote test event accepted")
        """
    }

    private static func pythonString(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22:
                result += "\\\""
            case 0x5C:
                result += "\\\\"
            case 0x09:
                result += "\\t"
            case 0x0A:
                result += "\\n"
            case 0x0D:
                result += "\\r"
            case 0x00..<0x20:
                result += String(format: "\\u%04X", scalar.value)
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        result += "\""
        return result
    }
}
