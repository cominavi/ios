import Foundation
import Network

protocol SharedPlanSyncRequestAuthorizing: Sendable {
    func sharedPlanSyncWebSocketRequest(planID: String) async throws -> URLRequest
}

protocol SharedPlanSyncSocket: Actor {
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close() async
}

protocol SharedPlanSyncConnecting: Sendable {
    func connect(request: URLRequest) async throws -> any SharedPlanSyncSocket
}

/// URLSession owns the TLS upgrade and socket lifecycle. The actor keeps its
/// mutable task isolated and enforces a bounded JSON envelope before decoding
/// the separately bounded Automerge payload.
actor URLSessionSharedPlanSyncSocket: SharedPlanSyncSocket {
    static let maximumEnvelopeBytes = 1_500_000

    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
        task.maximumMessageSize = Self.maximumEnvelopeBytes
    }

    func send(_ data: Data) async throws {
        guard data.count <= Self.maximumEnvelopeBytes else {
            throw SharedPlanError.syncPayloadTooLarge
        }
        try await task.send(try Self.outboundMessage(for: data))
    }

    /// The Worker wire contract is a UTF-8 JSON text frame. Keeping the
    /// conversion at the URLSession boundary prevents test doubles that carry
    /// `Data` from accidentally masking a binary WebSocket frame in production.
    static func outboundMessage(
        for data: Data
    ) throws -> URLSessionWebSocketTask.Message {
        guard let json = String(data: data, encoding: .utf8) else {
            throw SharedPlanError.syncProtocolViolation
        }
        return .string(json)
    }

    func receive() async throws -> Data {
        let data: Data
        switch try await task.receive() {
        case .data(let value):
            data = value
        case .string(let value):
            data = Data(value.utf8)
        @unknown default:
            throw SharedPlanError.syncProtocolViolation
        }
        guard data.count <= Self.maximumEnvelopeBytes else {
            throw SharedPlanError.syncPayloadTooLarge
        }
        return data
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
    }
}

final class URLSessionSharedPlanSyncConnector: SharedPlanSyncConnecting,
    @unchecked Sendable
{
    private let delegate: SharedPlanWebSocketSessionDelegate
    private let session: URLSession

    init() {
        let delegate = SharedPlanWebSocketSessionDelegate()
        self.delegate = delegate
        session = URLSession(
            configuration: .default,
            delegate: delegate,
            delegateQueue: nil
        )
    }

    func connect(request: URLRequest) async throws -> any SharedPlanSyncSocket {
        guard let scheme = request.url?.scheme?.lowercased(),
              scheme == "wss" || scheme == "ws"
        else { throw SharedPlanError.syncProtocolViolation }
        let task = session.webSocketTask(with: request)
        let socket = URLSessionSharedPlanSyncSocket(task: task)
        try await delegate.resumeAndWaitUntilOpen(task)
        return socket
    }
}

/// A WebSocket request is not connected merely because `resume()` returned.
/// Keep the Foundation handshake callback as the transport admission boundary
/// so a coordinator never starts its protocol receive loop on a task that has
/// not successfully negotiated HTTP 101 yet.
private final class SharedPlanWebSocketSessionDelegate: NSObject,
    URLSessionWebSocketDelegate, @unchecked Sendable
{
    private let lock = NSLock()
    private var pendingOpen: [Int: CheckedContinuation<Void, Error>] = [:]

    func resumeAndWaitUntilOpen(_ task: URLSessionWebSocketTask) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                precondition(pendingOpen[task.taskIdentifier] == nil)
                pendingOpen[task.taskIdentifier] = continuation
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
            self.complete(
                taskIdentifier: task.taskIdentifier,
                result: .failure(CancellationError())
            )
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        complete(taskIdentifier: webSocketTask.taskIdentifier, result: .success(()))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        complete(taskIdentifier: task.taskIdentifier, result: .failure(error))
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        complete(
            taskIdentifier: webSocketTask.taskIdentifier,
            result: .failure(URLError(.networkConnectionLost))
        )
    }

    private func complete(
        taskIdentifier: Int,
        result: Result<Void, Error>
    ) {
        lock.lock()
        let continuation = pendingOpen.removeValue(forKey: taskIdentifier)
        lock.unlock()
        continuation?.resume(with: result)
    }
}

