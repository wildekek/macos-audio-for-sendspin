import Foundation
import Network

/// A WebSocket a peer opened to one of our listeners.
public struct IncomingConnection: Sendable {
    let socket: WebSocketConnection
    /// The peer's address, e.g. "192.168.1.183:51234".
    public var remoteDescription: String { socket.remoteDescription }
}

/// Listens for WebSocket connections and advertises them over mDNS with the Sendspin path
/// (connection.md, Establishing a Connection). Two kinds:
/// - `server`: `_sendspin-server._tcp` on 8927, for players that look for a server
///   (client-initiated connections);
/// - `client`: `_sendspin._tcp` on 8928, for servers looking for clients, such as Music
///   Assistant connecting to this Mac as an audio source (server-initiated connections).
/// If the recommended port is taken, it listens on any free one; mDNS tells peers which.
public final class ServiceListener: @unchecked Sendable {
    public struct Kind: Sendable {
        let serviceType: String
        let port: UInt16
        /// Who connects, for the log.
        let peers: String

        public static let server = Kind(serviceType: "_sendspin-server._tcp", port: 8927, peers: "players")
        public static let client = Kind(serviceType: "_sendspin._tcp", port: 8928, peers: "servers")
    }

    public static let path = "/sendspin"

    public let connections: AsyncStream<IncomingConnection>
    /// The instance name mDNS registered, which can differ from `name` after a conflict.
    public let registeredNames: AsyncStream<String>

    private let name: String
    private let kind: Kind
    private let registeredContinuation: AsyncStream<String>.Continuation
    private let queue = DispatchQueue(label: "sendspin.listener")
    private let continuation: AsyncStream<IncomingConnection>.Continuation
    // Guarded by `queue`.
    private var listener: NWListener?
    private var failures = 0
    private var stopped = false

    public init(name: String, kind: Kind) {
        self.name = name
        self.kind = kind
        (connections, continuation) = AsyncStream.makeStream()
        (registeredNames, registeredContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    public func start() {
        queue.async { self.listen(on: NWEndpoint.Port(rawValue: self.kind.port)!) }
    }

    public func stop() {
        queue.async {
            self.stopped = true
            self.listener?.cancel()
            self.listener = nil
            self.continuation.finish()
            self.registeredContinuation.finish()
        }
    }

    private func listen(on port: NWEndpoint.Port) {
        let listener: NWListener
        do {
            listener = try NWListener(using: WebSocketConnection.parameters(listening: true), on: port)
        } catch {
            Log.error("Can't listen for \(kind.peers): \(error)")
            return
        }
        // The path is a discovery hint for peers; Network.framework doesn't show us the
        // request path, so any path is accepted.
        listener.service = NWListener.Service(name: name, type: kind.serviceType, domain: nil,
                                              txtRecord: NWTXTRecord(["path": Self.path, "name": name]))
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                Log.info("Listening for \(kind.peers) on port \(listener.port?.rawValue ?? 0) (\(kind.serviceType))")
            case .failed(let error):
                listener.cancel()
                if case .posix(.EADDRINUSE) = error, port != .any {
                    Log.info("Port \(port.rawValue) is taken; listening on another one")
                    queue.async { self.listen(on: .any) }
                } else {
                    // E.g. the mDNS announcement refused ("NoAuth") while macOS is still settling
                    // the Local Network permission, or the network went away: try again later.
                    let delays = [2, 5, 10, 30, 60]
                    let delay = delays[min(failures, delays.count - 1)]
                    failures += 1
                    if failures <= 2 || failures.isMultiple(of: 10) {
                        Log.warning("Listening for \(kind.peers) failed: \(error); trying again in \(delay) s")
                    }
                    queue.asyncAfter(deadline: .now() + .seconds(delay)) {
                        if !self.stopped { self.listen(on: port) }
                    }
                }
            default:
                break
            }
        }
        // Ready can still be followed by a refused announcement: only a registered one counts.
        listener.serviceRegistrationUpdateHandler = { [weak self] change in
            guard let self, case .add(let endpoint) = change else { return }
            failures = 0
            if case let .service(registered, _, _, _) = endpoint { registeredContinuation.yield(registered) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let socket = WebSocketConnection(connection: connection, label: "incoming")
            Log.debug("Incoming connection from \(socket.remoteDescription)")
            continuation.yield(IncomingConnection(socket: socket))
        }
        listener.start(queue: queue)
        self.listener = listener
    }
}
