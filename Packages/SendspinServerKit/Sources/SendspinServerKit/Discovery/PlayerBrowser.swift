import Foundation
import Network
import dnssd

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
        return await resolveAll(Array(latest)).values.sorted { $0.instanceName < $1.instanceName }
    }

    /// How often the players found are checked. One that lost power or the network can't say
    /// goodbye, and mDNS would keep it for up to 75 minutes (the PTR and TXT records' TTL).
    static let recheckInterval: Duration = .seconds(15)

    /// Browse continuously; yields the players mDNS reports, resolved, whenever they change.
    /// Every `recheckInterval` each one is resolved again, which connects to it: one that moved
    /// gets its new address, and mDNSResponder is asked to verify the records of one that
    /// can't be reached. If it doesn't answer, they're flushed and it leaves the list (for
    /// every app on the Mac); when it's back, its announcement adds it again straight away.
    /// Browsing stops when the consuming task is cancelled. Services named in `ignoring` are
    /// left out without connecting to them. `localNetworkDenied` reports whether macOS refuses
    /// the app Local Network access.
    public static func browse(ignoring: IgnoredNames = IgnoredNames(),
                              localNetworkDenied: (@Sendable (Bool) -> Void)? = nil) -> AsyncStream<[DiscoveredPlayer]> {
        AsyncStream { continuation in
            let (events, eventContinuation) = AsyncStream.makeStream(of: BrowseEvent.self)
            let browsing = Browsing(results: { eventContinuation.yield(.results($0)) }, report: localNetworkDenied)
            browsing.start()
            let ticker = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: recheckInterval)
                    eventContinuation.yield(.recheck)
                }
            }

            let task = Task {
                var current: [String: NWBrowser.Result] = [:]
                var resolved: [String: DiscoveredPlayer] = [:]
                var yielded: [DiscoveredPlayer]?
                for await event in events {
                    switch event {
                    case .results(let results):
                        current = Dictionary(results.compactMap { result -> (String, NWBrowser.Result)? in
                            guard case let .service(name, _, _, _) = result.endpoint,
                                  !ignoring.contains(name) else { return nil }
                            return (name, result)
                        }, uniquingKeysWith: { first, _ in first })
                        resolved = resolved.filter { current[$0.key] != nil }
                        let new = current.filter { resolved[$0.key] == nil }
                        resolved.merge(await resolveAll(Array(new.values))) { _, new in new }
                    case .recheck:
                        current = current.filter { !ignoring.contains($0.key) }
                        resolved = resolved.filter { current[$0.key] != nil }
                        let reachable = await resolveAll(Array(current.values))
                        for (name, result) in current where reachable[name] == nil {
                            Log.debug("\(name) isn't reachable; asking mDNS to verify it")
                            reconfirm(result)
                        }
                        resolved.merge(reachable) { _, new in new }
                    }
                    let players = resolved.values.sorted { $0.instanceName < $1.instanceName }
                    if players != yielded {
                        yielded = players
                        continuation.yield(players)
                    }
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                ticker.cancel()
                browsing.cancel()
                eventContinuation.finish()
            }
        }
    }

    private enum BrowseEvent: Sendable {
        /// The browser's results changed.
        case results(Set<NWBrowser.Result>)
        /// Time to check every player again.
        case recheck
    }

    /// Resolve the players at once: each one that's gone takes the full timeout.
    private static func resolveAll(_ results: [NWBrowser.Result]) async -> [String: DiscoveredPlayer] {
        await withTaskGroup(of: DiscoveredPlayer?.self) { group in
            for result in results {
                group.addTask { await resolve(result) }
            }
            var players: [String: DiscoveredPlayer] = [:]
            for await player in group {
                if let player { players[player.instanceName] = player }
            }
            return players
        }
    }

    /// Ask mDNSResponder to verify a player's PTR record on the interfaces it was found on: it
    /// queries for it, and flushes it unless the player answers. This is how Bonjour expects
    /// a client to report a service that doesn't work.
    private static func reconfirm(_ result: NWBrowser.Result) {
        guard case let .service(name, type, domain, _) = result.endpoint else { return }
        let typeLabels = "\(type).\(domain)".split(separator: ".").map(String.init)
        let serviceType = typeLabels.joined(separator: ".") + "."
        let labels = [name] + typeLabels
        // The instance's full name in DNS wire format: length-prefixed labels, then a zero.
        var rdata = Data()
        for label in labels {
            let bytes = Array(label.utf8.prefix(63))
            rdata.append(UInt8(bytes.count))
            rdata.append(contentsOf: bytes)
        }
        rdata.append(0)
        for interface in result.interfaces {
            let error = rdata.withUnsafeBytes { bytes in
                DNSServiceReconfirmRecord(0, UInt32(interface.index), serviceType,
                                          UInt16(kDNSServiceType_PTR), UInt16(kDNSServiceClass_IN),
                                          UInt16(bytes.count), bytes.baseAddress)
            }
            if error != kDNSServiceErr_NoError {
                Log.warning("\(name): couldn't ask mDNS to verify it (\(error))")
            }
        }
    }

    /// The browser, and whether Local Network access is denied. A browser started without
    /// access waits with "policy denied" straight away (TN3179), and stays that way after access
    /// is granted. Revoking access later doesn't change a running browser's state at all. The
    /// network path does change both times, without saying which way, so each change starts a
    /// short-lived probe browser to find out, and the browser restarts once access is back.
    /// Granting access doesn't always take effect by the time the path changes, so while it's
    /// denied the probe also repeats every few seconds. Everything runs on `queue`.
    private final class Browsing: @unchecked Sendable {
        private let queue = DispatchQueue(label: "sendspin.browser")
        private let results: @Sendable (Set<NWBrowser.Result>) -> Void
        private let report: (@Sendable (Bool) -> Void)?
        private let monitor = NWPathMonitor()
        private var browser: NWBrowser?
        private var probe: NWBrowser?
        private var denied: Bool?
        private var retryScheduled = false

        init(results: @escaping @Sendable (Set<NWBrowser.Result>) -> Void, report: (@Sendable (Bool) -> Void)?) {
            self.results = results
            self.report = report
        }

        func start() {
            queue.async { [self] in
                startBrowser()
                monitor.pathUpdateHandler = { [weak self] _ in self?.startProbe() }
                monitor.start(queue: queue)
            }
        }

        func cancel() {
            queue.async { [self] in
                monitor.cancel()
                browser?.cancel()
                probe?.cancel()
                browser = nil
                probe = nil
            }
        }

        private func startBrowser() {
            browser?.cancel()
            let browser = PlayerBrowser.makeBrowser()
            browser.browseResultsChangedHandler = { [results] current, _ in results(current) }
            browser.stateUpdateHandler = { [weak self, weak browser] state in
                guard let self, self.browser === browser, PlayerBrowser.isPolicyDenied(state) else { return }
                setDenied(true)
            }
            self.browser = browser
            browser.start(queue: queue)
        }

        private func startProbe() {
            probe?.cancel()
            let probe = PlayerBrowser.makeBrowser()
            probe.stateUpdateHandler = { [weak self, weak probe] state in
                guard let self, self.probe === probe, PlayerBrowser.isPolicyDenied(state) else { return }
                finishProbe(denied: true)
            }
            self.probe = probe
            probe.start(queue: queue)
            // With access, nothing happens: no "policy denied" by now means allowed.
            queue.asyncAfter(deadline: .now() + 2) { [weak self, weak probe] in
                guard let self, self.probe === probe else { return }
                finishProbe(denied: false)
            }
        }

        private func finishProbe(denied: Bool) {
            probe?.cancel()
            probe = nil
            if !denied && self.denied == true { startBrowser() }
            setDenied(denied)
        }

        private func setDenied(_ denied: Bool) {
            if denied { retryWhileDenied() }
            guard denied != self.denied else { return }
            Log.debug("Local Network access \(denied ? "denied" : "allowed")")
            self.denied = denied
            report?(denied)
        }

        private func retryWhileDenied() {
            guard !retryScheduled else { return }
            retryScheduled = true
            queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self else { return }
                retryScheduled = false
                if denied == true && probe == nil { startProbe() }
            }
        }
    }

    private static func makeBrowser() -> NWBrowser {
        NWBrowser(for: .bonjourWithTXTRecord(type: serviceType, domain: nil), using: NWParameters())
    }

    private static func isPolicyDenied(_ state: NWBrowser.State) -> Bool {
        switch state {
        case .waiting(let error), .failed(let error):
            if case .dns(let code) = error { return code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) }
            return false
        default:
            return false
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

/// Service names the browser leaves out, such as this Mac's own advertisement as a client:
/// checking it every `recheckInterval` would connect to ourselves.
public final class IgnoredNames: @unchecked Sendable {
    private let lock = NSLock()
    private var names: Set<String> = []

    public init() {}

    public func set(_ names: Set<String>) {
        lock.withLock { self.names = names }
    }

    func contains(_ name: String) -> Bool {
        lock.withLock { names.contains(name) }
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
