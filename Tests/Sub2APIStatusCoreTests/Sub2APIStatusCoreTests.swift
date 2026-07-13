import Foundation
import Darwin
import XCTest
@testable import Sub2APIStatusCore

final class MemoryTokenStore: TokenStore, @unchecked Sendable {
    var tokens = StoredAuthTokens()
    var saves: [StoredAuthTokens] = []

    func loadTokens() -> StoredAuthTokens {
        tokens
    }

    func saveTokens(_ tokens: StoredAuthTokens) throws {
        self.tokens = tokens
        saves.append(tokens)
    }
}

final class MemoryLegacyTokenStore: LegacyTokenStore, @unchecked Sendable {
    var tokens: StoredAuthTokens
    var deleteCallCount = 0

    init(tokens: StoredAuthTokens) {
        self.tokens = tokens
    }

    func loadTokens() -> StoredAuthTokens {
        tokens
    }

    func deleteTokens() {
        tokens = StoredAuthTokens()
        deleteCallCount += 1
    }
}

final class StubSSHTunnelProcessHandle: SSHTunnelProcessHandle, @unchecked Sendable {
    var isRunning: Bool
    var terminationStatus: Int32
    var standardError: String
    var terminateCallCount = 0

    init(isRunning: Bool = true, terminationStatus: Int32 = 0, standardError: String = "") {
        self.isRunning = isRunning
        self.terminationStatus = terminationStatus
        self.standardError = standardError
    }

    func terminate() {
        terminateCallCount += 1
        isRunning = false
    }
}

final class StubSSHTunnelProcessLauncher: SSHTunnelProcessLaunching, @unchecked Sendable {
    var launchedCommands: [ProcessCommand] = []
    var nextHandle = StubSSHTunnelProcessHandle()

    func launch(command: ProcessCommand) throws -> any SSHTunnelProcessHandle {
        launchedCommands.append(command)
        return nextHandle
    }
}

final class TestClock: @unchecked Sendable {
    var now: Date

    init(_ now: Date) {
        self.now = now
    }
}

final class RecordingCodexHookRemoteInstallRunner: CodexHookRemoteInstallRunning, @unchecked Sendable {
    var receivedPlans: [CodexHookRemoteInstallerCommandPlan] = []
    var result = CodexHookRemoteInstallResult(exitCode: 0, standardOutput: "ok", standardError: "")

    func run(_ commandPlan: CodexHookRemoteInstallerCommandPlan) async throws -> CodexHookRemoteInstallResult {
        receivedPlans.append(commandPlan)
        return result
    }
}

final class RecordingCodexHookRemoteConfigReader: CodexHookRemoteConfigReading, @unchecked Sendable {
    var receivedPlans: [CodexHookRemoteReadCommandPlan] = []
    var result = CodexHookRemoteInstallResult(exitCode: 0, standardOutput: #"model = "gpt-5""#, standardError: "")

    func read(_ commandPlan: CodexHookRemoteReadCommandPlan) async throws -> CodexHookRemoteInstallResult {
        receivedPlans.append(commandPlan)
        return result
    }
}

@MainActor
private final class LocalReceiverTestRecorder {
    var states: [LocalCodexHookReceiverState] = []
    var events: [CodexHookEvent] = []

    func append(state: LocalCodexHookReceiverState) {
        states.append(state)
    }

    func append(event: CodexHookEvent) {
        events.append(event)
    }
}

private func availableLoopbackPort() throws -> UInt16 {
    let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard socketDescriptor >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer {
        close(socketDescriptor)
    }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

    let bindResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            Darwin.bind(socketDescriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bindResult == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    var boundAddress = sockaddr_in()
    var boundAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            getsockname(socketDescriptor, sockaddrPointer, &boundAddressLength)
        }
    }
    guard nameResult == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return UInt16(bigEndian: boundAddress.sin_port)
}

private func sendRawLoopbackHTTPRequest(_ requestData: Data, port: UInt16) throws -> Data {
    let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard socketDescriptor >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer {
        close(socketDescriptor)
    }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

    let connectResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            connect(socketDescriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connectResult == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    try requestData.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else {
            return
        }
        var sent = 0
        while sent < rawBuffer.count {
            let count = Darwin.send(socketDescriptor, baseAddress.advanced(by: sent), rawBuffer.count - sent, 0)
            guard count > 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            sent += count
        }
    }
    shutdown(socketDescriptor, SHUT_WR)

    var responseData = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let readCount = recv(socketDescriptor, &buffer, buffer.count, 0)
        if readCount < 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if readCount == 0 {
            break
        }
        responseData.append(buffer, count: readCount)
    }
    return responseData
}

private func runCodexHookSender(
    senderURL: URL,
    eventName: String,
    nodeConfigURL: URL,
    stdinPayload: Data
) throws -> CodexHookRemoteInstallResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
        "python3",
        senderURL.path,
        "--managed-by", "Sub2APIStatusBar",
        "--event", eventName,
        "--config", nodeConfigURL.path,
    ]

    let inputPipe = Pipe()
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardInput = inputPipe
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    try process.run()
    inputPipe.fileHandleForWriting.write(stdinPayload)
    inputPipe.fileHandleForWriting.closeFile()
    process.waitUntilExit()

    return CodexHookRemoteInstallResult(
        exitCode: process.terminationStatus,
        standardOutput: String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
        standardError: String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    )
}

private enum HookCommandExtractionError: Error {
    case missingCommand(eventName: String)
    case malformedTomlString(String)
}

private enum LocalInstallerTestError: Error, Equatable {
    case forcedCodexConfigWriteFailure
}

private func managedHookCommand(eventName: String, in config: String) throws -> String {
    let lines = config
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
    let hookHeader = "[[hooks.\(eventName).hooks]]"

    for index in lines.indices where lines[index].trimmingCharacters(in: .whitespaces) == hookHeader {
        var lineIndex = lines.index(after: index)
        while lineIndex < lines.count {
            let trimmed = lines[lineIndex].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                break
            }
            if trimmed.hasPrefix("command = ") {
                let rawValue = String(trimmed.dropFirst("command = ".count))
                return try decodeTomlBasicString(rawValue)
            }
            lineIndex += 1
        }
    }

    throw HookCommandExtractionError.missingCommand(eventName: eventName)
}

private func decodeTomlBasicString(_ value: String) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") else {
        throw HookCommandExtractionError.malformedTomlString(value)
    }

    var result = ""
    var isEscaped = false
    for character in trimmed.dropFirst().dropLast() {
        if isEscaped {
            result.append(character)
            isEscaped = false
        } else if character == "\\" {
            isEscaped = true
        } else {
            result.append(character)
        }
    }
    if isEscaped {
        throw HookCommandExtractionError.malformedTomlString(value)
    }
    return result
}

private func runShellHookCommand(
    command: String,
    stdinPayload: Data
) throws -> CodexHookRemoteInstallResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]

    let inputPipe = Pipe()
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardInput = inputPipe
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    try process.run()
    inputPipe.fileHandleForWriting.write(stdinPayload)
    inputPipe.fileHandleForWriting.closeFile()
    process.waitUntilExit()

    return CodexHookRemoteInstallResult(
        exitCode: process.terminationStatus,
        standardOutput: String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
        standardError: String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    )
}

private func runShellScript(_ script: String) throws -> CodexHookRemoteInstallResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-s"]

    let inputPipe = Pipe()
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardInput = inputPipe
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    try process.run()
    inputPipe.fileHandleForWriting.write(Data(script.utf8))
    inputPipe.fileHandleForWriting.closeFile()
    process.waitUntilExit()

    return CodexHookRemoteInstallResult(
        exitCode: process.terminationStatus,
        standardOutput: String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
        standardError: String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    )
}

private func runShellCommand(
    _ command: String,
    environment: [String: String] = [:]
) throws -> CodexHookRemoteInstallResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    if !environment.isEmpty {
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
    }

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    try process.run()
    process.waitUntilExit()

    return CodexHookRemoteInstallResult(
        exitCode: process.terminationStatus,
        standardOutput: String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
        standardError: String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    )
}

private func shellQuoteForTest(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}

private func writeFakeSSHExecutable(at url: URL) throws {
    let script = """
    #!/bin/sh
    exec python3 -
    """
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try script.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o700))], ofItemAtPath: url.path)
}

@MainActor
private func waitForListenerReady(
    _ states: [LocalCodexHookReceiverState],
    timeout: TimeInterval = 2,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if states.contains(.ready) {
            return
        }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTFail("Listener did not become ready: \(states)", file: file, line: line)
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    static var responses: [String: Data] = [:]
    static var responseQueues: [String: [(status: Int, data: Data)]] = [:]
    static var requestedPaths: [String] = []

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: TokenRouterError.invalidBaseURL)
            return
        }

        let key = url.path + (url.query.map { "?\($0)" } ?? "")
        Self.requestedPaths.append(key)
        let queuedResponse: (status: Int, data: Data)?
        if var queue = Self.responseQueues[key], !queue.isEmpty {
            queuedResponse = queue.removeFirst()
            Self.responseQueues[key] = queue
        } else {
            queuedResponse = nil
        }
        let data = queuedResponse?.data ?? Self.responses[key] ?? Data(#"{"code":404,"message":"not found"}"#.utf8)
        let status = queuedResponse?.status ?? (Self.responses[key] == nil ? 404 : 200)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class Sub2APIStatusCoreTests: XCTestCase {

override func setUp() {
    super.setUp()
    StubURLProtocol.responses = [:]
    StubURLProtocol.responseQueues = [:]
    StubURLProtocol.requestedPaths = []
}

func testAppConfigNormalizesBaseURLAndRefreshInterval() {
    var config = AppConfig(baseURL: " http://127.0.0.1:8080/api/v1/// ", authToken: " token ", refreshIntervalSeconds: 1, language: .zhHans, monitorMode: .user)

    config.normalize()

    XCTAssert(config.baseURL == "http://127.0.0.1:8080")
    XCTAssert(config.authToken == "token")
    XCTAssert(config.refreshIntervalSeconds == 5)
    XCTAssert(config.monitorMode == .user)
    XCTAssert(config.showsMenuBarText == false)
    XCTAssert(config.launchAtLogin == false)
}

func testTokenRouterRefreshPolicySeparatesAutomaticAndManualSlowRefreshes() {
    let policy = TokenRouterRefreshPolicy(slowRefreshInterval: 60, accountUsageRefreshInterval: 600)
    let now = Date(timeIntervalSince1970: 1_000)

    XCTAssertTrue(policy.shouldRefreshSlowData(lastAttemptAt: nil, now: now, isManualRefresh: false))
    XCTAssertFalse(policy.shouldRefreshSlowData(lastAttemptAt: now.addingTimeInterval(-59), now: now, isManualRefresh: false))
    XCTAssertTrue(policy.shouldRefreshSlowData(lastAttemptAt: now.addingTimeInterval(-60), now: now, isManualRefresh: false))
    XCTAssertTrue(policy.shouldRefreshSlowData(lastAttemptAt: now, now: now, isManualRefresh: true))
    XCTAssertTrue(policy.shouldRefreshAccountUsage(lastAttemptAt: nil, now: now, isManualRefresh: false))
    XCTAssertFalse(policy.shouldRefreshAccountUsage(lastAttemptAt: now.addingTimeInterval(-599), now: now, isManualRefresh: false))
    XCTAssertTrue(policy.shouldRefreshAccountUsage(lastAttemptAt: now.addingTimeInterval(-600), now: now, isManualRefresh: false))
    XCTAssertTrue(policy.shouldRefreshAccountUsage(lastAttemptAt: now, now: now, isManualRefresh: true))
}

func testAppConfigNormalizesCodexTaskTimelineEventLimit() {
    var tooLow = AppConfig(baseURL: "http://127.0.0.1:8080", codexTaskTimelineEventLimit: -4)
    var tooHigh = AppConfig(baseURL: "http://127.0.0.1:8080", codexTaskTimelineEventLimit: 999)

    tooLow.normalize()
    tooHigh.normalize()

    XCTAssertEqual(tooLow.codexTaskTimelineEventLimit, 1)
    XCTAssertEqual(tooHigh.codexTaskTimelineEventLimit, 20)
}

func testAppConfigDefaultsMenuBarWindowAndItems() {
    let config = AppConfig(baseURL: "http://127.0.0.1:8080")

    XCTAssert(config.menuBarUsageWindow == .last24Hours)
    XCTAssert(config.menuBarDisplayItems == [
        .totalCost,
        .model,
        .reasoningEffort,
        .contextLength,
        .fast,
        .rpm,
    ])
    XCTAssertEqual(config.codexTaskTimelineEventLimit, AppConfig.defaultCodexTaskTimelineEventLimit)
}

func testAppConfigDefaultsToChineseLanguage() {
    let config = AppConfig(baseURL: "http://127.0.0.1:8080")

    XCTAssert(config.language == .zhHans)
}

func testAppConfigDefaultsToSystemAppearance() {
    let config = AppConfig(baseURL: "http://127.0.0.1:8080")

    XCTAssert(config.appearance == .system)
}

func testAppLanguageFallsBackToChineseWhenEnvironmentIsMissingOrUnknown() {
    XCTAssert(AppLanguage.fromEnvironment(nil) == .zhHans)
    XCTAssert(AppLanguage.fromEnvironment("") == .zhHans)
    XCTAssert(AppLanguage.fromEnvironment("auto") == .zhHans)
    XCTAssert(AppLanguage.fromEnvironment("english") == .en)
}

func testAppAppearanceFallsBackToSystemWhenEnvironmentIsMissingOrUnknown() {
    XCTAssert(AppAppearance.fromEnvironment(nil) == .system)
    XCTAssert(AppAppearance.fromEnvironment("") == .system)
    XCTAssert(AppAppearance.fromEnvironment("auto") == .system)
    XCTAssert(AppAppearance.fromEnvironment("system") == .system)
    XCTAssert(AppAppearance.fromEnvironment("light") == .light)
    XCTAssert(AppAppearance.fromEnvironment("dark-aqua") == .dark)
    XCTAssert(AppAppearance.fromEnvironment("unknown") == .system)
}

func testCodexHomeResolverPrefersEnvironmentValue() {
    let resolved = CodexHomeResolver.resolve(environmentValue: " /opt/codex-home/ ", homeDirectory: "/Users/tester")

    XCTAssertEqual(resolved.codexHomePath, "/opt/codex-home")
    XCTAssertEqual(resolved.configPath, "/opt/codex-home/config.toml")
    XCTAssertEqual(resolved.userHomePath, "/Users/tester")
}

func testCodexHomeResolverFallsBackToUserCodexDirectory() {
    let resolved = CodexHomeResolver.resolve(environmentValue: " ", homeDirectory: "/Users/tester")

    XCTAssertEqual(resolved.codexHomePath, "/Users/tester/.codex")
    XCTAssertEqual(resolved.configPath, "/Users/tester/.codex/config.toml")
    XCTAssertEqual(resolved.userHomePath, "/Users/tester")
}

func testCodexHomeResolverUsesRemoteCodexHomeBeforeRemoteHome() throws {
    let resolved = try CodexHomeResolver.resolve(
        remoteEnvironment: CodexRemoteEnvironment(commandOutput: """
        \(CodexRemoteEnvironment.codexHomeOutputPrefix)/srv/codex
        \(CodexRemoteEnvironment.homeDirectoryOutputPrefix)/home/deploy
        """)
    )

    XCTAssertEqual(resolved.codexHomePath, "/srv/codex")
    XCTAssertEqual(resolved.configPath, "/srv/codex/config.toml")
    XCTAssertEqual(resolved.userHomePath, "/home/deploy")
}

func testCodexHomeResolverReadsMarkedRemoteEnvironmentDespiteShellStartupNoise() throws {
    let resolved = try CodexHomeResolver.resolve(
        remoteEnvironment: CodexRemoteEnvironment(commandOutput: """
        remote shell banner
        \(CodexRemoteEnvironment.codexHomeOutputPrefix)/srv/codex
        debug line from profile
        \(CodexRemoteEnvironment.homeDirectoryOutputPrefix)/home/deploy
        """)
    )

    XCTAssertEqual(resolved.codexHomePath, "/srv/codex")
    XCTAssertEqual(resolved.configPath, "/srv/codex/config.toml")
    XCTAssertEqual(resolved.userHomePath, "/home/deploy")
}

func testCodexHomeResolverUsesRemoteOverrideWithoutLosingRemoteHome() throws {
    let resolved = try CodexHomeResolver.resolve(
        remoteEnvironment: CodexRemoteEnvironment(commandOutput: """
        \(CodexRemoteEnvironment.codexHomeOutputPrefix)/srv/codex
        \(CodexRemoteEnvironment.homeDirectoryOutputPrefix)/home/deploy
        """),
        override: " /opt/custom-codex/ "
    )

    XCTAssertEqual(resolved.codexHomePath, "/opt/custom-codex")
    XCTAssertEqual(resolved.configPath, "/opt/custom-codex/config.toml")
    XCTAssertEqual(resolved.userHomePath, "/home/deploy")
}

func testCodexHomeResolverFallsBackToRemoteHomeDirectory() throws {
    let resolved = try CodexHomeResolver.resolve(
        remoteEnvironment: CodexRemoteEnvironment(commandOutput: """
        \(CodexRemoteEnvironment.codexHomeOutputPrefix)
        \(CodexRemoteEnvironment.homeDirectoryOutputPrefix)/Users/remote
        """)
    )

    XCTAssertEqual(resolved.codexHomePath, "/Users/remote/.codex")
    XCTAssertEqual(resolved.configPath, "/Users/remote/.codex/config.toml")
    XCTAssertEqual(resolved.userHomePath, "/Users/remote")
}

func testCodexHomeResolverRejectsRemoteEnvironmentWithoutHome() {
    XCTAssertThrowsError(try CodexHomeResolver.resolve(
        remoteEnvironment: CodexRemoteEnvironment(commandOutput: """
        \(CodexRemoteEnvironment.codexHomeOutputPrefix)
        """)
    )) { error in
        XCTAssertEqual(error as? CodexHomeResolutionError, .missingRemoteHomeDirectory)
    }
}

func testCodexHomeResolverRejectsRemoteOverrideWithoutRemoteHome() {
    XCTAssertThrowsError(try CodexHomeResolver.resolve(
        remoteEnvironment: CodexRemoteEnvironment(commandOutput: """
        \(CodexRemoteEnvironment.codexHomeOutputPrefix)/srv/codex
        """),
        override: "/opt/custom-codex"
    )) { error in
        XCTAssertEqual(error as? CodexHomeResolutionError, .missingRemoteHomeDirectory)
    }
}

func testCodexHookSupportPathUsesRemoteHomeWhenCodexHomeIsCustom() throws {
    let codexHome = try CodexHomeResolver.resolve(
        remoteEnvironment: CodexRemoteEnvironment(commandOutput: """
        \(CodexRemoteEnvironment.codexHomeOutputPrefix)/srv/codex
        \(CodexRemoteEnvironment.homeDirectoryOutputPrefix)/home/deploy
        """)
    )

    let senderPath = try CodexHookSupportPathBuilder.remoteSupportPath(
        codexHome: codexHome,
        component: "sub2api-statusbar-hook-sender"
    )
    let nodeConfigPath = try CodexHookSupportPathBuilder.remoteNodeConfigPath(
        codexHome: codexHome,
        nodeID: "remote-node"
    )

    XCTAssertEqual(senderPath, "/home/deploy/.sub2api-statusbar/sub2api-statusbar-hook-sender")
    XCTAssertEqual(nodeConfigPath, "/home/deploy/.sub2api-statusbar/codex-hook-node-remote-node.json")
}

func testCodexHookSupportPathRequiresRemoteHome() {
    let codexHome = CodexHomeResolution(codexHomePath: "/srv/codex", configPath: "/srv/codex/config.toml")

    XCTAssertThrowsError(try CodexHookSupportPathBuilder.remoteNodeConfigPath(
        codexHome: codexHome,
        nodeID: "remote-node"
    )) { error in
        XCTAssertEqual(error as? CodexHomeResolutionError, .missingRemoteHomeDirectory)
    }
}

func testCodexHookSupportPathRejectsUnsafeNodeIDForConfigFileName() {
    XCTAssertEqual(try CodexHookSupportPathBuilder.nodeConfigFileName(nodeID: " remote.node_1-2 "), "codex-hook-node-remote.node_1-2.json")
    XCTAssertThrowsError(try CodexHookSupportPathBuilder.nodeConfigFileName(nodeID: "../remote")) { error in
        XCTAssertEqual(error as? CodexNodeValidationError, .invalidID)
    }
}

func testCodexNodeNormalizesLocalAndRemoteReceiverURLs() throws {
    let local = try CodexNode(
        id: " local-node ",
        name: " 本机 ",
        kind: .local,
        localReceiverPort: 43210,
        remoteReceiverPort: nil,
        ssh: nil,
        codexHomeOverride: " /Users/tester/.codex "
    )
    let remote = try CodexNode(
        id: " remote-node ",
        name: " 远端 ",
        kind: .remote,
        localReceiverPort: 43210,
        remoteReceiverPort: 53210,
        ssh: SSHNodeConnection(host: " example-host ", user: " deploy ", port: 2222, identityFile: " ~/.ssh/id_ed25519 "),
        codexHomeOverride: nil
    )

    XCTAssertEqual(local.id, "local-node")
    XCTAssertEqual(local.codexHomeOverride, "/Users/tester/.codex")
    XCTAssertEqual(local.hookReceiverURL.absoluteString, "http://127.0.0.1:43210/codex-hooks/events")
    XCTAssertEqual(local.localHookReceiverURL.absoluteString, "http://127.0.0.1:43210/codex-hooks/events")
    XCTAssertEqual(remote.id, "remote-node")
    XCTAssertEqual(remote.ssh?.host, "example-host")
    XCTAssertEqual(remote.ssh?.user, "deploy")
    XCTAssertEqual(remote.hookReceiverURL.absoluteString, "http://127.0.0.1:53210/codex-hooks/events")
    XCTAssertEqual(remote.localHookReceiverURL.absoluteString, "http://127.0.0.1:43210/codex-hooks/events")
}

func testCodexNodeRejectsRemoteNodeWithoutSSHOrRemotePort() {
    XCTAssertThrowsError(try CodexNode(
        id: "remote-node",
        name: "远端",
        kind: .remote,
        localReceiverPort: 43210,
        remoteReceiverPort: nil,
        ssh: SSHNodeConnection(host: "example-host"),
        codexHomeOverride: nil
    )) { error in
        XCTAssertEqual(error as? CodexNodeValidationError, .missingRemoteReceiverPort)
    }

    XCTAssertThrowsError(try CodexNode(
        id: "remote-node",
        name: "远端",
        kind: .remote,
        localReceiverPort: 43210,
        remoteReceiverPort: 53210,
        ssh: nil,
        codexHomeOverride: nil
    )) { error in
        XCTAssertEqual(error as? CodexNodeValidationError, .missingSSHConnection)
    }
}

func testCodexNodeRejectsPathUnsafeIDAndDecodingBypassesNoValidation() {
    XCTAssertThrowsError(try CodexNode(
        id: "../remote",
        name: "远端",
        kind: .local,
        localReceiverPort: 43210,
        remoteReceiverPort: nil,
        ssh: nil,
        codexHomeOverride: nil
    )) { error in
        XCTAssertEqual(error as? CodexNodeValidationError, .invalidID)
    }

    let raw = """
    {
      "id": "../remote",
      "name": "Remote",
      "kind": "local",
      "localReceiverPort": 43210
    }
    """.data(using: .utf8)!

    XCTAssertThrowsError(try JSONDecoder().decode(CodexNode.self, from: raw))
}

func testCodexNodeFormBuildsLocalRegisteredNodeWithSecret() throws {
    var form = CodexNodeFormState.localDefault(id: " local-node ", name: " 本机 ")
    form.codexHomeOverride = " /Users/tester/.codex "
    form.secret = " node-secret "

    let registered = try form.registeredNode()

    XCTAssertEqual(registered.node.id, "local-node")
    XCTAssertEqual(registered.node.name, "本机")
    XCTAssertEqual(registered.node.kind, .local)
    XCTAssertEqual(registered.node.localReceiverPort, 43210)
    XCTAssertNil(registered.node.remoteReceiverPort)
    XCTAssertNil(registered.node.ssh)
    XCTAssertEqual(registered.node.codexHomeOverride, "/Users/tester/.codex")
    XCTAssertEqual(registered.secret, "node-secret")
}

func testCodexNodeFormBuildsRemoteRegisteredNodeWithSSH() throws {
    let form = CodexNodeFormState(
        id: "remote-node",
        name: "远端",
        kind: .remote,
        localReceiverPort: "43210",
        remoteReceiverPort: "53210",
        sshHost: " example-host ",
        sshUser: " deploy ",
        sshPort: "2222",
        sshIdentityFile: " ~/.ssh/id_ed25519 ",
        codexHomeOverride: "",
        secret: "remote-secret"
    )

    let registered = try form.registeredNode()

    XCTAssertEqual(registered.node.kind, .remote)
    XCTAssertEqual(registered.node.remoteReceiverPort, 53210)
    XCTAssertEqual(registered.node.ssh?.host, "example-host")
    XCTAssertEqual(registered.node.ssh?.user, "deploy")
    XCTAssertEqual(registered.node.ssh?.port, 2222)
    XCTAssertEqual(registered.node.ssh?.identityFile, "~/.ssh/id_ed25519")
    XCTAssertEqual(registered.secret, "remote-secret")
}

func testSSHConfigParserBuildsConcreteHostsWithDefaults() {
    let rawConfig = """
    Host prod
      HostName prod.example.com
      User deploy

    Host staging
      HostName=staging.example.com
      IdentityFile "~/.ssh/staging key"

    Host *.internal
      User ignored

    Host *
      User shared
      Port 2200
      IdentityFile ~/.ssh/shared
    """

    let hosts = SSHConfigParser.parse(rawConfig)

    XCTAssertEqual(hosts.map(\.alias), ["prod", "staging"])
    XCTAssertEqual(hosts[0], SSHConfigHost(
        alias: "prod",
        hostName: "prod.example.com",
        user: "deploy",
        port: 2200,
        identityFile: "~/.ssh/shared"
    ))
    XCTAssertEqual(hosts[1], SSHConfigHost(
        alias: "staging",
        hostName: "staging.example.com",
        user: "shared",
        port: 2200,
        identityFile: "~/.ssh/staging key"
    ))
    XCTAssertEqual(hosts[0].nodeConnection, SSHNodeConnection(host: "prod.example.com", user: "deploy", port: 2200, identityFile: "~/.ssh/shared"))
}

func testSSHConfigParserUsesFirstValueAndSkipsComments() {
    let rawConfig = """
    # leading comment
    Host build-box
      HostName build-1.example.com # inline comment
      HostName build-2.example.com
      User first
      User second
      Port not-a-number
      Port 2222
      IdentityFile '~/.ssh/build'
    """

    let hosts = SSHConfigParser.parse(rawConfig)

    XCTAssertEqual(hosts, [
        SSHConfigHost(
            alias: "build-box",
            hostName: "build-1.example.com",
            user: "first",
            port: 2222,
            identityFile: "~/.ssh/build"
        )
    ])
}

func testCodexNodeFormRejectsInvalidPortAndEmptySecret() {
    var form = CodexNodeFormState.localDefault()
    form.localReceiverPort = "bad"
    XCTAssertThrowsError(try form.registeredNode()) { error in
        XCTAssertEqual(error as? CodexNodeFormError, .invalidLocalReceiverPort)
    }

    form.localReceiverPort = "43210"
    form.secret = ""
    XCTAssertThrowsError(try form.registeredNode()) { error in
        XCTAssertEqual(error as? CodexNodeValidationError, .emptySecret)
    }
}

func testCodexNodeStorePersistsNodeMetadataWithoutSecrets() throws {
    let nodesURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("codex-nodes.json")
    let secretsURL = nodesURL.deletingLastPathComponent().appendingPathComponent("codex-node-secrets.json")
    let store = CodexNodeStore(nodesURL: nodesURL, secretsURL: secretsURL)
    let nodes = [
        try CodexNode(
            id: "local-node",
            name: "本机",
            kind: .local,
            localReceiverPort: 43210,
            remoteReceiverPort: nil,
            ssh: nil,
            codexHomeOverride: "/Users/tester/.codex"
        ),
        try CodexNode(
            id: "remote-node",
            name: "远端",
            kind: .remote,
            localReceiverPort: 43210,
            remoteReceiverPort: 53210,
            ssh: SSHNodeConnection(host: "example-host", user: "deploy", port: 2222, identityFile: "~/.ssh/id_ed25519"),
            codexHomeOverride: nil
        ),
    ]

    try store.save(nodes)
    let raw = try String(contentsOf: nodesURL, encoding: .utf8)
    let loaded = try store.load()

    XCTAssertEqual(loaded, nodes)
    XCTAssert(raw.contains("local-node"))
    XCTAssert(raw.contains("remote-node"))
    XCTAssertFalse(raw.contains("secret"))
    XCTAssertFalse(raw.contains("token"))
}

func testCodexNodeStorePersistsRegistrySecretsInPrivateSeparateFile() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
    let nodesURL = root.appendingPathComponent("codex-nodes.json")
    let secretsURL = root.appendingPathComponent("codex-node-secrets.json")
    let store = CodexNodeStore(nodesURL: nodesURL, secretsURL: secretsURL)
    let node = try CodexNode(
        id: "local-node",
        name: "本机",
        kind: .local,
        localReceiverPort: 43210,
        remoteReceiverPort: nil,
        ssh: nil,
        codexHomeOverride: "/Users/tester/.codex"
    )
    let registry = CodexNodeRegistry(registeredNodes: [
        CodexRegisteredNode(node: node, secret: "node-secret"),
    ])

    try store.saveRegistry(registry)
    let loaded = try store.loadRegistry()
    let nodesRaw = try String(contentsOf: nodesURL, encoding: .utf8)
    let secretsRaw = try String(contentsOf: secretsURL, encoding: .utf8)

    XCTAssertEqual(loaded.nodes.map(\.id), ["local-node"])
    XCTAssertEqual(loaded.nodeSecrets, ["local-node": "node-secret"])
    XCTAssertFalse(nodesRaw.contains("node-secret"))
    XCTAssert(secretsRaw.contains("node-secret"))
    XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: secretsURL.path)[.posixPermissions] as? NSNumber, NSNumber(value: Int16(0o600)))
}

func testCodexNodeRegistryBuildsReceiverSecretsWithoutPersistingThemInNodes() throws {
    let local = try CodexNode(
        id: "local-node",
        name: "本机",
        kind: .local,
        localReceiverPort: 43210,
        remoteReceiverPort: nil,
        ssh: nil,
        codexHomeOverride: "/Users/tester/.codex"
    )
    let remote = try CodexNode(
        id: "remote-node",
        name: "远端",
        kind: .remote,
        localReceiverPort: 43210,
        remoteReceiverPort: 53210,
        ssh: SSHNodeConnection(host: "example-host", user: "deploy"),
        codexHomeOverride: nil
    )

    let registry = CodexNodeRegistry(registeredNodes: [
        CodexRegisteredNode(node: local, secret: "local-secret"),
        CodexRegisteredNode(node: remote, secret: "remote-secret"),
    ])

    XCTAssertEqual(registry.nodes.map(\.id), ["local-node", "remote-node"])
    XCTAssertEqual(registry.nodeSecrets, ["local-node": "local-secret", "remote-node": "remote-secret"])
    XCTAssertEqual(registry.node(id: " remote-node ")?.node.hookReceiverURL.absoluteString, "http://127.0.0.1:53210/codex-hooks/events")
    XCTAssertFalse(String(describing: registry.nodes).contains("secret"))
}

func testCodexNodeHealthStoreTracksInstallReceiverTunnelAndRealEvents() throws {
    let local = try CodexNode(
        id: "local-node",
        name: "本机",
        kind: .local,
        localReceiverPort: 43210,
        remoteReceiverPort: nil,
        ssh: nil,
        codexHomeOverride: nil
    )
    let remote = try CodexNode(
        id: "remote-node",
        name: "远端",
        kind: .remote,
        localReceiverPort: 43210,
        remoteReceiverPort: 53210,
        ssh: SSHNodeConnection(host: "example-host", user: "deploy"),
        codexHomeOverride: nil
    )
    var store = CodexNodeHealthStore()

    store.configure(nodes: [local, remote], now: Date(timeIntervalSince1970: 100))

    XCTAssertEqual(store.status(nodeID: "local-node")?.state, .unconfigured)
    XCTAssertEqual(store.status(nodeID: "remote-node")?.state, .unconfigured)

    store.markReceiverFailed(
        port: 43210,
        nodes: [local, remote],
        detail: "address already in use",
        now: Date(timeIntervalSince1970: 110)
    )

    XCTAssertEqual(store.status(nodeID: "local-node")?.state, .receiverFailed)
    XCTAssertEqual(store.status(nodeID: "remote-node")?.state, .receiverFailed)
    XCTAssertEqual(store.status(nodeID: "local-node")?.detail, "address already in use")

    store.markReceiverReady(port: 43210, nodes: [local, remote], now: Date(timeIntervalSince1970: 120))
    store.markHooksInstalled(nodeID: "local-node", detail: "installed", now: Date(timeIntervalSince1970: 130))
    store.markTunnelFailed(nodeID: "remote-node", detail: "exit 255", now: Date(timeIntervalSince1970: 140))

    XCTAssertEqual(store.status(nodeID: "local-node")?.state, .waitingForTrust)
    XCTAssertEqual(store.status(nodeID: "remote-node")?.state, .tunnelFailed)

    store.markEventReceived(CodexHookEvent(
        eventID: "test-event",
        nodeID: "local-node",
        observedAt: Date(timeIntervalSince1970: 150),
        hookEvent: .userPromptSubmit,
        sessionID: "sub2api-statusbar-test-session",
        turnID: "sub2api-statusbar-test-turn-150",
        cwd: nil,
        model: "test",
        toolName: nil
    ), now: Date(timeIntervalSince1970: 151))

    XCTAssertEqual(store.status(nodeID: "local-node")?.state, .waitingForTrust)
    XCTAssertNil(store.status(nodeID: "local-node")?.lastSeenAt)
    XCTAssertEqual(store.status(nodeID: "local-node")?.lastTestEventAt, Date(timeIntervalSince1970: 150))

    store.markEventReceived(CodexHookEvent(
        eventID: "real-event",
        nodeID: "local-node",
        observedAt: Date(timeIntervalSince1970: 160),
        hookEvent: .userPromptSubmit,
        sessionID: "session-1",
        turnID: "turn-1",
        cwd: nil,
        model: "gpt-5",
        toolName: nil
    ), now: Date(timeIntervalSince1970: 161))

    XCTAssertEqual(store.status(nodeID: "local-node")?.state, .healthy)
    XCTAssertEqual(store.status(nodeID: "local-node")?.lastSeenAt, Date(timeIntervalSince1970: 160))

    store.markTunnelStopped(
        nodeID: "local-node",
        detail: "SSH-R tunnel stopped.",
        now: Date(timeIntervalSince1970: 170)
    )

    XCTAssertEqual(store.status(nodeID: "local-node")?.state, .installed)
    XCTAssertEqual(store.status(nodeID: "local-node")?.detail, "SSH-R tunnel stopped.")
}

func testCodexNodeHealthStoreDoesNotTreatSyntheticTestEventAsPreciseMonitoringWithoutInstall() throws {
    let node = try CodexNode(
        id: "local-node",
        name: "本机",
        kind: .local,
        localReceiverPort: 43210,
        remoteReceiverPort: nil,
        ssh: nil,
        codexHomeOverride: nil
    )
    var store = CodexNodeHealthStore()
    store.configure(nodes: [node], now: Date(timeIntervalSince1970: 100))

    store.markEventReceived(CodexHookEvent(
        eventID: "test-event",
        nodeID: "local-node",
        observedAt: Date(timeIntervalSince1970: 120),
        hookEvent: .userPromptSubmit,
        sessionID: "sub2api-statusbar-test-session",
        turnID: "sub2api-statusbar-test-turn-120",
        cwd: nil,
        model: "test",
        toolName: nil
    ), now: Date(timeIntervalSince1970: 121))

    XCTAssertEqual(store.status(nodeID: "local-node")?.state, .unconfigured)
    XCTAssertNil(store.status(nodeID: "local-node")?.lastSeenAt)
    XCTAssertEqual(store.status(nodeID: "local-node")?.lastTestEventAt, Date(timeIntervalSince1970: 120))
}

func testCodexNodeHealthStoreMarksExistingManagedHooksAsConfiguredWithoutOverwritingHealthyState() throws {
    let node = try CodexNode(
        id: "local-node",
        name: "本机",
        kind: .local,
        localReceiverPort: 43210,
        remoteReceiverPort: nil,
        ssh: nil,
        codexHomeOverride: nil
    )
    var store = CodexNodeHealthStore()
    store.configure(nodes: [node], now: Date(timeIntervalSince1970: 100))

    store.markHooksConfigured(nodeID: "local-node", detail: "validated config", now: Date(timeIntervalSince1970: 110))

    XCTAssertEqual(store.status(nodeID: "local-node")?.state, .installed)
    XCTAssertEqual(store.status(nodeID: "local-node")?.detail, "validated config")

    store.markEventReceived(CodexHookEvent(
        eventID: "real-event",
        nodeID: "local-node",
        observedAt: Date(timeIntervalSince1970: 120),
        hookEvent: .userPromptSubmit,
        sessionID: "session-1",
        turnID: "turn-1",
        cwd: nil,
        model: "gpt-5",
        toolName: nil
    ), now: Date(timeIntervalSince1970: 121))
    store.markHooksConfigured(nodeID: "local-node", detail: "validated again", now: Date(timeIntervalSince1970: 130))

    XCTAssertEqual(store.status(nodeID: "local-node")?.state, .healthy)
    XCTAssertNil(store.status(nodeID: "local-node")?.detail)
}

func testCodexNodeHealthStoreLetsVerifiedHooksRecoverInstallOrTunnelFailures() throws {
    let node = try CodexNode(
        id: "remote-node",
        name: "远端",
        kind: .remote,
        localReceiverPort: 43210,
        remoteReceiverPort: 53210,
        ssh: SSHNodeConnection(host: "example-host"),
        codexHomeOverride: nil
    )
    var store = CodexNodeHealthStore()
    store.configure(nodes: [node], now: Date(timeIntervalSince1970: 100))

    store.markTunnelFailed(nodeID: "remote-node", detail: "exit 255", now: Date(timeIntervalSince1970: 110))
    store.markHooksConfigured(nodeID: "remote-node", detail: "validated config", now: Date(timeIntervalSince1970: 120))

    XCTAssertEqual(store.status(nodeID: "remote-node")?.state, .installed)
    XCTAssertEqual(store.status(nodeID: "remote-node")?.detail, "validated config")

    store.markInstallFailed(nodeID: "remote-node", detail: "previous failure", now: Date(timeIntervalSince1970: 130))
    store.markHooksConfigured(nodeID: "remote-node", detail: "validated again", now: Date(timeIntervalSince1970: 140))

    XCTAssertEqual(store.status(nodeID: "remote-node")?.state, .installed)
    XCTAssertEqual(store.status(nodeID: "remote-node")?.detail, "validated again")
}