/// Network.framework provides the same RFC 6455/TLS stack without routing the
/// upgrade through CFNetwork's URL loading layer. This is the production
/// fallback for OS releases where URLSession rejects a valid Cloudflare 101
/// response with `NSURLErrorNetworkConnectionLost` before `didOpen`.
final class NetworkFrameworkSharedPlanSyncConnector: SharedPlanSyncConnecting,
    @unchecked Sendable
{
    func connect(request: URLRequest) async throws -> any SharedPlanSyncSocket {
        let socket = try NetworkFrameworkSharedPlanSyncSocket(request: request)
        try await socket.start()
        return socket
    }
}

actor NetworkFrameworkSharedPlanSyncSocket: SharedPlanSyncSocket {
    private static let queue = DispatchQueue(
        label: "llc.mikunet.cominavi.shared-plan-websocket"
    )

    private let connection: NWConnection
    private let openGate: SharedPlanNWConnectionOpenGate

    init(request: URLRequest) throws {
        guard let url = request.url,
              let scheme = url.scheme?.lowercased(),
              scheme == "wss" || scheme == "ws"
        else { throw SharedPlanError.syncProtocolViolation }

        let webSocket = NWProtocolWebSocket.Options(.version13)
        webSocket.autoReplyPing = true
        webSocket.maximumMessageSize = URLSessionSharedPlanSyncSocket.maximumEnvelopeBytes
        let headers = (request.allHTTPHeaderFields ?? [:])
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { (name: $0.key, value: $0.value) }
        webSocket.setAdditionalHeaders(headers)

        let parameters: NWParameters
        if scheme == "wss" {
            parameters = NWParameters(
                tls: NWProtocolTLS.Options(),
                tcp: NWProtocolTCP.Options()
            )
        } else {
            parameters = .tcp
        }
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        connection = NWConnection(to: .url(url), using: parameters)
        openGate = SharedPlanNWConnectionOpenGate()
    }

    func start() async throws {
        try await openGate.start(connection, queue: Self.queue)
    }

    func send(_ data: Data) async throws {
        guard data.count <= URLSessionSharedPlanSyncSocket.maximumEnvelopeBytes else {
            throw SharedPlanError.syncPayloadTooLarge
        }
        guard String(data: data, encoding: .utf8) != nil else {
            throw SharedPlanError.syncProtocolViolation
        }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(
            identifier: "shared-plan-sync",
            metadata: [metadata]
        )
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data,
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }

    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receiveMessage { data, context, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard isComplete,
                      let data,
                      data.count <= URLSessionSharedPlanSyncSocket.maximumEnvelopeBytes,
                      let metadata = context?.protocolMetadata(
                          definition: NWProtocolWebSocket.definition
                      ) as? NWProtocolWebSocket.Metadata,
                      metadata.opcode == .text || metadata.opcode == .binary
                else {
                    continuation.resume(throwing: SharedPlanError.syncProtocolViolation)
                    return
                }
                continuation.resume(returning: data)
            }
        }
    }

    func close() {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = .protocolCode(.goingAway)
        let context = NWConnection.ContentContext(
            identifier: "shared-plan-close",
            metadata: [metadata]
        )
        connection.send(
            content: nil,
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { [connection] _ in
                connection.cancel()
            }
        )
    }
}

private final class SharedPlanNWConnectionOpenGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    func start(_ connection: NWConnection, queue: DispatchQueue) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                precondition(self.continuation == nil)
                self.continuation = continuation
                lock.unlock()
                connection.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        self?.complete(.success(()))
                    case .failed(let error):
                        self?.complete(.failure(error))
                    case .cancelled:
                        self?.complete(.failure(CancellationError()))
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            connection.cancel()
            self.complete(.failure(CancellationError()))
        }
    }

    private func complete(_ result: Result<Void, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

enum SharedPlanSyncConnectionStatus: Equatable, Sendable {
    case idle
    case connecting
    case connected(mutationsEnabled: Bool, pendingOperationCount: Int)
    case synchronized(mutationsEnabled: Bool, pendingOperationCount: Int)
    case reconnecting(String)
    case quarantined(SharedPlanSyncIssue)

    var permitsContentMutations: Bool {
        switch self {
        case .connected(true, _), .synchronized(true, _): true
        default: false
        }
    }
}

struct SharedPlanSyncCoordinatorCallbacks: Sendable {
    let pendingOperationCount: @Sendable () async -> Int
    let generateOutboundFrame: @Sendable (
        SharedPlanSyncSession
    ) async throws -> SharedPlanClientSyncFrame?
    let receiveServerFrame: @Sendable (
        SharedPlanSyncSession,
        SharedPlanServerSyncFrame
    ) async throws -> Bool
    let receiveAcknowledgement: @Sendable (
        SharedPlanSyncSession,
        SharedPlanSyncAcknowledgement
    ) async throws -> Set<UUID>
    let receiveError: @Sendable (SharedPlanSyncErrorFrame) async -> SharedPlanSyncIssue?
    let updateStatus: @Sendable (SharedPlanSyncConnectionStatus) async -> Void
}

private enum SharedPlanInboundSyncMessage {
    case hello(SharedPlanSyncHello)
    case sync(SharedPlanServerSyncFrame)
    case acknowledgement(SharedPlanSyncAcknowledgement)
    case error(SharedPlanSyncErrorFrame)

    private struct Header: Decodable {
        let v: Int
        let type: String
    }

    static func decode(_ data: Data) throws -> SharedPlanInboundSyncMessage {
        let decoder = JSONDecoder()
        let header = try decoder.decode(Header.self, from: data)
        guard header.v == 1 else { throw SharedPlanError.syncProtocolViolation }
        switch header.type {
        case "hello":
            return .hello(try decoder.decode(SharedPlanSyncHello.self, from: data))
        case "sync":
            return .sync(try decoder.decode(SharedPlanServerSyncFrame.self, from: data))
        case "ack":
            return .acknowledgement(
                try decoder.decode(SharedPlanSyncAcknowledgement.self, from: data)
            )
        case "error":
            return .error(try decoder.decode(SharedPlanSyncErrorFrame.self, from: data))
        default:
            throw SharedPlanError.syncProtocolViolation
        }
    }
}

private enum SharedPlanSyncLoopError: Error {
    case timeout
    case terminal
}

private actor SharedPlanReceiveRaceGate {
    private var hasWinner = false

    func claim() -> Bool {
        guard !hasWinner else { return false }
        hasWinner = true
        return true
    }
}

private enum SharedPlanReceiveRaceOutcome: @unchecked Sendable {
    case data(Data)
    case failure(any Error)
    case timeout
    case ignored
}

/// One open plan owns one coordinator. Raw frames, SyncState, direction
/// sequences, and receipt hashes never leave its live ordered session. A
/// reconnect discards all of them, reloads fresh auth, and regenerates from the
/// durable Automerge document plus semantic-operation ledger.
actor SharedPlanSyncCoordinator {
    private let planID: String
    private let authorizer: any SharedPlanSyncRequestAuthorizing
    private let connector: any SharedPlanSyncConnecting
    private let session: SharedPlanSyncSession
    private let callbacks: SharedPlanSyncCoordinatorCallbacks
    private let receiveTimeoutNanoseconds: UInt64
    private let maximumExactFrameRetries: Int
    private let reconnectBaseDelayNanoseconds: UInt64

    private var runTask: Task<Void, Never>?
    private var socket: (any SharedPlanSyncSocket)?
    private var generation: UInt64 = 0

    init(
        planID: String,
        authorizer: any SharedPlanSyncRequestAuthorizing,
        connector: any SharedPlanSyncConnecting,
        session: SharedPlanSyncSession,
        callbacks: SharedPlanSyncCoordinatorCallbacks,
        receiveTimeoutNanoseconds: UInt64 = 30_000_000_000,
        maximumExactFrameRetries: Int = 2,
        reconnectBaseDelayNanoseconds: UInt64 = 1_000_000_000
    ) {
        self.planID = planID
        self.authorizer = authorizer
        self.connector = connector
        self.session = session
        self.callbacks = callbacks
        self.receiveTimeoutNanoseconds = receiveTimeoutNanoseconds
        self.maximumExactFrameRetries = maximumExactFrameRetries
        self.reconnectBaseDelayNanoseconds = reconnectBaseDelayNanoseconds
    }

    func start() {
        guard runTask == nil else { return }
        launchRunTask()
    }

    func documentIdentity() async -> SharedPlanSyncDocumentIdentity {
        await session.documentIdentity()
    }

    private func launchRunTask() {
        generation &+= 1
        let currentGeneration = generation
        runTask = Task { [weak self] in
            await self?.run(generation: currentGeneration)
            await self?.finishedRun(generation: currentGeneration)
        }
    }

    func restartAfterNetworkRecovery() async {
        generation &+= 1
        runTask?.cancel()
        runTask = nil
        await stopSocketOnly()
        launchRunTask()
    }

    /// Local changes are already durable when this is called. Reconnecting
    /// intentionally discards live-only SyncState/raw frames and regenerates
    /// a fresh payload from the persisted document and semantic-operation
    /// ledger, which also wakes a coordinator blocked on an idle socket.
    func restartAfterDurableMutation() async {
        generation &+= 1
        runTask?.cancel()
        runTask = nil
        await stopSocketOnly()
        launchRunTask()
    }

    func stop() async {
        generation &+= 1
        runTask?.cancel()
        runTask = nil
        await stopSocketOnly()
        await callbacks.updateStatus(.idle)
    }

    private func run(generation expectedGeneration: UInt64) async {
        var retryAttempt = 0
        while isCurrent(expectedGeneration) {
            do {
                await callbacks.updateStatus(.connecting)
                let request = try await authorizer.sharedPlanSyncWebSocketRequest(planID: planID)
                guard isCurrent(expectedGeneration) else { return }
                let connectedSocket = try await connector.connect(request: request)
                guard isCurrent(expectedGeneration) else {
                    await connectedSocket.close()
                    return
                }
                socket = connectedSocket
                try await runLiveSession(
                    socket: connectedSocket,
                    generation: expectedGeneration
                )
                throw SharedPlanSyncLoopError.timeout
            } catch is CancellationError {
                break
            } catch SharedPlanSyncLoopError.terminal {
                break
            } catch {
                guard isCurrent(expectedGeneration) else { break }
                await stopSocketOnly()
                await callbacks.updateStatus(.reconnecting(error.localizedDescription))
                let multiplier = UInt64(1 << min(retryAttempt, 5))
                let (scaledDelay, overflow) = reconnectBaseDelayNanoseconds
                    .multipliedReportingOverflow(by: multiplier)
                let delay = min(
                    30_000_000_000,
                    overflow ? 30_000_000_000 : scaledDelay
                )
                retryAttempt += 1
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    break
                }
            }
        }
        if isCurrent(expectedGeneration) {
            await stopSocketOnly()
        }
    }

    private func runLiveSession(
        socket: any SharedPlanSyncSocket,
        generation expectedGeneration: UInt64
    ) async throws {
        let firstData = try await receiveWithTimeout(from: socket)
        guard case .hello(let hello) = try SharedPlanInboundSyncMessage.decode(firstData)
        else { throw SharedPlanError.syncProtocolViolation }
        try await session.receiveHello(hello)
        var exactRetryCount = 0
        var hasSentNegotiation = false
        await publishConnectedStatus(synchronized: false)
        hasSentNegotiation = try await sendNextFrameIfAvailable(
            to: socket,
            hasSentNegotiation: hasSentNegotiation
        ) || hasSentNegotiation

        while isCurrent(expectedGeneration) {
            let data: Data
            do {
                if await session.outboundFrameAwaitingResponse() != nil {
                    data = try await receiveWithTimeout(from: socket)
                } else {
                    // A quiet synchronized socket is healthy. Response
                    // deadlines only apply while an immutable outbound frame
                    // is awaiting a server response; otherwise reconnecting
                    // on a timer would create an endless idle loop.
                    data = try await socket.receive()
                }
                exactRetryCount = 0
            } catch SharedPlanSyncLoopError.timeout {
                guard let exactFrame = await session.outboundFrameAwaitingResponse(),
                      exactRetryCount < maximumExactFrameRetries
                else { throw SharedPlanSyncLoopError.timeout }
                try await socket.send(JSONEncoder().encode(exactFrame))
                exactRetryCount += 1
                continue
            }

            switch try SharedPlanInboundSyncMessage.decode(data) {
            case .hello:
                throw SharedPlanError.syncProtocolViolation

            case .sync(let frame):
                _ = try await callbacks.receiveServerFrame(session, frame)
                await publishConnectedStatus(synchronized: true)

            case .acknowledgement(let acknowledgement):
                _ = try await callbacks.receiveAcknowledgement(session, acknowledgement)
                await publishConnectedStatus(synchronized: true)

            case .error(let error):
                await session.receiveError(error)
                let issue = await callbacks.receiveError(error)
                if let issue { await callbacks.updateStatus(.quarantined(issue)) }
                if !error.retryable || issue != nil {
                    throw SharedPlanSyncLoopError.terminal
                }
                throw SharedPlanSyncLoopError.timeout
            }

            hasSentNegotiation = try await sendNextFrameIfAvailable(
                to: socket,
                hasSentNegotiation: hasSentNegotiation
            ) || hasSentNegotiation
        }
    }

    @discardableResult
    private func sendNextFrameIfAvailable(
        to socket: any SharedPlanSyncSocket,
        hasSentNegotiation: Bool
    ) async throws -> Bool {
        let pendingCount = await callbacks.pendingOperationCount()
        let serverAllowsMutations = await session.mutationsEnabled
        // A fresh Automerge state first advertises heads. That read-only
        // negotiation is safe, but once the server asks for local changes the
        // held mutation flag must prevent uploading them.
        guard serverAllowsMutations || pendingCount == 0 || !hasSentNegotiation else {
            await callbacks.updateStatus(.connected(
                mutationsEnabled: false,
                pendingOperationCount: pendingCount
            ))
            return false
        }
        guard let frame = try await callbacks.generateOutboundFrame(session) else {
            return false
        }
        try await socket.send(JSONEncoder().encode(frame))
        return true
    }

    private func publishConnectedStatus(synchronized: Bool) async {
        let status: SharedPlanSyncConnectionStatus
        let pendingCount = await callbacks.pendingOperationCount()
        let enabled = await session.mutationsEnabled
        if synchronized {
            status = .synchronized(
                mutationsEnabled: enabled,
                pendingOperationCount: pendingCount
            )
        } else {
            status = .connected(
                mutationsEnabled: enabled,
                pendingOperationCount: pendingCount
            )
        }
        await callbacks.updateStatus(status)
    }

    private func receiveWithTimeout(
        from socket: any SharedPlanSyncSocket
    ) async throws -> Data {
        let timeout = receiveTimeoutNanoseconds
        let gate = SharedPlanReceiveRaceGate()
        return try await withThrowingTaskGroup(
            of: SharedPlanReceiveRaceOutcome.self
        ) { group in
            group.addTask {
                do {
                    let data = try await socket.receive()
                    return await gate.claim() ? .data(data) : .ignored
                } catch {
                    return await gate.claim() ? .failure(error) : .ignored
                }
            }
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: timeout)
                } catch {
                    return .ignored
                }
                guard await gate.claim() else { return .ignored }
                // Some URLSessionWebSocketTask receives do not complete merely
                // because their Swift task was cancelled. Close this exact
                // live socket at the deadline so the receive child unblocks
                // before structured concurrency waits for group teardown.
                await socket.close()
                return .timeout
            }
            while let outcome = try await group.next() {
                switch outcome {
                case .data(let data):
                    group.cancelAll()
                    return data
                case .failure(let error):
                    group.cancelAll()
                    throw error
                case .timeout:
                    group.cancelAll()
                    throw SharedPlanSyncLoopError.timeout
                case .ignored:
                    continue
                }
            }
            throw SharedPlanSyncLoopError.timeout
        }
    }

    private func isCurrent(_ expectedGeneration: UInt64) -> Bool {
        generation == expectedGeneration && !Task.isCancelled
    }

    private func finishedRun(generation finishedGeneration: UInt64) {
        guard generation == finishedGeneration else { return }
        runTask = nil
    }

    private func stopSocketOnly() async {
        if let socket { await socket.close() }
        socket = nil
        await session.disconnect()
    }
}
