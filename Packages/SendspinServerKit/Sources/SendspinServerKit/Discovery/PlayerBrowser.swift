import Foundation
import Network

/// A Sendspin player advertised over mDNS (`_sendspin._tcp`).
public struct DiscoveredPlayer: Sendable, Hashable {
    /// mDNS instance name, e.g. `connect-aux-2-170280`.
    public var instanceName: String
    /// Friendly name from the TXT record, when present.
    public var displayName: String?
    public var url: URL

    public init(instanceName: String, displayName: String?, url: URL) {
        self.instanceName = instanceName
        self.displayName = displayName
        self.url = url
    }
}

public enum PlayerBrowser {
    public static let serviceType = "_sendspin._tcp"

    /// Browse for `duration` and return every player that could be resolved.
    public static func discover(for duration: Duration = .seconds(3)) async -> [DiscoveredPlayer] {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: serviceType, domain: nil),
                                using: NWParameters())
        let queue = DispatchQueue(label: "sendspin.browser")
        let (results, continuation) = AsyncStream.makeStream(of: Set<NWBrowser.Result>.self)
        browser.browseResultsChangedHandler = { results, _ in continuation.yield(results) }
        browser.start(queue: queue)

        let collector = Task {
            var collected = Set<NWBrowser.Result>()
            for await snapshot in results { collected = snapshot }
            return collected
        }
        try? await Task.sleep(for: duration)
        browser.cancel()
        continuation.finish()
        let latest = await collector.value

        return await withTaskGroup(of: DiscoveredPlayer?.self) { group in
            for result in latest {
                group.addTask { await resolve(result) }
            }
            var players: [DiscoveredPlayer] = []
            for await player in group {
                if let player { players.append(player) }
            }
            return players.sorted { $0.instanceName < $1.instanceName }
        }
    }

    /// Browse continuously; yields the full list of resolved players whenever it changes.
    /// Browsing stops when the consuming task is cancelled.
    public static func browse() -> AsyncStream<[DiscoveredPlayer]> {
        AsyncStream { continuation in
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: serviceType, domain: nil),
                                    using: NWParameters())
            let (snapshots, snapshotContinuation) = AsyncStream.makeStream(
                of: Set<NWBrowser.Result>.self, bufferingPolicy: .bufferingNewest(1))
            browser.browseResultsChangedHandler = { results, _ in snapshotContinuation.yield(results) }
            browser.start(queue: DispatchQueue(label: "sendspin.browser"))

            let task = Task {
                var resolved: [String: DiscoveredPlayer] = [:]
                for await results in snapshots {
                    let current = Dictionary(results.compactMap { result -> (String, NWBrowser.Result)? in
                        guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                        return (name, result)
                    }, uniquingKeysWith: { first, _ in first })
                    resolved = resolved.filter { current[$0.key] != nil }
                    for (name, result) in current where resolved[name] == nil {
                        if let player = await resolve(result) { resolved[name] = player }
                    }
                    continuation.yield(resolved.values.sorted { $0.instanceName < $1.instanceName })
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                browser.cancel()
                snapshotContinuation.finish()
            }
        }
    }

    private static func resolve(_ result: NWBrowser.Result) async -> DiscoveredPlayer? {
        guard case let .service(name, _, _, _) = result.endpoint else { return nil }
        var path = "/sendspin"
        var displayName: String?
        if case let .bonjour(txt) = result.metadata {
            if let value = txt["path"], value.hasPrefix("/") { path = value }
            displayName = txt["name"]
        }
        guard let (host, port) = await resolveHostPort(result.endpoint),
              let url = URL(string: "ws://\(host):\(port)\(path)") else { return nil }
        return DiscoveredPlayer(instanceName: name, displayName: displayName, url: url)
    }

    /// Resolve a Bonjour service endpoint to an IPv4 host and port by connecting to it.
    private static func resolveHostPort(_ endpoint: NWEndpoint) async -> (String, UInt16)? {
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: endpoint, using: parameters)
        let queue = DispatchQueue(label: "sendspin.resolve")
        let resolved: (String, UInt16)? = await withCheckedContinuation { continuation in
            let once = OnceFlag()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    var answer: (String, UInt16)?
                    if case let .hostPort(host, port)? = connection.currentPath?.remoteEndpoint {
                        answer = (hostString(host), port.rawValue)
                    }
                    if once.claim() { continuation.resume(returning: answer) }
                case .failed, .cancelled, .waiting:
                    if once.claim() { continuation.resume(returning: nil) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 3) {
                if once.claim() { continuation.resume(returning: nil) }
            }
        }
        connection.cancel()
        return resolved
    }

    private static func hostString(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let address):
            return "\(address)".components(separatedBy: "%").first ?? "\(address)"
        case .ipv6(let address):
            return "[\(address)]"
        case .name(let name, _):
            return name
        @unknown default:
            return "\(host)"
        }
    }
}

/// Thread-safe one-shot flag for resuming a continuation exactly once.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}