func testCodexNodeHealthStoreUpdatesInstallAndWaitingDetailsAfterVerification() throws {
    let node = try CodexNode(
        id: "local-node",
        name: "本机",
        kind: .local,
        localReceiverPort: 43210,
        remoteReceiverPort: nil,
        ssh: nil,
        codexHomeOverride: nil
    )
    var store = CodexNodeHealthStore()
    store.configure(nodes: [node], now: Date(timeIntervalSince1970: 100))

    store.markHooksConfigured(nodeID: "local-node", detail: "validated once", now: Date(timeIntervalSince1970: 110))
    store.markHooksConfigured(nodeID: "local-node", detail: "validated twice", now: Date(timeIntervalSince1970: 120))

    XCTAssertEqual(store.status(nodeID: "local-node")?.state, .installed)
    XCTAssertEqual(store.status(nodeID: "local-node")?.detail, "validated twice")

    store.markHooksInstalled(nodeID: "local-node", detail: "waiting for trust", now: Date(timeIntervalSince1970: 130))
    store.markHooksConfigured(nodeID: "local-node", detail: "verified while waiting", now: Date(timeIntervalSince1970: 140))

    XCTAssertEqual(store.status(nodeID: "local-node")?.state, .waitingForTrust)
    XCTAssertEqual(store.status(nodeID: "local-node")?.detail, "verified while waiting")
}

func testCodexNodeHealthStoreUsesSyntheticTestEventOnlyForIngressHealth() throws {
    let receiverFailed = CodexHookEvent(
        eventID: "receiver-test-event",
        nodeID: "receiver-node",
        observedAt: Date(timeIntervalSince1970: 120),
        hookEvent: .userPromptSubmit,
        sessionID: "sub2api-statusbar-test-session",
        turnID: "sub2api-statusbar-test-turn-120",
        cwd: nil,
        model: "test",
        toolName: nil
    )
    let tunnelFailed = CodexHookEvent(
        eventID: "remote-test-event",
        nodeID: "remote-node",
        observedAt: Date(timeIntervalSince1970: 121),
        hookEvent: .userPromptSubmit,
        sessionID: "sub2api-statusbar-remote-test-session",
        turnID: "sub2api-statusbar-remote-test-turn-121",
        cwd: nil,
        model: "test",
        toolName: nil
    )
    let installFailed = CodexHookEvent(
        eventID: "install-test-event",
        nodeID: "install-node",
        observedAt: Date(timeIntervalSince1970: 122),
        hookEvent: .userPromptSubmit,
        sessionID: "sub2api-statusbar-test-session",
        turnID: "sub2api-statusbar-test-turn-122",
        cwd: nil,
        model: "test",
        toolName: nil
    )
    var store = CodexNodeHealthStore()

    store.markInstallFailed(nodeID: "receiver-node", state: .receiverFailed, detail: "address in use", now: Date(timeIntervalSince1970: 100))
    store.markTunnelFailed(nodeID: "remote-node", detail: "exit 255", now: Date(timeIntervalSince1970: 101))
    store.markInstallFailed(nodeID: "install-node", detail: "write failed", now: Date(timeIntervalSince1970: 102))

    store.markEventReceived(receiverFailed, now: Date(timeIntervalSince1970: 130))
    store.markEventReceived(tunnelFailed, now: Date(timeIntervalSince1970: 131))
    store.markEventReceived(installFailed, now: Date(timeIntervalSince1970: 132))

    XCTAssertEqual(store.status(nodeID: "receiver-node")?.state, .unconfigured)
    XCTAssertNil(store.status(nodeID: "receiver-node")?.detail)
    XCTAssertEqual(store.status(nodeID: "receiver-node")?.lastTestEventAt, Date(timeIntervalSince1970: 120))
    XCTAssertEqual(store.status(nodeID: "remote-node")?.state, .unconfigured)
    XCTAssertNil(store.status(nodeID: "remote-node")?.detail)
    XCTAssertEqual(store.status(nodeID: "remote-node")?.lastTestEventAt, Date(timeIntervalSince1970: 121))
    XCTAssertEqual(store.status(nodeID: "install-node")?.state, .installFailed)
    XCTAssertEqual(store.status(nodeID: "install-node")?.detail, "write failed")
    XCTAssertEqual(store.status(nodeID: "install-node")?.lastTestEventAt, Date(timeIntervalSince1970: 122))
}

func testSSHTunnelCommandBuilderBindsRemoteLoopbackToLocalReceiver() throws {
    let node = try CodexNode(
        id: "remote-node",
        name: "远端",
        kind: .remote,
        localReceiverPort: 43210,
        remoteReceiverPort: 53210,
        ssh: SSHNodeConnection(host: "example-host", user: "deploy", port: 2222, identityFile: "~/.ssh/id_ed25519"),
        codexHomeOverride: nil
    )

    let command = try SSHTunnelCommandBuilder.buildCommand(for: node)

    XCTAssertEqual(command.executable, "/usr/bin/ssh")
    XCTAssertEqual(command.arguments, [
        "-N",
        "-o", "ExitOnForwardFailure=yes",
        "-o", "ServerAliveInterval=15",
        "-o", "ServerAliveCountMax=2",
        "-p", "2222",
        "-i", "~/.ssh/id_ed25519",
        "-R", "127.0.0.1:53210:127.0.0.1:43210",
        "deploy@example-host",
    ])
}

func testSSHTunnelManagerStartsStopsAndReportsRemoteTunnelState() throws {
    let node = try CodexNode(
        id: "remote-node",
        name: "远端",
        kind: .remote,
        localReceiverPort: 43210,
        remoteReceiverPort: 53210,
        ssh: SSHNodeConnection(host: "example-host", user: "deploy", port: 2222, identityFile: "~/.ssh/id_ed25519"),
        codexHomeOverride: nil
    )
    let launcher = StubSSHTunnelProcessLauncher()
    let clock = TestClock(Date(timeIntervalSince1970: 100))
    let manager = SSHTunnelManager(
        launcher: launcher,
        startupGraceInterval: 1,
        now: { clock.now }
    )

    let status = try manager.start(node: node)

    XCTAssertEqual(launcher.launchedCommands.count, 1)
    XCTAssertEqual(status.state, .starting)
    XCTAssertEqual(manager.status(nodeID: "remote-node")?.state, .starting)

    clock.now = Date(timeIntervalSince1970: 101.1)
    XCTAssertEqual(manager.status(nodeID: "remote-node")?.state, .running)

    launcher.nextHandle.isRunning = false
    launcher.nextHandle.terminationStatus = 255
    XCTAssertEqual(manager.status(nodeID: "remote-node")?.state, .failed(exitCode: 255))

    manager.stop(nodeID: "remote-node")
    XCTAssertEqual(launcher.nextHandle.terminateCallCount, 1)
    XCTAssertNil(manager.status(nodeID: "remote-node"))
}

func testSSHTunnelManagerEnsureStartedReusesRunningTunnelAndRestartsFailedTunnel() throws {
    let node = try CodexNode(
        id: "remote-node",
        name: "远端",
        kind: .remote,
        localReceiverPort: 43210,
        remoteReceiverPort: 53210,
        ssh: SSHNodeConnection(host: "example-host", user: "deploy", port: 2222, identityFile: "~/.ssh/id_ed25519"),
        codexHomeOverride: nil
    )
    let launcher = StubSSHTunnelProcessLauncher()
    let clock = TestClock(Date(timeIntervalSince1970: 100))
    let manager = SSHTunnelManager(
        launcher: launcher,
        startupGraceInterval: 1,
        now: { clock.now }
    )

    let starting = try manager.ensureStarted(node: node)
    let reusedStarting = try manager.ensureStarted(node: node)

    XCTAssertEqual(starting.state, .starting)
    XCTAssertEqual(reusedStarting.state, .starting)
    XCTAssertEqual(launcher.launchedCommands.count, 1)

    clock.now = Date(timeIntervalSince1970: 101.2)
    let running = try manager.ensureStarted(node: node)

    XCTAssertEqual(running.state, .running)
    XCTAssertEqual(launcher.launchedCommands.count, 1)

    launcher.nextHandle.isRunning = false
    launcher.nextHandle.terminationStatus = 255
    launcher.nextHandle = StubSSHTunnelProcessHandle()

    let restarted = try manager.ensureStarted(node: node)

    XCTAssertEqual(restarted.state, .starting)
    XCTAssertEqual(launcher.launchedCommands.count, 2)
}

func testSSHTunnelManagerReportsImmediateExitDuringStartupGraceWindow() throws {
    let node = try CodexNode(
        id: "remote-node",
        name: "远端",
        kind: .remote,
        localReceiverPort: 43210,
        remoteReceiverPort: 53210,
        ssh: SSHNodeConnection(host: "example-host", user: "deploy", port: 2222, identityFile: "~/.ssh/id_ed25519"),
        codexHomeOverride: nil
    )
    let launcher = StubSSHTunnelProcessLauncher()
    launcher.nextHandle = StubSSHTunnelProcessHandle(isRunning: false, terminationStatus: 255)
    let clock = TestClock(Date(timeIntervalSince1970: 100))
    let manager = SSHTunnelManager(
        launcher: launcher,
        startupGraceInterval: 1,
        now: { clock.now }
    )

    let status = try manager.start(node: node)

    XCTAssertEqual(status.state, .failed(exitCode: 255))
    XCTAssertEqual(manager.status(nodeID: "remote-node")?.state, .failed(exitCode: 255))
}

func testSSHTunnelManagerIncludesFailedProcessStandardErrorInStatusDetail() throws {
    let node = try CodexNode(
        id: "remote-node",
        name: "远端",
        kind: .remote,
        localReceiverPort: 43210,
        remoteReceiverPort: 53210,
        ssh: SSHNodeConnection(host: "example-host", user: "deploy", port: 2222, identityFile: "~/.ssh/id_ed25519"),
        codexHomeOverride: nil
    )
    let launcher = StubSSHTunnelProcessLauncher()
    launcher.nextHandle = StubSSHTunnelProcessHandle(
        isRunning: false,
        terminationStatus: 255,
        standardError: "Error: remote port forwarding failed for listen port 53210\n"
    )
    let manager = SSHTunnelManager(launcher: launcher, startupGraceInterval: 1)

    let status = try manager.start(node: node)

    XCTAssertEqual(status.state, .failed(exitCode: 255))
    XCTAssertEqual(status.detail, "Error: remote port forwarding failed for listen port 53210")
    XCTAssertEqual(manager.status(nodeID: "remote-node")?.detail, "Error: remote port forwarding failed for listen port 53210")
}

func testSSHTunnelManagerStopAllTerminatesManagedTunnels() throws {
    let node = try CodexNode(
        id: "remote-node",
        name: "远端",
        kind: .remote,
        localReceiverPort: 43210,
        remoteReceiverPort: 53210,
        ssh: SSHNodeConnection(host: "example-host", user: "deploy", port: 2222, identityFile: nil),
        codexHomeOverride: nil
    )
    let launcher = StubSSHTunnelProcessLauncher()
    let manager = SSHTunnelManager(launcher: launcher, startupGraceInterval: 1)

    _ = try manager.start(node: node)
    manager.stopAll()

    XCTAssertEqual(launcher.nextHandle.terminateCallCount, 1)
    XCTAssertNil(manager.status(nodeID: "remote-node"))
}

func testCodexRemoteTestEventTunnelGateUsesRunningTunnelImmediately() throws {
    let status = SSHTunnelStatus(
        nodeID: "remote-node",
        command: ProcessCommand(executable: "/usr/bin/ssh", arguments: []),
        state: .running
    )

    XCTAssertEqual(CodexRemoteTestEventTunnelGate.decideBeforeSending(currentStatus: status), .ready)
    XCTAssertEqual(CodexRemoteTestEventTunnelGate.decideAfterStart(startStatus: status), .ready)
    XCTAssertEqual(CodexRemoteTestEventTunnelGate.decideAfterWait(waitedStatus: status), .ready)
}

func testCodexRemoteTestEventTunnelGateStartsWhenMissingOrFailedBeforeSending() throws {
    let failedStatus = SSHTunnelStatus(
        nodeID: "remote-node",
        command: ProcessCommand(executable: "/usr/bin/ssh", arguments: []),
        state: .failed(exitCode: 255)
    )

    XCTAssertEqual(CodexRemoteTestEventTunnelGate.decideBeforeSending(currentStatus: nil), .startTunnel)
    XCTAssertEqual(CodexRemoteTestEventTunnelGate.decideBeforeSending(currentStatus: failedStatus), .startTunnel)
}

func testCodexRemoteTestEventTunnelGateWaitsForStartingTunnelBeforeSending() throws {
    let startingStatus = SSHTunnelStatus(
        nodeID: "remote-node",
        command: ProcessCommand(executable: "/usr/bin/ssh", arguments: []),
        state: .starting
    )

    XCTAssertEqual(CodexRemoteTestEventTunnelGate.decideBeforeSending(currentStatus: startingStatus), .waitForRunning)
    XCTAssertEqual(
        CodexRemoteTestEventTunnelGate.decideAfterStart(startStatus: startingStatus),
        .notReady(.stillStarting)
    )
}

func testCodexRemoteTestEventTunnelGateRejectsUnconfirmedTunnelAfterWait() throws {
    let startingStatus = SSHTunnelStatus(
        nodeID: "remote-node",
        command: ProcessCommand(executable: "/usr/bin/ssh", arguments: []),
        state: .starting
    )
    let failedStatus = SSHTunnelStatus(
        nodeID: "remote-node",
        command: ProcessCommand(executable: "/usr/bin/ssh", arguments: []),
        state: .failed(exitCode: 255)
    )

    XCTAssertEqual(
        CodexRemoteTestEventTunnelGate.decideAfterWait(waitedStatus: nil),
        .notReady(.missingStatus)
    )
    XCTAssertEqual(
        CodexRemoteTestEventTunnelGate.decideAfterWait(waitedStatus: startingStatus),
        .notReady(.stillStarting)
    )
    XCTAssertEqual(
        CodexRemoteTestEventTunnelGate.decideAfterWait(waitedStatus: failedStatus),
        .notReady(.failed(exitCode: 255))
    )
}

func testCodexRemoteTestEventTunnelGateRejectsFailedTunnelAfterStart() throws {
    let failedStatus = SSHTunnelStatus(
        nodeID: "remote-node",
        command: ProcessCommand(executable: "/usr/bin/ssh", arguments: []),
        state: .failed(exitCode: 255)
    )

    XCTAssertEqual(
        CodexRemoteTestEventTunnelGate.decideAfterStart(startStatus: failedStatus),
        .notReady(.failed(exitCode: 255))
    )
    XCTAssertEqual(
        CodexRemoteTestEventTunnelNotReadyReason.failed(exitCode: 255).statusDescription,
        "exit 255"
    )
}

func testCodexRemoteTunnelPathProbePolicyOnlyProbesRunningTunnelAfterInterval() throws {
    let runningStatus = SSHTunnelStatus(
        nodeID: "remote-node",
        command: ProcessCommand(executable: "/usr/bin/ssh", arguments: []),
        state: .running
    )
    let startingStatus = SSHTunnelStatus(
        nodeID: "remote-node",
        command: ProcessCommand(executable: "/usr/bin/ssh", arguments: []),
        state: .starting
    )
    let now = Date(timeIntervalSince1970: 200)

    XCTAssertTrue(CodexRemoteTunnelPathProbePolicy.shouldProbe(
        status: runningStatus,
        lastProbeAt: nil,
        now: now,
        minimumInterval: 60
    ))
    XCTAssertFalse(CodexRemoteTunnelPathProbePolicy.shouldProbe(
        status: startingStatus,
        lastProbeAt: nil,
        now: now,
        minimumInterval: 60
    ))
    XCTAssertFalse(CodexRemoteTunnelPathProbePolicy.shouldProbe(
        status: runningStatus,
        lastProbeAt: Date(timeIntervalSince1970: 170),
        now: now,
        minimumInterval: 60
    ))
    XCTAssertTrue(CodexRemoteTunnelPathProbePolicy.shouldProbe(
        status: runningStatus,
        lastProbeAt: Date(timeIntervalSince1970: 120),
        now: now,
        minimumInterval: 60
    ))
}

func testCodexHookInstallerBuildsLocalDryRunPlan() throws {
    let node = try CodexNode(
        id: "local-node",
        name: "本机",
        kind: .local,
        localReceiverPort: 43210,
        remoteReceiverPort: nil,
        ssh: nil,
        codexHomeOverride: "/Users/tester/.codex"
    )

    let plan = try CodexHookInstallerPlanBuilder.buildDryRun(
        node: node,
        codexHome: CodexHomeResolution(codexHomePath: "/Users/tester/.codex", configPath: "/Users/tester/.codex/config.toml"),
        existingConfig: #"model = "gpt-5""#,
        senderExecutablePayload: CodexHookSenderScript.payload,
        senderExecutableInstallPath: "/Users/tester/Library/Application Support/Sub2APIStatusBar/sub2api-statusbar-hook-sender",
        nodeConfigPath: "/Users/tester/.sub2api-statusbar/codex-hook-node.json",
        nodeSecret: "node-secret",
        timestamp: ISO8601DateFormatter().date(from: "2026-06-01T09:00:00Z")!
    )

    XCTAssertEqual(plan.kind, .local)
    XCTAssertEqual(plan.codexConfigPath, "/Users/tester/.codex/config.toml")
    XCTAssertEqual(plan.codexConfigBackupPath, "/Users/tester/.codex/config.toml.sub2api-statusbar.20260601T090000Z.bak")
    XCTAssertEqual(plan.nodeConfigPath, "/Users/tester/.sub2api-statusbar/codex-hook-node.json")
    XCTAssertEqual(plan.senderExecutableInstallPath, "/Users/tester/Library/Application Support/Sub2APIStatusBar/sub2api-statusbar-hook-sender")
    XCTAssert(String(data: plan.senderExecutablePayload, encoding: .utf8)?.contains("#!/usr/bin/env python3") == true)
    XCTAssert(plan.updatedCodexConfig.contains("hooks = true"))
    XCTAssert(plan.updatedCodexConfig.contains("'/Users/tester/Library/Application Support/Sub2APIStatusBar/sub2api-statusbar-hook-sender' '--managed-by' 'Sub2APIStatusBar' '--event' 'UserPromptSubmit' '--config' '/Users/tester/.sub2api-statusbar/codex-hook-node.json'"))
    XCTAssert(plan.nodeConfigJSON.contains("\"nodeId\" : \"local-node\""))
    XCTAssert(plan.nodeConfigJSON.contains("\"receiverUrl\" : \"http:\\/\\/127.0.0.1:43210\\/codex-hooks\\/events\""))
    XCTAssert(plan.nodeConfigJSON.contains("\"secret\" : \"node-secret\""))
    XCTAssertNoThrow(try CodexHookConfigValidator.validateManagedHooks(plan.updatedCodexConfig))
    XCTAssertNil(plan.sshTunnelCommand)
}

func testCodexHookInstallerBuildsRemoteDryRunPlanWithTunnelCommand() throws {
    let node = try CodexNode(
        id: "remote-node",
        name: "远端",
        kind: .remote,
        localReceiverPort: 43210,
        remoteReceiverPort: 53210,
        ssh: SSHNodeConnection(host: "example-host", user: "deploy", port: 2222, identityFile: "~/.ssh/id_ed25519"),
        codexHomeOverride: nil
    )

    let plan = try CodexHookInstallerPlanBuilder.buildDryRun(
        node: node,
        codexHome: CodexHomeResolution(codexHomePath: "/home/deploy/.codex", configPath: "/home/deploy/.codex/config.toml"),
        existingConfig: "",
        senderExecutablePayload: CodexHookSenderScript.payload,
        senderExecutableInstallPath: "/home/deploy/.sub2api-statusbar/sub2api-statusbar-hook-sender",
        nodeConfigPath: "/home/deploy/.sub2api-statusbar/codex-hook-node.json",
        nodeSecret: "remote-secret",
        timestamp: ISO8601DateFormatter().date(from: "2026-06-01T09:00:00Z")!
    )

    XCTAssertEqual(plan.kind, .remote)
    XCTAssertEqual(plan.sshTunnelCommand?.arguments, [
        "-N",
        "-o", "ExitOnForwardFailure=yes",
        "-o", "ServerAliveInterval=15",
        "-o", "ServerAliveCountMax=2",
        "-p", "2222",
        "-i", "~/.ssh/id_ed25519",
        "-R", "127.0.0.1:53210:127.0.0.1:43210",
        "deploy@example-host",
    ])
    XCTAssert(plan.nodeConfigJSON.contains("\"receiverUrl\" : \"http:\\/\\/127.0.0.1:53210\\/codex-hooks\\/events\""))
}

func testCodexHookLocalInstallerWritesNodeConfigBacksUpAndUpdatesCodexConfig() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
    let codexConfigURL = root.appendingPathComponent(".codex/config.toml")
    let nodeConfigURL = root.appendingPathComponent(".sub2api-statusbar/codex-hook-node.json")
    let senderURL = root.appendingPathComponent(".sub2api-statusbar/sub2api-statusbar-hook-sender")
    try FileManager.default.createDirectory(at: codexConfigURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try #"model = "gpt-5""#.write(to: codexConfigURL, atomically: true, encoding: .utf8)
    let node = try CodexNode(
        id: "local-node",
        name: "本机",
        kind: .local,
        localReceiverPort: 43210,
        remoteReceiverPort: nil,
        ssh: nil,
        codexHomeOverride: nil
    )
    let plan = try CodexHookInstallerPlanBuilder.buildDryRun(
        node: node,
        codexHome: CodexHomeResolution(codexHomePath: codexConfigURL.deletingLastPathComponent().path, configPath: codexConfigURL.path),
        existingConfig: #"model = "gpt-5""#,
        senderExecutablePayload: CodexHookSenderScript.payload,
        senderExecutableInstallPath: senderURL.path,
        nodeConfigPath: nodeConfigURL.path,
        nodeSecret: "node-secret",
        timestamp: ISO8601DateFormatter().date(from: "2026-06-01T09:00:00Z")!
    )

    try CodexHookLocalInstaller().apply(plan)

    let updatedConfig = try String(contentsOf: codexConfigURL, encoding: .utf8)
    let backupConfig = try String(contentsOfFile: plan.codexConfigBackupPath, encoding: .utf8)
    let nodeConfig = try String(contentsOf: nodeConfigURL, encoding: .utf8)
    let senderPayload = try String(contentsOf: senderURL, encoding: .utf8)
    XCTAssertEqual(backupConfig, #"model = "gpt-5""#)
    XCTAssert(updatedConfig.contains("hooks = true"))
    XCTAssert(nodeConfig.contains("\"nodeId\" : \"local-node\""))
    XCTAssertEqual(senderPayload, CodexHookSenderScript.source)
    XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: senderURL.path)[.posixPermissions] as? NSNumber, NSNumber(value: Int16(0o700)))
    XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: nodeConfigURL.path)[.posixPermissions] as? NSNumber, NSNumber(value: Int16(0o600)))
}

func testCodexHookLocalInstallerRollsBackSupportFilesWhenCodexConfigWriteFails() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
    let codexConfigURL = root.appendingPathComponent(".codex/config.toml")
    let nodeConfigURL = root.appendingPathComponent(".sub2api-statusbar/codex-hook-node.json")
    let senderURL = root.appendingPathComponent(".sub2api-statusbar/sub2api-statusbar-hook-sender")
    let originalConfig = #"model = "gpt-5""#
    let originalNodeConfig = #"{"nodeId":"old-node"}"#
    let originalSender = "#!/bin/sh\nexit 0\n"
    try FileManager.default.createDirectory(at: codexConfigURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: nodeConfigURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try originalConfig.write(to: codexConfigURL, atomically: true, encoding: .utf8)
    try originalNodeConfig.write(to: nodeConfigURL, atomically: true, encoding: .utf8)
    try originalSender.write(to: senderURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o700))],
        ofItemAtPath: senderURL.path
    )
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o600))],
        ofItemAtPath: nodeConfigURL.path
    )
    let node = try CodexNode(
        id: "local-node",
        name: "本机",
        kind: .local,
        localReceiverPort: 43210,
        remoteReceiverPort: nil,
        ssh: nil,
        codexHomeOverride: nil
    )
    let plan = try CodexHookInstallerPlanBuilder.buildDryRun(
        node: node,
        codexHome: CodexHomeResolution(codexHomePath: codexConfigURL.deletingLastPathComponent().path, configPath: codexConfigURL.path),
        existingConfig: originalConfig,
        senderExecutablePayload: CodexHookSenderScript.payload,
        senderExecutableInstallPath: senderURL.path,
        nodeConfigPath: nodeConfigURL.path,
        nodeSecret: "node-secret",
        timestamp: ISO8601DateFormatter().date(from: "2026-06-01T09:00:00Z")!
    )
    let installer = CodexHookLocalInstaller {
        throw LocalInstallerTestError.forcedCodexConfigWriteFailure
    }

    XCTAssertThrowsError(try installer.apply(plan)) { error in
        XCTAssertEqual(error as? LocalInstallerTestError, .forcedCodexConfigWriteFailure)
    }

    XCTAssertEqual(try String(contentsOf: codexConfigURL, encoding: .utf8), originalConfig)
    XCTAssertEqual(try String(contentsOf: nodeConfigURL, encoding: .utf8), originalNodeConfig)
    XCTAssertEqual(try String(contentsOf: senderURL, encoding: .utf8), originalSender)
    XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: senderURL.path)[.posixPermissions] as? NSNumber, NSNumber(value: Int16(0o700)))
    XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: nodeConfigURL.path)[.posixPermissions] as? NSNumber, NSNumber(value: Int16(0o600)))
}

func testCodexHookLocalInstallerRemovesNewSupportFilesWhenFirstInstallFails() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
    let codexConfigURL = root.appendingPathComponent(".codex/config.toml")
    let nodeConfigURL = root.appendingPathComponent(".sub2api-statusbar/codex-hook-node.json")
    let senderURL = root.appendingPathComponent(".sub2api-statusbar/sub2api-statusbar-hook-sender")
    let originalConfig = #"model = "gpt-5""#
    try FileManager.default.createDirectory(at: codexConfigURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try originalConfig.write(to: codexConfigURL, atomically: true, encoding: .utf8)
    let node = try CodexNode(
        id: "local-node",
        name: "本机",
        kind: .local,
        localReceiverPort: 43210,
        remoteReceiverPort: nil,
        ssh: nil,
        codexHomeOverride: nil
    )
    let plan = try CodexHookInstallerPlanBuilder.buildDryRun(
        node: node,
        codexHome: CodexHomeResolution(codexHomePath: codexConfigURL.deletingLastPathComponent().path, configPath: codexConfigURL.path),
        existingConfig: originalConfig,
        senderExecutablePayload: CodexHookSenderScript.payload,
        senderExecutableInstallPath: senderURL.path,
        nodeConfigPath: nodeConfigURL.path,
        nodeSecret: "node-secret",
        timestamp: ISO8601DateFormatter().date(from: "2026-06-01T09:00:00Z")!
    )
    let installer = CodexHookLocalInstaller {
        throw LocalInstallerTestError.forcedCodexConfigWriteFailure
    }

    XCTAssertThrowsError(try installer.apply(plan)) { error in
        XCTAssertEqual(error as? LocalInstallerTestError, .forcedCodexConfigWriteFailure)
    }

    XCTAssertEqual(try String(contentsOf: codexConfigURL, encoding: .utf8), originalConfig)
    XCTAssertFalse(FileManager.default.fileExists(atPath: nodeConfigURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: senderURL.path))
}

func testCodexHookLocalInstallerGeneratedCommandRunsWithApplicationSupportPath() async throws {
    let port = try availableLoopbackPort()
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
    let codexConfigURL = root.appendingPathComponent(".codex/config.toml")
    let nodeConfigURL = root.appendingPathComponent(".sub2api-statusbar/codex-hook-node.json")
    let senderURL = root.appendingPathComponent("Application Support/Sub2APIStatusBar/sub2api-statusbar-hook-sender")
    try FileManager.default.createDirectory(at: codexConfigURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try #"model = "gpt-5""#.write(to: codexConfigURL, atomically: true, encoding: .utf8)

    let node = try CodexNode(
        id: "local-node",
        name: "本机",
        kind: .local,
        localReceiverPort: Int(port),
        remoteReceiverPort: nil,
        ssh: nil,
        codexHomeOverride: nil
    )
    let plan = try CodexHookInstallerPlanBuilder.buildDryRun(
        node: node,
        codexHome: CodexHomeResolution(codexHomePath: codexConfigURL.deletingLastPathComponent().path, configPath: codexConfigURL.path),
        existingConfig: #"model = "gpt-5""#,
        senderExecutablePayload: CodexHookSenderScript.payload,
        senderExecutableInstallPath: senderURL.path,
        nodeConfigPath: nodeConfigURL.path,
        nodeSecret: "node-secret",
        timestamp: ISO8601DateFormatter().date(from: "2026-06-01T09:00:00Z")!
    )
    try CodexHookLocalInstaller().apply(plan)

    let recorder = await MainActor.run {
        LocalReceiverTestRecorder()
    }
    let server = await MainActor.run {
        LocalCodexHookReceiverServer(
            port: port,
            nodeSecrets: [node.id: "node-secret"],
            onStateChange: { state in
                recorder.append(state: state)
            },
            onEvent: { event in
                recorder.append(event: event)
            }
        )
    }
    try await MainActor.run {
        try server.start()
    }
    defer {
        Task { @MainActor in
            server.stop()
        }
    }
    try await waitForListenerReady(await MainActor.run { recorder.states })

    let updatedConfig = try String(contentsOf: codexConfigURL, encoding: .utf8)
    let command = try managedHookCommand(eventName: "UserPromptSubmit", in: updatedConfig)
    let codexPayload = Data("""
    {
      "session_id": "installed-session",
      "turn_id": "installed-turn",
      "cwd": "/workspace/sub2api-statusbar",
      "model": "gpt-5",
      "user_agent": "Codex Desktop/0.125.0"
    }
    """.utf8)
    let result = try runShellHookCommand(command: command, stdinPayload: codexPayload)

    XCTAssertEqual(result.exitCode, 0, result.standardError)
    XCTAssertEqual(result.standardOutput, "")
    let events = await MainActor.run { recorder.events }
    XCTAssertEqual(events.count, 1)
    XCTAssertEqual(events.first?.nodeID, "local-node")
    XCTAssertEqual(events.first?.hookEvent, .userPromptSubmit)
    XCTAssertEqual(events.first?.sessionID, "installed-session")
    XCTAssertEqual(events.first?.turnID, "installed-turn")
    XCTAssertEqual(events.first?.userAgent, "Codex Desktop/0.125.0")
}

func testCodexHookRemoteInstallerCommandPlanUsesSSHAndDoesNotInlineSecretsInCommand() throws {
    let node = try CodexNode(
        id: "remote-node",
        name: "远端",
        kind: .remote,
        localReceiverPort: 43210,
        remoteReceiverPort: 53210,
        ssh: SSHNodeConnection(host: "example-host", user: "deploy", port: 2222, identityFile: "~/.ssh/id_ed25519"),
        codexHomeOverride: nil
    )
    let installPlan = try CodexHookInstallerPlanBuilder.buildDryRun(
        node: node,
        codexHome: CodexHomeResolution(codexHomePath: "/home/deploy/.codex", configPath: "/home/deploy/.codex/config.toml"),
        existingConfig: "",
        senderExecutablePayload: Data([0x7f, 0x45, 0x4c, 0x46, 0x00, 0xff]),
        senderExecutableInstallPath: "/home/deploy/.sub2api-statusbar/sub2api-statusbar-hook-sender",
        nodeConfigPath: "/home/deploy/.sub2api-statusbar/codex-hook-node.json",
        nodeSecret: "remote-secret",
        timestamp: ISO8601DateFormatter().date(from: "2026-06-01T09:00:00Z")!
    )

    let commandPlan = try CodexHookRemoteInstallerCommandBuilder.buildCommandPlan(for: node, installPlan: installPlan)

    XCTAssertEqual(commandPlan.sshExecutable, "/usr/bin/ssh")
    XCTAssertEqual(commandPlan.sshArguments, ["-p", "2222", "-i", "~/.ssh/id_ed25519", "deploy@example-host", "sh", "-s"])
    XCTAssert(commandPlan.stdinScript.contains("mkdir -p '/home/deploy/.sub2api-statusbar' '/home/deploy/.codex' '/home/deploy/.sub2api-statusbar'"))
    XCTAssert(commandPlan.stdinScript.contains("sender_tmp='/home/deploy/.sub2api-statusbar/sub2api-statusbar-hook-sender.sub2api-statusbar.tmp'"))
    XCTAssert(commandPlan.stdinScript.contains("sender_restore='/home/deploy/.sub2api-statusbar/sub2api-statusbar-hook-sender.sub2api-statusbar.restore'"))
    XCTAssert(commandPlan.stdinScript.contains(": > \"$sender_tmp\""))
    XCTAssert(commandPlan.stdinScript.contains("printf -- '%b' '\\177\\105\\114\\106\\000\\377' >> \"$sender_tmp\""))
    XCTAssert(commandPlan.stdinScript.contains("chmod 700 \"$sender_tmp\""))
    XCTAssert(commandPlan.stdinScript.contains("node_config_tmp='/home/deploy/.sub2api-statusbar/codex-hook-node.json.sub2api-statusbar.tmp'"))
    XCTAssert(commandPlan.stdinScript.contains("node_config_restore='/home/deploy/.sub2api-statusbar/codex-hook-node.json.sub2api-statusbar.restore'"))
    XCTAssert(commandPlan.stdinScript.contains("Codex config path exists but is not a regular file"))
    XCTAssert(commandPlan.stdinScript.contains("Sender install path exists but is not a regular file"))
    XCTAssert(commandPlan.stdinScript.contains("Node config path exists but is not a regular file"))
    XCTAssert(commandPlan.stdinScript.contains(": > \"$node_config_tmp\""))
    XCTAssert(commandPlan.stdinScript.contains("cp '/home/deploy/.codex/config.toml' '/home/deploy/.codex/config.toml.sub2api-statusbar.20260601T090000Z.bak'"))
    XCTAssert(commandPlan.stdinScript.contains("cp -p '/home/deploy/.sub2api-statusbar/sub2api-statusbar-hook-sender' \"$sender_restore\""))
    XCTAssert(commandPlan.stdinScript.contains("cp -p '/home/deploy/.sub2api-statusbar/codex-hook-node.json' \"$node_config_restore\""))
    XCTAssert(commandPlan.stdinScript.contains("chmod 600 \"$node_config_tmp\""))
    XCTAssert(commandPlan.stdinScript.contains("codex_config_tmp='/home/deploy/.codex/config.toml.sub2api-statusbar.tmp'"))
    XCTAssert(commandPlan.stdinScript.contains(": > \"$codex_config_tmp\""))
    XCTAssert(commandPlan.stdinScript.contains("mv -f \"$sender_tmp\" '/home/deploy/.sub2api-statusbar/sub2api-statusbar-hook-sender'"))
    XCTAssert(commandPlan.stdinScript.contains("mv -f \"$node_config_tmp\" '/home/deploy/.sub2api-statusbar/codex-hook-node.json'"))
    XCTAssert(commandPlan.stdinScript.contains("mv -f \"$codex_config_tmp\" '/home/deploy/.codex/config.toml'"))
    XCTAssertFalse(commandPlan.stdinScript.contains("SUB2API_STATUSBAR_NODE_CONFIG"))
    XCTAssertFalse(commandPlan.stdinScript.contains("SUB2API_STATUSBAR_CODEX_CONFIG"))
    XCTAssertFalse(commandPlan.sshArguments.joined(separator: " ").contains("remote-secret"))
    XCTAssert(commandPlan.stdinScript.contains(">> \"$node_config_tmp\""))
}

func testCodexHookRemoteInstallerScriptUsesOptionSafePrintf() throws {
    let node = try CodexNode(
        id: "remote-node",
        name: "远端",
        kind: .remote,
        localReceiverPort: 43210,
        remoteReceiverPort: 53210,
        ssh: SSHNodeConnection(host: "example-host", user: "deploy", port: 2222, identityFile: nil),
        codexHomeOverride: nil
    )
    let installPlan = try CodexHookInstallerPlanBuilder.buildDryRun(
        node: node,
        codexHome: CodexHomeResolution(codexHomePath: "/home/deploy/.codex", configPath: "/home/deploy/.codex/config.toml"),
        existingConfig: "",
        senderExecutablePayload: Data([0x2d, 0x66, 0x6f, 0x6f, 0x0a]),
        senderExecutableInstallPath: "/home/deploy/.sub2api-statusbar/sub2api-statusbar-hook-sender",
        nodeConfigPath: "/home/deploy/.sub2api-statusbar/codex-hook-node.json",
        nodeSecret: "remote-secret",
        timestamp: ISO8601DateFormatter().date(from: "2026-06-01T09:00:00Z")!
    )

    let commandPlan = try CodexHookRemoteInstallerCommandBuilder.buildCommandPlan(for: node, installPlan: installPlan)

    XCTAssert(commandPlan.stdinScript.contains("printf -- '%b' '\\055\\146\\157\\157\\012' >> \"$sender_tmp\""))
    XCTAssertFalse(commandPlan.stdinScript.contains("printf '%b'"))
}

func testCodexHookRemoteInstallerScriptPreservesExistingConfigWhenFinalReplaceFails() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
    let codexConfigURL = root.appendingPathComponent(".codex/config.toml")
    let nodeConfigURL = root.appendingPathComponent(".sub2api-statusbar/codex-hook-node.json")
    let senderURL = root.appendingPathComponent(".sub2api-statusbar/sub2api-statusbar-hook-sender")
    let originalConfig = #"model = "gpt-5""#
    let originalNodeConfig = #"{"nodeId":"old-node"}"#
    let originalSender = "#!/bin/sh\nexit 0\n"
    try FileManager.default.createDirectory(at: codexConfigURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: nodeConfigURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try originalConfig.write(to: codexConfigURL, atomically: true, encoding: .utf8)
    try originalNodeConfig.write(to: nodeConfigURL, atomically: true, encoding: .utf8)
    try originalSender.write(to: senderURL, atomically: true, encoding: .utf8)
    let node = try CodexNode(
        id: "remote-node",
        name: "远端",
        kind: .remote,
        localReceiverPort: 43210,
        remoteReceiverPort: 53210,
        ssh: SSHNodeConnection(host: "example-host", user: "deploy", port: 2222, identityFile: "~/.ssh/id_ed25519"),
        codexHomeOverride: nil
    )
    let installPlan = try CodexHookInstallerPlanBuilder.buildDryRun(
        node: node,
        codexHome: CodexHomeResolution(codexHomePath: codexConfigURL.deletingLastPathComponent().path, configPath: codexConfigURL.path),
        existingConfig: originalConfig,
        senderExecutablePayload: Data([0x23, 0x21, 0x0a]),
        senderExecutableInstallPath: senderURL.path,
        nodeConfigPath: nodeConfigURL.path,
        nodeSecret: "remote-secret",
        timestamp: ISO8601DateFormatter().date(from: "2026-06-01T09:00:00Z")!
    )
    let commandPlan = try CodexHookRemoteInstallerCommandBuilder.buildCommandPlan(for: node, installPlan: installPlan)
    let scriptWithFailedReplace = """
    mv() {
      if [ "$3" = \(shellQuoteForTest(codexConfigURL.path)) ]; then
        return 13
      fi
      command mv "$@"
    }
    \(commandPlan.stdinScript)
    """

    let result = try runShellScript(scriptWithFailedReplace)

    XCTAssertNotEqual(result.exitCode, 0)
    XCTAssertEqual(try String(contentsOf: codexConfigURL, encoding: .utf8), originalConfig)
    XCTAssertEqual(try String(contentsOf: nodeConfigURL, encoding: .utf8), originalNodeConfig)
    XCTAssertEqual(try String(contentsOf: senderURL, encoding: .utf8), originalSender)
    XCTAssertFalse(FileManager.default.fileExists(atPath: senderURL.path + ".sub2api-statusbar.tmp"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: nodeConfigURL.path + ".sub2api-statusbar.tmp"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: codexConfigURL.path + ".sub2api-statusbar.tmp"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: senderURL.path + ".sub2api-statusbar.restore"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: nodeConfigURL.path + ".sub2api-statusbar.restore"))
}

func testCodexHookRemoteInstallerScriptRejectsDirectoryTargetsBeforeWritingSupportFiles() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
    let codexConfigURL = root.appendingPathComponent(".codex/config.toml", isDirectory: true)
    let nodeConfigURL = root.appendingPathComponent(".sub2api-statusbar/codex-hook-node.json")
    let senderURL = root.appendingPathComponent(".sub2api-statusbar/sub2api-statusbar-hook-sender")
    try FileManager.default.createDirectory(at: codexConfigURL, withIntermediateDirectories: true)
    let node = try CodexNode(
        id: "remote-node",
        name: "远端",
        kind: .remote,
        localReceiverPort: 43210,
        remoteReceiverPort: 53210,
        ssh: SSHNodeConnection(host: "example-host", user: "deploy", port: 2222, identityFile: "~/.ssh/id_ed25519"),
        codexHomeOverride: nil
    )
    let installPlan = try CodexHookInstallerPlanBuilder.buildDryRun(
        node: node,
        codexHome: CodexHomeResolution(codexHomePath: codexConfigURL.deletingLastPathComponent().path, configPath: codexConfigURL.path),
        existingConfig: "",
        senderExecutablePayload: Data([0x23, 0x21, 0x0a]),
        senderExecutableInstallPath: senderURL.path,
        nodeConfigPath: nodeConfigURL.path,
        nodeSecret: "remote-secret",
        timestamp: ISO8601DateFormatter().date(from: "2026-06-01T09:00:00Z")!
    )
    let commandPlan = try CodexHookRemoteInstallerCommandBuilder.buildCommandPlan(for: node, installPlan: installPlan)

    let result = try runShellScript(commandPlan.stdinScript)

    XCTAssertNotEqual(result.exitCode, 0)
    XCTAssert(result.standardError.contains("Codex config path exists but is not a regular file"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: nodeConfigURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: senderURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: senderURL.path + ".sub2api-statusbar.tmp"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: nodeConfigURL.path + ".sub2api-statusbar.tmp"))
}

