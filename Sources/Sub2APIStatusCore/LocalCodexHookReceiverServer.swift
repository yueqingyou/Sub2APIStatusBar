import Foundation
import Darwin

public enum LocalCodexHookReceiverState: Sendable, Equatable {
    case ready
    case failed(String)
    case invalidSignature(nodeID: String)
    case stopped
}

public final class LocalCodexHookReceiverServer {
    private static let maximumRequestBytes = 1024 * 1024

    private let port: UInt16
    private let onEvent: @MainActor (CodexHookEvent) -> Void
    private let onStateChange: @MainActor (LocalCodexHookReceiverState) -> Void
    private let receiverLock = NSLock()
    private var receiver: CodexHookHTTPReceiver
    private var serverSocket: Int32?
    private var acceptTask: Task<Void, Never>?

    public var listenPort: UInt16 {
        port
    }

    public init(
        port: UInt16,
        nodeSecrets: [String: String],
        onStateChange: @escaping @MainActor (LocalCodexHookReceiverState) -> Void = { _ in },
        onEvent: @escaping @MainActor (CodexHookEvent) -> Void
    ) {
        self.port = port
        self.receiver = CodexHookHTTPReceiver(
            ingestor: CodexHookEventIngestor(nodeSecrets: nodeSecrets, allowedClockSkewSeconds: 300)
        )
        self.onStateChange = onStateChange
        self.onEvent = onEvent
    }

    @MainActor
    public func updateNodeSecrets(_ nodeSecrets: [String: String]) {
        receiverLock.lock()
        defer { receiverLock.unlock() }
        receiver = CodexHookHTTPReceiver(
            ingestor: CodexHookEventIngestor(nodeSecrets: nodeSecrets, allowedClockSkewSeconds: 300)
        )
    }

    @MainActor
    public func start() throws {
        guard serverSocket == nil else {
            return
        }
        let socketDescriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        do {
            try configure(socketDescriptor)
            try bindLoopback(socketDescriptor)
            guard Darwin.listen(socketDescriptor, SOMAXCONN) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            serverSocket = socketDescriptor
            onStateChange(.ready)
            acceptTask = Task.detached(priority: .utility) { [weak self] in
                await self?.acceptLoop(socketDescriptor: socketDescriptor)
            }
        } catch {
            Darwin.close(socketDescriptor)
            onStateChange(.failed(error.localizedDescription))
            throw error
        }
    }

    @MainActor
    public func stop() {
        acceptTask?.cancel()
        acceptTask = nil
        if let serverSocket {
            Darwin.shutdown(serverSocket, SHUT_RDWR)
            Darwin.close(serverSocket)
            self.serverSocket = nil
        }
        onStateChange(.stopped)
    }

    private func configure(_ socketDescriptor: Int32) throws {
        var yes: Int32 = 1
        let result = setsockopt(
            socketDescriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &yes,
            socklen_t(MemoryLayout<Int32>.size)
        )
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func bindLoopback(_ socketDescriptor: Int32) throws {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(socketDescriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func acceptLoop(socketDescriptor: Int32) async {
        while !Task.isCancelled {
            let clientSocket = Darwin.accept(socketDescriptor, nil, nil)
            if clientSocket < 0 {
                if Task.isCancelled {
                    return
                }
                continue
            }
            await handle(clientSocket: clientSocket)
        }
    }

    private func handle(clientSocket: Int32) async {
        defer {
            Darwin.shutdown(clientSocket, SHUT_RDWR)
            Darwin.close(clientSocket)
        }

        let statusCode: Int
        do {
            let requestData = try readRequestData(from: clientSocket)
            statusCode = await responseStatus(for: requestData)
        } catch {
            statusCode = 400
        }
        writeAll(CodexHookHTTPMessageCodec.serializeResponse(statusCode: statusCode), to: clientSocket)
    }

    private func readRequestData(from clientSocket: Int32) throws -> Data {
        var requestData = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while requestData.count <= Self.maximumRequestBytes {
            let readCount = Darwin.recv(clientSocket, &buffer, buffer.count, 0)
            if readCount < 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if readCount == 0 {
                break
            }
            requestData.append(buffer, count: readCount)
            if let completeLength = try CodexHookHTTPMessageCodec.completeRequestLength(in: requestData) {
                return Data(requestData.prefix(completeLength))
            }
        }
        throw CodexHookHTTPMessageCodecError.invalidRequest
    }

    private func responseStatus(for requestData: Data) async -> Int {
        do {
            let request = try CodexHookHTTPMessageCodec.parseRequest(requestData)
            let response = handleRequest(request)
            if response.error == .invalidSignature,
               let nodeID = request.header(CodexHookHTTPReceiver.nodeIDHeader) {
                await onStateChange(.invalidSignature(nodeID: nodeID))
            }
            if let event = response.result?.event {
                await onEvent(event)
            }
            return response.statusCode
        } catch {
            return 400
        }
    }

    private func handleRequest(_ request: CodexHookHTTPRequest) -> CodexHookHTTPResponse {
        receiverLock.lock()
        defer { receiverLock.unlock() }
        return receiver.handle(request, now: Date())
    }

    private func writeAll(_ data: Data, to clientSocket: Int32) {
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }
            var written = 0
            while written < rawBuffer.count {
                let count = Darwin.send(
                    clientSocket,
                    baseAddress.advanced(by: written),
                    rawBuffer.count - written,
                    0
                )
                if count <= 0 {
                    return
                }
                written += count
            }
        }
    }
}
