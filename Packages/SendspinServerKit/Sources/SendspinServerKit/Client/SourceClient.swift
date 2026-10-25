import Foundation

/// What the app shows about this Mac as a source for a Sendspin server such as Music Assistant.
public struct SourceStatus: Sendable, Equatable {
    /// The server holding this Mac's connection, if any.
    public var serverName: String?
    /// That connection is paired: the server may use the Mac's audio.
    public var paired = false
    /// Some server is paired with this Mac, connected or not.
    public var hasPairing = false
    /// Names of paired servers, from their last connection.
    public var pairedServerNames: [String] = []
    /// The server is receiving the Mac's audio.
    public var streaming = false
    /// A code to show while the server pairs with this Mac: six digits, entered there.
    public var pairingCode: String?
    /// The instance name this Mac advertises as a client; the speaker browser skips it.
    public var advertisedName: String?
    /// Too many codes failed: no server can pair by code until the user allows it again.
    public var pairingHeldBack = false

    public var connected: Bool { serverName != nil }

    public init() {}
}

/// This Mac as a Sendspin client with the `source@v1` role: Music Assistant and other servers
/// find it over mDNS (`_sendspin._tcp`), connect, pair with its pairing token, and play its
/// audio wherever they like (roles/source/v1.md). It holds one admitted connection at a time,
/// by the spec's priority rules (connection.md, Multiple servers).
public actor SourceClient {
    public nonisolated let statusUpdates: AsyncStream<SourceStatus>
    var currentStatus: SourceStatus { status }
    /// What the operator pastes into the server to pair. The pairing PSK never changes, so
    /// neither does this.
    public nonisolated let pairingToken: String

    private(set) var credentials: SourceCredentials
    private let save: @Sendable (SourceCredentials) -> Void
    private let name: String
    private let softwareVersion: String
    private let statusContinuation: AsyncStream<SourceStatus>.Continuation
    private var status = SourceStatus() {
        didSet { if status != oldValue { statusContinuation.yield(status) } }
    }

    private var listener: ServiceListener?
    private var tasks: [Task<Void, Never>] = []
    private var sessions: [UUID: SourceSession] = [:]
    private var admitted: SourceSession?
    private var admittedState = SourceSession.State()
    private var available = false
    private var sending = true
    /// Dynamic pairing code rounds since the last verified server_kc, across servers. At the
    /// limit, attempts wait until the app starts anew (pairing.md, Rounds).
    private static let codeRoundLimit = 20

    /// `save` is called with the credentials whenever a pairing changes; persist them whole.
    public init(name: String, softwareVersion: String, credentials: SourceCredentials,
                save: @escaping @Sendable (SourceCredentials) -> Void) {
        // The same name in client/hello as in mDNS, where it's shortest.
        self.name = name.truncated(toUTF8Bytes: ServiceListener.maxNameBytes)
        self.softwareVersion = softwareVersion
        self.credentials = credentials
        self.save = save
        pairingToken = credentials.pairingToken
        (statusUpdates, statusContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        var initial = SourceStatus()
        initial.hasPairing = !credentials.records.isEmpty
        initial.pairedServerNames = credentials.records.compactMap(\.serverName)
        initial.pairingHeldBack = (credentials.failedCodeRounds ?? 0) >= Self.codeRoundLimit
        status = initial
        statusContinuation.yield(initial)
    }

    /// Advertise and accept servers.
    public func start() {
        guard listener == nil else { return }
        let listener = ServiceListener(name: name, kind: .client)
        self.listener = listener
        listener.start()
        tasks.append(Task { [weak self] in
            for await connection in listener.connections {
                await self?.accept(connection)
            }
        })
        tasks.append(Task { [weak self] in
            for await registered in listener.registeredNames {
                await self?.setAdvertisedName(registered)
            }
        })
    }

    /// Say goodbye to every server and stop advertising.
    public func stop() async {
        listener?.stop()
        listener = nil
        tasks.forEach { $0.cancel() }
        tasks = []
        for session in sessions.values { await session.close(goodbye: "shutdown") }
    }

    /// Whether the user offers the Mac's audio (the Music Assistant row is ticked).
    public func setAvailable(_ available: Bool) async {
        self.available = available
        for session in sessions.values { await session.setAvailable(available) }
    }

    /// Send the Mac's audio, or silence: an open stream keeps running on silence, so the
    /// server picks up again when sending resumes.
    public func setSending(_ sending: Bool) async {
        self.sending = sending
        for session in sessions.values { await session.setSending(sending) }
    }

    /// One captured block of the Mac's audio, `captureTimeUs` on this Mac's clock.
    public func deliver(_ pcm: PCMBuffer, captureTimeUs: Int64, bitDepth: Int) async {
        guard let admitted, admittedState.sourceActive else { return }
        await admitted.deliver(pcm, captureTimeUs: captureTimeUs, bitDepth: bitDepth)
    }

    /// Forget every pairing (servers must pair again). Open connections still run on the
    /// forgotten keys, so they close; servers reconnect at once (`restart`), find their key
    /// unknown here and offer pairing again (connection.md, Sentinel Fallback).
    public func forgetPairings() async {
        credentials.records = []
        credentials.lastPlaybackServerID = nil
        save(credentials)
        for session in sessions.values { await session.close(goodbye: "restart") }
        refreshStatus()
    }

    /// Cancel a pairing in progress, from this Mac.
    public func cancelPairing() async {
        await admitted?.cancelPairing()
    }

    var codeRoundLimitReached: Bool { (credentials.failedCodeRounds ?? 0) >= Self.codeRoundLimit }

    /// Count a round whose code didn't match; true once that reaches the limit.
    func codeRoundFailed() -> Bool {
        credentials.failedCodeRounds = (credentials.failedCodeRounds ?? 0) + 1
        save(credentials)
        refreshStatus()
        return codeRoundLimitReached
    }

    func codeRoundVerified() {
        guard credentials.failedCodeRounds != nil else { return }
        credentials.failedCodeRounds = nil
        save(credentials)
        refreshStatus()
    }

    /// The deliberate action that lifts the round limit (pairing.md, Rounds): the user allows
    /// pairing again, in Settings.
    public func allowPairingAgain() {
        codeRoundVerified()
    }

    private func setAdvertisedName(_ name: String) {
        status.advertisedName = name
    }

    private func accept(_ connection: IncomingConnection) {
        let session = SourceSession(client: self, connection: connection, credentials: credentials, name: name,
                                    softwareVersion: softwareVersion, available: available, sending: sending)
        sessions[session.id] = session
        Task { await session.run() }
    }

    // MARK: Sessions

    /// Admission of a connection's first server/activate. The incoming connection wins when
    /// its activities rank at least as high as the admitted one's (playback over pairing over
    /// none), with the spec's exceptions.
    func admit(_ session: SourceSession, activities: Set<String>) async -> Bool {
        let incoming = await session.state
        defer { refreshStatus() }
        guard let current = admitted, current.id != session.id else {
            admitted = session
            admittedState = incoming
            return true
        }
        let held = Set(admittedState.activities)
        func rank(_ activities: Set<String>) -> Int {
            activities.contains("playback") ? 2 : activities.contains("pairing") ? 1 : 0
        }
        let accept: Bool
        if held.contains("pairing") {
            accept = false  // a pairing attempt isn't displaced
        } else if held.isEmpty && activities.isEmpty {
            // Two idle servers: only the last one we played for may take over.
            let last = credentials.lastPlaybackServerID
            accept = incoming.serverID == last && admittedState.serverID != last
        } else {
            accept = rank(activities) >= rank(held)
        }
        guard accept else { return false }
        Log.info("Source: \(incoming.serverName ?? "a server") takes over from \(admittedState.serverName ?? "another server")")
        await current.close(goodbye: "another_server")
        admitted = session
        admittedState = incoming
        return true
    }

    func sessionChanged(_ session: SourceSession) async {
        guard session.id == admitted?.id else { return }
        admittedState = await session.state
        if let serverID = admittedState.serverID, let serverName = admittedState.serverName,
           let index = credentials.records.firstIndex(where: { $0.serverID == serverID }),
           credentials.records[index].serverName != serverName {
            credentials.records[index].serverName = serverName
            save(credentials)
        }
        refreshStatus()
    }

    func sessionEnded(_ session: SourceSession) {
        sessions[session.id] = nil
        if session.id == admitted?.id {
            admitted = nil
            admittedState = SourceSession.State()
        }
        refreshStatus()
    }

    func storePairing(serverID: String, psk: Data) async {
        // Never evict a record an open connection uses, provisional or admitted (pairing.md,
        // Pairing Records).
        let inUse = await recordsInUse()
        credentials.store(serverID: serverID, psk: psk, keeping: inUse)
        save(credentials)
        refreshStatus()
    }

    func touchPairing(serverID: String) {
        credentials.touch(serverID: serverID)
    }

    func removePairing(serverID: String) {
        credentials.remove(serverID: serverID)
        save(credentials)
        refreshStatus()
    }

    func recordPlayback(serverID: String) {
        guard credentials.lastPlaybackServerID != serverID else { return }
        credentials.lastPlaybackServerID = serverID
        save(credentials)
    }

    private func recordsInUse() async -> Set<String> {
        var inUse = Set<String>()
        for session in sessions.values {
            if let serverID = await session.pairedServerID { inUse.insert(serverID) }
        }
        return inUse
    }

    /// Paired connections stay below the record capacity, so a pairing always finds a record
    /// it may evict (pairing.md, Pairing Records). Further ones are turned away as if lower in
    /// priority (connection.md, Multiple servers).
    func admitsPairedConnection(_ session: SourceSession) async -> Bool {
        var open = 0
        for other in sessions.values where other.id != session.id {
            if await other.pairedServerID != nil { open += 1 }
        }
        return open < SourceCredentials.recordCapacity - 1
    }

    private func refreshStatus() {
        var status = self.status
        status.serverName = admitted == nil ? nil : (admittedState.serverName ?? "Sendspin server")
        status.paired = admittedState.paired
        status.streaming = admittedState.streaming
        status.pairingCode = admittedState.pairingCode
        status.hasPairing = !credentials.records.isEmpty
        status.pairedServerNames = credentials.records.compactMap(\.serverName)
        status.pairingHeldBack = codeRoundLimitReached
        self.status = status
    }
}