func testCodexHookRemoteInstallerRunsSSHCommandPlanThroughRunner() async throws {
    let node = try CodexNode(
        id: "remote-node",
        name: "远端",
        kind: .remote,
        localReceiverPort: 43210,
        remoteReceiverPort: 53210,
        ssh: SSHNodeConnection(host: "example-host", user: "deploy", port: 2222, identityFile: "~/.ssh/id_ed25519"),
        codexHomeOverride: nil
    )
    let installPlan = try CodexHookInstallerPlanBuilder.buildDryRun(
        node: node,
        codexHome: CodexHomeResolution(codexHomePath: "/home/deploy/.codex", configPath: "/home/deploy/.codex/config.toml"),
        existingConfig: "",
        senderExecutablePayload: CodexHookSenderScript.payload,
        senderExecutableInstallPath: "/home/deploy/.sub2api-statusbar/sub2api-statusbar-hook-sender",
        nodeConfigPath: "/home/deploy/.sub2api-statusbar/codex-hook-node.json",
        nodeSecret: "remote-secret",
        timestamp: ISO8601DateFormatter().date(from: "2026-06-01T09:00:00Z")!
    )
    let runner = RecordingCodexHookRemoteInstallRunner()
    let configReader = RecordingCodexHookRemoteConfigReader()
    let installer = CodexHookRemoteInstaller(runner: runner, configReader: configReader)

    let remoteConfig = try await installer.readExistingConfig(node: node, codexConfigPath: "/home/deploy/.codex/config.toml")

    let result = try await installer.apply(node: node, plan: installPlan)

    XCTAssertEqual(remoteConfig.standardOutput, #"model = "gpt-5""#)
    XCTAssertEqual(configReader.receivedPlans.count, 1)
    let readConfigCommand = "if [ -f \(shellQuoteForTest("/home/deploy/.codex/config.toml")) ]; then cat \(shellQuoteForTest("/home/deploy/.codex/config.toml")); elif [ -e \(shellQuoteForTest("/home/deploy/.codex/config.toml")) ]; then echo \(shellQuoteForTest("Codex config path exists but is not a regular file")) >&2; exit 66; fi"
    XCTAssertEqual(configReader.receivedPlans.first?.sshArguments, [
        "-p", "2222",
        "-i", "~/.ssh/id_ed25519",
        "deploy@example-host",
        "sh -lc \(shellQuoteForTest(readConfigCommand))",
    ])
    XCTAssertEqual(result.exitCode, 0)
    XCTAssertEqual(runner.receivedPlans.count, 1)
    XCTAssertEqual(runner.receivedPlans.first?.sshArguments, ["-p", "2222", "-i", "~/.ssh/id_ed25519", "deploy@example-host", "sh", "-s"])
    XCTAssertFalse(runner.receivedPlans.first?.sshArguments.joined(separator: " ").contains("remote-secret") ?? true)
}

func testCodexHookRemoteInstallerBuildsCodexHomeEnvironmentReadCommand() throws {
    let node = try CodexNode(
        id: "remote-node",
        name: "远端",
        kind: .remote,
        localReceiverPort: 43210,
        remoteReceiverPort: 53210,
        ssh: SSHNodeConnection(host: "example-host", user: "deploy", port: 2222, identityFile: "~/.ssh/id_ed25519"),
        codexHomeOverride: nil
    )

    let commandPlan = try CodexHookRemoteInstallerCommandBuilder.buildReadCodexHomeCommandPlan(for: node)

    XCTAssertEqual(commandPlan.sshExecutable, "/usr/bin/ssh")
    let readEnvironmentCommand = "printf -- '%s%s\\n%s%s\\n' \(shellQuoteForTest(CodexRemoteEnvironment.codexHomeOutputPrefix)) \"${CODEX_HOME:-}\" \(shellQuoteForTest(CodexRemoteEnvironment.homeDirectoryOutputPrefix)) \"${HOME:-}\""
    XCTAssertEqual(commandPlan.sshArguments, [
        "-p", "2222",
        "-i", "~/.ssh/id_ed25519",
        "deploy@example-host",
        "shell_path=${SHELL:-/bin/sh}; exec \"$shell_path\" -ic \(shellQuoteForTest(readEnvironmentCommand))",
    ])
}

func testCodexHookRemoteInstallerReadCodexHomeCommandUsesRemoteInteractiveShell() throws {
    let node = try CodexNode(
        id: "remote-node",
        name: "远端",
        kind: .remote,
        localReceiverPort: 43210,
        remoteReceiverPort: 53210,
        ssh: SSHNodeConnection(host: "example-host", user: "deploy", port: 2222, identityFile: nil),
        codexHomeOverride: nil
    )
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
    let fakeShellURL = root.appendingPathComponent("remote-user-shell")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try """
    #!/bin/sh
    if [ "$1" != "-ic" ]; then
      exit 64
    fi
    CODEX_HOME=/interactive/codex HOME=/interactive/home /bin/sh -c "$2"
    """.write(to: fakeShellURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeShellURL.path)
    let commandPlan = try CodexHookRemoteInstallerCommandBuilder.buildReadCodexHomeCommandPlan(for: node)
    let remoteCommand = Array(commandPlan.sshArguments.drop { $0 != "deploy@example-host" }.dropFirst())
        .joined(separator: " ")

    let result = try runShellCommand(
        remoteCommand,
        environment: [
            "CODEX_HOME": "/non-interactive/codex",
            "HOME": "/non-interactive/home",
            "SHELL": fakeShellURL.path,
        ]
    )

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertEqual(result.standardOutput, """
    \(CodexRemoteEnvironment.codexHomeOutputPrefix)/interactive/codex
    \(CodexRemoteEnvironment.homeDirectoryOutputPrefix)/interactive/home

    """)
    XCTAssertEqual(result.standardError, "")
}

func testCodexHookRemoteInstallerBuildsStrictConfigReadCommand() throws {
    let node = try CodexNode(
        id: "remote-node",
        name: "远端",
        kind: .remote,
        localReceiverPort: 43210,
        remoteReceiverPort: 53210,
        ssh: SSHNodeConnection(host: "example-host", user: "deploy", port: 2222, identityFile: "~/.ssh/id_ed25519"),
        codexHomeOverride: nil
    )

    let commandPlan = try CodexHookRemoteInstallerCommandBuilder.buildReadConfigCommandPlan(
        for: node,
        codexConfigPath: "/home/deploy/.codex/config.toml"
    )

    XCTAssertEqual(commandPlan.sshExecutable, "/usr/bin/ssh")
    let readConfigCommand = "if [ -f \(shellQuoteForTest("/home/deploy/.codex/config.toml")) ]; then cat \(shellQuoteForTest("/home/deploy/.codex/config.toml")); elif [ -e \(shellQuoteForTest("/home/deploy/.codex/config.toml")) ]; then echo \(shellQuoteForTest("Codex config path exists but is not a regular file")) >&2; exit 66; fi"
    XCTAssertEqual(commandPlan.sshArguments, [
        "-p", "2222",
        "-i", "~/.ssh/id_ed25519",
        "deploy@example-host",
        "sh -lc \(shellQuoteForTest(readConfigCommand))",
    ])
}

func testCodexHookRemoteTestEventBuildsSSHCommandWithoutSecretInArguments() throws {
    let node = try CodexNode(
        id: "remote-node",
        name: "远端",
        kind: .remote,
        localReceiverPort: 43210,
        remoteReceiverPort: 53210,
        ssh: SSHNodeConnection(host: "example-host", user: "deploy", port: 2222, identityFile: "~/.ssh/id_ed25519"),
        codexHomeOverride: nil
    )
    let registeredNode = CodexRegisteredNode(node: node, secret: "remote-secret")

    let commandPlan = try CodexHookRemoteTestEventCommandBuilder.buildCommandPlan(registeredNode: registeredNode)

    XCTAssertEqual(commandPlan.sshExecutable, "/usr/bin/ssh")
    XCTAssertEqual(commandPlan.sshArguments, [
        "-p", "2222",
        "-i", "~/.ssh/id_ed25519",
        "deploy@example-host",
        "python3",
        "-",
    ])
    XCTAssertFalse(commandPlan.sshArguments.joined(separator: " ").contains("remote-secret"))
    XCTAssert(commandPlan.stdinScript.contains(#"receiver_url = "http://127.0.0.1:53210/codex-hooks/events""#))
    XCTAssert(commandPlan.stdinScript.contains(#"node_id = "remote-node""#))
    XCTAssert(commandPlan.stdinScript.contains("sub2api-statusbar-remote-test-session"))
}

func testCodexHookRemoteTestEventServiceRunsRemoteScriptThroughSSHRunner() async throws {
    let port = try availableLoopbackPort()
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
    let fakeSSHURL = root.appendingPathComponent("fake-ssh")
    try writeFakeSSHExecutable(at: fakeSSHURL)

    let node = try CodexNode(
        id: "remote-node",
        name: "远端",
        kind: .remote,
        localReceiverPort: Int(port),
        remoteReceiverPort: Int(port),
        ssh: SSHNodeConnection(host: "example-host", user: "deploy", port: 2222, identityFile: "~/.ssh/id_ed25519"),
        codexHomeOverride: nil
    )
    let registeredNode = CodexRegisteredNode(node: node, secret: "remote-secret")
    let recorder = await MainActor.run {
        LocalReceiverTestRecorder()
    }
    let server = await MainActor.run {
        LocalCodexHookReceiverServer(
            port: port,
            nodeSecrets: [node.id: registeredNode.secret],
            onStateChange: { state in
                recorder.append(state: state)
            },
            onEvent: { event in
                recorder.append(event: event)
            }
        )
    }
    try await MainActor.run {
        try server.start()
    }
    defer {
        Task { @MainActor in
            server.stop()
        }
    }
    try await waitForListenerReady(await MainActor.run { recorder.states })

    let service = CodexHookRemoteTestEventService()
    let result = try await service.send(registeredNode: registeredNode, sshExecutable: fakeSSHURL.path)

    XCTAssertEqual(result.exitCode, 0, result.standardError)
    XCTAssert(result.standardOutput.contains("remote test event accepted"))
    let events = await MainActor.run { recorder.events }
    XCTAssertEqual(events.count, 1)
    XCTAssertEqual(events.first?.nodeID, "remote-node")
    XCTAssertEqual(events.first?.hookEvent, .userPromptSubmit)
    XCTAssertEqual(events.first?.sessionID, "sub2api-statusbar-remote-test-session")
    XCTAssertEqual(events.first?.turnID.hasPrefix("sub2api-statusbar-remote-test-turn-"), true)
    XCTAssertEqual(events.first?.model, "test")
}

func testCodexHookRemoteTestEventServiceReportsReceiverHTTPRejection() async throws {
    let port = try availableLoopbackPort()
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
    let fakeSSHURL = root.appendingPathComponent("fake-ssh")
    try writeFakeSSHExecutable(at: fakeSSHURL)

    let node = try CodexNode(
        id: "remote-node",
        name: "远端",
        kind: .remote,
        localReceiverPort: Int(port),
        remoteReceiverPort: Int(port),
        ssh: SSHNodeConnection(host: "example-host", user: "deploy", port: 2222, identityFile: "~/.ssh/id_ed25519"),
        codexHomeOverride: nil
    )
    let registeredNode = CodexRegisteredNode(node: node, secret: "client-secret")
    let recorder = await MainActor.run {
        LocalReceiverTestRecorder()
    }
    let server = await MainActor.run {
        LocalCodexHookReceiverServer(
            port: port,
            nodeSecrets: [node.id: "server-secret"],
            onStateChange: { state in
                recorder.append(state: state)
            },
            onEvent: { event in
                recorder.append(event: event)
            }
        )
    }
    try await MainActor.run {
        try server.start()
    }
    defer {
        Task { @MainActor in
            server.stop()
        }
    }
    try await waitForListenerReady(await MainActor.run { recorder.states })

    let service = CodexHookRemoteTestEventService()
    let result = try await service.send(registeredNode: registeredNode, sshExecutable: fakeSSHURL.path)

    XCTAssertEqual(result.exitCode, 66)
    XCTAssert(result.standardError.contains("S2SB_REMOTE_TEST_EVENT_HTTP_401"), result.standardError)
    let failure = CodexHookTestEventFailureClassifier.classifyRemoteResult(result)
    XCTAssertEqual(failure.kind, .invalidSignature)
    XCTAssertEqual(failure.detail, "HTTP 401")
    let events = await MainActor.run { recorder.events }
    XCTAssertEqual(events, [])
}

func testCodexHookTestEventFailureClassifierMapsHTTPAndTransportFailures() {
    XCTAssertEqual(CodexHookTestEventFailureClassifier.classifyLocalHTTPStatus(400).kind, .receiverRejected)
    XCTAssertEqual(CodexHookTestEventFailureClassifier.classifyLocalHTTPStatus(401).kind, .invalidSignature)
    XCTAssertEqual(CodexHookTestEventFailureClassifier.classifyLocalHTTPStatus(409).kind, .replayRejected)
    XCTAssertEqual(CodexHookTestEventFailureClassifier.classifyLocalHTTPStatus(503).kind, .receiverUnavailable)

    let remoteHTTP = CodexHookRemoteInstallResult(
        exitCode: 66,
        standardOutput: "",
        standardError: "S2SB_REMOTE_TEST_EVENT_HTTP_409\n"
    )
    let remoteTransport = CodexHookRemoteInstallResult(
        exitCode: 67,
        standardOutput: "",
        standardError: "S2SB_REMOTE_TEST_EVENT_TRANSPORT <urlopen error>"
    )

    XCTAssertEqual(CodexHookTestEventFailureClassifier.classifyRemoteResult(remoteHTTP), CodexHookTestEventFailure(kind: .replayRejected, detail: "HTTP 409"))
    XCTAssertEqual(CodexHookTestEventFailureClassifier.classifyRemoteResult(remoteTransport).kind, .transportFailed)
}

func testCodexHookConfigWriterAddsFeatureAndManagedHooksWithoutDroppingUserHooks() throws {
    let existing = """
    model = "gpt-5"

    [[hooks.UserPromptSubmit]]
    [[hooks.UserPromptSubmit.hooks]]
    type = "command"
    command = "/usr/bin/python3 /Users/tester/custom.py"
    timeout = 30
    statusMessage = "Custom hook"
    """

    let updated = try CodexHookConfigWriter.renderConfig(
        existingConfig: existing,
        senderCommand: "/Users/tester/Library/Application Support/Sub2APIStatusBar/sub2api-statusbar-hook-sender",
        nodeConfigPath: "/Users/tester/.sub2api-statusbar/codex-hook-node.json",
        timeoutSeconds: 5
    )

    XCTAssert(updated.contains("model = \"gpt-5\""))
    XCTAssert(updated.contains("command = \"/usr/bin/python3 /Users/tester/custom.py\""))
    XCTAssert(updated.contains("[features]"))
    XCTAssert(updated.contains("hooks = true"))
    XCTAssert(updated.contains("'/Users/tester/Library/Application Support/Sub2APIStatusBar/sub2api-statusbar-hook-sender' '--managed-by' 'Sub2APIStatusBar' '--event' 'UserPromptSubmit' '--config' '/Users/tester/.sub2api-statusbar/codex-hook-node.json'"))
    XCTAssertFalse(updated.contains("[[hooks.SessionStart]]"))
    XCTAssertFalse(updated.contains("'--event' 'SessionStart'"))
    XCTAssert(updated.contains("[[hooks.PermissionRequest]]"))
    XCTAssert(updated.contains("[[hooks.PreCompact]]"))
    XCTAssert(updated.contains("[[hooks.PostCompact]]"))
    XCTAssert(updated.contains("[[hooks.SubagentStart]]"))
    XCTAssert(updated.contains("'--event' 'PermissionRequest'"))
    XCTAssert(updated.contains("'--event' 'PreCompact'"))
    XCTAssert(updated.contains("'--event' 'PostCompact'"))
    XCTAssert(updated.contains("'--event' 'SubagentStart'"))
    XCTAssert(updated.contains("statusMessage = \"Sub2APIStatusBar task monitor\""))
    XCTAssertNoThrow(try CodexHookConfigValidator.validateManagedHooks(updated))
}

func testCodexHookConfigValidatorRequiresExpectedNodeConfigPathWhenProvided() throws {
    let updated = try CodexHookConfigWriter.renderConfig(
        existingConfig: "",
        senderCommand: "/new/sender",
        nodeConfigPath: "/Users/tester/.sub2api-statusbar/codex-hook-node-local.json",
        timeoutSeconds: 5
    )

    XCTAssertNoThrow(try CodexHookConfigValidator.validateManagedHooks(
        updated,
        expectedNodeConfigPath: "/Users/tester/.sub2api-statusbar/codex-hook-node-local.json"
    ))
    XCTAssertThrowsError(try CodexHookConfigValidator.validateManagedHooks(
        updated,
        expectedNodeConfigPath: "/Users/tester/.sub2api-statusbar/codex-hook-node-remote.json"
    )) { error in
        XCTAssertEqual(
            error as? CodexHookConfigValidationError,
            .invalidHandlerField(event: "UserPromptSubmit", field: "command")
        )
    }
}

func testCodexHookConfigValidatorRejectsMissingManagedHandler() throws {
    let invalid = """
    [features]
    hooks = true

    [[hooks.UserPromptSubmit]]
    """

    XCTAssertThrowsError(try CodexHookConfigValidator.validateManagedHooks(invalid)) { error in
        XCTAssertEqual(
            error as? CodexHookConfigValidationError,
            .missingManagedHandler("UserPromptSubmit")
        )
    }
}

func testCodexHookConfigWriterReplacesExistingManagedHooksWithoutDuplicatingFeatureTable() throws {
    let first = try CodexHookConfigWriter.renderConfig(
        existingConfig: "[features]\nhooks = false\n",
        senderCommand: "/old/sender",
        nodeConfigPath: "/old/node.json",
        timeoutSeconds: 5
    )

    let second = try CodexHookConfigWriter.renderConfig(
        existingConfig: first,
        senderCommand: "/new/sender",
        nodeConfigPath: "/new/node.json",
        timeoutSeconds: 5
    )

    XCTAssertEqual(second.components(separatedBy: "[features]").count - 1, 1)
    XCTAssertFalse(second.contains("/old/sender"))
    XCTAssertFalse(second.contains("/old/node.json"))
    XCTAssert(second.contains("/new/sender"))
    XCTAssert(second.contains("/new/node.json"))
    XCTAssertEqual(second.components(separatedBy: "'--managed-by' 'Sub2APIStatusBar' '--event' 'UserPromptSubmit' '--config' '/new/node.json'").count - 1, 1)
}

func testCodexHookConfigWriterDoesNotTreatSimilarFeatureKeysAsHooksFlag() throws {
    let existing = """
    [features]
    hooks_timeout = 30
    hooks_enabled_note = "keep"
    """

    let updated = try CodexHookConfigWriter.renderConfig(
        existingConfig: existing,
        senderCommand: "/new/sender",
        nodeConfigPath: "/new/node.json",
        timeoutSeconds: 5
    )

    XCTAssert(updated.contains("hooks_timeout = 30"))
    XCTAssert(updated.contains("hooks_enabled_note = \"keep\""))
    XCTAssert(updated.contains("[features]\nhooks = true\nhooks_timeout = 30"))
    XCTAssertEqual(updated.components(separatedBy: "hooks = true").count - 1, 1)
}

func testCodexHookConfigWriterHandlesTomlHeadersWithTrailingComments() throws {
    let existing = """
    [features] # user feature flags
    hooks = false

    [[hooks.Stop]] # existing managed group

    [[hooks.Stop.hooks]] # existing managed handler
    type = "command"
    command = "'/old/sender' '--managed-by' 'Sub2APIStatusBar' '--event' 'Stop' '--config' '/old/node.json'"
    timeout = 5
    statusMessage = "Sub2APIStatusBar task monitor"
    """

    let updated = try CodexHookConfigWriter.renderConfig(
        existingConfig: existing,
        senderCommand: "/new/sender",
        nodeConfigPath: "/new/node.json",
        timeoutSeconds: 5
    )

    XCTAssert(updated.contains("[features] # user feature flags\nhooks = true"))
    XCTAssertFalse(updated.contains("/old/sender"))
    XCTAssertFalse(updated.contains("/old/node.json"))
    XCTAssertEqual(updated.components(separatedBy: "[features]").count - 1, 1)
    XCTAssertEqual(updated.components(separatedBy: "'--managed-by' 'Sub2APIStatusBar' '--event' 'Stop' '--config' '/new/node.json'").count - 1, 1)
}

func testCodexHookConfigWriterReplacesManagedHandlerWithoutDroppingUserHandlerInSameGroup() throws {
    let existing = """
    [features]
    hooks = true

    [[hooks.PreToolUse]]
    matcher = ".*"

    [[hooks.PreToolUse.hooks]]
    type = "command"
    command = "/usr/bin/env custom-pre-tool"
    timeout = 30
    statusMessage = "User custom pre-tool"

    [[hooks.PreToolUse.hooks]]
    type = "command"
    command = "'/old/sender' '--managed-by' 'Sub2APIStatusBar' '--event' 'PreToolUse' '--config' '/old/node.json'"
    timeout = 5
    statusMessage = "Sub2APIStatusBar task monitor"

    [[hooks.Stop]]

    [[hooks.Stop.hooks]]
    type = "command"
    command = "'/old/sender' '--managed-by' 'Sub2APIStatusBar' '--event' 'Stop' '--config' '/old/node.json'"
    timeout = 5
    statusMessage = "Sub2APIStatusBar task monitor"
    """

    let updated = try CodexHookConfigWriter.renderConfig(
        existingConfig: existing,
        senderCommand: "/new/sender",
        nodeConfigPath: "/new/node.json",
        timeoutSeconds: 5
    )

    XCTAssert(updated.contains("command = \"/usr/bin/env custom-pre-tool\""))
    XCTAssert(updated.contains("statusMessage = \"User custom pre-tool\""))
    XCTAssertFalse(updated.contains("/old/sender"))
    XCTAssertFalse(updated.contains("/old/node.json"))
    XCTAssertEqual(updated.components(separatedBy: "'--managed-by' 'Sub2APIStatusBar' '--event' 'PreToolUse' '--config' '/new/node.json'").count - 1, 1)
    XCTAssertEqual(updated.components(separatedBy: "'--managed-by' 'Sub2APIStatusBar' '--event' 'Stop' '--config' '/new/node.json'").count - 1, 1)
}

func testCodexHookConfigWriterPreservesTrustedHookStatePosition() throws {
    let existing = """
    [features]
    hooks = true

    [[hooks.Stop]]

    [[hooks.Stop.hooks]]
    type = "command"
    command = "'/old/sender' '--managed-by' 'Sub2APIStatusBar' '--event' 'Stop' '--config' '/old/node.json'"
    timeout = 5
    statusMessage = "Sub2APIStatusBar task monitor"

    [hooks.state]

    [hooks.state."/Users/tester/.codex/config.toml:stop:0:0"]
    trusted_hash = "sha256:trusted-stop"

    [tui.model_availability_nux]
    "gpt-5.5" = 2
    """

    let updated = try CodexHookConfigWriter.renderConfig(
        existingConfig: existing,
        senderCommand: "/new/sender",
        nodeConfigPath: "/new/node.json",
        timeoutSeconds: 5
    )
    let diff = UnifiedTextDiff.render(
        old: existing,
        new: updated,
        fromPath: "current",
        toPath: "updated"
    )

    XCTAssert(updated.contains("[hooks.state]"))
    XCTAssert(updated.contains("[hooks.state.\"/Users/tester/.codex/config.toml:stop:0:0\"]"))
    XCTAssert(updated.contains("trusted_hash = \"sha256:trusted-stop\""))
    XCTAssertFalse(updated.contains("/old/sender"))
    XCTAssertLessThan(
        try XCTUnwrap(updated.range(of: "'--event' 'UserPromptSubmit'")?.lowerBound),
        try XCTUnwrap(updated.range(of: "[hooks.state]")?.lowerBound)
    )
    XCTAssertLessThan(
        try XCTUnwrap(updated.range(of: "[hooks.state]")?.lowerBound),
        try XCTUnwrap(updated.range(of: "[tui.model_availability_nux]")?.lowerBound)
    )
    XCTAssertFalse(diff.contains("-[hooks.state"), diff)
    XCTAssertFalse(diff.contains("-trusted_hash"), diff)
}

func testUnifiedTextDiffShowsAddedRemovedAndContextLines() {
    let diff = UnifiedTextDiff.render(
        old: "model = \"gpt-5\"\n[features]\nhooks = false\n",
        new: "model = \"gpt-5\"\n[features]\nhooks = true\n",
        fromPath: "/Users/tester/.codex/config.toml (current)",
        toPath: "/Users/tester/.codex/config.toml (updated)"
    )

    XCTAssert(diff.contains("--- /Users/tester/.codex/config.toml (current)"))
    XCTAssert(diff.contains("+++ /Users/tester/.codex/config.toml (updated)"))
    XCTAssert(diff.contains(" model = \"gpt-5\""))
    XCTAssert(diff.contains("-hooks = false"))
    XCTAssert(diff.contains("+hooks = true"))
}

func testUnifiedTextDiffRedactsSensitiveConfigPreviewWithoutChangingNormalLines() {
    let diff = UnifiedTextDiff.renderRedactedConfigPreview(
        old: """
        model = "gpt-5"
        auth_token = "sk-old"
        api_key = "key-old"
        [features]
        hooks = false
        """,
        new: """
        model = "gpt-5"
        auth_token = "sk-new"
        api_key = "key-new"
        [features]
        hooks = true
        """,
        fromPath: "/Users/tester/.codex/config.toml (current)",
        toPath: "/Users/tester/.codex/config.toml (updated)"
    )

    XCTAssert(diff.contains(" model = \"gpt-5\""))
    XCTAssert(diff.contains(" auth_token = \"<redacted>\""))
    XCTAssert(diff.contains(" api_key = \"<redacted>\""))
    XCTAssert(diff.contains("-hooks = false"))
    XCTAssert(diff.contains("+hooks = true"))
    XCTAssertFalse(diff.contains("sk-old"))
    XCTAssertFalse(diff.contains("sk-new"))
    XCTAssertFalse(diff.contains("key-old"))
    XCTAssertFalse(diff.contains("key-new"))
}

func testCodexTaskActivityStoreCreatesRunningTurnFromUserPromptSubmit() {
    var store = CodexTaskActivityStore()
    let event = CodexHookEvent(
        eventID: "event-1",
        nodeID: "node-a",
        observedAt: Date(timeIntervalSince1970: 100),
        hookEvent: .userPromptSubmit,
        sessionID: "session-1",
        turnID: "turn-1",
        cwd: "/workspace/app",
        model: "codex-auto",
        toolName: nil
    )

    store.apply(event)

    let activity = store.activities.first
    XCTAssertEqual(activity?.nodeID, "node-a")
    XCTAssertEqual(activity?.sessionID, "session-1")
    XCTAssertEqual(activity?.turnID, "turn-1")
    XCTAssertEqual(activity?.status, .running)
    XCTAssertEqual(activity?.phase, .prompt)
    XCTAssertEqual(activity?.badge, "A1")
}

func testCodexTaskActivityStoreCreatesSeparateTasksForTurnsInSameSession() {
    var store = CodexTaskActivityStore()

    store.apply(CodexHookEvent(eventID: "event-1", nodeID: "node-a", observedAt: Date(timeIntervalSince1970: 100), hookEvent: .userPromptSubmit, sessionID: "session-1", turnID: "turn-1", cwd: "/workspace/app", model: "gpt-5", toolName: nil))
    store.apply(CodexHookEvent(eventID: "event-2", nodeID: "node-a", observedAt: Date(timeIntervalSince1970: 120), hookEvent: .preToolUse, sessionID: "session-1", turnID: "turn-1", cwd: nil, model: nil, toolName: "Bash"))
    store.apply(CodexHookEvent(eventID: "event-3", nodeID: "node-a", observedAt: Date(timeIntervalSince1970: 300), hookEvent: .userPromptSubmit, sessionID: "session-1", turnID: "turn-2", cwd: "/workspace/app", model: "gpt-5", toolName: nil))

    XCTAssertEqual(store.activities.count, 2)
    let firstTurn = store.activities.first { $0.turnID == "turn-1" }
    let secondTurn = store.activities.first { $0.turnID == "turn-2" }
    XCTAssertEqual(firstTurn?.id, "node-a|session-1|turn-1")
    XCTAssertEqual(firstTurn?.badge, "A1")
    XCTAssertEqual(firstTurn?.timeline.map(\.eventID), ["event-1", "event-2"])
    XCTAssertEqual(secondTurn?.id, "node-a|session-1|turn-2")
    XCTAssertEqual(secondTurn?.badge, "A2")
    XCTAssertEqual(secondTurn?.status, .running)
    XCTAssertEqual(secondTurn?.phase, .prompt)
    XCTAssertEqual(secondTurn?.timeline.map(\.eventID), ["event-3"])
}

func testCodexTaskActivityStoreAppliesLateStopOnlyToMatchingTurn() {
    var store = CodexTaskActivityStore()

    store.apply(CodexHookEvent(eventID: "event-1", nodeID: "node-a", observedAt: Date(timeIntervalSince1970: 100), hookEvent: .userPromptSubmit, sessionID: "session-1", turnID: "turn-1", cwd: nil, model: nil, toolName: nil))
    store.apply(CodexHookEvent(eventID: "event-2", nodeID: "node-a", observedAt: Date(timeIntervalSince1970: 200), hookEvent: .userPromptSubmit, sessionID: "session-1", turnID: "turn-2", cwd: nil, model: nil, toolName: nil))
    store.apply(CodexHookEvent(eventID: "event-3", nodeID: "node-a", observedAt: Date(timeIntervalSince1970: 210), hookEvent: .stop, sessionID: "session-1", turnID: "turn-1", cwd: nil, model: nil, toolName: nil))

    XCTAssertEqual(store.activities.count, 2)
    let firstTurn = store.activities.first { $0.turnID == "turn-1" }
    let secondTurn = store.activities.first { $0.turnID == "turn-2" }
    XCTAssertEqual(firstTurn?.status, .done)
    XCTAssertEqual(firstTurn?.timeline.map(\.eventID), ["event-1", "event-3"])
    XCTAssertEqual(secondTurn?.status, .running)
    XCTAssertEqual(secondTurn?.timeline.map(\.eventID), ["event-2"])
}

func testCodexTaskActivityStoreKeepsCompletedTurnWhenNewTurnStarts() {
    var store = CodexTaskActivityStore()

    store.apply(CodexHookEvent(eventID: "event-1", nodeID: "node-a", observedAt: Date(timeIntervalSince1970: 100), hookEvent: .userPromptSubmit, sessionID: "session-1", turnID: "turn-1", cwd: "/workspace/app", model: "gpt-5", toolName: nil))
    store.apply(CodexHookEvent(eventID: "event-2", nodeID: "node-a", observedAt: Date(timeIntervalSince1970: 150), hookEvent: .stop, sessionID: "session-1", turnID: "turn-1", cwd: nil, model: nil, toolName: nil))
    store.apply(CodexHookEvent(eventID: "event-3", nodeID: "node-a", observedAt: Date(timeIntervalSince1970: 300), hookEvent: .userPromptSubmit, sessionID: "session-1", turnID: "turn-2", cwd: "/workspace/app", model: "gpt-5", toolName: nil))

    XCTAssertEqual(store.activities.count, 2)
    let firstTurn = store.activities.first { $0.turnID == "turn-1" }
    let secondTurn = store.activities.first { $0.turnID == "turn-2" }
    XCTAssertEqual(firstTurn?.status, .done)
    XCTAssertEqual(firstTurn?.timeline.map(\.hookEvent), [.userPromptSubmit, .stop])
    XCTAssertEqual(secondTurn?.status, .running)
    XCTAssertEqual(secondTurn?.timeline.map(\.hookEvent), [.userPromptSubmit])
}

func testCodexTaskActivityStoreDoesNotLetLatePreviousTurnStopOverwriteCurrentTurnMetadata() {
    var store = CodexTaskActivityStore()

    store.apply(CodexHookEvent(eventID: "event-1", nodeID: "node-a", observedAt: Date(timeIntervalSince1970: 100), hookEvent: .userPromptSubmit, sessionID: "session-1", turnID: "turn-1", cwd: nil, model: nil, toolName: nil))
    store.apply(CodexHookEvent(eventID: "event-2", nodeID: "node-a", observedAt: Date(timeIntervalSince1970: 200), hookEvent: .userPromptSubmit, sessionID: "session-1", turnID: "turn-2", cwd: nil, model: nil, toolName: nil))
    store.apply(CodexHookEvent(eventID: "event-3", nodeID: "node-a", observedAt: Date(timeIntervalSince1970: 210), hookEvent: .stop, sessionID: "session-1", turnID: "turn-1", cwd: nil, model: nil, toolName: nil, statusHint: "failed", errorMessage: "old turn failed"))

    let firstTurn = store.activities.first { $0.turnID == "turn-1" }
    let secondTurn = store.activities.first { $0.turnID == "turn-2" }
    XCTAssertEqual(firstTurn?.status, .error)
    XCTAssertEqual(firstTurn?.errorMessage, "old turn failed")
    XCTAssertEqual(secondTurn?.status, .running)
    XCTAssertNil(secondTurn?.statusHint)
    XCTAssertNil(secondTurn?.errorMessage)
    XCTAssertEqual(secondTurn?.updatedAt, Date(timeIntervalSince1970: 200))
}

func testCodexTaskActivityStoreDoesNotRewindToLatePreviousTurnNonTerminalEvent() {
    var store = CodexTaskActivityStore()

    store.apply(CodexHookEvent(eventID: "event-1", nodeID: "node-a", observedAt: Date(timeIntervalSince1970: 100), hookEvent: .userPromptSubmit, sessionID: "session-1", turnID: "turn-1", cwd: nil, model: nil, toolName: nil))
    store.apply(CodexHookEvent(eventID: "event-2", nodeID: "node-a", observedAt: Date(timeIntervalSince1970: 200), hookEvent: .userPromptSubmit, sessionID: "session-1", turnID: "turn-2", cwd: nil, model: nil, toolName: nil))
    store.apply(CodexHookEvent(eventID: "event-3", nodeID: "node-a", observedAt: Date(timeIntervalSince1970: 210), hookEvent: .postToolUse, sessionID: "session-1", turnID: "turn-1", cwd: nil, model: nil, toolName: "Bash", statusHint: "success"))

    let firstTurn = store.activities.first { $0.turnID == "turn-1" }
    let secondTurn = store.activities.first { $0.turnID == "turn-2" }
    XCTAssertEqual(firstTurn?.status, .running)
    XCTAssertEqual(firstTurn?.phase, .tooling)
    XCTAssertEqual(firstTurn?.toolName, "Bash")
    XCTAssertEqual(firstTurn?.timeline.map(\.eventID), ["event-1", "event-3"])
    XCTAssertEqual(secondTurn?.status, .running)
    XCTAssertEqual(secondTurn?.phase, .prompt)
    XCTAssertNil(secondTurn?.toolName)
    XCTAssertEqual(secondTurn?.updatedAt, Date(timeIntervalSince1970: 200))
}

func testCodexTaskActivityStoreDoesNotReopenCompletedTurnFromLateNonTerminalEvent() {
    var store = CodexTaskActivityStore()

    store.apply(CodexHookEvent(eventID: "event-1", nodeID: "node-a", observedAt: Date(timeIntervalSince1970: 100), hookEvent: .userPromptSubmit, sessionID: "session-1", turnID: "turn-1", cwd: nil, model: nil, toolName: nil))
    store.apply(CodexHookEvent(eventID: "event-2", nodeID: "node-a", observedAt: Date(timeIntervalSince1970: 150), hookEvent: .stop, sessionID: "session-1", turnID: "turn-1", cwd: nil, model: nil, toolName: nil))
    store.apply(CodexHookEvent(eventID: "event-3", nodeID: "node-a", observedAt: Date(timeIntervalSince1970: 160), hookEvent: .postToolUse, sessionID: "session-1", turnID: "turn-1", cwd: nil, model: nil, toolName: "Bash", statusHint: "success"))

    let activity = store.activities.first
    XCTAssertEqual(activity?.turnID, "turn-1")
    XCTAssertEqual(activity?.status, .done)
    XCTAssertEqual(activity?.phase, .completed)
    XCTAssertEqual(activity?.toolName, nil)
    XCTAssertEqual(activity?.completedAt, Date(timeIntervalSince1970: 150))
    XCTAssertEqual(activity?.updatedAt, Date(timeIntervalSince1970: 150))
    XCTAssertEqual(activity?.timeline.map(\.eventID), ["event-1", "event-2", "event-3"])
}

func testCodexTaskActivityStorePersistenceReloadsActivitiesAcrossAppRestarts() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
    let storageURL = root.appendingPathComponent("codex-task-activities.json")
    let persistence = CodexTaskActivityStorePersistence(storageURL: storageURL)
    var store = CodexTaskActivityStore()
    let completedAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
    let startedAt = completedAt.addingTimeInterval(-20)

    store.apply(CodexHookEvent(
        eventID: "event-1",
        nodeID: "remote-node",
        observedAt: startedAt,
        hookEvent: .userPromptSubmit,
        sessionID: "session-1",
        turnID: "turn-1",
        cwd: "/workspace/app",
        model: "gpt-5.5",
        toolName: nil,
        transcriptPath: "/tmp/transcript.jsonl",
        userAgent: "codex_cli_rs/0.136.0",
        rawPayloadHash: "sha256:abc123",
        rawPayloadJSON: #"{"event_id":"event-1"}"#
    ))
    store.apply(CodexHookEvent(
        eventID: "event-2",
        nodeID: "remote-node",
        observedAt: completedAt,
        hookEvent: .stop,
        sessionID: "session-1",
        turnID: "turn-1",
        cwd: nil,
        model: nil,
        toolName: nil
    ))

    try persistence.save(store)
    let savedData = try Data(contentsOf: storageURL)
    let savedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: savedData) as? [String: Any])
    let reloaded = try persistence.load()

    XCTAssertEqual(savedObject["schema_version"] as? Int, 2)
    XCTAssertNotNil(savedObject["activities"] as? [[String: Any]])
    XCTAssertFalse(String(decoding: savedData, as: UTF8.self).contains("rawPayloadJSON"))
    let attributes = try FileManager.default.attributesOfItem(atPath: storageURL.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    XCTAssertEqual(reloaded.activities.count, 1)
    let activity = reloaded.activities.first
    XCTAssertEqual(activity?.id, "remote-node|session-1|turn-1")
    XCTAssertEqual(activity?.status, .done)
    XCTAssertEqual(activity?.completedAt, completedAt)
    XCTAssertEqual(activity?.timeline.map(\.eventID), ["event-1", "event-2"])
    XCTAssertNil(activity?.timeline.first?.rawPayloadJSON)
    XCTAssertEqual(activity?.userAgent, "codex_cli_rs/0.136.0")
}

func testCodexTaskActivityStorePersistencePrunesLegacyTerminalHistoryBeforeReturning() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
    let storageURL = root.appendingPathComponent("codex-task-activities.json")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let now = Date()
    let activities = (0 ..< 205).map { index in
        let observedAt = now.addingTimeInterval(-TimeInterval(index))
        return CodexTaskActivity(
            nodeID: "node-a",
            sessionID: "session-\(index)",
            turnID: "turn-\(index)",
            badge: "A\(index + 1)",
            cwd: nil,
            model: nil,
            status: .done,
            phase: .completed,
            toolName: nil,
            startedAt: observedAt,
            updatedAt: observedAt,
            completedAt: observedAt,
            timeline: [
                CodexTaskActivity.TimelineEvent(
                    eventID: "event-\(index)",
                    hookEvent: .stop,
                    observedAt: observedAt,
                    sessionID: "session-\(index)",
                    turnID: "turn-\(index)",
                    cwd: nil,
                    model: nil,
                    toolName: nil
                ),
            ]
        )
    }
    try JSONEncoder.codexHook.encode(activities).write(to: storageURL)

    let loaded = try CodexTaskActivityStorePersistence(storageURL: storageURL).load()

    XCTAssertEqual(loaded.activities.count, CodexTaskActivityStore.maxTerminalActivities)
    XCTAssertTrue(loaded.activities.contains { $0.sessionID == "session-0" })
    XCTAssertFalse(loaded.activities.contains { $0.sessionID == "session-204" })
}

func testCodexTaskActivityStoreKeepsRawPayloadOnlyForThreeNewestTimelineEvents() {
    var store = CodexTaskActivityStore()

    for index in 1 ... 5 {
        store.apply(CodexHookEvent(
            eventID: "event-\(index)",
            nodeID: "node-a",
            observedAt: Date(timeIntervalSince1970: TimeInterval(index)),
            hookEvent: index == 1 ? .userPromptSubmit : .postToolUse,
            sessionID: "session-1",
            turnID: "turn-1",
            cwd: nil,
            model: nil,
            toolName: index == 1 ? nil : "Bash",
            rawPayloadJSON: #"{"index":\#(index)}"#
        ))
    }

    let timeline = store.activities.first?.timeline ?? []
    XCTAssertEqual(timeline.map(\.eventID), ["event-1", "event-2", "event-3", "event-4", "event-5"])
    XCTAssertEqual(timeline.compactMap(\.rawPayloadJSON).count, 3)
    XCTAssertNil(timeline[0].rawPayloadJSON)
    XCTAssertNil(timeline[1].rawPayloadJSON)
    XCTAssertNotNil(timeline[2].rawPayloadJSON)
}

func testCodexTaskActivityStoreMergesLoadedHistoryWithoutOverwritingNewerLiveState() {
    var loadedStore = CodexTaskActivityStore()
    loadedStore.apply(CodexHookEvent(
        eventID: "event-loaded",
        nodeID: "node-a",
        observedAt: Date(timeIntervalSince1970: 100),
        hookEvent: .userPromptSubmit,
        sessionID: "session-1",
        turnID: "turn-1",
        cwd: "/loaded",
        model: "gpt-5.5",
        toolName: nil
    ))

    var liveStore = CodexTaskActivityStore()
    liveStore.apply(CodexHookEvent(
        eventID: "event-live",
        nodeID: "node-a",
        observedAt: Date(timeIntervalSince1970: 120),
        hookEvent: .postToolUse,
        sessionID: "session-1",
        turnID: "turn-1",
        cwd: "/live",
        model: "gpt-5.6-sol",
        toolName: "Bash"
    ))

    liveStore.merge(activities: loadedStore.activities)

    let activity = liveStore.activities.first
    XCTAssertEqual(activity?.updatedAt, Date(timeIntervalSince1970: 120))
    XCTAssertEqual(activity?.toolName, "Bash")
    XCTAssertEqual(activity?.timeline.map(\.eventID), ["event-loaded", "event-live"])
}

func testCodexTaskActivityStoreMergesDuplicatePersistedEventIDsWithoutCrashing() throws {
    var persistedStore = CodexTaskActivityStore()
    persistedStore.apply(CodexHookEvent(
        eventID: "event-duplicate",
        nodeID: "node-a",
        observedAt: Date(timeIntervalSince1970: 100),
        hookEvent: .userPromptSubmit,
        sessionID: "session-1",
        turnID: "turn-1",
        cwd: nil,
        model: nil,
        toolName: nil
    ))
    var persistedActivity = try XCTUnwrap(persistedStore.activities.first)
    persistedActivity.timeline.append(CodexTaskActivity.TimelineEvent(
        eventID: "event-duplicate",
        hookEvent: .postToolUse,
        observedAt: Date(timeIntervalSince1970: 110),
        sessionID: "session-1",
        turnID: "turn-1",
        cwd: nil,
        model: nil,
        toolName: "Read"
    ))

    var liveStore = CodexTaskActivityStore()
    liveStore.apply(CodexHookEvent(
        eventID: "event-live",
        nodeID: "node-a",
        observedAt: Date(timeIntervalSince1970: 120),
        hookEvent: .postToolUse,
        sessionID: "session-1",
        turnID: "turn-1",
        cwd: nil,
        model: nil,
        toolName: "Bash"
    ))

    liveStore.merge(activities: [persistedActivity])

    let duplicateEvents = liveStore.activities.first?.timeline.filter { $0.eventID == "event-duplicate" }
    XCTAssertEqual(duplicateEvents?.count, 1)
    XCTAssertEqual(duplicateEvents?.first?.observedAt, Date(timeIntervalSince1970: 110))
    XCTAssertEqual(duplicateEvents?.first?.toolName, "Read")
}

func testCodexTaskActivityStorePersistenceMigratesLegacyMixedSessionTimelineIntoTurns() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
    let storageURL = root.appendingPathComponent("codex-task-activities.json")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let firstTurnStartedAt = Date().addingTimeInterval(-120)
    let firstTurnCompletedAt = firstTurnStartedAt.addingTimeInterval(20)
    let secondTurnStartedAt = firstTurnStartedAt.addingTimeInterval(100)
    let timeline = [
        CodexTaskActivity.TimelineEvent(eventID: "event-1", hookEvent: .userPromptSubmit, observedAt: firstTurnStartedAt, sessionID: "session-1", turnID: "turn-1", cwd: "/workspace", model: "gpt-5.5", toolName: nil),
        CodexTaskActivity.TimelineEvent(eventID: "event-2", hookEvent: .stop, observedAt: firstTurnCompletedAt, sessionID: "session-1", turnID: "turn-1", cwd: nil, model: nil, toolName: nil),
        CodexTaskActivity.TimelineEvent(eventID: "event-3", hookEvent: .userPromptSubmit, observedAt: secondTurnStartedAt, sessionID: "session-1", turnID: "turn-2", cwd: "/workspace", model: "gpt-5.6-sol", toolName: nil),
    ]
    let legacyActivity = CodexTaskActivity(
        nodeID: "node-a",
        sessionID: "session-1",
        turnID: "turn-2",
        badge: "A1",
        cwd: "/workspace",
        model: "gpt-5.6-sol",
        status: .running,
        phase: .prompt,
        toolName: nil,
        startedAt: firstTurnStartedAt,
        updatedAt: secondTurnStartedAt,
        completedAt: nil,
        timeline: timeline
    )
    try JSONEncoder.codexHook.encode([legacyActivity]).write(to: storageURL)

    let migrated = try CodexTaskActivityStorePersistence(storageURL: storageURL).load()
    let migratedData = try Data(contentsOf: storageURL)
    let migratedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: migratedData) as? [String: Any])

    XCTAssertEqual(migrated.activities.count, 2)
    XCTAssertEqual(migratedObject["schema_version"] as? Int, 2)
    XCTAssertEqual(migrated.activities.first { $0.turnID == "turn-1" }?.status, .done)
    XCTAssertEqual(migrated.activities.first { $0.turnID == "turn-2" }?.status, .running)
    XCTAssertEqual(migrated.activities.first { $0.turnID == "turn-1" }?.timeline.count, 2)
    XCTAssertEqual(migrated.activities.first { $0.turnID == "turn-2" }?.timeline.count, 1)
}

