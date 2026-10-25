import Foundation
import Network

/// A client-side WebSocket over Network.framework.
///
/// Inbound frames are stamped with the server clock in the receive callback, before
/// any hop to an actor, so `server/time` replies carry an accurate `server_received`.
final class WebSocketConnection: @unchecked Sendable {
    enum Frame: Sendable {
        case text(Data, receivedAtUs: Int64)
        case binary(Data, receivedAtUs: Int64)
    }

    enum Failure: Error {
        case closed
        /// The peer stopped answering pings: it's gone without closing (unplugged, off the network).
        case unresponsive
    }

    /// A peer that's gone without closing leaves TCP waiting for minutes. Ping/Pong is the
    /// expected liveness check (messaging.md): ping every few seconds, and give up on a peer
    /// that hasn't sent anything, pongs included, for a while.
    private static let pingInterval: DispatchTimeInterval = .seconds(2)
    private static let unresponsiveAfterUs: Int64 = 6_000_000

    let frames: AsyncThrowingStream<Frame, any Error>

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let continuation: AsyncThrowingStream<Frame, any Error>.Continuation
    // Guarded by `queue`.
    private var pendingSends = 0
    private var lastHeardUs: Int64 = 0
    private var pinger: DispatchSourceTimer?
    private var finished = false

    /// Dial a player.
    convenience init(url: URL) {
        self.init(connection: NWConnection(to: .url(url), using: Self.parameters(host: Self.hostHeader(url))),
                  label: url.host() ?? "?")
    }

    /// The `Host` header for dialing `url`: Network.framework leaves out a port that isn't 80,
    /// which RFC 6455 (4.1) requires, and a player that checks it would refuse the upgrade.
    static func hostHeader(_ url: URL) -> String? {
        guard let host = url.host(percentEncoded: false), let port = url.port, port != 80 else { return nil }
        return host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    /// Wrap a connection a client opened to our listener (already a WebSocket); `open()` starts it.
    init(connection: NWConnection, label: String) {
        self.connection = connection
        queue = DispatchQueue(label: "sendspin.ws.\(label)", qos: .userInteractive)
        (frames, continuation) = AsyncThrowingStream.makeStream()
    }

    /// WebSocket over TCP without Nagle's delay, for both dialing and listening. A client's
    /// endpoint refuses an upgrade request with an `Origin` header, which a browser adds
    /// (connection.md, Server Initiated Connections): a web page can't reach it. A server's
    /// endpoint has no such rule, and players send one: sendspin-cpp always, browsers too.
    static func parameters(listening: Bool = false, refusingOrigin: Bool = false, host: String? = nil) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        websocket.maximumMessageSize = 4 * 1024 * 1024
        // Replaces the one Network.framework writes, rather than adding a second.
        if let host { websocket.setAdditionalHeaders([("Host", host)]) }
        if listening && refusingOrigin {
            websocket.setClientRequestHandler(DispatchQueue(label: "sendspin.ws.upgrade")) { _, headers in
                let hasOrigin = headers.contains { $0.name.caseInsensitiveCompare("Origin") == .orderedSame }
                return NWProtocolWebSocket.Response(status: hasOrigin ? .reject : .accept, subprotocol: nil)
            }
        }
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        return parameters
    }

    /// The peer's address, e.g. "192.168.1.183:51234".
    var remoteDescription: String {
        if case let .hostPort(host, port) = connection.endpoint { return "\(host):\(port)" }
        return "\(connection.endpoint)"
    }

    /// Open the connection; returns once the WebSocket upgrade completed.
    func open(timeout: Duration = .seconds(10)) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.waitUntilReady() }
            group.addTask { [connection] in
                try await Task.sleep(for: timeout)
                // The group waits for the other task too: cancelling ends its wait.
                connection.cancel()
                throw NWError.posix(.ETIMEDOUT)
            }
            defer { group.cancelAll() }
            try await group.next()
        }
        receiveNext()
        startPinging()
    }

    private func waitUntilReady() async throws {
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, any Error>) in
            let once = OnceFlag()
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if once.claim() { ready.resume() }
                case .failed(let error), .waiting(let error):
                    if once.claim() { ready.resume(throwing: error) }
                    self?.finish(error)
                case .cancelled:
                    if once.claim() { ready.resume(throwing: Failure.closed) }
                    self?.finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func receiveNext() {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            let now = ServerClock.nowMicros()
            if let error {
                finish(error)
                return
            }
            lastHeardUs = now
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata
            switch metadata?.opcode {
            case .text:
                continuation.yield(.text(data ?? Data(), receivedAtUs: now))
            case .binary:
                continuation.yield(.binary(data ?? Data(), receivedAtUs: now))
            case .close:
                finish(nil)
                connection.cancel()
                return
            default:
                break
            }
            receiveNext()
        }
    }

    /// A text message: UTF-8 JSON, sent as these exact bytes.
    func send(text: Data) {
        send(text, opcode: .text)
    }

    func send(binary: Data) {
        send(binary, opcode: .binary)
    }

    /// Number of sends handed to the network stack but not yet processed.
    var backlog: Int {
        queue.sync { pendingSends }
    }

    private func send(_ data: Data, opcode: NWProtocolWebSocket.Opcode) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: opcode)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
        queue.async { self.pendingSends += 1 }
        connection.send(content: data, contentContext: context, isComplete: true,
                        completion: .contentProcessed { [weak self] error in
                            guard let self else { return }
                            pendingSends -= 1
                            if let error { finish(error) }
                        })
    }

    private func startPinging() {
        queue.async { [self] in
            guard pinger == nil, !finished else { return }
            lastHeardUs = ServerClock.nowMicros()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + Self.pingInterval, repeating: Self.pingInterval)
            timer.setEventHandler { [weak self] in self?.ping() }
            timer.resume()
            pinger = timer
        }
    }

    private func ping() {
        guard ServerClock.nowMicros() - lastHeardUs < Self.unresponsiveAfterUs else {
            finish(Failure.unresponsive)
            connection.cancel()
            return
        }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .ping)
        metadata.setPongHandler(queue) { [weak self] error in
            if error == nil { self?.lastHeardUs = ServerClock.nowMicros() }
        }
        let context = NWConnection.ContentContext(identifier: "ping", metadata: [metadata])
        connection.send(content: Data(), contentContext: context, isComplete: true, completion: .idempotent)
    }

    func close() {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = .protocolCode(.normalClosure)
        let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
        connection.send(content: nil, contentContext: context, isComplete: true,
                        completion: .contentProcessed { [weak self] _ in self?.connection.cancel() })
        // A connection that failed doesn't complete the send, and until it's cancelled it
        // keeps its socket.
        queue.asyncAfter(deadline: .now() + 1) { [connection] in connection.cancel() }
        finish(nil)
    }

    private func finish(_ error: (any Error)?) {
        queue.async { [self] in
            finished = true
            pinger?.cancel()
            pinger = nil
        }
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }
}
