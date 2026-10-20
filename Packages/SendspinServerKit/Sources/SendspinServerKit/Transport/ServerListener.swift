import Foundation
import Network

/// A WebSocket a player opened to this server (client-initiated connection).
public struct IncomingConnection: Sendable {
    let socket: WebSocketConnection
    /// The player's address, e.g. "192.168.1.183:51234".
    public var remoteDescription: String { socket.remoteDescription }
}

/// Accepts client-initiated connections (connection.md, Client Initiated Connections):
/// advertises this server over mDNS as `_sendspin-server._tcp` with its WebSocket path, and
/// hands over each player that connects. If the recommended port is taken, it listens on any
/// free one; mDNS tells players which.
public final class ServerListener: @unchecked Sendable {
    public static let serviceType = "_sendspin-server._tcp"
    public static let defaultPort: UInt16 = 8927
    public static let path = "/sendspin"

    public let connections: AsyncStream<IncomingConnection>

    private let name: String
    private let queue = DispatchQueue(label: "sendspin.listener")
    private let continuation: AsyncStream<IncomingConnection>.Continuation
    // Guarded by `queue`.
    private var listener: NWListener?
    private var failures = 0
    private var stopped = false

    public init(name: String) {
        self.name = name
        (connections, continuation) = AsyncStream.makeStream()
    }

    public func start() {
        queue.async { self.listen(on: NWEndpoint.Port(rawValue: Self.defaultPort)!) }
    }

    public func stop() {
        queue.async {
            self.stopped = true
            self.listener?.cancel()
            self.listener = nil
            self.continuation.finish()
        }
    }

    private func listen(on port: NWEndpoint.Port) {
        let listener: NWListener
        do {
            listener = try NWListener(using: WebSocketConnection.parameters(), on: port)
        } catch {
            Log.error("Can't listen for players: \(error)")
            return
        }
        // The path is a discovery hint for players; Network.framework doesn't show us the
        // request path, so any path is accepted.
        listener.service = NWListener.Service(name: name, type: Self.serviceType, domain: nil,
                                              txtRecord: NWTXTRecord(["path": Self.path, "name": name]))
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                Log.info("Listening for players on port \(listener.port?.rawValue ?? 0) (\(Self.serviceType))")
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
                        Log.warning("Listening for players failed: \(error); trying again in \(delay) s")
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
            if case .add = change { self?.failures = 0 }
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