func testCodexTaskActivityStoreKeepsOnlyRegisteredNodesWhenRegistryChanges() {
    var store = CodexTaskActivityStore()
    store.apply(CodexHookEvent(eventID: "event-1", nodeID: "local-node", observedAt: Date(timeIntervalSince1970: 100), hookEvent: .userPromptSubmit, sessionID: "session-1", turnID: "turn-1", cwd: nil, model: nil, toolName: nil))
    store.apply(CodexHookEvent(eventID: "event-2", nodeID: "removed-node", observedAt: Date(timeIntervalSince1970: 101), hookEvent: .userPromptSubmit, sessionID: "session-2", turnID: "turn-2", cwd: nil, model: nil, toolName: nil))

    store.keepOnlyActivities(forNodeIDs: ["local-node"])

    XCTAssertEqual(store.activities.map(\.nodeID), ["local-node"])
    store.apply(CodexHookEvent(eventID: "event-3", nodeID: "new-node", observedAt: Date(timeIntervalSince1970: 102), hookEvent: .userPromptSubmit, sessionID: "session-3", turnID: "turn-3", cwd: nil, model: nil, toolName: nil))
    XCTAssertEqual(store.activities.map(\.badge), ["A1", "A2"])
}

func testCodexTaskActivityStoreDoesNotReuseExistingBadgeAfterReloadingSparseBadges() {
    let keptActivity = CodexTaskActivity(
        nodeID: "kept-node",
        sessionID: "session-kept",
        turnID: "turn-kept",
        badge: "A2",
        cwd: nil,
        model: nil,
        status: .done,
        phase: .completed,
        toolName: nil,
        startedAt: Date(timeIntervalSince1970: 100),
        updatedAt: Date(timeIntervalSince1970: 120),
        completedAt: Date(timeIntervalSince1970: 120),
        timeline: []
    )
    var store = CodexTaskActivityStore(activities: [keptActivity])

    store.apply(CodexHookEvent(eventID: "event-new", nodeID: "new-node", observedAt: Date(timeIntervalSince1970: 130), hookEvent: .userPromptSubmit, sessionID: "session-new", turnID: "turn-new", cwd: nil, model: nil, toolName: nil))

    XCTAssertEqual(store.activities.map(\.badge), ["A2", "A3"])
}

func testCodexTaskActivityStoreIgnoresSyntheticTestEvents() {
    var store = CodexTaskActivityStore()

    store.apply(CodexHookEvent(
        eventID: "local-test-event",
        nodeID: "local-node",
        observedAt: Date(timeIntervalSince1970: 100),
        hookEvent: .userPromptSubmit,
        sessionID: "sub2api-statusbar-test-session",
        turnID: "sub2api-statusbar-test-turn-100",
        cwd: nil,
        model: "test",
        toolName: nil
    ))
    store.apply(CodexHookEvent(
        eventID: "remote-test-event",
        nodeID: "remote-node",
        observedAt: Date(timeIntervalSince1970: 101),
        hookEvent: .userPromptSubmit,
        sessionID: "sub2api-statusbar-remote-test-session",
        turnID: "sub2api-statusbar-remote-test-turn-101",
        cwd: nil,
        model: "test",
        toolName: nil
    ))

    XCTAssertEqual(store.activities, [])
}

func testCodexHookEventDecodesSnakeCasePayload() throws {
    let json = """
    {
      "schema_version": 1,
      "event_id": "event-1",
      "node_id": "node-a",
      "observed_at": "2026-06-01T09:00:00Z",
      "hook_event": "UserPromptSubmit",
      "session_id": "session-1",
      "turn_id": "turn-1",
      "cwd": "/workspace/app",
      "model": "codex-auto",
      "tool_name": "Bash",
      "status_hint": "running",
      "tool_use_id": "tool-1",
      "error_message": "explicit error",
      "transcript_path": "/tmp/transcript.jsonl",
      "user_agent": "Codex Desktop/0.125.0",
      "raw_payload_hash": "sha256:abc123"
    }
    """.data(using: .utf8)!

    let event = try JSONDecoder.codexHook.decode(CodexHookEvent.self, from: json)

    XCTAssertEqual(event.schemaVersion, 1)
    XCTAssertEqual(event.eventID, "event-1")
    XCTAssertEqual(event.nodeID, "node-a")
    XCTAssertEqual(event.hookEvent, .userPromptSubmit)
    XCTAssertEqual(event.sessionID, "session-1")
    XCTAssertEqual(event.turnID, "turn-1")
    XCTAssertEqual(event.cwd, "/workspace/app")
    XCTAssertEqual(event.model, "codex-auto")
    XCTAssertEqual(event.toolName, "Bash")
    XCTAssertEqual(event.statusHint, "running")
    XCTAssertEqual(event.toolUseID, "tool-1")
    XCTAssertEqual(event.errorMessage, "explicit error")
    XCTAssertEqual(event.transcriptPath, "/tmp/transcript.jsonl")
    XCTAssertEqual(event.userAgent, "Codex Desktop/0.125.0")
    XCTAssertEqual(event.rawPayloadHash, "sha256:abc123")
}

func testCodexHookEventRejectsNonCanonicalPayloads() throws {
    let missingSchema = """
    {
      "event_id": "event-1",
      "node_id": "node-a",
      "observed_at": "2026-06-01T09:00:00Z",
      "hook_event": "UserPromptSubmit",
      "session_id": "session-1",
      "turn_id": "turn-1"
    }
    """.data(using: .utf8)!
    let camelCase = """
    {
      "schemaVersion": 1,
      "eventId": "event-1",
      "nodeId": "node-a",
      "observedAt": "2026-06-01T09:00:00Z",
      "hookEvent": "UserPromptSubmit",
      "sessionId": "session-1",
      "turnId": "turn-1"
    }
    """.data(using: .utf8)!

    XCTAssertThrowsError(try JSONDecoder.codexHook.decode(CodexHookEvent.self, from: missingSchema))
    XCTAssertThrowsError(try JSONDecoder.codexHook.decode(CodexHookEvent.self, from: camelCase))
}

func testCodexTaskActivityStoreMarksRunningAndWaitingTurnsStale() {
    var store = CodexTaskActivityStore()
    store.apply(CodexHookEvent(eventID: "event-1", nodeID: "node-a", observedAt: Date(timeIntervalSince1970: 100), hookEvent: .userPromptSubmit, sessionID: "session-1", turnID: "turn-1", cwd: nil, model: nil, toolName: nil))
    store.apply(CodexHookEvent(eventID: "event-2", nodeID: "node-a", observedAt: Date(timeIntervalSince1970: 110), hookEvent: .userPromptSubmit, sessionID: "session-2", turnID: "turn-2", cwd: nil, model: nil, toolName: nil))
    store.apply(CodexHookEvent(eventID: "event-3", nodeID: "node-a", observedAt: Date(timeIntervalSince1970: 115), hookEvent: .stop, sessionID: "session-2", turnID: "turn-2", cwd: nil, model: nil, toolName: nil))
    store.apply(CodexHookEvent(eventID: "event-4", nodeID: "node-a", observedAt: Date(timeIntervalSince1970: 120), hookEvent: .permissionRequest, sessionID: "session-3", turnID: "turn-3", cwd: nil, model: nil, toolName: "Bash"))

    store.markStale(now: Date(timeIntervalSince1970: 500), staleAfter: 300)

    let staleActivity = store.activities.first { $0.turnID == "turn-1" }
    let doneActivity = store.activities.first { $0.turnID == "turn-2" }
    let waitingActivity = store.activities.first { $0.turnID == "turn-3" }
    XCTAssertEqual(staleActivity?.status, .stale)
    XCTAssertEqual(doneActivity?.status, .done)
    XCTAssertEqual(waitingActivity?.status, .stale)
}

func testCodexTaskActivityStoreBoundsTimelineAndTerminalHistory() {
    var store = CodexTaskActivityStore()
    for index in 0..<25 {
        store.apply(CodexHookEvent(
            eventID: "timeline-\(index)",
            nodeID: "node-a",
            observedAt: Date(timeIntervalSince1970: Double(100 + index)),
            hookEvent: index == 0 ? .userPromptSubmit : .postToolUse,
            sessionID: "session-live",
            turnID: "turn-live",
            cwd: nil,
            model: nil,
            toolName: index == 0 ? nil : "Bash"
        ))
    }
    for index in 0..<205 {
        let time = Date(timeIntervalSince1970: Double(1_000 + index * 2))
        store.apply(CodexHookEvent(eventID: "done-start-\(index)", nodeID: "node-a", observedAt: time, hookEvent: .userPromptSubmit, sessionID: "session-\(index)", turnID: "turn-\(index)", cwd: nil, model: nil, toolName: nil))
        store.apply(CodexHookEvent(eventID: "done-stop-\(index)", nodeID: "node-a", observedAt: time.addingTimeInterval(1), hookEvent: .stop, sessionID: "session-\(index)", turnID: "turn-\(index)", cwd: nil, model: nil, toolName: nil))
    }

    store.prune(now: Date(timeIntervalSince1970: 2_000))

    XCTAssertEqual(store.activities.first { $0.turnID == "turn-live" }?.timeline.count, 20)
    XCTAssertEqual(store.activities.filter { $0.status == .done }.count, 200)
    XCTAssertEqual(store.activities.filter { $0.status == .running }.count, 1)
}

func testCodexTaskActivityStorePrunesTerminalTasksOlderThanSevenDays() {
    var store = CodexTaskActivityStore()
    let now = Date(timeIntervalSince1970: 1_000_000)
    let old = now.addingTimeInterval(-(7 * 24 * 60 * 60) - 2)
    store.apply(CodexHookEvent(eventID: "old-start", nodeID: "node-a", observedAt: old, hookEvent: .userPromptSubmit, sessionID: "old", turnID: "old", cwd: nil, model: nil, toolName: nil))
    store.apply(CodexHookEvent(eventID: "old-stop", nodeID: "node-a", observedAt: old.addingTimeInterval(1), hookEvent: .stop, sessionID: "old", turnID: "old", cwd: nil, model: nil, toolName: nil))
    store.apply(CodexHookEvent(eventID: "live", nodeID: "node-a", observedAt: old, hookEvent: .userPromptSubmit, sessionID: "live", turnID: "live", cwd: nil, model: nil, toolName: nil))

    store.prune(now: now)

    XCTAssertNil(store.activities.first { $0.turnID == "old" })
    XCTAssertNotNil(store.activities.first { $0.turnID == "live" })
}

func testCodexTaskActivityStoreKeepsBadgeStableAcrossUpdates() {
    var store = CodexTaskActivityStore()
    store.apply(CodexHookEvent(eventID: "event-1", nodeID: "node-a", observedAt: Date(timeIntervalSince1970: 100), hookEvent: .userPromptSubmit, sessionID: "session-1", turnID: "turn-1", cwd: nil, model: nil, toolName: nil))
    let firstBadge = store.activities.first?.badge

    store.apply(CodexHookEvent(eventID: "event-2", nodeID: "node-a", observedAt: Date(timeIntervalSince1970: 120), hookEvent: .preToolUse, sessionID: "session-1", turnID: "turn-1", cwd: nil, model: nil, toolName: "Bash"))
    store.markStale(now: Date(timeIntervalSince1970: 500), staleAfter: 300)

    XCTAssertEqual(store.activities.first?.badge, firstBadge)
    XCTAssertEqual(store.activities.first?.status, .stale)
}

func testCodexRuntimeStateRefresherMarksTaskAndNodeStaleTogether() throws {
    var activityStore = CodexTaskActivityStore()
    var nodeHealthStore = CodexNodeHealthStore()
    let node = try CodexNode(
        id: "node-a",
        name: "Node A",
        kind: .local,
        localReceiverPort: 43210,
        remoteReceiverPort: nil,
        ssh: nil,
        codexHomeOverride: nil
    )
    let event = CodexHookEvent(
        eventID: "event-1",
        nodeID: "node-a",
        observedAt: Date(timeIntervalSince1970: 100),
        hookEvent: .userPromptSubmit,
        sessionID: "session-1",
        turnID: "turn-1",
        cwd: nil,
        model: nil,
        toolName: nil
    )
    nodeHealthStore.configure(nodes: [node], now: Date(timeIntervalSince1970: 90))
    activityStore.apply(event)
    nodeHealthStore.markEventReceived(event, now: Date(timeIntervalSince1970: 100))

    let activities = CodexRuntimeStateRefresher(
        taskStaleAfterSeconds: 300,
        nodeStaleAfterSeconds: 300
    ).refresh(
        activityStore: &activityStore,
        nodeHealthStore: &nodeHealthStore,
        now: Date(timeIntervalSince1970: 500)
    )

    XCTAssertEqual(activities.first?.status, .stale)
    XCTAssertEqual(nodeHealthStore.status(nodeID: "node-a")?.state, .stale)
}

func testCodexTaskActivityStoreKeepsTimelineForTurnEventsAndDeduplicatesEventIDs() {
    var store = CodexTaskActivityStore()
    store.apply(CodexHookEvent(eventID: "event-1", nodeID: "node-a", observedAt: Date(timeIntervalSince1970: 100), hookEvent: .userPromptSubmit, sessionID: "session-1", turnID: "turn-1", cwd: "/workspace/app", model: "gpt-5", toolName: nil))
    store.apply(CodexHookEvent(eventID: "event-2", nodeID: "node-a", observedAt: Date(timeIntervalSince1970: 120), hookEvent: .preToolUse, sessionID: "session-1", turnID: "turn-1", cwd: nil, model: nil, toolName: "Bash"))
    store.apply(CodexHookEvent(eventID: "event-2", nodeID: "node-a", observedAt: Date(timeIntervalSince1970: 125), hookEvent: .postToolUse, sessionID: "session-1", turnID: "turn-1", cwd: nil, model: nil, toolName: "Bash"))

    let activity = store.activities.first

    XCTAssertEqual(activity?.timeline.map(\.eventID), ["event-1", "event-2"])
    XCTAssertEqual(activity?.timeline.map(\.hookEvent), [.userPromptSubmit, .preToolUse])
    XCTAssertEqual(activity?.timeline.last?.toolName, "Bash")
    XCTAssertEqual(activity?.cwd, "/workspace/app")
    XCTAssertEqual(activity?.model, "gpt-5")
}

func testCodexTaskActivityStoreMarksExplicitWaitingHintAsWaiting() {
    var store = CodexTaskActivityStore()

    store.apply(CodexHookEvent(
        eventID: "event-waiting",
        nodeID: "node-a",
        observedAt: Date(timeIntervalSince1970: 100),
        hookEvent: .userPromptSubmit,
        sessionID: "session-1",
        turnID: "turn-1",
        cwd: "/workspace/app",
        model: "gpt-5",
        toolName: nil,
        statusHint: "paused"
    ))

    let activity = store.activities.first
    XCTAssertEqual(activity?.status, .waiting)
    XCTAssertEqual(activity?.phase, .prompt)
    XCTAssertEqual(activity?.statusHint, "paused")
    XCTAssertEqual(activity?.timeline.first?.statusHint, "paused")
}

func testCodexTaskActivityStoreMarksPermissionRequestAsWaiting() {
    var store = CodexTaskActivityStore()

    store.apply(CodexHookEvent(
        eventID: "event-permission",
        nodeID: "node-a",
        observedAt: Date(timeIntervalSince1970: 100),
        hookEvent: .permissionRequest,
        sessionID: "session-1",
        turnID: "turn-1",
        cwd: "/workspace/app",
        model: "gpt-5",
        toolName: "Bash",
        toolUseID: "tool-1",
        transcriptPath: "/tmp/transcript.jsonl",
        rawPayloadHash: "sha256:abc123"
    ))

    let activity = store.activities.first
    XCTAssertEqual(activity?.status, .waiting)
    XCTAssertEqual(activity?.phase, .prompt)
    XCTAssertEqual(activity?.toolName, "Bash")
    XCTAssertEqual(activity?.toolUseID, "tool-1")
    XCTAssertEqual(activity?.transcriptPath, "/tmp/transcript.jsonl")
    XCTAssertEqual(activity?.rawPayloadHash, "sha256:abc123")
}

func testCodexTaskActivityStoreMarksStopAsErrorOnlyWithExplicitFailureSignal() {
    var store = CodexTaskActivityStore()

    store.apply(CodexHookEvent(
        eventID: "event-1",
        nodeID: "node-a",
        observedAt: Date(timeIntervalSince1970: 100),
        hookEvent: .userPromptSubmit,
        sessionID: "session-success",
        turnID: "turn-success",
        cwd: nil,
        model: nil,
        toolName: nil
    ))
    store.apply(CodexHookEvent(
        eventID: "event-2",
        nodeID: "node-a",
        observedAt: Date(timeIntervalSince1970: 110),
        hookEvent: .stop,
        sessionID: "session-success",
        turnID: "turn-success",
        cwd: nil,
        model: nil,
        toolName: nil
    ))
    store.apply(CodexHookEvent(
        eventID: "event-3",
        nodeID: "node-a",
        observedAt: Date(timeIntervalSince1970: 120),
        hookEvent: .userPromptSubmit,
        sessionID: "session-error",
        turnID: "turn-error",
        cwd: nil,
        model: nil,
        toolName: nil
    ))
    store.apply(CodexHookEvent(
        eventID: "event-4",
        nodeID: "node-a",
        observedAt: Date(timeIntervalSince1970: 130),
        hookEvent: .stop,
        sessionID: "session-error",
        turnID: "turn-error",
        cwd: nil,
        model: nil,
        toolName: nil,
        statusHint: "failed",
        errorMessage: "tool execution failed"
    ))

    let success = store.activities.first { $0.turnID == "turn-success" }
    let failure = store.activities.first { $0.turnID == "turn-error" }
    XCTAssertEqual(success?.status, .done)
    XCTAssertEqual(success?.phase, .completed)
    XCTAssertEqual(failure?.status, .error)
    XCTAssertEqual(failure?.phase, .completed)
    XCTAssertEqual(failure?.errorMessage, "tool execution failed")
}

func testCodexTaskActivityStoreDoesNotCompleteTurnFromNonTerminalSuccessHint() {
    var store = CodexTaskActivityStore()

    store.apply(CodexHookEvent(
        eventID: "event-1",
        nodeID: "node-a",
        observedAt: Date(timeIntervalSince1970: 100),
        hookEvent: .postToolUse,
        sessionID: "session-1",
        turnID: "turn-1",
        cwd: nil,
        model: nil,
        toolName: "Bash",
        statusHint: "success"
    ))

    let activity = store.activities.first
    XCTAssertEqual(activity?.status, .running)
    XCTAssertEqual(activity?.phase, .tooling)
    XCTAssertNil(activity?.completedAt)
}

func testCodexTaskActivityStoreDoesNotCompleteTurnFromSubagentStop() {
    var store = CodexTaskActivityStore()

    store.apply(CodexHookEvent(
        eventID: "event-1",
        nodeID: "node-a",
        observedAt: Date(timeIntervalSince1970: 100),
        hookEvent: .userPromptSubmit,
        sessionID: "session-1",
        turnID: "turn-1",
        cwd: nil,
        model: nil,
        toolName: nil
    ))
    store.apply(CodexHookEvent(
        eventID: "event-2",
        nodeID: "node-a",
        observedAt: Date(timeIntervalSince1970: 110),
        hookEvent: .subagentStart,
        sessionID: "session-1",
        turnID: "turn-1",
        cwd: nil,
        model: nil,
        toolName: "ReviewAgent",
        statusHint: "started"
    ))
    store.apply(CodexHookEvent(
        eventID: "event-3",
        nodeID: "node-a",
        observedAt: Date(timeIntervalSince1970: 120),
        hookEvent: .subagentStop,
        sessionID: "session-1",
        turnID: "turn-1",
        cwd: nil,
        model: nil,
        toolName: "ReviewAgent",
        statusHint: "success"
    ))

    let activityAfterSubagentStop = store.activities.first
    XCTAssertEqual(activityAfterSubagentStop?.status, .running)
    XCTAssertEqual(activityAfterSubagentStop?.phase, .tooling)
    XCTAssertEqual(activityAfterSubagentStop?.toolName, "ReviewAgent")
    XCTAssertNil(activityAfterSubagentStop?.completedAt)
    XCTAssertEqual(activityAfterSubagentStop?.timeline.map(\.hookEvent), [.userPromptSubmit, .subagentStart, .subagentStop])

    store.apply(CodexHookEvent(
        eventID: "event-4",
        nodeID: "node-a",
        observedAt: Date(timeIntervalSince1970: 130),
        hookEvent: .stop,
        sessionID: "session-1",
        turnID: "turn-1",
        cwd: nil,
        model: nil,
        toolName: nil
    ))

    let completedActivity = store.activities.first
    XCTAssertEqual(completedActivity?.status, .done)
    XCTAssertEqual(completedActivity?.phase, .completed)
    XCTAssertEqual(completedActivity?.completedAt, Date(timeIntervalSince1970: 130))
}

func testCodexMenuBarTaskSummaryUsesPersistentTwoRows() {
    let activities = [
        CodexTaskActivity(
            nodeID: "local-node",
            sessionID: "session-a",
            turnID: "turn-a",
            badge: "A1",
            cwd: "/workspace/app",
            model: "gpt-5",
            status: .running,
            phase: .tooling,
            toolName: "Bash",
            startedAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 120),
            completedAt: nil,
            timeline: []
        ),
        CodexTaskActivity(
            nodeID: "remote-node",
            sessionID: "session-b",
            turnID: "turn-b",
            badge: "A2",
            cwd: "/workspace/api",
            model: "gpt-5",
            status: .done,
            phase: .completed,
            toolName: nil,
            startedAt: Date(timeIntervalSince1970: 90),
            updatedAt: Date(timeIntervalSince1970: 130),
            completedAt: Date(timeIntervalSince1970: 130),
            timeline: []
        ),
    ]

    let summary = CodexMenuBarTaskSummary.make(
        activities: activities,
        maxTasks: 2,
        now: Date(timeIntervalSince1970: 140)
    )

    XCTAssertEqual(summary.topRow, "A2D A1R")
    XCTAssertEqual(summary.bottomRow, "T2R1Q0D1E0")
    XCTAssert(summary.tooltip.contains("A1 local-node session-a turn-a running tooling Bash"))
    XCTAssert(summary.tooltip.contains("A2 remote-node session-b turn-b done completed"))
}

func testCodexMenuBarTaskSummaryUsesZeroCountsWithoutPlaceholders() {
    let summary = CodexMenuBarTaskSummary.make(activities: [], maxTasks: 2)

    XCTAssertEqual(summary.topRow, "0")
    XCTAssertEqual(summary.bottomRow, "T0R0Q0D0E0")
    XCTAssertFalse(summary.topRow.contains("--"))
    XCTAssertFalse(summary.bottomRow.contains("--"))
}

func testCodexMenuBarTaskSummaryShowsOverflowCountAndKeepsStaleOutOfTopRow() {
    let activities = [
        CodexTaskActivity(
            nodeID: "local-node",
            sessionID: "session-a",
            turnID: "turn-a",
            badge: "A1",
            cwd: nil,
            model: nil,
            status: .running,
            phase: .tooling,
            toolName: nil,
            startedAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 130),
            completedAt: nil,
            timeline: []
        ),
        CodexTaskActivity(
            nodeID: "local-node",
            sessionID: "session-b",
            turnID: "turn-b",
            badge: "A2",
            cwd: nil,
            model: nil,
            status: .waiting,
            phase: .prompt,
            toolName: nil,
            startedAt: Date(timeIntervalSince1970: 105),
            updatedAt: Date(timeIntervalSince1970: 140),
            completedAt: nil,
            timeline: []
        ),
        CodexTaskActivity(
            nodeID: "remote-node",
            sessionID: "session-c",
            turnID: "turn-c",
            badge: "A3",
            cwd: nil,
            model: nil,
            status: .done,
            phase: .completed,
            toolName: nil,
            startedAt: Date(timeIntervalSince1970: 110),
            updatedAt: Date(timeIntervalSince1970: 150),
            completedAt: Date(timeIntervalSince1970: 150),
            timeline: []
        ),
        CodexTaskActivity(
            nodeID: "remote-node",
            sessionID: "session-d",
            turnID: "turn-d",
            badge: "A4",
            cwd: nil,
            model: nil,
            status: .stale,
            phase: .tooling,
            toolName: nil,
            startedAt: Date(timeIntervalSince1970: 115),
            updatedAt: Date(timeIntervalSince1970: 160),
            completedAt: nil,
            timeline: []
        ),
    ]

    let summary = CodexMenuBarTaskSummary.make(
        activities: activities,
        maxTasks: 2,
        now: Date(timeIntervalSince1970: 180)
    )

    XCTAssertEqual(summary.topRow, "A3D A2Q +1")
    XCTAssertEqual(summary.bottomRow, "T4R1Q1D1E0")
    XCTAssertFalse(summary.topRow.contains("A4"))
    XCTAssert(summary.tooltip.contains("A4 remote-node session-d turn-d stale tooling"))
}

func testCodexMenuBarTaskSummaryCountsOnlyRecentTerminalEventsAndKeepsStaleOutOfErrors() {
    let activities = [
        CodexTaskActivity(
            nodeID: "local-node",
            sessionID: "session-running",
            turnID: "turn-running",
            badge: "A1",
            cwd: nil,
            model: nil,
            status: .running,
            phase: .tooling,
            toolName: nil,
            startedAt: Date(timeIntervalSince1970: 7_000),
            updatedAt: Date(timeIntervalSince1970: 7_100),
            completedAt: nil,
            timeline: []
        ),
        CodexTaskActivity(
            nodeID: "local-node",
            sessionID: "session-waiting",
            turnID: "turn-waiting",
            badge: "A2",
            cwd: nil,
            model: nil,
            status: .waiting,
            phase: .prompt,
            toolName: nil,
            startedAt: Date(timeIntervalSince1970: 7_010),
            updatedAt: Date(timeIntervalSince1970: 7_120),
            completedAt: nil,
            timeline: []
        ),
        CodexTaskActivity(
            nodeID: "local-node",
            sessionID: "session-recent-done",
            turnID: "turn-recent-done",
            badge: "A3",
            cwd: nil,
            model: nil,
            status: .done,
            phase: .completed,
            toolName: nil,
            startedAt: Date(timeIntervalSince1970: 7_020),
            updatedAt: Date(timeIntervalSince1970: 7_200),
            completedAt: Date(timeIntervalSince1970: 7_200),
            timeline: []
        ),
        CodexTaskActivity(
            nodeID: "local-node",
            sessionID: "session-old-done",
            turnID: "turn-old-done",
            badge: "A4",
            cwd: nil,
            model: nil,
            status: .done,
            phase: .completed,
            toolName: nil,
            startedAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 2_000),
            completedAt: Date(timeIntervalSince1970: 2_000),
            timeline: []
        ),
        CodexTaskActivity(
            nodeID: "local-node",
            sessionID: "session-recent-error",
            turnID: "turn-recent-error",
            badge: "A5",
            cwd: nil,
            model: nil,
            status: .error,
            phase: .completed,
            toolName: nil,
            startedAt: Date(timeIntervalSince1970: 7_030),
            updatedAt: Date(timeIntervalSince1970: 7_300),
            completedAt: Date(timeIntervalSince1970: 7_300),
            timeline: []
        ),
        CodexTaskActivity(
            nodeID: "local-node",
            sessionID: "session-stale",
            turnID: "turn-stale",
            badge: "A6",
            cwd: nil,
            model: nil,
            status: .stale,
            phase: .tooling,
            toolName: nil,
            startedAt: Date(timeIntervalSince1970: 6_000),
            updatedAt: Date(timeIntervalSince1970: 6_100),
            completedAt: nil,
            timeline: []
        ),
    ]

    let summary = CodexMenuBarTaskSummary.make(
        activities: activities,
        maxTasks: 3,
        now: Date(timeIntervalSince1970: 7_400),
        recentWindow: 3600
    )

    XCTAssertEqual(summary.bottomRow, "T6R1Q1D1E1")
    XCTAssert(summary.topRow.contains("A5E"))
    XCTAssert(summary.topRow.contains("A3D"))
    XCTAssertFalse(summary.bottomRow.contains("--"))
}

func testMenuBarStatusLayoutAlwaysUsesFixedTwoRows() {
    let fallbackLayout = MenuBarStatusLayout.make(
        presentation: MenuBarStatusPresentation(title: "", hidesHealthyStatusImage: false),
        fallbackTitle: " Refresh Failed "
    )
    let explicitLayout = MenuBarStatusLayout.make(
        presentation: MenuBarStatusPresentation(
            title: " T",
            topRow: "T",
            bottomRow: "OK",
            hidesHealthyStatusImage: true
        ),
        fallbackTitle: "Healthy"
    )

    XCTAssertEqual(fallbackLayout.topRow, "Refresh Failed")
    XCTAssertEqual(fallbackLayout.bottomRow, "Refresh Failed")
    XCTAssertEqual(fallbackLayout.width, 128)
    XCTAssertEqual(fallbackLayout.height, 22)
    XCTAssertEqual(fallbackLayout.topRowHeight, 13)
    XCTAssertEqual(fallbackLayout.bottomRowHeight, 9)
    XCTAssertEqual(explicitLayout.topRow, "T")
    XCTAssertEqual(explicitLayout.bottomRow, "OK")
    XCTAssertNotEqual(explicitLayout.width, Double(explicitLayout.topRow.count))
}

func testMenuBarStatusLayoutUsesFixedCellWidthsForEnabledItems() {
    let presentation = MenuBarStatusPresentation(
        title: "$1.00 A1R",
        cells: [
            MenuBarStatusCell(value: "$1.00", label: "Cost", width: 58),
            MenuBarStatusCell(value: "A1R", label: "T1R1Q0D0E0", width: 88),
        ],
        topRow: "$1.00 | A1R",
        bottomRow: "Cost | T1R1Q0D0E0",
        hidesHealthyStatusImage: true
    )

    let layout = MenuBarStatusLayout.make(presentation: presentation, fallbackTitle: "OK")

    XCTAssertEqual(layout.cells.count, 2)
    XCTAssertEqual(layout.width, 58 + 88 + 1 + 3 + 3)
    XCTAssertEqual(MenuBarStatusLayout.separatorHeight, 14)
}

func testMenuBarStatusCellUsesBoundedSteppedAdaptiveWidth() {
    let cell = MenuBarStatusCell(value: "Auto Review", label: "Model", width: 100)

    XCTAssertEqual(cell.fittedWidth(contentWidth: 20), 28)
    XCTAssertEqual(cell.fittedWidth(contentWidth: 69), 80)
    XCTAssertEqual(cell.fittedWidth(contentWidth: 200), 100)
}

func testCodexTaskConsoleRowsExposeIdentityAndSortByRecentUpdate() {
    let older = CodexTaskActivity(
        nodeID: "local-node",
        sessionID: "session-a",
        turnID: "turn-a",
        badge: "A1",
        cwd: "/workspace/app",
        model: "gpt-5",
        status: .running,
        phase: .tooling,
        toolName: "Bash",
        startedAt: Date(timeIntervalSince1970: 100),
        updatedAt: Date(timeIntervalSince1970: 120),
        completedAt: nil,
        timeline: [
            CodexTaskActivity.TimelineEvent(
                eventID: "event-1",
                hookEvent: .preToolUse,
                observedAt: Date(timeIntervalSince1970: 115),
                sessionID: "session-a",
                turnID: "turn-a",
                cwd: nil,
                model: nil,
                toolName: "Bash"
            ),
            CodexTaskActivity.TimelineEvent(
                eventID: "event-0",
                hookEvent: .userPromptSubmit,
                observedAt: Date(timeIntervalSince1970: 100),
                sessionID: "session-a",
                turnID: "turn-a",
                cwd: "/workspace/app",
                model: "gpt-5",
                toolName: nil,
                statusHint: "running",
                toolUseID: "tool-0",
                errorMessage: nil,
                transcriptPath: "/tmp/transcript.jsonl",
                userAgent: "Codex Desktop/0.125.0",
                rawPayloadHash: "sha256:abc123",
                rawPayloadJSON: #"{"event_id":"event-0"}"#
            ),
        ]
    )
    let newer = CodexTaskActivity(
        nodeID: "remote-node",
        sessionID: "session-b",
        turnID: "turn-b",
        badge: "A2",
        cwd: "/workspace/api",
        model: "gpt-5",
        status: .done,
        phase: .completed,
        toolName: nil,
        startedAt: Date(timeIntervalSince1970: 90),
        updatedAt: Date(timeIntervalSince1970: 130),
        completedAt: Date(timeIntervalSince1970: 130),
        timeline: []
    )

    let rows = CodexTaskConsoleModel.rows(activities: [older, newer])

    XCTAssertEqual(rows.map(\.badge), ["A1", "A2"])
    XCTAssertEqual(rows.first?.status, "R")
    XCTAssertEqual(rows.first?.isActive, true)
    XCTAssertEqual(rows.first?.nodeID, "local-node")
    XCTAssertEqual(rows.first?.sessionID, "session-a")
    XCTAssertEqual(rows.first?.turnID, "turn-a")
    XCTAssertEqual(rows.first?.toolName, "Bash")
    XCTAssertEqual(rows.first?.events.map(\.eventID), ["event-0", "event-1"])
    XCTAssertEqual(rows.first?.events.first?.eventName, "UserPromptSubmit")
    XCTAssertEqual(rows.first?.events.first?.sessionID, "session-a")
    XCTAssertEqual(rows.first?.events.first?.turnID, "turn-a")
    XCTAssertEqual(rows.first?.events.first?.statusHint, "running")
    XCTAssertEqual(rows.first?.events.first?.toolUseID, "tool-0")
    XCTAssertEqual(rows.first?.events.first?.transcriptPath, "/tmp/transcript.jsonl")
    XCTAssertEqual(rows.first?.events.first?.userAgent, "Codex Desktop/0.125.0")
    XCTAssertEqual(rows.first?.userAgent, "Codex Desktop/0.125.0")
    XCTAssertEqual(rows.first?.events.first?.rawPayloadHash, "sha256:abc123")
    XCTAssertEqual(rows.first?.events.first?.rawPayloadJSON, #"{"event_id":"event-0"}"#)
    XCTAssertEqual(rows.first?.events.last?.toolName, "Bash")
    XCTAssertEqual(rows.first?.latestEvents(limit: 1).map(\.eventID), ["event-1"])
    XCTAssertEqual(rows.first?.latestEvents(limit: 20).map(\.eventID), ["event-1", "event-0"])
    XCTAssertEqual(rows.last?.status, "D")
    XCTAssertEqual(rows.last?.isActive, false)
}

func testCodexTaskConsoleGatewayUsageDetailKeepsSupplementaryFields() {
    let usage = UsageLog(
        id: 133605,
        requestID: "req-133605",
        model: "gpt-5.5",
        upstreamModel: "gpt-5.5-openai-compact",
        modelMappingChain: "gpt-5.5 -> gpt-5.5-openai-compact",
        serviceTier: "priority",
        reasoningEffort: "xhigh",
        inboundEndpoint: "/openai/v1/responses",
        upstreamEndpoint: "/v1/responses",
        inputTokens: 430,
        outputTokens: 1172,
        cacheCreationTokens: 30,
        cacheReadTokens: 164224,
        totalCost: 0.067,
        actualCost: 0.238844,
        requestType: "stream",
        stream: true,
        durationMs: 1200,
        firstTokenMs: 250,
        userAgent: "codex_cli_rs/0.125.0",
        billingMode: "token",
        createdAt: Date(timeIntervalSince1970: 100)
    )

    let detail = CodexTaskConsoleModel.gatewayUsageDetail(latestUsage: usage)

    XCTAssertEqual(detail?.requestID, "req-133605")
    XCTAssertEqual(detail?.model, "gpt-5.5")
    XCTAssertEqual(detail?.upstreamModel, "gpt-5.5-openai-compact")
    XCTAssertEqual(detail?.modelMappingChain, "gpt-5.5 -> gpt-5.5-openai-compact")
    XCTAssertEqual(detail?.serviceTier, "priority")
    XCTAssertEqual(detail?.reasoningEffort, "xhigh")
    XCTAssertEqual(detail?.inboundEndpoint, "/openai/v1/responses")
    XCTAssertEqual(detail?.upstreamEndpoint, "/v1/responses")
    XCTAssertEqual(detail?.requestType, "stream")
    XCTAssertEqual(detail?.stream, true)
    XCTAssertEqual(detail?.totalTokens, 165_856)
    XCTAssertEqual(detail?.actualCost ?? 0, 0.238844, accuracy: 0.000001)
    XCTAssertEqual(detail?.totalCost ?? 0, 0.067, accuracy: 0.000001)
    XCTAssertEqual(detail?.durationMs ?? 0, 1200, accuracy: 0.000001)
    XCTAssertEqual(detail?.firstTokenMs ?? 0, 250, accuracy: 0.000001)
    XCTAssertEqual(detail?.userAgent, "codex_cli_rs/0.125.0")
    XCTAssertEqual(detail?.billingMode, "token")
}

func testCodexTaskConsoleGatewayConcurrencyDetailKeepsAdminLoadFields() {
    let concurrency = UserRealtimeConcurrency(
        userID: 42,
        userEmail: "target@example.com",
        username: "target",
        currentInUse: 3,
        maxCapacity: 100,
        loadPercentage: 3,
        waitingInQueue: 1
    )

    let detail = CodexTaskConsoleModel.gatewayConcurrencyDetail(realtimeConcurrency: concurrency)

    XCTAssertEqual(detail?.userID, 42)
    XCTAssertEqual(detail?.userEmail, "target@example.com")
    XCTAssertEqual(detail?.username, "target")
    XCTAssertEqual(detail?.currentInUse, 3)
    XCTAssertEqual(detail?.maxCapacity, 100)
    XCTAssertEqual(detail?.capacityText, "3/100")
    XCTAssertEqual(detail?.waitingInQueue, 1)
    XCTAssertEqual(detail?.loadPercentage ?? 0, 3, accuracy: 0.000001)
    XCTAssertNil(CodexTaskConsoleModel.gatewayConcurrencyDetail(realtimeConcurrency: nil))
}

func testCodexHookSignatureVerifierAcceptsValidSignature() throws {
    let body = Data(#"{"event_id":"event-1"}"#.utf8)
    let secret = "node-secret"
    let signature = CodexHookSignatureVerifier.signatureHeader(for: body, secret: secret)

    XCTAssertTrue(try CodexHookSignatureVerifier.verify(body: body, signatureHeader: signature, secret: secret))
}

func testCodexHookSignatureVerifierRejectsInvalidSignature() throws {
    let body = Data(#"{"event_id":"event-1"}"#.utf8)

    XCTAssertFalse(try CodexHookSignatureVerifier.verify(body: body, signatureHeader: "hmac-sha256=bad", secret: "node-secret"))
}

func testCodexHookReplayGuardRejectsDuplicateAndStaleEvents() {
    var guardState = CodexHookReplayGuard(allowedClockSkewSeconds: 300)
    let now = Date(timeIntervalSince1970: 1_000)

    XCTAssertTrue(guardState.accepts(eventID: "event-1", timestamp: Date(timeIntervalSince1970: 950), now: now))
    XCTAssertFalse(guardState.accepts(eventID: "event-1", timestamp: Date(timeIntervalSince1970: 950), now: now))
    XCTAssertFalse(guardState.accepts(eventID: "event-2", timestamp: Date(timeIntervalSince1970: 100), now: now))
}

func testCodexHookEventIngestorVerifiesDecodesAndAppliesEvent() throws {
    let body = """
    {
      "schema_version": 1,
      "event_id": "event-1",
      "node_id": "node-a",
      "observed_at": "2026-06-01T09:00:00Z",
      "hook_event": "UserPromptSubmit",
      "session_id": "session-1",
      "turn_id": "turn-1"
    }
    """.data(using: .utf8)!
    let secret = "node-secret"
    let signature = CodexHookSignatureVerifier.signatureHeader(for: body, secret: secret)
    var ingestor = CodexHookEventIngestor(nodeSecrets: ["node-a": secret], allowedClockSkewSeconds: 300)

    let result = try ingestor.ingest(
        body: body,
        nodeIDHeader: "node-a",
        timestampHeader: "2026-06-01T09:00:00Z",
        signatureHeader: signature,
        now: ISO8601DateFormatter().date(from: "2026-06-01T09:00:10Z")!
    )

    XCTAssertEqual(result.event.eventID, "event-1")
    let rawPayload = try XCTUnwrap(result.event.rawPayloadJSON?.data(using: .utf8))
    let rawObject = try XCTUnwrap(JSONSerialization.jsonObject(with: rawPayload) as? [String: Any])
    XCTAssertEqual(rawObject["event_id"] as? String, "event-1")
    XCTAssertEqual(result.activities.first?.status, .running)
    XCTAssertEqual(result.activities.first?.badge, "A1")
    XCTAssertEqual(result.activities.first?.timeline.first?.rawPayloadJSON, result.event.rawPayloadJSON)
    XCTAssertEqual(rawObject["session_id"] as? String, "session-1")
}

func testCodexHookEventIngestorRejectsMismatchedNodeHeader() throws {
    let body = """
    {
      "schema_version": 1,
      "event_id": "event-1",
      "node_id": "node-a",
      "observed_at": "2026-06-01T09:00:00Z",
      "hook_event": "UserPromptSubmit",
      "session_id": "session-1",
      "turn_id": "turn-1"
    }
    """.data(using: .utf8)!
    let secret = "node-secret"
    let signature = CodexHookSignatureVerifier.signatureHeader(for: body, secret: secret)
    var ingestor = CodexHookEventIngestor(nodeSecrets: ["node-b": secret], allowedClockSkewSeconds: 300)

    XCTAssertThrowsError(try ingestor.ingest(
        body: body,
        nodeIDHeader: "node-b",
        timestampHeader: "2026-06-01T09:00:00Z",
        signatureHeader: signature,
        now: ISO8601DateFormatter().date(from: "2026-06-01T09:00:10Z")!
    )) { error in
        XCTAssertEqual(error as? CodexHookIngestError, .nodeMismatch)
    }
}

func testCodexHookReceiverAcceptsValidHookPost() throws {
    let body = """
    {
      "schema_version": 1,
      "event_id": "event-1",
      "node_id": "node-a",
      "observed_at": "2026-06-01T09:00:00Z",
      "hook_event": "UserPromptSubmit",
      "session_id": "session-1",
      "turn_id": "turn-1"
    }
    """.data(using: .utf8)!
    let secret = "node-secret"
    let signature = CodexHookSignatureVerifier.signatureHeader(for: body, secret: secret)
    var receiver = CodexHookHTTPReceiver(ingestor: CodexHookEventIngestor(nodeSecrets: ["node-a": secret], allowedClockSkewSeconds: 300))

    let response = receiver.handle(
        CodexHookHTTPRequest(
            method: "POST",
            path: "/codex-hooks/events",
            headers: [
                "x-s2sb-node-id": "node-a",
                "x-s2sb-timestamp": "2026-06-01T09:00:00Z",
                "x-s2sb-signature": signature,
            ],
            body: body
        ),
        now: ISO8601DateFormatter().date(from: "2026-06-01T09:00:10Z")!
    )

    XCTAssertEqual(response.statusCode, 202)
    XCTAssertEqual(response.result?.event.schemaVersion, 1)
    XCTAssertEqual(response.result?.event.eventID, "event-1")
    XCTAssertEqual(response.result?.activities.first?.badge, "A1")
}

func testLocalCodexHookReceiverServerAcceptsSignedEventThroughURLSession() async throws {
    let port = try availableLoopbackPort()
    let node = try CodexNode(
        id: "local-node",
        name: "本机",
        kind: .local,
        localReceiverPort: Int(port),
        remoteReceiverPort: nil,
        ssh: nil,
        codexHomeOverride: nil
    )
    let registeredNode = CodexRegisteredNode(node: node, secret: "node-secret")
    let recorder = await MainActor.run {
        LocalReceiverTestRecorder()
    }
    let server = await MainActor.run {
        LocalCodexHookReceiverServer(
            port: port,
            nodeSecrets: [registeredNode.node.id: registeredNode.secret],
            onStateChange: { state in
                recorder.append(state: state)
            },
            onEvent: { event in
                recorder.append(event: event)
            }
        )
    }
    try await MainActor.run {
        try server.start()
    }
    defer {
        Task { @MainActor in
            server.stop()
        }
    }
    try await waitForListenerReady(await MainActor.run { recorder.states })

    let now = Date()
    let request = try CodexHookTestEventRequestBuilder.build(
        registeredNode: registeredNode,
        now: now,
        receiverURL: node.localHookReceiverURL
    )
    let (_, response) = try await URLSession.shared.data(for: request)
    let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)

    XCTAssertEqual(httpResponse.statusCode, 202)
    let events = await MainActor.run { recorder.events }
    XCTAssertEqual(events.count, 1)
    XCTAssertEqual(events.first?.nodeID, "local-node")
    XCTAssertEqual(events.first?.sessionID, "sub2api-statusbar-test-session")
    XCTAssertEqual(events.first?.turnID, "sub2api-statusbar-test-turn-\(Int(now.timeIntervalSince1970))")
}

func testCodexHookReceiverRejectsWrongRouteMissingHeadersAndReplay() throws {
    let body = """
    {
      "schema_version": 1,
      "event_id": "event-1",
      "node_id": "node-a",
      "observed_at": "2026-06-01T09:00:00Z",
      "hook_event": "UserPromptSubmit",
      "session_id": "session-1",
      "turn_id": "turn-1"
    }
    """.data(using: .utf8)!
    let secret = "node-secret"
    let signature = CodexHookSignatureVerifier.signatureHeader(for: body, secret: secret)
    var receiver = CodexHookHTTPReceiver(ingestor: CodexHookEventIngestor(nodeSecrets: ["node-a": secret], allowedClockSkewSeconds: 300))
    let now = ISO8601DateFormatter().date(from: "2026-06-01T09:00:10Z")!
    let validRequest = CodexHookHTTPRequest(
        method: "POST",
        path: "/codex-hooks/events",
        headers: [
            "X-S2SB-Node-ID": "node-a",
            "X-S2SB-Timestamp": "2026-06-01T09:00:00Z",
            "X-S2SB-Signature": signature,
        ],
        body: body
    )

    XCTAssertEqual(receiver.handle(CodexHookHTTPRequest(method: "GET", path: "/codex-hooks/events", headers: [:], body: Data()), now: now).statusCode, 404)
    XCTAssertEqual(receiver.handle(CodexHookHTTPRequest(method: "POST", path: "/codex/hooks", headers: validRequest.headers, body: body), now: now).statusCode, 404)
    XCTAssertEqual(receiver.handle(CodexHookHTTPRequest(method: "POST", path: "/codex-hooks/events", headers: [:], body: body), now: now).statusCode, 401)
    XCTAssertEqual(receiver.handle(
        CodexHookHTTPRequest(
            method: "POST",
            path: "/codex-hooks/events",
            headers: [
                "X-Sub2API-Node-ID": "node-a",
                "X-Sub2API-Hook-Timestamp": "2026-06-01T09:00:00Z",
                "X-Sub2API-Hook-Signature": signature,
            ],
            body: body
        ),
        now: now
    ).statusCode, 401)
    XCTAssertEqual(receiver.handle(validRequest, now: now).statusCode, 202)
    XCTAssertEqual(receiver.handle(validRequest, now: now).statusCode, 409)
}

func testCodexHookReceiverRejectsHeaderTimestampThatDoesNotMatchSignedEventTimestamp() throws {
    let body = """
    {
      "schema_version": 1,
      "event_id": "event-1",
      "node_id": "node-a",
      "observed_at": "2026-06-01T09:00:00Z",
      "hook_event": "UserPromptSubmit",
      "session_id": "session-1",
      "turn_id": "turn-1"
    }
    """.data(using: .utf8)!
    let secret = "node-secret"
    let signature = CodexHookSignatureVerifier.signatureHeader(for: body, secret: secret)
    var receiver = CodexHookHTTPReceiver(ingestor: CodexHookEventIngestor(nodeSecrets: ["node-a": secret], allowedClockSkewSeconds: 300))

    let response = receiver.handle(
        CodexHookHTTPRequest(
            method: "POST",
            path: "/codex-hooks/events",
            headers: [
                "X-S2SB-Node-ID": "node-a",
                "X-S2SB-Timestamp": "2026-06-01T09:00:10Z",
                "X-S2SB-Signature": signature,
            ],
            body: body
        ),
        now: ISO8601DateFormatter().date(from: "2026-06-01T09:00:10Z")!
    )

    XCTAssertEqual(response.statusCode, 400)
    XCTAssertEqual(response.error, .timestampMismatch)
}

func testCodexHookReceiverRejectsMissingAndUnsupportedSchemaVersion() throws {
    let missingSchemaBody = """
    {
      "event_id": "event-missing-schema",
      "node_id": "node-a",
      "observed_at": "2026-06-01T09:00:00Z",
      "hook_event": "UserPromptSubmit",
      "session_id": "session-1",
      "turn_id": "turn-1"
    }
    """.data(using: .utf8)!
    let unsupportedSchemaBody = """
    {
      "schema_version": 2,
      "event_id": "event-unsupported-schema",
      "node_id": "node-a",
      "observed_at": "2026-06-01T09:00:00Z",
      "hook_event": "UserPromptSubmit",
      "session_id": "session-1",
      "turn_id": "turn-1"
    }
    """.data(using: .utf8)!
    let secret = "node-secret"
    let now = ISO8601DateFormatter().date(from: "2026-06-01T09:00:10Z")!
    var receiver = CodexHookHTTPReceiver(ingestor: CodexHookEventIngestor(nodeSecrets: ["node-a": secret], allowedClockSkewSeconds: 300))

    let missingSchemaResponse = receiver.handle(
        CodexHookHTTPRequest(
            method: "POST",
            path: "/codex-hooks/events",
            headers: [
                "X-S2SB-Node-ID": "node-a",
                "X-S2SB-Timestamp": "2026-06-01T09:00:00Z",
                "X-S2SB-Signature": CodexHookSignatureVerifier.signatureHeader(for: missingSchemaBody, secret: secret),
            ],
            body: missingSchemaBody
        ),
        now: now
    )
    let unsupportedSchemaResponse = receiver.handle(
        CodexHookHTTPRequest(
            method: "POST",
            path: "/codex-hooks/events",
            headers: [
                "X-S2SB-Node-ID": "node-a",
                "X-S2SB-Timestamp": "2026-06-01T09:00:00Z",
                "X-S2SB-Signature": CodexHookSignatureVerifier.signatureHeader(for: unsupportedSchemaBody, secret: secret),
            ],
            body: unsupportedSchemaBody
        ),
        now: now
    )

    XCTAssertEqual(missingSchemaResponse.statusCode, 400)
    XCTAssertNil(missingSchemaResponse.error)
    XCTAssertEqual(unsupportedSchemaResponse.statusCode, 400)
    XCTAssertEqual(unsupportedSchemaResponse.error, .unsupportedSchemaVersion(2))
}

func testCodexHookHTTPMessageCodecParsesRequestAndSerializesResponse() throws {
    let raw = Data("""
    POST /codex-hooks/events HTTP/1.1\r
    Host: 127.0.0.1:43210\r
    X-S2SB-Node-ID: node-a\r
    Content-Length: 17\r
    \r
    {"event_id":"e1"}
    """.utf8)

    let request = try CodexHookHTTPMessageCodec.parseRequest(raw)
    let response = CodexHookHTTPMessageCodec.serializeResponse(statusCode: 202)

    XCTAssertEqual(request.method, "POST")
    XCTAssertEqual(request.path, "/codex-hooks/events")
    XCTAssertEqual(request.headers["X-S2SB-Node-ID"], "node-a")
    XCTAssertEqual(String(data: request.body, encoding: .utf8), #"{"event_id":"e1"}"#)
    XCTAssertEqual(
        String(data: response, encoding: .utf8),
        "HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    )
}

func testCodexHookHTTPMessageCodecDetectsCompleteRequestLengthForSplitBodies() throws {
    let headers = Data("POST /codex-hooks/events HTTP/1.1\r\nHost: 127.0.0.1:43210\r\nContent-Length: 17\r\n\r\n".utf8)
    let partial = headers + Data(#"{"event_id":"e"#.utf8)
    let complete = headers + Data(#"{"event_id":"e1"}"#.utf8)

    XCTAssertNil(try CodexHookHTTPMessageCodec.completeRequestLength(in: partial))
    XCTAssertEqual(try CodexHookHTTPMessageCodec.completeRequestLength(in: complete), complete.count)
}

func testCodexHookHTTPMessageCodecTreatsHeaderOnlyRequestWithoutContentLengthAsComplete() throws {
    let request = Data("GET /codex-hooks/events HTTP/1.1\r\nHost: 127.0.0.1:43210\r\n\r\n".utf8)

    XCTAssertEqual(try CodexHookHTTPMessageCodec.completeRequestLength(in: request), request.count)
}

func testCodexHookTestEventRequestBuilderBuildsSignedLocalReceiverRequest() throws {
    let node = try CodexNode(
        id: "local-node",
        name: "本机",
        kind: .local,
        localReceiverPort: 43210,
        remoteReceiverPort: nil,
        ssh: nil,
        codexHomeOverride: nil
    )
    let registeredNode = CodexRegisteredNode(node: node, secret: "node-secret")
    let now = ISO8601DateFormatter().date(from: "2026-06-01T09:00:10Z")!

    let request = try CodexHookTestEventRequestBuilder.build(
        registeredNode: registeredNode,
        now: now,
        receiverURL: node.localHookReceiverURL
    )
    let body = try XCTUnwrap(request.httpBody)
    let bodyText = String(data: body, encoding: .utf8) ?? ""
    let event = try JSONDecoder.codexHook.decode(CodexHookEvent.self, from: body)

    XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:43210/codex-hooks/events")
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.value(forHTTPHeaderField: CodexHookHTTPReceiver.nodeIDHeader), "local-node")
    XCTAssertEqual(request.value(forHTTPHeaderField: CodexHookHTTPReceiver.timestampHeader), "2026-06-01T09:00:10Z")
    XCTAssertEqual(event.schemaVersion, 1)
    XCTAssertTrue(bodyText.contains("\"schema_version\""))
    XCTAssertTrue(bodyText.contains("\"event_id\""))
    XCTAssertFalse(bodyText.contains("\"schemaVersion\""))
    XCTAssertFalse(bodyText.contains("\"eventId\""))
    XCTAssertEqual(event.nodeID, "local-node")
    XCTAssertEqual(event.hookEvent, .userPromptSubmit)
    XCTAssertEqual(event.sessionID, "sub2api-statusbar-test-session")
    XCTAssertEqual(event.turnID, "sub2api-statusbar-test-turn-1780304410")
    XCTAssertTrue(try CodexHookSignatureVerifier.verify(
        body: body,
        signatureHeader: try XCTUnwrap(request.value(forHTTPHeaderField: CodexHookHTTPReceiver.signatureHeader)),
        secret: "node-secret"
    ))
}

func testLocalCodexHookReceiverServerAcceptsSignedEventOverLoopback() async throws {
    let port = try availableLoopbackPort()
    let node = try CodexNode(
        id: "local-node",
        name: "本机",
        kind: .local,
        localReceiverPort: Int(port),
        remoteReceiverPort: nil,
        ssh: nil,
        codexHomeOverride: nil
    )
    let registeredNode = CodexRegisteredNode(node: node, secret: "node-secret")
    let recorder = await MainActor.run {
        LocalReceiverTestRecorder()
    }
    let server = await MainActor.run {
        LocalCodexHookReceiverServer(
            port: port,
            nodeSecrets: [registeredNode.node.id: registeredNode.secret],
            onStateChange: { state in
                recorder.append(state: state)
            },
            onEvent: { event in
                recorder.append(event: event)
            }
        )
    }
    try await MainActor.run {
        try server.start()
    }
    defer {
        Task { @MainActor in
            server.stop()
        }
    }
    try await waitForListenerReady(await MainActor.run { recorder.states })

    let now = Date()
    let request = try CodexHookTestEventRequestBuilder.build(
        registeredNode: registeredNode,
        now: now,
        receiverURL: node.localHookReceiverURL
    )
    let body = try XCTUnwrap(request.httpBody)
    let rawHeader = [
        "POST /codex-hooks/events HTTP/1.1",
        "Host: 127.0.0.1:\(port)",
        "Content-Type: application/json",
        "Content-Length: \(body.count)",
        "\(CodexHookHTTPReceiver.nodeIDHeader): \(try XCTUnwrap(request.value(forHTTPHeaderField: CodexHookHTTPReceiver.nodeIDHeader)))",
        "\(CodexHookHTTPReceiver.timestampHeader): \(try XCTUnwrap(request.value(forHTTPHeaderField: CodexHookHTTPReceiver.timestampHeader)))",
        "\(CodexHookHTTPReceiver.signatureHeader): \(try XCTUnwrap(request.value(forHTTPHeaderField: CodexHookHTTPReceiver.signatureHeader)))",
        "",
        "",
    ].joined(separator: "\r\n")
    let rawRequest = Data(rawHeader.utf8) + body
    XCTAssertNotNil(try CodexHookHTTPMessageCodec.completeRequestLength(in: rawRequest))
    XCTAssertEqual(try CodexHookHTTPMessageCodec.parseRequest(rawRequest).body, body)
    let responseData = try sendRawLoopbackHTTPRequest(rawRequest, port: port)
    let responseText = String(data: responseData, encoding: .utf8) ?? ""

    XCTAssert(responseText.hasPrefix("HTTP/1.1 202 Accepted\r\n"), responseText)
    let events = await MainActor.run { recorder.events }
    XCTAssertEqual(events.count, 1)
    XCTAssertEqual(events.first?.nodeID, "local-node")
    XCTAssertEqual(events.first?.sessionID, "sub2api-statusbar-test-session")
    XCTAssertEqual(events.first?.turnID, "sub2api-statusbar-test-turn-\(Int(now.timeIntervalSince1970))")
}

func testCodexHookSenderReadsNodeConfigAndPostsToLocalReceiver() async throws {
    let port = try availableLoopbackPort()
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
    let senderURL = root.appendingPathComponent("sub2api-statusbar-hook-sender")
    let nodeConfigURL = root.appendingPathComponent("codex-hook-node.json")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try CodexHookSenderScript.source.write(to: senderURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o700))], ofItemAtPath: senderURL.path)

    let node = try CodexNode(
        id: "local-node",
        name: "本机",
        kind: .local,
        localReceiverPort: Int(port),
        remoteReceiverPort: nil,
        ssh: nil,
        codexHomeOverride: nil
    )
    let nodeConfig = """
    {
      "nodeId": "\(node.id)",
      "receiverUrl": "\(node.localHookReceiverURL.absoluteString)",
      "secret": "node-secret"
    }
    """
    try nodeConfig.write(to: nodeConfigURL, atomically: true, encoding: .utf8)

    let recorder = await MainActor.run {
        LocalReceiverTestRecorder()
    }
    let server = await MainActor.run {
        LocalCodexHookReceiverServer(
            port: port,
            nodeSecrets: [node.id: "node-secret"],
            onStateChange: { state in
                recorder.append(state: state)
            },
            onEvent: { event in
                recorder.append(event: event)
            }
        )
    }
    try await MainActor.run {
        try server.start()
    }
    defer {
        Task { @MainActor in
            server.stop()
        }
    }
    try await waitForListenerReady(await MainActor.run { recorder.states })

    let codexPayload = Data("""
    {
      "session_id": "session-from-sender",
      "turn_id": "turn-from-sender",
      "cwd": "/workspace/sub2api-statusbar",
      "model": "gpt-5",
      "tool_name": "shell"
    }
    """.utf8)

    let result = try runCodexHookSender(
        senderURL: senderURL,
        eventName: "UserPromptSubmit",
        nodeConfigURL: nodeConfigURL,
        stdinPayload: codexPayload
    )

    XCTAssertEqual(result.exitCode, 0, result.standardError)
    XCTAssertEqual(result.standardOutput, "")
    XCTAssertEqual(result.standardError, "")
    let events = await MainActor.run { recorder.events }
    XCTAssertEqual(events.count, 1)
    XCTAssertEqual(events.first?.nodeID, "local-node")
    XCTAssertEqual(events.first?.hookEvent, .userPromptSubmit)
    XCTAssertEqual(events.first?.sessionID, "session-from-sender")
    XCTAssertEqual(events.first?.turnID, "turn-from-sender")
    XCTAssertEqual(events.first?.cwd, "/workspace/sub2api-statusbar")
    XCTAssertEqual(events.first?.model, "gpt-5")
    XCTAssertEqual(events.first?.toolName, "shell")
}

func testCodexHookSenderNormalizesStatusToolUseAndStopErrorFields() async throws {
    let port = try availableLoopbackPort()
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
    let senderURL = root.appendingPathComponent("sub2api-statusbar-hook-sender")
    let nodeConfigURL = root.appendingPathComponent("codex-hook-node.json")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try CodexHookSenderScript.source.write(to: senderURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o700))], ofItemAtPath: senderURL.path)

    let node = try CodexNode(
        id: "local-node",
        name: "本机",
        kind: .local,
        localReceiverPort: Int(port),
        remoteReceiverPort: nil,
        ssh: nil,
        codexHomeOverride: nil
    )
    let nodeConfig = """
    {
      "nodeId": "\(node.id)",
      "receiverUrl": "\(node.localHookReceiverURL.absoluteString)",
      "secret": "node-secret"
    }
    """
    try nodeConfig.write(to: nodeConfigURL, atomically: true, encoding: .utf8)

    let recorder = await MainActor.run {
        LocalReceiverTestRecorder()
    }
    let server = await MainActor.run {
        LocalCodexHookReceiverServer(
            port: port,
            nodeSecrets: [node.id: "node-secret"],
            onStateChange: { state in
                recorder.append(state: state)
            },
            onEvent: { event in
                recorder.append(event: event)
            }
        )
    }
    try await MainActor.run {
        try server.start()
    }
    defer {
        Task { @MainActor in
            server.stop()
        }
    }
    try await waitForListenerReady(await MainActor.run { recorder.states })

    let codexPayload = Data("""
    {
      "session_id": "session-from-sender",
      "turn_id": "turn-from-sender",
      "cwd": "/workspace/sub2api-statusbar",
      "model": "gpt-5",
      "tool": {
        "name": "Bash"
      },
      "tool_use_id": "tool-call-1",
      "transcript_path": "/tmp/transcript.jsonl",
      "status_hint": "failed",
      "error_message": "command failed"
    }
    """.utf8)

    let result = try runCodexHookSender(
        senderURL: senderURL,
        eventName: "Stop",
        nodeConfigURL: nodeConfigURL,
        stdinPayload: codexPayload
    )

    XCTAssertEqual(result.exitCode, 0, result.standardError)
    let events = await MainActor.run { recorder.events }
    XCTAssertEqual(events.count, 1)
    XCTAssertEqual(events.first?.hookEvent, .stop)
    XCTAssertEqual(events.first?.sessionID, "session-from-sender")
    XCTAssertEqual(events.first?.turnID, "turn-from-sender")
    XCTAssertEqual(events.first?.toolName, "Bash")
    XCTAssertEqual(events.first?.toolUseID, "tool-call-1")
    XCTAssertEqual(events.first?.statusHint, "failed")
    XCTAssertEqual(events.first?.errorMessage, "command failed")
    XCTAssertEqual(events.first?.transcriptPath, "/tmp/transcript.jsonl")
    XCTAssertEqual(events.first?.rawPayloadHash?.hasPrefix("sha256:"), true)
}

func testCodexHookSenderRejectsCamelCasePayloadFields() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
    let senderURL = root.appendingPathComponent("sub2api-statusbar-hook-sender")
    let nodeConfigURL = root.appendingPathComponent("codex-hook-node.json")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try CodexHookSenderScript.source.write(to: senderURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o700))], ofItemAtPath: senderURL.path)
    try """
    {
      "nodeId": "local-node",
      "receiverUrl": "http://127.0.0.1:1/codex-hooks/events",
      "secret": "node-secret"
    }
    """.write(to: nodeConfigURL, atomically: true, encoding: .utf8)

    let result = try runCodexHookSender(
        senderURL: senderURL,
        eventName: "UserPromptSubmit",
        nodeConfigURL: nodeConfigURL,
        stdinPayload: Data(#"{"sessionId":"camel-session","turnId":"camel-turn"}"#.utf8)
    )

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertEqual(result.standardOutput, "")
    XCTAssertEqual(result.standardError, "")
}

func testCodexHookSenderDoesNotBlockOrPrintToCodexWhenReceiverIsUnavailable() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
    let senderURL = root.appendingPathComponent("sub2api-statusbar-hook-sender")
    let nodeConfigURL = root.appendingPathComponent("codex-hook-node.json")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try CodexHookSenderScript.source.write(to: senderURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o700))], ofItemAtPath: senderURL.path)
    try """
    {
      "nodeId": "local-node",
      "receiverUrl": "http://127.0.0.1:1/codex-hooks/events",
      "secret": "node-secret-value"
    }
    """.write(to: nodeConfigURL, atomically: true, encoding: .utf8)

    let result = try runCodexHookSender(
        senderURL: senderURL,
        eventName: "UserPromptSubmit",
        nodeConfigURL: nodeConfigURL,
        stdinPayload: Data(#"{"session_id":"session-1","turn_id":"turn-1"}"#.utf8)
    )

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertEqual(result.standardOutput, "")
    XCTAssertEqual(result.standardError, "")
}

func testLegacyAutoLanguageNormalizesToChinese() throws {
    let data = """
    {
      "baseURL": "http://127.0.0.1:8080",
      "language": "auto"
    }
    """.data(using: .utf8)!

    let config = try JSONDecoder.tokenRouter.decode(AppConfig.self, from: data)

    XCTAssert(config.language == .zhHans)
}

func testLegacyConfigWithoutAppearanceDefaultsToSystem() throws {
    let data = """
    {
      "baseURL": "http://127.0.0.1:8080",
      "language": "zhHans"
    }
    """.data(using: .utf8)!

    let config = try JSONDecoder.tokenRouter.decode(AppConfig.self, from: data)

    XCTAssert(config.appearance == .system)
}

func testAppConfigPersistsMenuBarTextPreference() throws {
    let configURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("config.json")
    let store = ConfigStore(configURL: configURL, tokenStore: MemoryTokenStore())
    let config = AppConfig(baseURL: "http://127.0.0.1:8080", showsMenuBarText: true)

    try store.save(config)
    let loaded = store.load()

    XCTAssert(loaded.baseURL == "http://127.0.0.1:8080")
    XCTAssert(loaded.showsMenuBarText == true)
}

func testAppConfigPersistsMenuBarDetailPreferences() throws {
    let configURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("config.json")
    let store = ConfigStore(configURL: configURL, tokenStore: MemoryTokenStore())
    let config = AppConfig(
        baseURL: "http://127.0.0.1:8080",
        showsMenuBarText: true,
        menuBarUsageWindow: .today,
        menuBarDisplayItems: [.totalRequests, .inputPrice, .outputPrice]
    )

    try store.save(config)
    let loaded = store.load()

    XCTAssert(loaded.menuBarUsageWindow == .today)
    XCTAssert(loaded.menuBarDisplayItems == [.totalRequests, .inputPrice, .outputPrice])
}

func testAppConfigPersistsCodexTaskTimelineEventLimit() throws {
    let configURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("config.json")
    let store = ConfigStore(configURL: configURL, tokenStore: MemoryTokenStore())
    let config = AppConfig(
        baseURL: "http://127.0.0.1:8080",
        codexTaskTimelineEventLimit: 5
    )

    try store.save(config)
    let loaded = store.load()

    XCTAssertEqual(loaded.codexTaskTimelineEventLimit, 5)
}

func testAppConfigPersistsAppearancePreference() throws {
    let configURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("config.json")
    let store = ConfigStore(configURL: configURL, tokenStore: MemoryTokenStore())
    let config = AppConfig(baseURL: "http://127.0.0.1:8080", appearance: .dark)

    try store.save(config)
    let loaded = store.load()

    XCTAssert(loaded.appearance == .dark)
}

func testAppConfigPersistsLaunchAtLoginPreference() throws {
    let configURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("config.json")
    let store = ConfigStore(configURL: configURL, tokenStore: MemoryTokenStore())
    let config = AppConfig(baseURL: "http://127.0.0.1:8080", launchAtLogin: true)

    try store.save(config)
    let loaded = store.load()

    XCTAssert(loaded.launchAtLogin == true)
}

func testLaunchAtLoginManagerWritesAndRemovesUserLaunchAgent() throws {
    let launchAgentsURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("LaunchAgents", isDirectory: true)
    let appURL = URL(fileURLWithPath: "/Applications/Sub2APIStatusBar.app", isDirectory: true)
    let manager = LaunchAtLoginManager(
        appBundleURL: appURL,
        launchAgentsDirectory: launchAgentsURL,
        label: "com.example.sub2api-statusbar.login"
    )

    try manager.setEnabled(true)

    let plist = try manager.loadLaunchAgentPlist()
    XCTAssert(plist["Label"] as? String == "com.example.sub2api-statusbar.login")
    XCTAssert(plist["ProgramArguments"] as? [String] == ["/usr/bin/open", appURL.path])
    XCTAssert(plist["RunAtLoad"] as? Bool == true)
    XCTAssert(manager.isEnabled == true)

    try manager.setEnabled(false)

    XCTAssert(FileManager.default.fileExists(atPath: manager.plistURL.path) == false)
    XCTAssert(manager.isEnabled == false)
}

func testLaunchAtLoginManagerTreatsStaleAppPathAsDisabled() throws {
    let launchAgentsURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("LaunchAgents", isDirectory: true)
    let manager = LaunchAtLoginManager(
        appBundleURL: URL(fileURLWithPath: "/Applications/Sub2APIStatusBar.app", isDirectory: true),
        launchAgentsDirectory: launchAgentsURL,
        label: "com.example.sub2api-statusbar.login"
    )
    let staleManager = LaunchAtLoginManager(
        appBundleURL: URL(fileURLWithPath: "/Users/me/Downloads/Sub2APIStatusBar.app", isDirectory: true),
        launchAgentsDirectory: launchAgentsURL,
        label: "com.example.sub2api-statusbar.login"
    )

    try staleManager.setEnabled(true)

    XCTAssert(manager.isEnabled == false)
}

func testConfigStoreSavesTokensOutsideConfigJSON() throws {
    let configURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("config.json")
    let tokenStore = MemoryTokenStore()
    let store = ConfigStore(configURL: configURL, tokenStore: tokenStore)
    let config = AppConfig(
        baseURL: "http://127.0.0.1:8080",
        authToken: "access-token",
        refreshToken: "refresh-token",
        showsMenuBarText: true
    )

    try store.save(config)

    let rawJSON = try String(contentsOf: configURL, encoding: .utf8)
    XCTAssert(!rawJSON.contains("access-token"))
    XCTAssert(!rawJSON.contains("refresh-token"))
    XCTAssert(!rawJSON.contains("authToken"))
    XCTAssert(!rawJSON.contains("refreshToken"))
    XCTAssert(tokenStore.tokens.authToken == "access-token")
    XCTAssert(tokenStore.tokens.refreshToken == "refresh-token")
    XCTAssert(store.load().authToken == "access-token")
}

func testConfigStoreMigratesLegacyJSONTokensOutOfConfigFile() throws {
    let configURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("config.json")
    try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try """
    {
      "baseURL" : "http://127.0.0.1:8080",
      "authToken" : "legacy-access",
      "refreshToken" : "legacy-refresh",
      "refreshIntervalSeconds" : 15,
      "language" : "auto",
      "monitorMode" : "user",
      "showsMenuBarText" : true
    }
    """.write(to: configURL, atomically: true, encoding: .utf8)
    let tokenStore = MemoryTokenStore()
    let store = ConfigStore(configURL: configURL, tokenStore: tokenStore)

    let loaded = store.load()

    XCTAssert(loaded.authToken == "legacy-access")
    XCTAssert(loaded.refreshToken == "legacy-refresh")
    XCTAssert(tokenStore.tokens.authToken == "legacy-access")
    XCTAssert(tokenStore.tokens.refreshToken == "legacy-refresh")

    let migratedJSON = try String(contentsOf: configURL, encoding: .utf8)
    XCTAssert(!migratedJSON.contains("legacy-access"))
    XCTAssert(!migratedJSON.contains("legacy-refresh"))
    XCTAssert(!migratedJSON.contains("authToken"))
    XCTAssert(!migratedJSON.contains("refreshToken"))
}

func testStoredAuthTokensEncodeAsSingleCredentialsPayload() throws {
    let tokens = StoredAuthTokens(authToken: "access", refreshToken: "refresh")

    let data = try JSONEncoder.tokenRouter.encode(tokens)
    let rawJSON = try XCTUnwrap(String(data: data, encoding: .utf8))
    let decoded = try JSONDecoder.tokenRouter.decode(StoredAuthTokens.self, from: data)

    XCTAssert(rawJSON.contains("auth_token"))
    XCTAssert(rawJSON.contains("refresh_token"))
    XCTAssert(decoded == tokens)
}

func testLocalCredentialsTokenStorePersistsTokensInPrivateFile() throws {
    let credentialsURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("credentials.json")
    let store = LocalCredentialsTokenStore(credentialsURL: credentialsURL)
    let tokens = StoredAuthTokens(authToken: "access-token", refreshToken: "refresh-token")

    try store.saveTokens(tokens)
    let loaded = store.loadTokens()
    let attributes = try FileManager.default.attributesOfItem(atPath: credentialsURL.path)
    let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)

    XCTAssertEqual(loaded, tokens)
    XCTAssertEqual(permissions.intValue & 0o777, 0o600)
}

func testLocalCredentialsTokenStoreMigratesThenDeletesLegacyTokens() throws {
    let credentialsURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("credentials.json")
    let legacyTokens = StoredAuthTokens(authToken: "legacy-access", refreshToken: "legacy-refresh")
    let legacyStore = MemoryLegacyTokenStore(tokens: legacyTokens)
    let store = LocalCredentialsTokenStore(credentialsURL: credentialsURL, legacyTokenStore: legacyStore)

    XCTAssertEqual(store.loadTokens(), legacyTokens)
    XCTAssertEqual(legacyStore.deleteCallCount, 1)
    XCTAssertEqual(legacyStore.tokens, StoredAuthTokens())
    XCTAssertEqual(store.loadTokens(), legacyTokens)
}

func testLocalCredentialsTokenStorePersistsEmptyCredentialsToPreventLegacyRemigration() throws {
    let credentialsURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("credentials.json")
    let legacyStore = MemoryLegacyTokenStore(tokens: StoredAuthTokens(authToken: "legacy-access", refreshToken: "legacy-refresh"))
    let store = LocalCredentialsTokenStore(credentialsURL: credentialsURL, legacyTokenStore: legacyStore)

    try store.saveTokens(StoredAuthTokens(authToken: "access-token", refreshToken: "refresh-token"))
    try store.saveTokens(StoredAuthTokens())

    XCTAssertEqual(store.loadTokens(), StoredAuthTokens())
    XCTAssertTrue(FileManager.default.fileExists(atPath: credentialsURL.path))
}

func testAppConfigDefaultsToUserMode() {
    let config = AppConfig(baseURL: "http://127.0.0.1:8080")

    XCTAssert(config.monitorMode == .user)
}

func testAppConfigRejectsUnknownMonitorMode() {
    let data = """
    {
      "baseURL": "http://127.0.0.1:8080",
      "monitorMode": "operator"
    }
    """.data(using: .utf8)!

    XCTAssertThrowsError(try JSONDecoder.tokenRouter.decode(AppConfig.self, from: data))
}

func testUserModeNormalizationRemovesAdminOnlyMenuItems() {
    let config = AppConfig(
        baseURL: "http://127.0.0.1:8080",
        monitorMode: .user,
        menuBarDisplayItems: [.totalCost, .realtimeConcurrency, .normalAccounts, .fiveHourRemaining, .sevenDayRemaining],
        adminMonitoredUserID: 42
    )

    XCTAssert(config.adminMonitoredUserID == nil)
    XCTAssert(config.menuBarDisplayItems == [.totalCost])
}

func testAppConfigCapabilityPolicyRemovesUnavailableMenuBarItems() {
    var userConfig = AppConfig(
        baseURL: "http://127.0.0.1:8080",
        monitorMode: .admin,
        menuBarDisplayItems: [.totalCost, .realtimeConcurrency, .normalAccounts, .rpm],
        adminMonitoredUserID: 42
    )
    userConfig.applyCapabilityPolicy(CapabilityPolicy(isAdminAccount: false))

    XCTAssertEqual(userConfig.monitorMode, .user)
    XCTAssertNil(userConfig.adminMonitoredUserID)
    XCTAssertEqual(userConfig.menuBarDisplayItems, [.totalCost, .rpm])

    var adminConfig = AppConfig(
        baseURL: "http://127.0.0.1:8080",
        monitorMode: .admin,
        menuBarDisplayItems: [.totalCost, .rpm, .realtimeConcurrency, .normalAccounts],
        adminMonitoredUserID: 42
    )
    adminConfig.applyCapabilityPolicy(CapabilityPolicy(isAdminAccount: true))

    XCTAssertEqual(adminConfig.monitorMode, .admin)
    XCTAssertEqual(adminConfig.adminMonitoredUserID, 42)
    XCTAssertEqual(adminConfig.menuBarDisplayItems, [.totalCost, .realtimeConcurrency, .normalAccounts])
}

func testAppConfigCapabilityPolicyDeduplicatesWhileCleaningUnavailableItems() {
    var config = AppConfig(
        baseURL: "http://127.0.0.1:8080",
        monitorMode: .admin,
        menuBarDisplayItems: [.rpm, .totalCost, .realtimeConcurrency, .rpm, .normalAccounts, .realtimeConcurrency, .totalCost],
        adminMonitoredUserID: 42
    )

    config.applyCapabilityPolicy(CapabilityPolicy(isAdminAccount: true))

    XCTAssertEqual(config.menuBarDisplayItems, [.totalCost, .realtimeConcurrency, .normalAccounts])
}

func testAppConfigSupportsAdminModeAndSelectedUser() throws {
    let data = """
    {
      "baseURL": "http://127.0.0.1:8080",
      "monitorMode": "admin",
      "adminMonitoredUserID": 42,
      "menuBarDisplayItems": ["totalCost", "realtimeConcurrency", "normalAccounts"]
    }
    """.data(using: .utf8)!

    let config = try JSONDecoder.tokenRouter.decode(AppConfig.self, from: data)

    XCTAssert(config.monitorMode == .admin)
    XCTAssert(config.adminMonitoredUserID == 42)
    XCTAssert(config.menuBarDisplayItems == [.totalCost, .realtimeConcurrency, .normalAccounts])
}

func testMenuBarDisplayItemsExposeAdminRealtimeConcurrencyItem() {
    XCTAssertEqual(MenuBarDisplayItem(rawValue: "realtimeConcurrency"), .realtimeConcurrency)
    XCTAssert(MenuBarDisplayItem.defaultSelection.contains(.normalAccounts) == false)
    XCTAssert(MenuBarDisplayItem.defaultSelection.contains(.realtimeConcurrency) == false)
    XCTAssert(MenuBarDisplayItem.userVisibleCases.contains(.normalAccounts) == false)
    XCTAssert(MenuBarDisplayItem.userVisibleCases.contains(.realtimeConcurrency) == false)
    XCTAssert(MenuBarDisplayItem.userVisibleCases.contains(.fiveHourRemaining) == false)
    XCTAssert(MenuBarDisplayItem.userVisibleCases.contains(.sevenDayRemaining) == false)
    XCTAssert(MenuBarDisplayItem.adminVisibleCases.contains(.normalAccounts) == true)
    XCTAssert(MenuBarDisplayItem.adminVisibleCases.contains(.realtimeConcurrency) == true)
    XCTAssert(MenuBarDisplayItem.adminVisibleCases.contains(.fiveHourRemaining) == true)
    XCTAssert(MenuBarDisplayItem.adminVisibleCases.contains(.sevenDayRemaining) == true)
    XCTAssert(MenuBarDisplayItem.adminVisibleCases.contains(.rpm) == false)
    XCTAssert(MenuBarDisplayItem.userVisibleCases.contains(.codexTasks) == true)
    XCTAssert(MenuBarDisplayItem.adminVisibleCases.contains(.codexTasks) == true)
    XCTAssertEqual(MenuBarDisplayItem.codexTasks.displayName, "Tasks")
    XCTAssertEqual(MenuBarDisplayItem.realtimeConcurrency.displayName, "Realtime Concurrency")
    XCTAssertEqual(MenuBarDisplayItem.fiveHourRemaining.displayName, "5-hour Remaining")
    XCTAssertEqual(MenuBarDisplayItem.sevenDayRemaining.displayName, "7-day Remaining")
}

func testCapabilityPolicyFiltersUserAndAdminOnlyFeatures() {
    let userPolicy = CapabilityPolicy(isAdminAccount: false)
    let adminPolicy = CapabilityPolicy(isAdminAccount: true)

    XCTAssertTrue(userPolicy.allows(.codexTaskMonitoring))
    XCTAssertTrue(userPolicy.allows(.codexNodeConfiguration))
    XCTAssertFalse(userPolicy.allows(.adminNormalAccounts))
    XCTAssertFalse(userPolicy.allows(.adminRealtimeConcurrency))
    XCTAssertFalse(userPolicy.allows(.adminSelectedUserMonitoring))
    XCTAssertFalse(userPolicy.visibleMenuBarDisplayItems.contains(.normalAccounts))
    XCTAssertFalse(userPolicy.visibleMenuBarDisplayItems.contains(.realtimeConcurrency))
    XCTAssertFalse(userPolicy.visibleMenuBarDisplayItems.contains(.fiveHourRemaining))
    XCTAssertFalse(userPolicy.visibleMenuBarDisplayItems.contains(.sevenDayRemaining))
    XCTAssertTrue(userPolicy.visibleMenuBarDisplayItems.contains(.rpm))

    XCTAssertTrue(adminPolicy.allows(.adminNormalAccounts))
    XCTAssertTrue(adminPolicy.allows(.adminRealtimeConcurrency))
    XCTAssertTrue(adminPolicy.allows(.adminSelectedUserMonitoring))
    XCTAssertTrue(adminPolicy.visibleMenuBarDisplayItems.contains(.normalAccounts))
    XCTAssertTrue(adminPolicy.visibleMenuBarDisplayItems.contains(.realtimeConcurrency))
    XCTAssertTrue(adminPolicy.visibleMenuBarDisplayItems.contains(.fiveHourRemaining))
    XCTAssertTrue(adminPolicy.visibleMenuBarDisplayItems.contains(.sevenDayRemaining))
    XCTAssertFalse(adminPolicy.visibleMenuBarDisplayItems.contains(.rpm))
}

func testMenuBarPresentationIncludesAdminConcurrencyAndNormalAccountsWhenSelected() {
    let config = AppConfig(
        baseURL: "http://127.0.0.1:8080",
        monitorMode: .admin,
        showsMenuBarText: true,
        menuBarDisplayItems: [.realtimeConcurrency, .normalAccounts]
    )
    let snapshot = MonitorSnapshot(
        mode: .admin,
        connected: true,
        stats: nil,
        realtime: nil,
        realtimeConcurrency: UserRealtimeConcurrency(
            userID: 2,
            userEmail: "target@example.com",
            username: "target",
            currentInUse: 12,
            maxCapacity: 100,
            loadPercentage: 0.01,
            waitingInQueue: 0
        ),
        adminNormalAccountCount: 12,
        accountHealth: nil,
        subscriptionSummary: nil,
        lastUpdatedAt: nil,
        message: nil
    )

    let presentation = snapshot.menuBarStatusPresentation(config: config)

    XCTAssertEqual(presentation.topRow, "12C | 12N")
    XCTAssertEqual(presentation.bottomRow, "Conc | Acct")
    XCTAssertEqual(presentation.cells, [
        MenuBarStatusCell(value: "12C", label: "Conc", width: 36),
        MenuBarStatusCell(value: "12N", label: "Acct", width: 36),
    ])
}

func testMenuBarPresentationIncludesAccountPageQuotaRemainingWhenSelected() {
    let quota = OpenAIAccountQuotaSnapshot(
        accounts: [
            makeOpenAIQuota(id: 1, plan: "pro", utilization: 20, sevenDayUtilization: 40, resetAt: "2033-05-19T12:00:00Z", updatedAt: "one"),
            makeOpenAIQuota(id: 2, plan: "pro", utilization: 90, sevenDayUtilization: 50, resetAt: "2033-05-19T12:00:00Z", updatedAt: "two"),
            makeOpenAIQuota(id: 3, plan: "plus", utilization: 25, sevenDayUtilization: 75, resetAt: "2033-05-19T12:00:00Z", updatedAt: "three"),
        ],
        history: OpenAIQuotaHistory()
    )
    let snapshot = MonitorSnapshot(
        mode: .admin,
        connected: true,
        stats: nil,
        realtime: nil,
        openAIQuota: quota,
        accountHealth: nil,
        subscriptionSummary: nil,
        lastUpdatedAt: nil,
        message: nil
    )
    let config = AppConfig(
        baseURL: "http://127.0.0.1:8080",
        monitorMode: .admin,
        showsMenuBarText: true,
        menuBarDisplayItems: [.fiveHourRemaining, .sevenDayRemaining]
    )

    let presentation = snapshot.menuBarStatusPresentation(config: config)

    XCTAssertEqual(presentation.topRow, "Plus 75% · Pro 90% | Plus 25% · Pro 110%")
    XCTAssertEqual(presentation.bottomRow, "5h Left | 7d Left")
    XCTAssertEqual(presentation.cells.map(\.width), [64, 64])
    XCTAssertTrue(snapshot.menuBarTooltip(statusText: "OK", config: config).contains("Plus 25% · Pro 110%"))
}

func testOpenAIQuotaRemainingFormatterHandlesEmptyLargeAndMultiplePlanValues() {
    XCTAssertEqual(StatusFormatters.openAIQuotaRemaining([], window: .fiveHour), "0%")

    let singlePlan = [
        OpenAIQuotaPlanCapacity(plan: "Pro", fiveHourRemaining: 0, sevenDayRemaining: 12.34),
    ]
    XCTAssertEqual(StatusFormatters.openAIQuotaRemaining(singlePlan, window: .fiveHour), "0%")
    XCTAssertEqual(StatusFormatters.openAIQuotaRemaining(singlePlan, window: .sevenDay), "1234%")

    let multiplePlans = [
        OpenAIQuotaPlanCapacity(plan: "Plus", fiveHourRemaining: 0.75, sevenDayRemaining: 0.25),
        OpenAIQuotaPlanCapacity(plan: "Team", fiveHourRemaining: 1.9, sevenDayRemaining: 1.1),
    ]
    XCTAssertEqual(
        StatusFormatters.openAIQuotaRemaining(multiplePlans, window: .fiveHour),
        "Plus 75% · Team 190%"
    )
}

func testAppConfigClearsAuthTokens() {
    var config = AppConfig(baseURL: "http://127.0.0.1:8080", authToken: "access", refreshToken: "refresh")

    config.clearAuthTokens()

    XCTAssert(config.authToken.isEmpty)
    XCTAssert(config.refreshToken.isEmpty)
}

func testApiEnvelopeDecodesWrappedData() throws {
    let json = """
    {
      "code": 0,
      "message": "ok",
      "data": {
        "active_requests": 2,
        "requests_per_minute": 13.5,
        "average_response_time": 840,
        "error_rate": 0.025
      }
    }
    """.data(using: .utf8)!

    let metrics = try JSONDecoder.tokenRouter.decode(TokenRouterEnvelope<RealtimeMetrics>.self, from: json).value()

    XCTAssert(metrics.activeRequests == 2)
    XCTAssert(metrics.requestsPerMinute == 13.5)
    XCTAssert(metrics.averageResponseTime == 840)
    XCTAssert(metrics.errorRate == 0.025)
}

func testTokenRouterErrorIdentifiesUnauthorizedResponses() {
    XCTAssert(TokenRouterError.badStatus(401, "expired").isUnauthorized == true)
    XCTAssert(TokenRouterError.badStatus(403, "forbidden").isUnauthorized == false)
    XCTAssert(TokenRouterError.invalidBaseURL.isUnauthorized == false)
}

func testAppVersionComparesSemanticVersions() {
    XCTAssert(AppVersion("v0.1.10") > AppVersion("0.1.2"))
    XCTAssert(AppVersion("1.0") == AppVersion("1.0.0"))
    XCTAssert(AppVersion("v2.0.0-beta") > AppVersion("1.9.9"))
}

func testGithubReleaseDecodesLatestReleasePayload() throws {
    let json = """
    {
      "tag_name": "v0.1.3",
      "name": "Sub2API Status Bar v0.1.3",
      "html_url": "https://github.com/yueqingyou/Sub2APIStatusBar/releases/tag/v0.1.3",
      "draft": false,
      "prerelease": false,
      "assets": [
        {
          "name": "Sub2APIStatusBar-0.1.3-macOS.zip.sha256",
          "browser_download_url": "https://github.com/yueqingyou/Sub2APIStatusBar/releases/download/v0.1.3/Sub2APIStatusBar-0.1.3-macOS.zip.sha256",
          "content_type": "text/plain",
          "size": 96
        },
        {
          "name": "Sub2APIStatusBar-0.1.3-macOS.zip",
          "browser_download_url": "https://github.com/yueqingyou/Sub2APIStatusBar/releases/download/v0.1.3/Sub2APIStatusBar-0.1.3-macOS.zip",
          "content_type": "application/zip",
          "size": 4096
        }
      ]
    }
    """.data(using: .utf8)!

    let release = try JSONDecoder().decode(GitHubRelease.self, from: json)
    let asset = release.installArchiveAsset(repositoryName: "Sub2APIStatusBar")

    XCTAssert(release.tagName == "v0.1.3")
    XCTAssert(release.version == AppVersion("0.1.3"))
    XCTAssert(release.releaseURL.absoluteString.hasSuffix("/v0.1.3"))
    XCTAssert(release.assets.count == 2)
    XCTAssert(asset?.name == "Sub2APIStatusBar-0.1.3-macOS.zip")
    XCTAssert(asset?.downloadURL.absoluteString.hasSuffix("/Sub2APIStatusBar-0.1.3-macOS.zip") == true)
}

func testDefaultUpdateCheckerUsesPublishedRepository() {
    let checker = GitHubUpdateChecker()

    XCTAssert(checker.owner == "yueqingyou")
    XCTAssert(checker.repository == "Sub2APIStatusBar")
}

func testUpdateInfoDetectsAvailableRelease() {
    let release = GitHubRelease(
        tagName: "v0.1.3",
        name: "Sub2API Status Bar v0.1.3",
        releaseURL: URL(string: "https://github.com/yueqingyou/Sub2APIStatusBar/releases/tag/v0.1.3")!,
        draft: false,
        prerelease: false
    )

    let available = UpdateInfo(currentVersion: AppVersion("0.1.2"), release: release)
    let current = UpdateInfo(currentVersion: AppVersion("0.1.3"), release: release)

    XCTAssert(available.isUpdateAvailable == true)
    XCTAssert(available.statusText == "Version 0.1.3 is available.")
    XCTAssert(current.isUpdateAvailable == false)
    XCTAssert(current.statusText == "You are up to date.")
}

func testGitHubReleaseSelectsMacOSZipAssetOverOtherAssets() {
    let checksum = GitHubReleaseAsset(
        name: "Sub2APIStatusBar-0.1.9-macOS.zip.sha256",
        downloadURL: URL(string: "https://example.com/Sub2APIStatusBar-0.1.9-macOS.zip.sha256")!,
        contentType: "text/plain",
        size: 96
    )
    let symbols = GitHubReleaseAsset(
        name: "Sub2APIStatusBar-0.1.9-symbols.zip",
        downloadURL: URL(string: "https://example.com/Sub2APIStatusBar-0.1.9-symbols.zip")!,
        contentType: "application/zip",
        size: 2048
    )
    let app = GitHubReleaseAsset(
        name: "Sub2APIStatusBar-0.1.9-macOS.zip",
        downloadURL: URL(string: "https://example.com/Sub2APIStatusBar-0.1.9-macOS.zip")!,
        contentType: "application/zip",
        size: 4096
    )
    let release = GitHubRelease(
        tagName: "v0.1.9",
        name: "Sub2API Status Bar v0.1.9",
        releaseURL: URL(string: "https://github.com/yueqingyou/Sub2APIStatusBar/releases/tag/v0.1.9")!,
        draft: false,
        prerelease: false,
        assets: [checksum, symbols, app]
    )

    XCTAssert(release.installArchiveAsset(repositoryName: "Sub2APIStatusBar") == app)
}

func testAppUpdateInstallerValidatesExtractedAppBundleMetadata() throws {
    let appURL = try makeTemporaryAppBundle(bundleIdentifier: "com.geekywizkid.sub2api-statusbar", version: "0.1.9")
    let installer = AppUpdateInstaller()

    XCTAssertNoThrow(try installer.validateExtractedApp(
        at: appURL,
        expectedVersion: AppVersion("0.1.9"),
        bundleIdentifier: "com.geekywizkid.sub2api-statusbar"
    ))
}

func testAppUpdateInstallerRejectsUnexpectedBundleIdentifier() throws {
    let appURL = try makeTemporaryAppBundle(bundleIdentifier: "com.example.other", version: "0.1.9")
    let installer = AppUpdateInstaller()

    XCTAssertThrowsError(try installer.validateExtractedApp(
        at: appURL,
        expectedVersion: AppVersion("0.1.9"),
        bundleIdentifier: "com.geekywizkid.sub2api-statusbar"
    )) { error in
        if case AppUpdateInstallerError.unexpectedBundleIdentifier = error {
            return
        }
        XCTFail("Expected unexpectedBundleIdentifier, got \\(error)")
    }
}

func testAppUpdateInstallerBuildsSelfReplacementScript() {
    let installer = AppUpdateInstaller()
    let script = installer.installScript(
        sourceAppURL: URL(fileURLWithPath: "/tmp/Sub2API's Status Bar.app"),
        targetAppURL: URL(fileURLWithPath: "/Applications/Sub2APIStatusBar.app"),
        currentProcessID: 1234
    )

    XCTAssert(script.contains("SOURCE_APP='/tmp/Sub2API'\"'\"'s Status Bar.app'"))
    XCTAssert(script.contains("TARGET_APP='/Applications/Sub2APIStatusBar.app'"))
    XCTAssert(script.contains("while /bin/kill -0 \"$APP_PID\""))
    XCTAssert(script.contains("/bin/kill -TERM \"$APP_PID\""))
    XCTAssert(script.contains("/bin/kill -KILL \"$APP_PID\""))
    XCTAssert(script.contains("/usr/bin/ditto \"$SOURCE_APP\" \"$TARGET_APP\""))
    XCTAssert(script.contains("/usr/bin/open \"$TARGET_APP\""))
    XCTAssert(script.contains("Sub2APIStatusBar-update-install.log"))
}

func testAppUpdateInstallerScriptTerminatesStuckProcessAndReplacesTarget() throws {
    let fileManager = FileManager.default
    let rootURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let sourceAppURL = rootURL.appendingPathComponent("Source.app", isDirectory: true)
    let targetAppURL = rootURL.appendingPathComponent("Target.app", isDirectory: true)
    try fileManager.createDirectory(at: sourceAppURL, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: targetAppURL, withIntermediateDirectories: true)
    try "new".write(to: sourceAppURL.appendingPathComponent("version.txt"), atomically: true, encoding: .utf8)
    try "old".write(to: targetAppURL.appendingPathComponent("version.txt"), atomically: true, encoding: .utf8)

    let stuckProcess = Process()
    stuckProcess.executableURL = URL(fileURLWithPath: "/bin/sleep")
    stuckProcess.arguments = ["30"]
    try stuckProcess.run()
    defer {
        if stuckProcess.isRunning {
            stuckProcess.terminate()
        }
    }

    let script = AppUpdateInstaller().installScript(
        sourceAppURL: sourceAppURL,
        targetAppURL: targetAppURL,
        currentProcessID: stuckProcess.processIdentifier,
        appExitWaitIterations: 1
    )
    let scriptURL = rootURL.appendingPathComponent("install-update.sh")
    try script.write(to: scriptURL, atomically: true, encoding: .utf8)

    let installerProcess = Process()
    installerProcess.executableURL = URL(fileURLWithPath: "/bin/sh")
    installerProcess.arguments = [scriptURL.path]
    var environment = ProcessInfo.processInfo.environment
    environment["TMPDIR"] = rootURL.path
    installerProcess.environment = environment
    try installerProcess.run()
    installerProcess.waitUntilExit()

    XCTAssert(installerProcess.terminationStatus == 0)
    XCTAssert(stuckProcess.isRunning == false)
    XCTAssert(try String(contentsOf: targetAppURL.appendingPathComponent("version.txt")) == "new")
    XCTAssert(fileManager.fileExists(atPath: "\(targetAppURL.path).updater-backup") == false)

    let logURL = rootURL.appendingPathComponent("Sub2APIStatusBar-update-install.log")
    let log = try String(contentsOf: logURL)
    XCTAssert(log.contains("sending TERM"))
    XCTAssert(log.contains("Installed update"))
}

func testCurrentUserResponseDecodesDirectUserPayload() throws {
    let json = """
    {
      "id": 7,
      "email": "user@example.com",
      "username": "das",
      "role": "user",
      "balance": 12.34,
      "concurrency": 100,
      "status": "active"
    }
    """.data(using: .utf8)!

    let response = try JSONDecoder.tokenRouter.decode(CurrentUserResponse.self, from: json)

    XCTAssert(response.user.balance == 12.34)
    XCTAssert(response.user.username == "das")
    XCTAssert(response.user.concurrency == 100)
}

func testCurrentUserResponseRequiresConcurrencyField() {
    let json = """
    {
      "id": 7,
      "email": "user@example.com",
      "username": "das",
      "role": "user",
      "balance": 12.34,
      "status": "active"
    }
    """.data(using: .utf8)!

    XCTAssertThrowsError(try JSONDecoder.tokenRouter.decode(CurrentUserResponse.self, from: json))
}

func testCurrentUserRecognizesAdminRole() throws {
    let json = """
    {
      "id": 1,
      "email": "admin@example.com",
      "username": "root",
      "role": "admin",
      "balance": 0,
      "concurrency": 100,
      "status": "active"
    }
    """.data(using: .utf8)!

    let response = try JSONDecoder.tokenRouter.decode(CurrentUserResponse.self, from: json)

    XCTAssert(response.user.isAdmin == true)
}

func testAdminUserConcurrencyStatsDecodeRealUserConcurrencyPayload() throws {
    let json = """
    {
      "code": 0,
      "message": "success",
      "data": {
        "enabled": true,
        "user": {
          "42": {
            "user_id": 42,
            "user_email": "target@example.com",
            "username": "target",
            "current_in_use": 3,
            "max_capacity": 100,
            "load_percentage": 3,
            "waiting_in_queue": 1
          }
        },
        "timestamp": "2026-05-21T12:34:56Z"
      }
    }
    """.data(using: .utf8)!

    let stats = try JSONDecoder.tokenRouter.decode(TokenRouterEnvelope<AdminUserConcurrencyStats>.self, from: json).value()
    let target = try XCTUnwrap(stats.concurrency(forUserID: 42, userEmail: "target@example.com", username: "target", maxCapacity: 100))

    XCTAssert(stats.enabled == true)
    XCTAssert(target.userID == 42)
    XCTAssert(target.currentInUse == 3)
    XCTAssert(target.maxCapacity == 100)
    XCTAssert(target.waitingInQueue == 1)
}

func testAdminUserConcurrencyStatsTreatsMissingActiveUserAsZeroOnlyWhenEnabled() throws {
    let enabledJSON = """
    {
      "enabled": true,
      "user": {},
      "timestamp": "2026-05-21T12:34:56Z"
    }
    """.data(using: .utf8)!
    let disabledJSON = """
    {
      "enabled": false,
      "user": {},
      "timestamp": "2026-05-21T12:34:56Z"
    }
    """.data(using: .utf8)!

    let enabled = try JSONDecoder.tokenRouter.decode(AdminUserConcurrencyStats.self, from: enabledJSON)
    let disabled = try JSONDecoder.tokenRouter.decode(AdminUserConcurrencyStats.self, from: disabledJSON)

    XCTAssert(enabled.concurrency(forUserID: 99, userEmail: "idle@example.com", username: nil, maxCapacity: 12)?.currentInUse == 0)
    XCTAssert(enabled.concurrency(forUserID: 99, userEmail: "idle@example.com", username: nil, maxCapacity: 12)?.maxCapacity == 12)
    XCTAssert(disabled.concurrency(forUserID: 99, userEmail: "idle@example.com", username: nil, maxCapacity: 12) == nil)
}

func testAdminUsersPageDecodesStrictUserListShape() throws {
    let json = """
    {
      "items": [
        {
          "id": 42,
          "email": "target@example.com",
          "username": "target",
          "role": "user",
          "balance": 8.25,
          "status": "active",
          "concurrency": 100,
          "current_concurrency": 3
        }
      ],
      "total": 1,
      "page": 1,
      "page_size": 20,
      "pages": 1
    }
    """.data(using: .utf8)!

    let page = try JSONDecoder.tokenRouter.decode(AdminUsersPage.self, from: json)

    XCTAssert(page.items.first?.id == 42)
    XCTAssert(page.items.first?.email == "target@example.com")
    XCTAssert(page.items.first?.concurrency == 100)
    XCTAssert(page.items.first?.currentConcurrency == 3)
    XCTAssert(page.pageSize == 20)
}

func testTokenRouterClientFetchesAllAdminUsersAcrossPages() async throws {
    StubURLProtocol.responses = [
        "/api/v1/admin/users?page=1&page_size=1000": Data("""
        {
          "items": [
            {
              "id": 1,
              "email": "one@example.com",
              "username": "one",
              "role": "user",
              "balance": 0,
              "status": "active",
              "concurrency": 10,
              "current_concurrency": 0
            }
          ],
          "total": 2,
          "page": 1,
          "page_size": 1000,
          "pages": 2
        }
        """.utf8),
        "/api/v1/admin/users?page=2&page_size=1000": Data("""
        {
          "items": [
            {
              "id": 2,
              "email": "two@example.com",
              "username": "two",
              "role": "user",
              "balance": 0,
              "status": "active",
              "concurrency": 10,
              "current_concurrency": 1
            }
          ],
          "total": 2,
          "page": 2,
          "page_size": 1000,
          "pages": 2
        }
        """.utf8),
    ]
    StubURLProtocol.requestedPaths = []
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let client = TokenRouterClient(config: AppConfig(baseURL: "https://example.test", authToken: "token"), session: session)

    let users = try await client.allAdminUsers()

    XCTAssert(users.map(\.id) == [1, 2])
    XCTAssert(StubURLProtocol.requestedPaths == [
        "/api/v1/admin/users?page=1&page_size=1000",
        "/api/v1/admin/users?page=2&page_size=1000",
    ])
}

func testNormalAccountCompositionSummarizesTypesPlatformsAndPlans() throws {
    let accounts = [
        AccountSummary(
            id: 1,
            name: "openai-pro",
            platform: "openai",
            type: "oauth",
            status: "active",
            schedulable: true,
            credentials: ["plan_type": "pro"],
            quotaLimit: nil,
            quotaUsed: nil,
            quotaDailyLimit: nil,
            quotaDailyUsed: nil,
            quotaWeeklyLimit: nil,
            quotaWeeklyUsed: nil,
            errorMessage: "",
            rateLimitResetAt: nil
        ),
        AccountSummary(
            id: 2,
            name: "openai-plus",
            platform: "openai",
            type: "oauth",
            status: "active",
            schedulable: true,
            credentials: ["plan_type": "plus"],
            quotaLimit: nil,
            quotaUsed: nil,
            quotaDailyLimit: nil,
            quotaDailyUsed: nil,
            quotaWeeklyLimit: nil,
            quotaWeeklyUsed: nil,
            errorMessage: "",
            rateLimitResetAt: nil
        ),
        AccountSummary(
            id: 3,
            name: "gemini-pro",
            platform: "gemini",
            type: "oauth",
            status: "active",
            schedulable: true,
            credentials: ["oauth_type": "google_one", "tier_id": "google_ai_pro"],
            quotaLimit: nil,
            quotaUsed: nil,
            quotaDailyLimit: nil,
            quotaDailyUsed: nil,
            quotaWeeklyLimit: nil,
            quotaWeeklyUsed: nil,
            errorMessage: "",
            rateLimitResetAt: nil
        ),
        AccountSummary(
            id: 4,
            name: "api",
            platform: "openai",
            type: "apikey",
            status: "active",
            schedulable: true,
            credentials: [:],
            quotaLimit: nil,
            quotaUsed: nil,
            quotaDailyLimit: nil,
            quotaDailyUsed: nil,
            quotaWeeklyLimit: nil,
            quotaWeeklyUsed: nil,
            errorMessage: "",
            rateLimitResetAt: nil
        ),
        AccountSummary(
            id: 5,
            name: "team",
            platform: "antigravity",
            type: "oauth",
            status: "active",
            schedulable: true,
            credentials: ["plan_type": "team"],
            quotaLimit: nil,
            quotaUsed: nil,
            quotaDailyLimit: nil,
            quotaDailyUsed: nil,
            quotaWeeklyLimit: nil,
            quotaWeeklyUsed: nil,
            errorMessage: "",
            rateLimitResetAt: nil
        ),
    ]

    let composition = NormalAccountComposition(accounts: accounts)

    XCTAssertEqual(composition.typeLine(language: .zhHans), "API 1 · OAuth 4")
    XCTAssertEqual(composition.detailLine(language: .zhHans), "Pro 2 · Plus 1 · Team 1")
    XCTAssertEqual(composition.detailLine(language: .en), "Pro 2 · Plus 1 · Team 1")
    XCTAssertEqual(composition.compactLine(language: .zhHans), "API 1 · OAuth 4 · Pro 2 · Plus 1 · Team 1")
    XCTAssertEqual(composition.compactLine(language: .en), "API 1 · OAuth 4 · Pro 2 · Plus 1 · Team 1")
}

func testNormalAccountCompositionCompactLineUsesPlatformsWhenPlansAreUnavailable() throws {
    let composition = NormalAccountComposition(
        total: 2,
        typeCounts: ["API": 1, "OAuth": 1],
        platformCounts: ["OpenAI": 1, "Gemini": 1],
        planCounts: [:]
    )

    XCTAssertEqual(composition.compactLine(language: .zhHans), "API 1 · OAuth 1 · OpenAI 1 · Gemini 1")
}

func testTokenRouterClientFetchesNormalAccountCompositionFromFlatAccountList() async throws {
    StubURLProtocol.responses = [
        "/api/v1/admin/accounts?page=1&page_size=1000&status=active&lite=true": Data("""
        {
          "items": [
            {
              "id": 41,
              "name": "openai-pro",
              "platform": "openai",
              "type": "oauth",
              "credentials": {
                "email": "pro@example.com",
                "plan_type": "pro",
                "model_mapping": {
                  "gpt-5.5": "gpt-5.5"
                }
              },
              "credentials_status": {
                "has_access_token": true
              },
              "status": "active",
              "schedulable": true,
              "error_message": "",
              "current_concurrency": 0
            },
            {
              "id": 42,
              "name": "openai-api",
              "platform": "openai",
              "type": "apikey",
              "credentials": {},
              "status": "active",
              "schedulable": true,
              "error_message": "",
              "current_concurrency": 0
            },
            {
              "id": 43,
              "name": "gemini-pro",
              "platform": "gemini",
              "type": "oauth",
              "credentials": {
                "oauth_type": "google_one",
                "tier_id": "google_ai_pro"
              },
              "status": "active",
              "schedulable": true,
              "error_message": "",
              "current_concurrency": 0
            },
            {
              "id": 44,
              "name": "openai-spark",
              "platform": "openai",
              "type": "oauth",
              "credentials": {
                "plan_type": "pro"
              },
              "status": "active",
              "schedulable": true,
              "parent_account_id": 41,
              "quota_dimension": "spark",
              "error_message": "",
              "current_concurrency": 0
            }
          ],
          "total": 4,
          "page": 1,
          "page_size": 1000,
          "pages": 1
        }
        """.utf8),
    ]
    StubURLProtocol.requestedPaths = []
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let client = TokenRouterClient(config: AppConfig(baseURL: "https://example.test", authToken: "token"), session: session)

    let composition = try await client.adminNormalAccountComposition()

    XCTAssertEqual(composition.total, 3)
    XCTAssertEqual(composition.typeLine(language: .zhHans), "API 1 · OAuth 2")
    XCTAssertEqual(composition.detailLine(language: .zhHans), "Pro 2")
    XCTAssertEqual(composition.compactLine(language: .zhHans), "API 1 · OAuth 2 · Pro 2")
    XCTAssertEqual(StubURLProtocol.requestedPaths, [
        "/api/v1/admin/accounts?page=1&page_size=1000&status=active&lite=true",
    ])
}

func testTokenRouterClientFetchesOnlyRootOpenAIOAuthQuota() async throws {
    StubURLProtocol.responses = [
        "/api/v1/admin/accounts?page=1&page_size=1000&platform=openai&type=oauth&lite=true": Data("""
        {
          "items": [
            {
              "id": 41,
              "name": "openai-pro",
              "platform": "openai",
              "type": "oauth",
              "credentials": {
                "email":"pro@example.com",
                "plan_type":"pro",
                "subscription_expires_at":"2026-07-27T15:03:00+00:00"
              },
              "extra": {"privacy_mode":"training_off"},
              "status": "active",
              "schedulable": true,
              "quota_dimension": "global",
              "error_message": ""
            },
            {
              "id": 42,
              "name": "openai-spark",
              "platform": "openai",
              "type": "oauth",
              "credentials": {"plan_type":"pro"},
              "status": "active",
              "schedulable": true,
              "parent_account_id": 41,
              "quota_dimension": "spark",
              "error_message": ""
            },
            {
              "id": 43,
              "name": "anthropic-oauth",
              "platform": "anthropic",
              "type": "oauth",
              "status": "active",
              "schedulable": true,
              "error_message": ""
            },
            {
              "id": 44,
              "name": "openai-api",
              "platform": "openai",
              "type": "apikey",
              "status": "active",
              "schedulable": true,
              "error_message": ""
            }
          ],
          "total": 4,
          "page": 1,
          "page_size": 1000,
          "pages": 1
        }
        """.utf8),
        "/api/v1/admin/accounts/41/usage": Data("""
        {
          "source": "passive",
          "updated_at": "2026-07-11T08:00:00Z",
          "five_hour": {
            "utilization": 29,
            "resets_at": "2026-07-11T12:00:00Z",
            "remaining_seconds": 14400,
            "window_stats": {
              "requests": 365,
              "tokens": 55900000,
              "cost": 101.2,
              "standard_cost": 92.589,
              "user_cost": 110.3
            }
          },
          "seven_day": {
            "utilization": 11,
            "resets_at": "2026-07-18T08:00:00Z",
            "remaining_seconds": 604800,
            "window_stats": {
              "requests": 1208,
              "tokens": 229600000,
              "cost": 280.1,
              "standard_cost": 262.104,
              "user_cost": 300.2
            }
          },
          "quota_auto_paused": false
        }
        """.utf8),
    ]
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let client = TokenRouterClient(
        config: AppConfig(baseURL: "https://example.test", authToken: "token"),
        session: URLSession(configuration: configuration)
    )

    let quotas = try await client.adminOpenAIOAuthAccountQuotas()

    XCTAssertEqual(quotas.map(\.id), [41])
    XCTAssertEqual(quotas.first?.account.email, "pro@example.com")
    XCTAssertEqual(quotas.first?.planLabel, "Pro")
    XCTAssertEqual(quotas.first?.account.privacyMode, "training_off")
    XCTAssertEqual(quotas.first?.account.isPrivate, true)
    XCTAssertNotNil(quotas.first?.account.subscriptionExpiresAt)
    XCTAssertEqual(quotas.first?.usage.fiveHour?.utilization, 29)
    XCTAssertEqual(quotas.first?.usage.fiveHour?.windowStats?.standardCost, 92.589)
    XCTAssertEqual(StubURLProtocol.requestedPaths, [
        "/api/v1/admin/accounts?page=1&page_size=1000&platform=openai&type=oauth&lite=true",
        "/api/v1/admin/accounts/41/usage",
    ])
}

func testOpenAIQuotaHistoryDeduplicatesPrunesAndPersistsPrivateFields() throws {
    let storageURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("openai-quota-history-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: storageURL) }
    let persistence = OpenAIQuotaHistoryPersistence(storageURL: storageURL)
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    var history = OpenAIQuotaHistory()
    let oldQuota = makeOpenAIQuota(
        utilization: 10,
        resetAt: "2033-05-19T08:00:00Z",
        updatedAt: "2033-05-18T06:00:00Z"
    )
    history.record(accounts: [oldQuota], capturedAt: now.addingTimeInterval(-31 * 24 * 60 * 60))

    let currentQuota = makeOpenAIQuota(
        utilization: 30,
        resetAt: "2033-05-19T12:00:00Z",
        updatedAt: "2033-05-18T08:00:00Z"
    )
    XCTAssertTrue(history.record(accounts: [currentQuota], capturedAt: now))
    XCTAssertFalse(history.record(accounts: [currentQuota], capturedAt: now.addingTimeInterval(60)))
    XCTAssertEqual(history.samples.count, 1)

    try persistence.save(history)
    let loaded = try persistence.load(now: now)
    XCTAssertEqual(loaded, history)

    let raw = try String(contentsOf: storageURL, encoding: .utf8)
    XCTAssertFalse(raw.contains("pro@example.com"))
    XCTAssertFalse(raw.contains("Primary Pro"))
    let permissions = try FileManager.default.attributesOfItem(atPath: storageURL.path)[.posixPermissions] as? NSNumber
    XCTAssertEqual(permissions?.intValue, 0o600)
}

func testOpenAIQuotaForecastUsesCurrentResetCycleOnly() throws {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let resetAt = "2033-05-18T07:33:20Z"
    var history = OpenAIQuotaHistory()
    history.record(
        accounts: [makeOpenAIQuota(utilization: 99, resetAt: "2033-05-18T02:00:00Z", updatedAt: "old")],
        capturedAt: now.addingTimeInterval(-60 * 60)
    )
    history.record(
        accounts: [makeOpenAIQuota(utilization: 10, resetAt: resetAt, updatedAt: "one")],
        capturedAt: now.addingTimeInterval(-40 * 60)
    )
    history.record(
        accounts: [makeOpenAIQuota(utilization: 20, resetAt: resetAt, updatedAt: "two")],
        capturedAt: now.addingTimeInterval(-20 * 60)
    )
    let current = makeOpenAIQuota(utilization: 30, resetAt: resetAt, updatedAt: "three")
    history.record(accounts: [current], capturedAt: now)

    let forecast = OpenAIQuotaForecaster.forecast(
        accountID: current.id,
        window: .fiveHour,
        current: try XCTUnwrap(current.usage.fiveHour),
        history: history,
        now: now
    )

    XCTAssertEqual(forecast.trend, .rising)
    XCTAssertEqual(forecast.confidence, .low)
    XCTAssertEqual(forecast.thresholds.map(\.threshold), [70, 85, 95, 100])
    XCTAssertNotNil(forecast.estimatedAt(85))
    XCTAssertNotNil(forecast.estimatedAt(100))
}

func testOpenAIQuotaForecastRequiresCurrentResetBoundary() throws {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    var history = OpenAIQuotaHistory()
    history.record(
        accounts: [makeOpenAIQuota(utilization: 10, resetAt: nil, updatedAt: "one")],
        capturedAt: now.addingTimeInterval(-40 * 60)
    )
    history.record(
        accounts: [makeOpenAIQuota(utilization: 20, resetAt: nil, updatedAt: "two")],
        capturedAt: now.addingTimeInterval(-20 * 60)
    )
    let current = makeOpenAIQuota(utilization: 30, resetAt: nil, updatedAt: "three")
    history.record(accounts: [current], capturedAt: now)

    let forecast = OpenAIQuotaForecaster.forecast(
        accountID: current.id,
        window: .fiveHour,
        current: try XCTUnwrap(current.usage.fiveHour),
        history: history,
        now: now
    )

    XCTAssertEqual(forecast.confidence, .insufficient)
    XCTAssertEqual(forecast.trend, .insufficient)
    XCTAssertNil(forecast.predictedUtilizationAtReset)
    XCTAssertTrue(forecast.thresholds.isEmpty)
}

func testOpenAIQuotaPoolSummaryGroupsCapacityByPlanAndExcludesUnavailableAccounts() {
    let accounts = [
        makeOpenAIQuota(id: 1, plan: "pro", utilization: 20, resetAt: "2033-05-19T12:00:00Z", updatedAt: "one"),
        makeOpenAIQuota(id: 2, plan: "pro", utilization: 90, resetAt: "2033-05-19T12:00:00Z", updatedAt: "two"),
        makeOpenAIQuota(id: 3, plan: "plus", status: "disabled", schedulable: false, utilization: 0, resetAt: "2033-05-19T12:00:00Z", updatedAt: "three"),
    ]

    let summary = OpenAIQuotaPoolSummary(accounts: accounts)

    XCTAssertEqual(summary.accountCount, 3)
    XCTAssertEqual(summary.schedulableCount, 2)
    XCTAssertEqual(summary.riskCount, 1)
    XCTAssertEqual(summary.capacities.map(\.plan), ["Pro"])
    XCTAssertEqual(summary.capacities.first?.fiveHourRemaining ?? 0, 0.9, accuracy: 0.001)
}

private func makeOpenAIQuota(
    id: Int64 = 41,
    plan: String = "pro",
    status: String = "active",
    schedulable: Bool = true,
    utilization: Double,
    sevenDayUtilization: Double? = nil,
    resetAt: String?,
    updatedAt: String
) -> OpenAIAccountQuota {
    let account = AccountSummary(
        id: id,
        name: "Primary Pro",
        platform: "openai",
        type: "oauth",
        status: status,
        schedulable: schedulable,
        credentials: ["email": "pro@example.com", "plan_type": plan],
        quotaLimit: nil,
        quotaUsed: nil,
        quotaDailyLimit: nil,
        quotaDailyUsed: nil,
        quotaWeeklyLimit: nil,
        quotaWeeklyUsed: nil,
        errorMessage: "",
        rateLimitResetAt: nil
    )
    let stats = AccountUsageWindowStats(
        requests: 10,
        tokens: 1_000,
        standardCost: 1.5
    )
    let fiveHourProgress = UsageProgress(
        utilization: utilization,
        resetsAt: resetAt,
        remainingSeconds: 14_400,
        windowStats: stats
    )
    let sevenDayProgress = UsageProgress(
        utilization: sevenDayUtilization ?? utilization,
        resetsAt: resetAt,
        remainingSeconds: 14_400,
        windowStats: stats
    )
    return OpenAIAccountQuota(
        account: account,
        usage: AccountUsageInfo(
            updatedAt: updatedAt,
            fiveHour: fiveHourProgress,
            sevenDay: sevenDayProgress,
            quotaAutoPaused: false
        )
    )
}

func testTokenRouterClientUsesAdminFilteredEndpointsForSelectedUserMetrics() async throws {
    StubURLProtocol.responses = [
        "/api/v1/admin/users/2": Data("""
        {
          "id": 2,
          "email": "target@example.com",
          "username": "target",
          "role": "user",
          "balance": 66937.34,
          "status": "active",
          "concurrency": 100,
          "notes": "admin detail payload"
        }
        """.utf8),
        "/api/v1/admin/usage/stats?user_id=2&start_date=2026-05-21&end_date=2026-05-21&timezone=Asia/Shanghai": Data("""
        {
          "total_requests": 3953,
          "total_actual_cost": 1010.5504306,
          "total_tokens": 511283323,
          "total_input_tokens": 38967768,
          "total_output_tokens": 3026083,
          "total_cache_creation_tokens": 0,
          "total_cache_read_tokens": 469289472,
          "average_duration_ms": 14514.63
        }
        """.utf8),
        "/api/v1/admin/usage?user_id=2&page=1&page_size=1&sort_by=created_at&sort_order=desc&timezone=Asia/Shanghai": Data("""
        {
          "items": [
            {
              "id": 133605,
              "user_id": 2,
              "api_key_id": 5,
              "account_id": 9,
              "request_id": "req-admin-133605",
              "model": "gpt-5.5",
              "upstream_model": "gpt-5.5-openai-compact",
              "model_mapping_chain": "gpt-5.5 -> gpt-5.5-openai-compact",
              "service_tier": "priority",
              "reasoning_effort": "xhigh",
              "inbound_endpoint": "/openai/v1/responses",
              "upstream_endpoint": "/v1/responses",
              "input_tokens": 430,
              "output_tokens": 1172,
              "cache_creation_tokens": 0,
              "cache_read_tokens": 164224,
              "actual_cost": 0.238844,
              "request_type": "stream",
              "stream": true,
              "duration_ms": 1200,
              "first_token_ms": 250,
              "user_agent": "codex_cli_rs/0.125.0",
              "billing_mode": "token",
              "created_at": "2026-05-21T15:37:40.960689+08:00"
            }
          ],
          "total": 1,
          "page": 1,
          "page_size": 1,
          "pages": 1
        }
        """.utf8),
    ]
    StubURLProtocol.requestedPaths = []
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let client = TokenRouterClient(config: AppConfig(baseURL: "https://example.test", authToken: "token"), session: session)

    let user = try await client.adminUser(id: 2)
    let stats = try await client.adminUsageStats(userID: 2, startDate: "2026-05-21", endDate: "2026-05-21", timezone: "Asia/Shanghai")
    let latest = try await client.adminUsageLogs(userID: 2, page: 1, pageSize: 1, sortBy: "created_at", sortOrder: "desc", timezone: "Asia/Shanghai")

    XCTAssert(user.balance == 66937.34)
    XCTAssert(stats.totalRequests == 3953)
    XCTAssert(stats.totalCacheReadTokens == 469_289_472)
    XCTAssert(latest.items.first?.model == "gpt-5.5")
    XCTAssert(latest.items.first?.upstreamModel == "gpt-5.5-openai-compact")
    XCTAssert(latest.items.first?.modelMappingChain == "gpt-5.5 -> gpt-5.5-openai-compact")
    XCTAssert(latest.items.first?.reasoningEffort == "xhigh")
    XCTAssert(latest.items.first?.requestID == "req-admin-133605")
    XCTAssert(latest.items.first?.userAgent == "codex_cli_rs/0.125.0")
    XCTAssert(latest.items.first?.inboundEndpoint == "/openai/v1/responses")
    XCTAssert(latest.items.first?.upstreamEndpoint == "/v1/responses")
    XCTAssert(latest.items.first?.stream == true)
    XCTAssert(StubURLProtocol.requestedPaths == [
        "/api/v1/admin/users/2",
        "/api/v1/admin/usage/stats?user_id=2&start_date=2026-05-21&end_date=2026-05-21&timezone=Asia/Shanghai",
        "/api/v1/admin/usage?user_id=2&page=1&page_size=1&sort_by=created_at&sort_order=desc&timezone=Asia/Shanghai",
    ])
}

func testTokenRouterClientFetchesTokenRouterDashboardSnapshots() async throws {
    let response = Data("""
    {
      "code": 0,
      "message": "success",
      "data": {
        "generated_at": "2026-07-10T08:00:00Z",
        "start_date": "2026-07-03",
        "end_date": "2026-07-10",
        "granularity": "day",
        "trend": [{"date":"2026-07-10","requests":2,"total_tokens":100}],
        "models": [{"model":"gpt-5.6-sol","requests":2,"total_tokens":100}]
      }
    }
    """.utf8)
    StubURLProtocol.responses = [
        "/api/v1/usage/dashboard/snapshot-v2?start_date=2026-07-03&end_date=2026-07-10&granularity=day&include_trend=true&include_model_stats=true&include_group_stats=false": response,
        "/api/v1/admin/dashboard/snapshot-v2?user_id=2&start_date=2026-07-03&end_date=2026-07-10&granularity=day&include_stats=false&include_trend=false&include_model_stats=true&include_group_stats=false&timezone=Asia/Shanghai": response,
    ]
    StubURLProtocol.requestedPaths = []
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let client = TokenRouterClient(
        config: AppConfig(baseURL: "https://example.test", authToken: "token"),
        session: URLSession(configuration: configuration)
    )

    let userSnapshot = try await client.usageDashboardSnapshot(
        startDate: "2026-07-03",
        endDate: "2026-07-10"
    )
    let adminSnapshot = try await client.adminDashboardSnapshot(
        userID: 2,
        startDate: "2026-07-03",
        endDate: "2026-07-10",
        timezone: "Asia/Shanghai"
    )

    XCTAssertEqual(userSnapshot.models.first?.model, "gpt-5.6-sol")
    XCTAssertEqual(adminSnapshot.models.first?.model, "gpt-5.6-sol")
    XCTAssertEqual(StubURLProtocol.requestedPaths, [
        "/api/v1/usage/dashboard/snapshot-v2?start_date=2026-07-03&end_date=2026-07-10&granularity=day&include_trend=true&include_model_stats=true&include_group_stats=false",
        "/api/v1/admin/dashboard/snapshot-v2?user_id=2&start_date=2026-07-03&end_date=2026-07-10&granularity=day&include_stats=false&include_trend=false&include_model_stats=true&include_group_stats=false&timezone=Asia/Shanghai",
    ])
}

func testUsageDashboardDecodesUserStatsTrendAndModels() throws {
    let statsJSON = """
    {
      "total_api_keys": 2,
      "active_api_keys": 2,
      "total_requests": 5476,
      "total_input_tokens": 40529619,
      "total_output_tokens": 3499464,
      "total_cache_creation_tokens": 0,
      "total_cache_read_tokens": 554867072,
      "total_tokens": 598896155,
      "total_cost": 498.69043735,
      "total_actual_cost": 498.69043735,
      "today_requests": 1186,
      "today_input_tokens": 7657045,
      "today_output_tokens": 536098,
      "today_cache_creation_tokens": 0,
      "today_cache_read_tokens": 118193024,
      "today_tokens": 126386167,
      "today_cost": 117.56682985,
      "today_actual_cost": 117.56682985,
      "average_duration_ms": 14514.6375,
      "rpm": 1,
      "tpm": 10752
    }
    """.data(using: .utf8)!
    let snapshotJSON = """
    {
      "trend": [
        {
          "date": "2026-04-28",
          "requests": 1187,
          "input_tokens": 7672001,
          "output_tokens": 536486,
          "cache_creation_tokens": 0,
          "cache_read_tokens": 118310656,
          "total_tokens": 126519143,
          "cost": 117.71206585,
          "actual_cost": 117.71206585
        }
      ],
      "models": [
        {
          "model": "gpt-5.5",
          "requests": 2184,
          "input_tokens": 14103149,
          "output_tokens": 1004490,
          "cache_creation_tokens": 0,
          "cache_read_tokens": 234003712,
          "total_tokens": 249111351,
          "cost": 222.61852,
          "actual_cost": 222.61852,
          "account_cost": 222.61852
        }
      ]
    }
    """.data(using: .utf8)!

    let stats = try JSONDecoder.tokenRouter.decode(DashboardStats.self, from: statsJSON)
    let snapshot = try JSONDecoder.tokenRouter.decode(TokenRouterDashboardSnapshot.self, from: snapshotJSON)

    XCTAssert(stats.todayCacheReadTokens == 118_193_024)
    XCTAssert(stats.todayCost == 117.56682985)
    XCTAssert(snapshot.trend.first?.inputTokens == 7_672_001)
    XCTAssert(snapshot.trend.first?.cacheReadTokens == 118_310_656)
    XCTAssert(snapshot.models.first?.accountCost == 222.61852)
    XCTAssert(snapshot.models.first?.standardCost == 222.61852)
}

func testMenuBarUsageWindowBuildsDateRangesLikeWebPreset() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
    let now = Date(timeIntervalSince1970: 1_777_456_800) // 2026-04-29 20:00:00 +0800

    XCTAssert(MenuBarUsageWindow.last24Hours.dateRange(now: now, calendar: calendar) == MenuBarDateRange(start: "2026-04-28", end: "2026-04-29"))
    XCTAssert(MenuBarUsageWindow.today.dateRange(now: now, calendar: calendar) == MenuBarDateRange(start: "2026-04-29", end: "2026-04-29"))
}

func testUsageLogDecodesLatestMetadataAndDerivedValues() throws {
    let json = """
    {
      "id": 133605,
      "user_id": 2,
      "api_key_id": 5,
      "account_id": 9,
      "request_id": "req-user-133605",
      "model": "gpt-5.5",
      "service_tier": "priority",
      "reasoning_effort": "xhigh",
      "inbound_endpoint": "/openai/v1/responses",
      "upstream_endpoint": "/v1/responses",
      "input_tokens": 946,
      "output_tokens": 429,
      "cache_creation_tokens": 12000,
      "cache_read_tokens": 75432,
      "input_cost": 0.00946,
      "output_cost": 0.02574,
      "total_cost": 0.0352,
      "actual_cost": 0.124712,
      "request_type": "stream",
      "stream": true,
      "duration_ms": 1456,
      "first_token_ms": 231,
      "user_agent": "codex_cli_rs/0.125.0",
      "billing_mode": "token",
      "created_at": "2026-04-29T19:15:11.118937+08:00"
    }
    """.data(using: .utf8)!

    let usage = try JSONDecoder.tokenRouter.decode(UsageLog.self, from: json)

    XCTAssert(usage.model == "gpt-5.5")
    XCTAssert(usage.userID == 2)
    XCTAssert(usage.apiKeyID == 5)
    XCTAssert(usage.accountID == 9)
    XCTAssert(usage.requestID == "req-user-133605")
    XCTAssert(usage.reasoningEffort == "xhigh")
    XCTAssert(usage.isFastEnabled == true)
    XCTAssertEqual(usage.menuBarServiceTierName, "Fast")
    XCTAssert(usage.inboundEndpoint == "/openai/v1/responses")
    XCTAssert(usage.upstreamEndpoint == "/v1/responses")
    XCTAssert(usage.contextLengthTokens == 88_378)
    XCTAssertEqual(usage.inputPricePerMillion ?? 0, 10, accuracy: 0.000001)
    XCTAssertEqual(usage.outputPricePerMillion ?? 0, 60, accuracy: 0.000001)
    XCTAssertEqual(usage.totalCost, 0.0352, accuracy: 0.000001)
    XCTAssert(usage.requestType == "stream")
    XCTAssert(usage.stream == true)
    XCTAssertEqual(usage.durationMs, 1456, accuracy: 0.000001)
    XCTAssertEqual(usage.firstTokenMs ?? 0, 231, accuracy: 0.000001)
    XCTAssert(usage.userAgent == "codex_cli_rs/0.125.0")
    XCTAssert(usage.billingMode == "token")
}

func testUsageLogRecognizesUpdatedFastModeServiceTierAlias() throws {
    let json = """
    {
      "id": 133606,
      "model": "gpt-5.5",
      "service_tier": "fast-mode-2026-02-01",
      "input_tokens": 946,
      "output_tokens": 429,
      "created_at": "2026-04-29T19:15:11.118937+08:00"
    }
    """.data(using: .utf8)!

    let usage = try JSONDecoder.tokenRouter.decode(UsageLog.self, from: json)

    XCTAssert(usage.isFastEnabled == true)
    XCTAssertEqual(usage.menuBarServiceTierName, "Fast")
}

func testUsageLogBuildsReadableMenuBarServiceTierNames() {
    XCTAssertEqual(UsageLog(serviceTier: nil).menuBarServiceTierName, "Std")
    XCTAssertEqual(UsageLog(serviceTier: "standard").menuBarServiceTierName, "Std")
    XCTAssertEqual(UsageLog(serviceTier: "priority").menuBarServiceTierName, "Fast")
    XCTAssertEqual(UsageLog(serviceTier: "flex").menuBarServiceTierName, "Flex")
    XCTAssertEqual(UsageLog(serviceTier: "auto").menuBarServiceTierName, "Auto")
    XCTAssertEqual(UsageLog(serviceTier: "scale").menuBarServiceTierName, "Scale")
}

func testUsagePeriodStatsDecodesPartialStatsPayload() throws {
    let json = """
    {
      "total_requests": 1051,
      "total_actual_cost": 123.45,
      "total_tokens": 98765,
      "average_duration_ms": 12.3
    }
    """.data(using: .utf8)!

    let stats = try JSONDecoder.tokenRouter.decode(UsagePeriodStats.self, from: json)

    XCTAssert(stats.totalRequests == 1051)
    XCTAssert(stats.totalActualCost == 123.45)
    XCTAssert(stats.totalTokens == 98_765)
    XCTAssert(stats.totalInputTokens == 0)
    XCTAssert(stats.totalOutputTokens == 0)
    XCTAssert(stats.totalCacheCreationTokens == 0)
    XCTAssert(stats.totalCacheReadTokens == 0)
}

func testAccountHealthSummaryCountsRuntimeStates() {
    let accounts = [
        AccountSummary(id: 1, name: "ok", platform: "openai", type: "oauth", status: "active", schedulable: true, quotaLimit: 100, quotaUsed: 30, quotaDailyLimit: nil, quotaDailyUsed: nil, quotaWeeklyLimit: nil, quotaWeeklyUsed: nil, errorMessage: "", rateLimitResetAt: nil),
        AccountSummary(id: 2, name: "blocked", platform: "openai", type: "oauth", status: "active", schedulable: false, quotaLimit: 100, quotaUsed: 91, quotaDailyLimit: nil, quotaDailyUsed: nil, quotaWeeklyLimit: nil, quotaWeeklyUsed: nil, errorMessage: "", rateLimitResetAt: nil),
        AccountSummary(id: 3, name: "bad", platform: "anthropic", type: "setup_token", status: "disabled", schedulable: false, quotaLimit: nil, quotaUsed: nil, quotaDailyLimit: nil, quotaDailyUsed: nil, quotaWeeklyLimit: nil, quotaWeeklyUsed: nil, errorMessage: "expired", rateLimitResetAt: nil),
    ]

    let summary = AccountHealthSummary(accounts: accounts)

    XCTAssert(summary.total == 3)
    XCTAssert(summary.active == 2)
    XCTAssert(summary.schedulable == 1)
    XCTAssert(summary.blocked == 2)
    XCTAssert(summary.nearQuotaLimit == 1)
}

func testSubscriptionProgressFindsHighestUsageRatio() {
    let subscriptions = [
        SubscriptionSummaryItem(id: 1, groupName: "Claude", status: "active", dailyProgress: 0.25, weeklyProgress: nil, monthlyProgress: 0.6, expiresAt: nil, daysRemaining: 12),
        SubscriptionSummaryItem(id: 2, groupName: "OpenAI", status: "active", dailyProgress: 0.82, weeklyProgress: 0.71, monthlyProgress: nil, expiresAt: nil, daysRemaining: 2),
    ]

    let summary = SubscriptionSummary(activeCount: 2, subscriptions: subscriptions)

    XCTAssert(summary.highestProgress == 0.82)
    XCTAssert(summary.expiringSoonCount == 1)
}

func testSubscriptionSummaryDecodesUsdUsageIntoProgress() throws {
    let json = """
    {
      "active_count": 1,
      "total_used_usd": 498.38329835,
      "subscriptions": [
        {
          "id": 2,
          "group_name": "codex",
          "status": "active",
          "daily_used_usd": 117.25969085,
          "daily_limit_usd": 124.97,
          "weekly_used_usd": 153.11513095,
          "weekly_limit_usd": 500,
          "monthly_used_usd": 498.38329835,
          "monthly_limit_usd": 2000,
          "daily_reset_in_seconds": 6960,
          "weekly_reset_in_seconds": 435660,
          "monthly_reset_in_seconds": 1821660,
          "days_remaining": 22,
          "expires_at": "2026-05-20T16:29:44+08:00"
        }
      ]
    }
    """.data(using: .utf8)!

    let summary = try JSONDecoder.tokenRouter.decode(SubscriptionSummary.self, from: json)

    XCTAssert(summary.totalUsedUSD == 498.38329835)
    XCTAssert(summary.subscriptions.first?.dailyProgress ?? 0 > 0.93)
    XCTAssert(summary.subscriptions.first?.monthlyProgress ?? 0 > 0.24)
    XCTAssert(summary.subscriptions.first?.dailyResetInSeconds == 6960)
    XCTAssert(summary.subscriptions.first?.daysRemaining == 22)
}

func testAdminUserSubscriptionBuildsSelectedUserSubscriptionSummary() throws {
    let json = """
    [
      {
        "id": 9,
        "user_id": 2,
        "group_id": 3,
        "starts_at": "2026-05-01T00:00:00+08:00",
        "expires_at": "2026-05-23T00:00:00+08:00",
        "status": "active",
        "daily_usage_usd": 117.25,
        "weekly_usage_usd": 153.11,
        "monthly_usage_usd": 498.38,
        "group": {
          "id": 3,
          "name": "codex",
          "daily_limit_usd": 125,
          "weekly_limit_usd": 500,
          "monthly_limit_usd": 2000
        }
      }
    ]
    """.data(using: .utf8)!
    let referenceDate = ISO8601DateFormatter().date(from: "2026-05-21T00:00:00+08:00")!

    let subscriptions = try JSONDecoder.tokenRouter.decode([AdminUserSubscription].self, from: json)
    let summary = SubscriptionSummary(adminSubscriptions: subscriptions, referenceDate: referenceDate)

    XCTAssert(subscriptions.first?.userID == 2)
    XCTAssert(summary.activeCount == 1)
    XCTAssertEqual(summary.totalUsedUSD, 498.38, accuracy: 0.000001)
    XCTAssert(summary.subscriptions.first?.groupName == "codex")
    XCTAssertEqual(summary.subscriptions.first?.dailyProgress ?? 0, 0.938, accuracy: 0.000001)
    XCTAssert(summary.subscriptions.first?.daysRemaining == 2)
}

func testMonitorSnapshotEscalatesSeverityFromSignals() {
    let healthy = MonitorSnapshot(
        mode: .user,
        connected: true,
        stats: DashboardStats(todayRequests: 20, todayActualCost: 1.2, rpm: 4),
        realtime: RealtimeMetrics(errorRate: 0.01),
        accountHealth: AccountHealthSummary(accounts: []),
        subscriptionSummary: nil,
        lastUpdatedAt: Date(timeIntervalSince1970: 0),
        message: nil
    )

    let warned = MonitorSnapshot(
        mode: .user,
        connected: true,
        stats: DashboardStats(todayRequests: 20, todayActualCost: 1.2, rpm: 4),
        realtime: RealtimeMetrics(errorRate: 0.01),
        accountHealth: AccountHealthSummary(accounts: [
            AccountSummary(id: 1, name: "quota", platform: "openai", type: "oauth", status: "active", schedulable: true, quotaLimit: 10, quotaUsed: 9.1, quotaDailyLimit: nil, quotaDailyUsed: nil, quotaWeeklyLimit: nil, quotaWeeklyUsed: nil, errorMessage: "", rateLimitResetAt: nil),
        ]),
        subscriptionSummary: nil,
        lastUpdatedAt: Date(timeIntervalSince1970: 0),
        message: nil
    )

    let failed = MonitorSnapshot(
        mode: .user,
        connected: false,
        stats: nil,
        realtime: nil,
        accountHealth: nil,
        subscriptionSummary: nil,
        lastUpdatedAt: nil,
        message: "offline"
    )

    XCTAssert(healthy.severity == .healthy)
    XCTAssert(warned.severity == .warning)
    XCTAssert(failed.severity == .error)
}

func testMonitorSnapshotLabelsNearLimitSeparatelyFromConnectionFailure() {
    let nearLimit = MonitorSnapshot(
        mode: .user,
        connected: true,
        stats: nil,
        realtime: nil,
        accountHealth: nil,
        subscriptionSummary: SubscriptionSummary(activeCount: 1, subscriptions: [
            SubscriptionSummaryItem(id: 1, groupName: "codex", status: "active", dailyProgress: 0.966, weeklyProgress: nil, monthlyProgress: nil, expiresAt: nil, daysRemaining: 20),
        ]),
        lastUpdatedAt: Date(timeIntervalSince1970: 0),
        message: nil
    )
    let disconnected = MonitorSnapshot(
        mode: .user,
        connected: false,
        stats: nil,
        realtime: nil,
        accountHealth: nil,
        subscriptionSummary: nil,
        lastUpdatedAt: nil,
        message: "offline"
    )

    XCTAssert(nearLimit.statusLabel == "Near Limit")
    XCTAssert(disconnected.statusLabel == "Disconnected")
}

func testMonitorSnapshotBuildsMenuBarPresentationFromDashboardStats() {
    let latestUsage = UsageLog(
        id: 133605,
        model: "gpt-5.5",
        serviceTier: "priority",
        reasoningEffort: "xhigh",
        inputTokens: 946,
        outputTokens: 429,
        cacheCreationTokens: 12_000,
        cacheReadTokens: 75_432,
        inputCost: 0.00946,
        outputCost: 0.02574,
        actualCost: 0.124712,
        createdAt: Date(timeIntervalSince1970: 1_777_453_711)
    )
    let snapshot = MonitorSnapshot(
        mode: .user,
        connected: true,
        stats: DashboardStats(todayRequests: 1119, todayActualCost: 113.3052, rpm: 3),
        menuBarUsageStats: UsagePeriodStats(totalRequests: 2048, totalActualCost: 12.3456),
        latestUsage: latestUsage,
        realtime: nil,
        accountHealth: nil,
        subscriptionSummary: nil,
        lastUpdatedAt: Date(timeIntervalSince1970: 0),
        message: nil
    )
    let defaultConfig = AppConfig(baseURL: "http://127.0.0.1:8080")
    let customConfig = AppConfig(
        baseURL: "http://127.0.0.1:8080",
        menuBarDisplayItems: [.totalRequests, .inputPrice, .outputPrice]
    )

    let defaultPresentation = snapshot.menuBarStatusPresentation(config: defaultConfig)
    let customPresentation = snapshot.menuBarStatusPresentation(config: customConfig)

    XCTAssertEqual(defaultPresentation.topRow, "")
    XCTAssertEqual(defaultPresentation.bottomRow, "")
    XCTAssertEqual(defaultPresentation.hidesHealthyStatusImage, false)
    XCTAssertEqual(customPresentation.topRow, "")
    XCTAssertEqual(customPresentation.bottomRow, "")
    XCTAssertEqual(customPresentation.hidesHealthyStatusImage, false)

    let visibleDefaultConfig = AppConfig(
        baseURL: "http://127.0.0.1:8080",
        showsMenuBarText: true
    )
    let visibleCustomConfig = AppConfig(
        baseURL: "http://127.0.0.1:8080",
        showsMenuBarText: true,
        menuBarDisplayItems: [.totalRequests, .inputPrice, .outputPrice]
    )
    XCTAssertEqual(snapshot.menuBarStatusPresentation(config: visibleDefaultConfig).topRow, "$12.35 | GPT-5.5 | xhigh | 88.4Kc | Fast | 3rpm")
    XCTAssertEqual(snapshot.menuBarStatusPresentation(config: visibleDefaultConfig).bottomRow, "Cost | Model | Eff | Ctx | Tier | RPM")
    XCTAssertEqual(snapshot.menuBarStatusPresentation(config: visibleCustomConfig).topRow, "2048r | $10/M | $60/M")
    XCTAssertEqual(snapshot.menuBarStatusPresentation(config: visibleCustomConfig).bottomRow, "Req | In | Out")
}

func testMonitorSnapshotShowsStandardTierWhenLatestUsageIsNotFast() {
    let latestUsage = UsageLog(
        id: 133605,
        model: "gpt-5.5",
        serviceTier: "standard",
        reasoningEffort: "xhigh",
        inputTokens: 946,
        outputTokens: 429,
        cacheCreationTokens: 12_000,
        cacheReadTokens: 75_432,
        inputCost: 0.00946,
        outputCost: 0.02574,
        actualCost: 0.124712,
        createdAt: Date(timeIntervalSince1970: 1_777_453_711)
    )
    let snapshot = MonitorSnapshot(
        mode: .user,
        connected: true,
        stats: DashboardStats(todayRequests: 1119, todayActualCost: 113.3052, rpm: 3),
        menuBarUsageStats: UsagePeriodStats(totalRequests: 2048, totalActualCost: 12.3456),
        latestUsage: latestUsage,
        realtime: nil,
        accountHealth: nil,
        subscriptionSummary: nil,
        lastUpdatedAt: Date(timeIntervalSince1970: 0),
        message: nil
    )
    let config = AppConfig(baseURL: "http://127.0.0.1:8080")

    XCTAssertEqual(snapshot.menuBarStatusPresentation(config: config).topRow, "")

    let visibleConfig = AppConfig(baseURL: "http://127.0.0.1:8080", showsMenuBarText: true)
    XCTAssertEqual(snapshot.menuBarStatusPresentation(config: visibleConfig).topRow, "$12.35 | GPT-5.5 | xhigh | 88.4Kc | Std | 3rpm")
    XCTAssertEqual(snapshot.menuBarStatusPresentation(config: visibleConfig).bottomRow, "Cost | Model | Eff | Ctx | Tier | RPM")
}

func testMonitorSnapshotMenuBarPresentationHidesHealthyImageWhenTextIsShown() {
    let latestUsage = UsageLog(id: 133605, model: "gpt-5.5")
    let snapshot = MonitorSnapshot(
        mode: .user,
        connected: true,
        stats: DashboardStats(),
        latestUsage: latestUsage,
        realtime: nil,
        accountHealth: nil,
        subscriptionSummary: nil,
        lastUpdatedAt: Date(timeIntervalSince1970: 0),
        message: nil
    )
    let config = AppConfig(
        baseURL: "http://127.0.0.1:8080",
        showsMenuBarText: true,
        menuBarDisplayItems: [.model]
    )

    let presentation = snapshot.menuBarStatusPresentation(config: config)

    XCTAssert(presentation.title == " GPT-5.5")
    XCTAssertEqual(presentation.topRow, "GPT-5.5")
    XCTAssertEqual(presentation.bottomRow, "Model")
    XCTAssert(presentation.hidesHealthyStatusImage == true)
}

func testMonitorSnapshotMenuBarModelPresentationCapitalizesGPTWithoutChangingSnapshotModel() {
    let latestUsage = UsageLog(id: 133605, model: "gpt-5.5")
    let snapshot = MonitorSnapshot(
        mode: .user,
        connected: true,
        stats: DashboardStats(),
        latestUsage: latestUsage,
        realtime: nil,
        accountHealth: nil,
        subscriptionSummary: nil,
        lastUpdatedAt: Date(timeIntervalSince1970: 0),
        message: nil
    )
    let config = AppConfig(
        baseURL: "http://127.0.0.1:8080",
        showsMenuBarText: true,
        menuBarDisplayItems: [.model]
    )

    XCTAssertEqual(snapshot.menuBarStatusPresentation(config: config).topRow, "GPT-5.5")
    XCTAssertEqual(snapshot.latestUsage?.model, "gpt-5.5")
}

func testMonitorSnapshotMenuBarModelPresentationUsesReadableCodexShortName() {
    let latestUsage = UsageLog(id: 133605, model: "codex-mini-latest")
    let snapshot = MonitorSnapshot(
        mode: .user,
        connected: true,
        stats: DashboardStats(),
        latestUsage: latestUsage,
        realtime: nil,
        accountHealth: nil,
        subscriptionSummary: nil,
        lastUpdatedAt: Date(timeIntervalSince1970: 0),
        message: nil
    )
    let config = AppConfig(
        baseURL: "http://127.0.0.1:8080",
        showsMenuBarText: true,
        menuBarDisplayItems: [.model]
    )

    XCTAssertEqual(snapshot.menuBarStatusPresentation(config: config).topRow, "Mini Latest")
    XCTAssertEqual(snapshot.latestUsage?.model, "codex-mini-latest")
}

func testMonitorSnapshotMenuBarModelPresentationUsesReadableClaudeShortName() {
    let latestUsage = UsageLog(id: 133605, model: "claude-opus-4-1-20250805")
    let snapshot = MonitorSnapshot(
        mode: .user,
        connected: true,
        stats: DashboardStats(),
        latestUsage: latestUsage,
        realtime: nil,
        accountHealth: nil,
        subscriptionSummary: nil,
        lastUpdatedAt: Date(timeIntervalSince1970: 0),
        message: nil
    )
    let config = AppConfig(
        baseURL: "http://127.0.0.1:8080",
        showsMenuBarText: true,
        menuBarDisplayItems: [.model]
    )

    XCTAssertEqual(snapshot.menuBarStatusPresentation(config: config).topRow, "Opus 4.1")
    XCTAssertEqual(snapshot.latestUsage?.model, "claude-opus-4-1-20250805")
}

func testStatusFormattersUseReadableClaudeModelNames() {
    XCTAssertEqual(StatusFormatters.menuBarModelName("claude-opus-4-1-20250805"), "Opus 4.1")
    XCTAssertEqual(StatusFormatters.menuBarModelName("claude-3-5-sonnet-20241022"), "Sonnet 3.5")
    XCTAssertEqual(StatusFormatters.menuBarModelName("anthropic/claude-3-5-haiku-20241022"), "Haiku 3.5")
    XCTAssertEqual(StatusFormatters.modelDisplayName("claude-opus-4-1-20250805"), "Claude Opus 4.1")
}

func testStatusFormattersBuildFutureProofModelPresentations() {
    let gpt = StatusFormatters.modelPresentation("gpt-5.6-sol")
    XCTAssertEqual(gpt.rawValue, "gpt-5.6-sol")
    XCTAssertEqual(gpt.displayName, "GPT-5.6 Sol")
    XCTAssertEqual(gpt.compactName, "GPT-5.6-Sol")
    XCTAssertFalse(gpt.isLossy)

    XCTAssertEqual(StatusFormatters.menuBarModelName("gpt-5.6-terra"), "GPT-5.6-Terra")
    XCTAssertEqual(StatusFormatters.menuBarModelName("gpt-5.6-luna"), "GPT-5.6-Luna")

    let codex = StatusFormatters.modelPresentation("codex-auto-review")
    XCTAssertEqual(codex.rawValue, "codex-auto-review")
    XCTAssertEqual(codex.displayName, "Codex Auto Review")
    XCTAssertEqual(codex.compactName, "Auto Review")
    XCTAssertFalse(codex.isLossy)
    XCTAssertEqual(StatusFormatters.menuBarModelName("codex-auto-review"), "Auto Review")

    let unknown = StatusFormatters.modelPresentation("vendor/new-model_ultra")
    XCTAssertEqual(unknown.rawValue, "vendor/new-model_ultra")
    XCTAssertEqual(unknown.displayName, "vendor/new-model_ultra")
    XCTAssertEqual(unknown.compactName, "vendor/new-model_ultra")
    XCTAssertFalse(unknown.isLossy)
}

func testStatusFormattersBuildReasoningEffortPresentationsWithoutRejectingNewValues() {
    let missing = StatusFormatters.reasoningEffortPresentation(nil)
    XCTAssertNil(missing.rawValue)
    XCTAssertEqual(missing.displayName, "None")
    XCTAssertEqual(missing.compactName, "no")
    XCTAssertFalse(missing.isProvided)

    let minimal = StatusFormatters.reasoningEffortPresentation("minimal")
    XCTAssertEqual(minimal.displayName, "Minimal")
    XCTAssertEqual(minimal.compactName, "min")
    XCTAssertTrue(minimal.isProvided)

    XCTAssertEqual(StatusFormatters.reasoningEffortPresentation("low").compactName, "low")
    XCTAssertEqual(StatusFormatters.reasoningEffortPresentation("medium").compactName, "med")
    XCTAssertEqual(StatusFormatters.reasoningEffortPresentation("high").compactName, "high")

    let extraHigh = StatusFormatters.reasoningEffortPresentation("x-high")
    XCTAssertEqual(extraHigh.displayName, "Extra High")
    XCTAssertEqual(extraHigh.compactName, "xhigh")
    XCTAssertTrue(extraHigh.isProvided)

    let maximum = StatusFormatters.reasoningEffortPresentation("max")
    XCTAssertEqual(maximum.displayName, "Max")
    XCTAssertEqual(maximum.compactName, "max")
    XCTAssertTrue(maximum.isProvided)

    let unknown = StatusFormatters.reasoningEffortPresentation("ultracode")
    XCTAssertEqual(unknown.rawValue, "ultracode")
    XCTAssertEqual(unknown.displayName, "ultracode")
    XCTAssertEqual(unknown.compactName, "ultra")
    XCTAssertTrue(unknown.isLossy)
    XCTAssertTrue(unknown.isProvided)
}

func testMonitorSnapshotMenuBarTooltipKeepsFullClaudeModelName() {
    let latestUsage = UsageLog(id: 133605, model: "claude-opus-4-1-20250805")
    let snapshot = MonitorSnapshot(
        mode: .user,
        connected: true,
        stats: DashboardStats(),
        latestUsage: latestUsage,
        realtime: nil,
        accountHealth: nil,
        subscriptionSummary: nil,
        lastUpdatedAt: Date(timeIntervalSince1970: 0),
        message: nil
    )
    let config = AppConfig(
        baseURL: "http://127.0.0.1:8080",
        showsMenuBarText: true,
        menuBarDisplayItems: [.model]
    )

    XCTAssertEqual(
        snapshot.menuBarTooltip(statusText: "OK", config: config),
        """
        TokenRouter OK
        Opus 4.1
        Model
        Model: claude-opus-4-1-20250805
        """
    )
}

func testMonitorSnapshotMenuBarTooltipKeepsUnknownReasoningEffortRawValue() {
    let snapshot = MonitorSnapshot(
        mode: .user,
        connected: true,
        stats: nil,
        latestUsage: UsageLog(model: "gpt-5.6-terra", reasoningEffort: "ultracode"),
        realtime: nil,
        accountHealth: nil,
        subscriptionSummary: nil,
        lastUpdatedAt: nil,
        message: nil
    )
    let config = AppConfig(
        baseURL: "http://127.0.0.1:8080",
        showsMenuBarText: true,
        menuBarDisplayItems: [.model, .reasoningEffort]
    )

    let presentation = snapshot.menuBarStatusPresentation(config: config)
    let tooltip = snapshot.menuBarTooltip(statusText: "OK", config: config)

    XCTAssertEqual(presentation.topRow, "GPT-5.6-Terra | ultra")
    XCTAssertTrue(tooltip.contains("Model: gpt-5.6-terra"))
    XCTAssertTrue(tooltip.contains("Reasoning Effort: ultracode"))
}

func testMonitorSnapshotMenuBarTooltipKeepsTransformedServiceTierRawValue() {
    let snapshot = MonitorSnapshot(
        mode: .user,
        connected: true,
        stats: nil,
        latestUsage: UsageLog(model: "gpt-5.6-luna", serviceTier: "burst-experimental"),
        realtime: nil,
        accountHealth: nil,
        subscriptionSummary: nil,
        lastUpdatedAt: nil,
        message: nil
    )
    let config = AppConfig(
        baseURL: "http://127.0.0.1:8080",
        showsMenuBarText: true,
        menuBarDisplayItems: [.fast]
    )

    let presentation = snapshot.menuBarStatusPresentation(config: config)
    let tooltip = snapshot.menuBarTooltip(statusText: "OK", config: config)

    XCTAssertEqual(presentation.topRow, "Burst")
    XCTAssertTrue(tooltip.contains("Service Tier: burst-experimental"))
}

func testMonitorSnapshotMenuBarPresentationUsesValueAndLabelRowsForSelectedItems() {
    let latestUsage = UsageLog(
        id: 133605,
        model: "gpt-5.5",
        serviceTier: "priority",
        reasoningEffort: "xhigh",
        inputTokens: 430,
        outputTokens: 1172,
        cacheReadTokens: 164_224,
        actualCost: 0.238844
    )
    let snapshot = MonitorSnapshot(
        mode: .admin,
        connected: true,
        stats: DashboardStats(todayRequests: 239, todayActualCost: 0.22, rpm: 52),
        menuBarUsageStats: UsagePeriodStats(totalRequests: 239, totalActualCost: 0.22),
        latestUsage: latestUsage,
        realtime: nil,
        realtimeConcurrency: UserRealtimeConcurrency(userID: 2, userEmail: "target@example.com", username: "target", currentInUse: 1, maxCapacity: 100, loadPercentage: 0.01, waitingInQueue: 0),
        adminNormalAccountCount: 4,
        accountHealth: nil,
        subscriptionSummary: nil,
        lastUpdatedAt: Date(timeIntervalSince1970: 0),
        message: nil
    )
    let config = AppConfig(
        baseURL: "http://127.0.0.1:8080",
        monitorMode: .admin,
        showsMenuBarText: true,
        menuBarDisplayItems: [.totalCost, .totalRequests, .model, .reasoningEffort, .fast, .rpm, .normalAccounts]
    )

    let presentation = snapshot.menuBarStatusPresentation(config: config)

    XCTAssertEqual(presentation.title, " $0.22 | 239r | GPT-5.5 | xhigh | Fast | 4N")
    XCTAssertEqual(presentation.topRow, "$0.22 | 239r | GPT-5.5 | xhigh | Fast | 4N")
    XCTAssertEqual(presentation.bottomRow, "Cost | Req | Model | Eff | Tier | Acct")
    XCTAssert(presentation.hidesHealthyStatusImage == true)
}

func testMonitorSnapshotMenuBarPresentationKeepsAllSelectedItemsInRows() {
    let latestUsage = UsageLog(
        id: 133605,
        model: "gpt-5.5",
        serviceTier: "priority",
        reasoningEffort: "xhigh",
        inputTokens: 430,
        outputTokens: 1172,
        cacheReadTokens: 164_224,
        actualCost: 0.238844
    )
    let snapshot = MonitorSnapshot(
        mode: .admin,
        connected: true,
        stats: DashboardStats(todayRequests: 239, todayActualCost: 0.22, rpm: 52),
        menuBarUsageStats: UsagePeriodStats(totalRequests: 239, totalActualCost: 2864.10),
        latestUsage: latestUsage,
        realtime: nil,
        realtimeConcurrency: UserRealtimeConcurrency(userID: 2, userEmail: "target@example.com", username: "target", currentInUse: 1, maxCapacity: 100, loadPercentage: 0.01, waitingInQueue: 0),
        adminNormalAccountCount: 4,
        accountHealth: nil,
        subscriptionSummary: nil,
        lastUpdatedAt: Date(timeIntervalSince1970: 0),
        message: nil
    )
    let config = AppConfig(
        baseURL: "http://127.0.0.1:8080",
        monitorMode: .admin,
        showsMenuBarText: true,
        menuBarDisplayItems: [.totalCost, .model, .reasoningEffort, .fast, .normalAccounts]
    )

    let presentation = snapshot.menuBarStatusPresentation(config: config)

    XCTAssertEqual(presentation.topRow, "$2.86K | GPT-5.5 | xhigh | Fast | 4N")
    XCTAssertEqual(presentation.bottomRow, "Cost | Model | Eff | Tier | Acct")
}

func testMonitorSnapshotMenuBarPresentationUsesReadableCellWidthsForCommonStatusValues() {
    let latestUsage = UsageLog(
        id: 133605,
        model: "gpt-5.5",
        serviceTier: "standard",
        reasoningEffort: nil
    )
    let snapshot = MonitorSnapshot(
        mode: .admin,
        connected: true,
        stats: DashboardStats(),
        menuBarUsageStats: UsagePeriodStats(totalActualCost: 597.0),
        latestUsage: latestUsage,
        realtime: nil,
        adminNormalAccountCount: 1,
        accountHealth: nil,
        subscriptionSummary: nil,
        lastUpdatedAt: Date(timeIntervalSince1970: 0),
        message: nil
    )
    let config = AppConfig(
        baseURL: "http://127.0.0.1:8080",
        monitorMode: .admin,
        showsMenuBarText: true,
        menuBarDisplayItems: [.totalCost, .model, .reasoningEffort, .fast, .normalAccounts, .codexTasks]
    )

    let presentation = snapshot.menuBarStatusPresentation(config: config)

    XCTAssertEqual(presentation.cells, [
        MenuBarStatusCell(value: "$597.00", label: "Cost", width: 58),
        MenuBarStatusCell(value: "GPT-5.5", label: "Model", width: 100),
        MenuBarStatusCell(value: "no", label: "Eff", width: 40),
        MenuBarStatusCell(value: "Std", label: "Tier", width: 40),
        MenuBarStatusCell(value: "1N", label: "Acct", width: 36),
        MenuBarStatusCell(value: "0", label: "T0R0Q0D0E0", width: 96, valueTone: .secondary),
    ])
}

func testMonitorSnapshotMenuBarPresentationKeepsAllAdminItemsReadable() {
    let latestUsage = UsageLog(
        id: 133605,
        model: "codex-mini-latest",
        serviceTier: "priority",
        reasoningEffort: "xhigh",
        inputTokens: 1_000,
        outputTokens: 1_000,
        cacheReadTokens: 85_400,
        inputCost: 0.00125,
        outputCost: 0.006,
        actualCost: 0.00725
    )
    var activities: [CodexTaskActivity] = []
    for index in 1 ... 33 {
        let isRunning = index >= 32
        activities.append(CodexTaskActivity(
            nodeID: "node-\(index)",
            sessionID: "session-\(index)",
            turnID: "turn-\(index)",
            badge: "A\(index)",
            cwd: nil,
            model: "gpt-5",
            status: isRunning ? .running : .done,
            phase: isRunning ? .tooling : .completed,
            toolName: nil,
            startedAt: Date(timeIntervalSince1970: Double(100 + index)),
            updatedAt: Date(timeIntervalSince1970: Double(200 + index)),
            completedAt: isRunning ? nil : Date(timeIntervalSince1970: Double(200 + index)),
            timeline: []
        ))
    }
    let snapshot = MonitorSnapshot(
        mode: .admin,
        connected: true,
        stats: DashboardStats(todayRequests: 223, todayActualCost: 53.24, rpm: 99),
        menuBarUsageStats: UsagePeriodStats(totalRequests: 223, totalActualCost: 53.24),
        latestUsage: latestUsage,
        realtime: nil,
        realtimeConcurrency: UserRealtimeConcurrency(
            userID: 2,
            userEmail: "target@example.com",
            username: "target",
            currentInUse: 2,
            maxCapacity: 100,
            loadPercentage: 0.02,
            waitingInQueue: 0
        ),
        adminNormalAccountCount: 2,
        accountHealth: nil,
        subscriptionSummary: nil,
        codexTaskActivities: activities,
        lastUpdatedAt: Date(timeIntervalSince1970: 0),
        message: nil
    )
    let config = AppConfig(
        baseURL: "http://127.0.0.1:8080",
        monitorMode: .admin,
        showsMenuBarText: true,
        menuBarDisplayItems: MenuBarDisplayItem.adminVisibleCases
    )

    let presentation = snapshot.menuBarStatusPresentation(config: config)

    XCTAssertEqual(
        presentation.topRow,
        "$53.24 | 223r | Mini Latest | xhigh | 86.4Kc | Fast | $1.25/M | $6/M | 2C | 2N | 0% | 0% | A33R +32"
    )
    XCTAssertEqual(
        presentation.bottomRow,
        "Cost | Req | Model | Eff | Ctx | Tier | In | Out | Conc | Acct | 5h Left | 7d Left | T33R2Q0D0E0"
    )
    XCTAssertEqual(presentation.cells.map { $0.width }, [58, 36, 100, 40, 50, 40, 54, 54, 36, 36, 64, 64, 96])
    XCTAssertFalse(presentation.topRow.contains("i$"))
    XCTAssertFalse(presentation.topRow.contains("o$"))
}

func testMonitorSnapshotMenuBarPresentationTreatsNoneReasoningEffortAsNo() {
    let latestUsage = UsageLog(
        id: 133606,
        model: "gpt-5.5",
        reasoningEffort: "none"
    )
    let snapshot = MonitorSnapshot(
        mode: .user,
        connected: true,
        stats: nil,
        latestUsage: latestUsage,
        realtime: nil,
        accountHealth: nil,
        subscriptionSummary: nil,
        lastUpdatedAt: Date(timeIntervalSince1970: 0),
        message: nil
    )
    let config = AppConfig(
        baseURL: "http://127.0.0.1:8080",
        showsMenuBarText: true,
        menuBarDisplayItems: [.reasoningEffort]
    )

    let presentation = snapshot.menuBarStatusPresentation(config: config)

    XCTAssertEqual(presentation.topRow, "no")
    XCTAssertEqual(presentation.bottomRow, "Eff")
    XCTAssertEqual(presentation.cells, [
        MenuBarStatusCell(value: "no", label: "Eff", width: 40)
    ])
}

func testMonitorSnapshotMenuBarPresentationFitsGPT56SolAndMaxReasoning() {
    let latestUsage = UsageLog(
        id: 133608,
        model: "gpt-5.6-sol",
        reasoningEffort: "max"
    )
    let snapshot = MonitorSnapshot(
        mode: .user,
        connected: true,
        stats: nil,
        latestUsage: latestUsage,
        realtime: nil,
        accountHealth: nil,
        subscriptionSummary: nil,
        lastUpdatedAt: Date(timeIntervalSince1970: 0),
        message: nil
    )
    let config = AppConfig(
        baseURL: "http://127.0.0.1:8080",
        showsMenuBarText: true,
        menuBarDisplayItems: [.model, .reasoningEffort]
    )

    let presentation = snapshot.menuBarStatusPresentation(config: config)

    XCTAssertEqual(presentation.topRow, "GPT-5.6-Sol | max")
    XCTAssertEqual(presentation.bottomRow, "Model | Eff")
    XCTAssertEqual(presentation.cells.map(\.width), [100, 40])
    XCTAssertTrue(snapshot.menuBarTooltip(statusText: "OK", config: config).contains("Model: gpt-5.6-sol"))
}

func testMonitorSnapshotMenuBarPresentationKeepsMinimalReasoningDistinctFromMissing() {
    let snapshot = MonitorSnapshot(
        mode: .user,
        connected: true,
        stats: nil,
        latestUsage: UsageLog(id: 133609, model: "gpt-5.6-sol", reasoningEffort: "minimal"),
        realtime: nil,
        accountHealth: nil,
        subscriptionSummary: nil,
        lastUpdatedAt: Date(timeIntervalSince1970: 0),
        message: nil
    )
    let config = AppConfig(
        baseURL: "http://127.0.0.1:8080",
        showsMenuBarText: true,
        menuBarDisplayItems: [.reasoningEffort]
    )

    XCTAssertEqual(snapshot.menuBarStatusPresentation(config: config).topRow, "min")
}

func testMonitorSnapshotMenuBarPresentationShowsDashReasoningEffortAsNo() {
    let latestUsage = UsageLog(
        id: 133607,
        model: "gpt-5.5",
        reasoningEffort: "-"
    )
    let snapshot = MonitorSnapshot(
        mode: .user,
        connected: true,
        stats: nil,
        latestUsage: latestUsage,
        realtime: nil,
        accountHealth: nil,
        subscriptionSummary: nil,
        lastUpdatedAt: Date(timeIntervalSince1970: 0),
        message: nil
    )
    let config = AppConfig(
        baseURL: "http://127.0.0.1:8080",
        showsMenuBarText: true,
        menuBarDisplayItems: [.reasoningEffort]
    )

    let presentation = snapshot.menuBarStatusPresentation(config: config)

    XCTAssertEqual(presentation.topRow, "no")
    XCTAssertEqual(presentation.bottomRow, "Eff")
    XCTAssertEqual(presentation.cells, [
        MenuBarStatusCell(value: "no", label: "Eff", width: 40)
    ])
}

func testMonitorSnapshotMenuBarPresentationCompressesPricesAndRates() {
    let latestUsage = UsageLog(
        id: 133605,
        model: "gpt-5.5",
        serviceTier: "priority",
        inputTokens: 946,
        outputTokens: 429,
        inputCost: 0.00946,
        outputCost: 0.02574,
        actualCost: 0.124712
    )
    let snapshot = MonitorSnapshot(
        mode: .user,
        connected: true,
        stats: DashboardStats(todayRequests: 2048, todayActualCost: 12.34, rpm: 3),
        menuBarUsageStats: UsagePeriodStats(totalRequests: 2048, totalActualCost: 12.34),
        latestUsage: latestUsage,
        realtime: nil,
        accountHealth: nil,
        subscriptionSummary: nil,
        lastUpdatedAt: Date(timeIntervalSince1970: 0),
        message: nil
    )
    let config = AppConfig(
        baseURL: "http://127.0.0.1:8080",
        showsMenuBarText: true,
        menuBarDisplayItems: [.totalRequests, .inputPrice, .outputPrice, .rpm]
    )

    let presentation = snapshot.menuBarStatusPresentation(config: config)

    XCTAssertEqual(presentation.topRow, "2048r | $10/M | $60/M | 3rpm")
    XCTAssertEqual(presentation.bottomRow, "Req | In | Out | RPM")
}

func testMonitorSnapshotMenuBarPresentationShowsStandardWhenOnlyFastIsSelected() {
    let latestUsage = UsageLog(id: 133605, model: "gpt-5.5", serviceTier: "standard")
    let snapshot = MonitorSnapshot(
        mode: .user,
        connected: true,
        stats: DashboardStats(),
        latestUsage: latestUsage,
        realtime: nil,
        accountHealth: nil,
        subscriptionSummary: nil,
        lastUpdatedAt: Date(timeIntervalSince1970: 0),
        message: nil
    )
    let config = AppConfig(
        baseURL: "http://127.0.0.1:8080",
        showsMenuBarText: true,
        menuBarDisplayItems: [.fast]
    )

    let presentation = snapshot.menuBarStatusPresentation(config: config)

    XCTAssert(presentation.title == " Std")
    XCTAssertEqual(presentation.topRow, "Std")
    XCTAssertEqual(presentation.bottomRow, "Tier")
    XCTAssert(presentation.hidesHealthyStatusImage == true)
}

func testMonitorSnapshotMenuBarPresentationUsesPersistentValueAndLabelRowsForEnabledItems() {
    let snapshot = MonitorSnapshot(
        mode: .user,
        connected: true,
        stats: DashboardStats(),
        latestUsage: nil,
        realtime: nil,
        accountHealth: nil,
        subscriptionSummary: nil,
        lastUpdatedAt: Date(timeIntervalSince1970: 0),
        message: nil
    )
    let config = AppConfig(
        baseURL: "http://127.0.0.1:8080",
        showsMenuBarText: true,
        menuBarDisplayItems: [.totalCost, .model, .reasoningEffort, .contextLength, .fast, .rpm]
    )

    let presentation = snapshot.menuBarStatusPresentation(config: config)

    XCTAssertEqual(presentation.topRow, "$0.00 | No model | no | 0c | no | 0rpm")
    XCTAssertEqual(presentation.bottomRow, "Cost | Model | Eff | Ctx | Tier | RPM")
    XCTAssertEqual(presentation.cells.first { $0.label == "Model" }?.valueTone, .secondary)
    XCTAssertEqual(presentation.cells.first { $0.label == "Tier" }?.valueTone, .secondary)
    XCTAssertFalse(presentation.topRow.contains("--"))
    XCTAssertFalse(presentation.bottomRow.contains("--"))
}

func testMonitorSnapshotMenuBarPresentationKeepsEnabledItemsWhenDisconnected() {
    let snapshot = MonitorSnapshot(
        mode: .user,
        connected: false,
        stats: nil,
        latestUsage: nil,
        realtime: nil,
        accountHealth: nil,
        subscriptionSummary: nil,
        lastUpdatedAt: nil,
        message: "offline"
    )
    let config = AppConfig(
        baseURL: "http://127.0.0.1:8080",
        showsMenuBarText: true,
        menuBarDisplayItems: [.totalCost, .model, .fast, .rpm]
    )

    let presentation = snapshot.menuBarStatusPresentation(config: config)
    let tooltip = snapshot.menuBarTooltip(statusText: "Disconnected", config: config)

    XCTAssertEqual(presentation.topRow, "$0.00 | No model | no | 0rpm")
    XCTAssertEqual(presentation.bottomRow, "Cost | Model | Tier | RPM")
    XCTAssertEqual(
        tooltip,
        """
        TokenRouter Disconnected
        $0.00 | No model | no | 0rpm
        Cost | Model | Tier | RPM
        """
    )
    XCTAssertFalse(presentation.topRow.contains("--"))
    XCTAssertFalse(presentation.bottomRow.contains("--"))
}

func testMonitorSnapshotMenuBarTooltipUsesSamePersistentValueAndLabelRows() {
    let snapshot = MonitorSnapshot(
        mode: .user,
        connected: true,
        stats: DashboardStats(),
        latestUsage: nil,
        realtime: nil,
        accountHealth: nil,
        subscriptionSummary: nil,
        lastUpdatedAt: Date(timeIntervalSince1970: 0),
        message: nil
    )
    let config = AppConfig(
        baseURL: "http://127.0.0.1:8080",
        showsMenuBarText: true,
        menuBarDisplayItems: [.totalCost, .model, .reasoningEffort, .contextLength, .fast, .rpm]
    )

    let tooltip = snapshot.menuBarTooltip(statusText: "OK", config: config)

    XCTAssertEqual(
        tooltip,
        """
        TokenRouter OK
        $0.00 | No model | no | 0c | no | 0rpm
        Cost | Model | Eff | Ctx | Tier | RPM
        """
    )
    XCTAssertFalse(tooltip.contains("--"))
}

func testMonitorSnapshotDoesNotUseTodayFallbackForLast24HourMenuBarStats() {
    let snapshot = MonitorSnapshot(
        mode: .user,
        connected: true,
        stats: DashboardStats(todayRequests: 503, todayActualCost: 12.34, rpm: 3),
        menuBarUsageStats: nil,
        realtime: nil,
        accountHealth: nil,
        subscriptionSummary: nil,
        lastUpdatedAt: Date(timeIntervalSince1970: 0),
        message: nil
    )
    let presentation = snapshot.menuBarStatusPresentation(config: AppConfig(
        baseURL: "http://127.0.0.1:8080",
        showsMenuBarText: true,
        menuBarUsageWindow: .last24Hours,
        menuBarDisplayItems: [.totalCost, .totalRequests]
    ))

    XCTAssertFalse(presentation.topRow.contains("503"))
    XCTAssertFalse(presentation.topRow.contains("$12.34"))
    XCTAssertEqual(presentation.topRow, "$0.00 | 0")
}

func testMonitorSnapshotAllowsEmptyMenuBarItemSelection() {
    let snapshot = MonitorSnapshot(
        mode: .user,
        connected: true,
        stats: DashboardStats(todayRequests: 1119, todayActualCost: 113.3052, rpm: 3),
        menuBarUsageStats: UsagePeriodStats(totalRequests: 2048, totalActualCost: 12.3456),
        realtime: nil,
        accountHealth: nil,
        subscriptionSummary: nil,
        lastUpdatedAt: Date(timeIntervalSince1970: 0),
        message: nil
    )
    let config = AppConfig(baseURL: "http://127.0.0.1:8080", menuBarDisplayItems: [])

    let presentation = snapshot.menuBarStatusPresentation(config: config)

    XCTAssertEqual(presentation.topRow, "")
    XCTAssertEqual(presentation.bottomRow, "")
}

func testMonitorSnapshotIncludesCodexTaskPresentationWhenSelected() {
    let activity = CodexTaskActivity(
        nodeID: "local-node",
        sessionID: "session-a",
        turnID: "turn-a",
        badge: "A1",
        cwd: "/workspace/app",
        model: "gpt-5",
        status: .running,
        phase: .prompt,
        toolName: nil,
        startedAt: Date(timeIntervalSince1970: 100),
        updatedAt: Date(timeIntervalSince1970: 120),
        completedAt: nil,
        timeline: []
    )
    let snapshot = MonitorSnapshot(
        mode: .user,
        connected: true,
        stats: DashboardStats(),
        latestUsage: nil,
        realtime: nil,
        accountHealth: nil,
        subscriptionSummary: nil,
        codexTaskActivities: [activity],
        lastUpdatedAt: Date(timeIntervalSince1970: 0),
        message: nil
    )
    let config = AppConfig(
        baseURL: "http://127.0.0.1:8080",
        showsMenuBarText: true,
        menuBarDisplayItems: [.codexTasks]
    )

    let presentation = snapshot.menuBarStatusPresentation(config: config)

    XCTAssertEqual(presentation.topRow, "A1R")
    XCTAssertEqual(presentation.bottomRow, "T1R1Q0D0E0")
    XCTAssertEqual(presentation.cells, [
        MenuBarStatusCell(value: "A1R", label: "T1R1Q0D0E0", width: 96),
    ])
}

func testMonitorSnapshotCodexTaskPresentationUsesLatestTaskBadgeAndPersistentCounts() {
    let activities = [
        CodexTaskActivity(
            nodeID: "local-node",
            sessionID: "session-a",
            turnID: "turn-a",
            badge: "A1",
            cwd: "/workspace/app",
            model: "gpt-5",
            status: .running,
            phase: .tooling,
            toolName: "Bash",
            startedAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 130),
            completedAt: nil,
            timeline: []
        ),
        CodexTaskActivity(
            nodeID: "remote-node",
            sessionID: "session-b",
            turnID: "turn-b",
            badge: "A2",
            cwd: "/workspace/api",
            model: "gpt-5",
            status: .waiting,
            phase: .prompt,
            toolName: nil,
            startedAt: Date(timeIntervalSince1970: 110),
            updatedAt: Date(timeIntervalSince1970: 140),
            completedAt: nil,
            timeline: []
        ),
    ]
    let snapshot = MonitorSnapshot(
        mode: .user,
        connected: true,
        stats: DashboardStats(),
        latestUsage: nil,
        realtime: nil,
        accountHealth: nil,
        subscriptionSummary: nil,
        codexTaskActivities: activities,
        lastUpdatedAt: Date(timeIntervalSince1970: 0),
        message: nil
    )
    let config = AppConfig(
        baseURL: "http://127.0.0.1:8080",
        showsMenuBarText: true,
        menuBarDisplayItems: [.codexTasks]
    )

    let presentation = snapshot.menuBarStatusPresentation(config: config)

    XCTAssertEqual(presentation.topRow, "A2Q +1")
    XCTAssertEqual(presentation.bottomRow, "T2R1Q1D0E0")
    XCTAssertEqual(presentation.cells, [
        MenuBarStatusCell(value: "A2Q +1", label: "T2R1Q1D0E0", width: 96),
    ])
    XCTAssertFalse(presentation.topRow.contains("--"))
    XCTAssertFalse(presentation.bottomRow.contains("--"))
}

func testMonitorSnapshotCodexTaskPresentationUsesBoundedTaskCellForManyTasks() {
    var activities: [CodexTaskActivity] = []
    for index in 1 ... 5 {
        let isRunning = index == 5
        activities.append(CodexTaskActivity(
            nodeID: "node-\(index)",
            sessionID: "session-\(index)",
            turnID: "turn-\(index)",
            badge: "A\(index)",
            cwd: nil,
            model: "gpt-5",
            status: isRunning ? .running : .done,
            phase: isRunning ? .tooling : .completed,
            toolName: nil,
            startedAt: Date(timeIntervalSince1970: Double(100 + index)),
            updatedAt: Date(timeIntervalSince1970: Double(200 + index)),
            completedAt: isRunning ? nil : Date(timeIntervalSince1970: Double(200 + index)),
            timeline: []
        ))
    }
    let snapshot = MonitorSnapshot(
        mode: .user,
        connected: true,
        stats: DashboardStats(),
        latestUsage: nil,
        realtime: nil,
        accountHealth: nil,
        subscriptionSummary: nil,
        codexTaskActivities: activities,
        lastUpdatedAt: Date(timeIntervalSince1970: 0),
        message: nil
    )
    let config = AppConfig(
        baseURL: "http://127.0.0.1:8080",
        showsMenuBarText: true,
        menuBarDisplayItems: [.codexTasks]
    )

    let presentation = snapshot.menuBarStatusPresentation(config: config)

    XCTAssertEqual(presentation.topRow, "A5R +4")
    XCTAssertEqual(presentation.bottomRow, "T5R1Q0D0E0")
    XCTAssertEqual(presentation.cells, [
        MenuBarStatusCell(value: "A5R +4", label: "T5R1Q0D0E0", width: 96),
    ])
}

func testTokenRouterClientRetriesTransientFailuresBeforeDecodingSuccess() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    StubURLProtocol.responses = [:]
    StubURLProtocol.responseQueues = [
        "/api/v1/auth/me": [
            (status: 500, data: Data(#"{"code":500,"message":"temporary"}"#.utf8)),
            (status: 200, data: Data(#"{"code":0,"message":"ok","data":{"user":{"id":7,"email":"a@example.com","role":"user","concurrency":4}}}"#.utf8)),
        ],
    ]
    StubURLProtocol.requestedPaths = []
    let client = TokenRouterClient(
        config: AppConfig(baseURL: "http://127.0.0.1:8080", authToken: "token"),
        session: session,
        retryPolicy: HTTPRetryPolicy(maxRetries: 2, baseDelaySeconds: 0)
    )

    let response = try await client.currentUser()

    XCTAssert(response.user.id == 7)
    XCTAssert(StubURLProtocol.requestedPaths == ["/api/v1/auth/me", "/api/v1/auth/me"])
}

func testTokenRouterClientDoesNotRetryUnauthorizedResponses() async {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    StubURLProtocol.responses = [:]
    StubURLProtocol.responseQueues = [
        "/api/v1/auth/me": [
            (status: 401, data: Data(#"{"code":401,"message":"unauthorized"}"#.utf8)),
            (status: 200, data: Data(#"{"code":0,"message":"ok","data":{"user":{"id":7,"email":"a@example.com","role":"user","concurrency":4}}}"#.utf8)),
        ],
    ]
    StubURLProtocol.requestedPaths = []
    let client = TokenRouterClient(
        config: AppConfig(baseURL: "http://127.0.0.1:8080", authToken: "expired"),
        session: session,
        retryPolicy: HTTPRetryPolicy(maxRetries: 2, baseDelaySeconds: 0)
    )

    do {
        _ = try await client.currentUser()
        XCTFail("401 should throw without retrying so the auth refresh path can handle it.")
    } catch {
        XCTAssert((error as? TokenRouterError)?.isUnauthorized == true)
        XCTAssert(StubURLProtocol.requestedPaths == ["/api/v1/auth/me"])
    }
}

func testTokenRouterClientDoesNotRetryPostRequests() async {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    StubURLProtocol.responses = [:]
    StubURLProtocol.responseQueues = [
        "/api/v1/auth/login": [
            (status: 500, data: Data(#"{"code":500,"message":"temporary"}"#.utf8)),
            (status: 200, data: Data(#"{"code":0,"message":"ok","data":{"accessToken":"access","refreshToken":"refresh"}}"#.utf8)),
        ],
    ]
    StubURLProtocol.requestedPaths = []
    let client = TokenRouterClient(
        config: AppConfig(baseURL: "http://127.0.0.1:8080"),
        session: session,
        retryPolicy: HTTPRetryPolicy(maxRetries: 2, baseDelaySeconds: 0)
    )

    do {
        _ = try await client.login(email: "a@example.com", password: "secret")
        XCTFail("POST login should not retry automatically.")
    } catch {
        XCTAssert(StubURLProtocol.requestedPaths == ["/api/v1/auth/login"])
    }
}

func testMonitorSnapshotRetainsLastSuccessDataWhenRefreshFails() {
    let previous = MonitorSnapshot(
        mode: .user,
        connected: true,
        currentUser: CurrentUser(id: 7, email: "a@example.com", username: "alice", role: "user", balance: 12.5, concurrency: 4, status: "active"),
        stats: DashboardStats(todayRequests: 1119, todayActualCost: 113.3052, rpm: 3),
        menuBarUsageStats: UsagePeriodStats(totalRequests: 2048, totalActualCost: 12.3456),
        latestUsage: UsageLog(id: 133605, model: "gpt-5.5"),
        realtime: nil,
        accountHealth: nil,
        subscriptionSummary: nil,
        lastUpdatedAt: Date(timeIntervalSince1970: 100),
        message: nil
    )
    let stale = previous.retainingDataAfterRefreshFailure("temporary timeout")
    let config = AppConfig(
        baseURL: "http://127.0.0.1:8080",
        showsMenuBarText: true,
        menuBarDisplayItems: [.totalCost, .model, .rpm]
    )

    XCTAssert(stale.connected == true)
    XCTAssert(stale.isStale == true)
    XCTAssert(stale.severity == .warning)
    XCTAssert(stale.statusLabel == "Refresh Failed")
    XCTAssert(stale.lastUpdatedAt == Date(timeIntervalSince1970: 100))
    let presentation = stale.menuBarStatusPresentation(config: config)
    XCTAssert(presentation.title == " $12.35 | GPT-5.5 | 3rpm")
    XCTAssert(presentation.topRow == "$12.35 | GPT-5.5 | 3rpm")
    XCTAssert(presentation.bottomRow == "Cost | Model | RPM")
}

func testLoginFormStateRequiresURLAccountAndPassword() {
    XCTAssert(LoginFormState(baseURL: "", email: "a@example.com", password: "secret").canSubmit == false)
    XCTAssert(LoginFormState(baseURL: "http://127.0.0.1:8080", email: "", password: "secret").canSubmit == false)
    XCTAssert(LoginFormState(baseURL: "http://127.0.0.1:8080", email: "a@example.com", password: "").canSubmit == false)
    XCTAssert(LoginFormState(baseURL: "http://127.0.0.1:8080", email: "a@example.com", password: "secret").canSubmit == true)
}

private func makeTemporaryAppBundle(bundleIdentifier: String, version: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let appURL = root.appendingPathComponent("Sub2APIStatusBar.app", isDirectory: true)
    let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
    let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
    try FileManager.default.createDirectory(at: macOSURL, withIntermediateDirectories: true)
    let plist: [String: Any] = [
        "CFBundleIdentifier": bundleIdentifier,
        "CFBundleShortVersionString": version,
        "CFBundleExecutable": "Sub2APIStatusBar",
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: contentsURL.appendingPathComponent("Info.plist"))
    return appURL
}

}
