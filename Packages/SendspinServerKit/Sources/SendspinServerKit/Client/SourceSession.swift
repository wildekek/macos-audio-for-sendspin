import CryptoKit
import Foundation

/// One server's connection to this Mac as a Sendspin client with the `source@v1` role: a
/// server-initiated connection (Music Assistant dials us). It runs the Noise handshake as
/// responder, keeps the clock in sync, pairs with the pairing token or a pairing code shown
/// on this Mac, and streams the Mac's audio while the server asks for it (roles/source/v1.md).
actor SourceSession {
    /// Which PSK keyed the session (connection.md, Pre-Shared Key).
    enum PSKCategory: String {
        case longTerm = "lt", pairing = "pr", sentinel = "sn"
    }

    struct State: Sendable, Equatable {
        var serverID: String?
        var serverName: String?
        /// Keyed by a long-term PSK: the server holds our pairing record.
        var paired = false
        var activities: [String] = []
        var sourceActive = false
        var streaming = false
        /// The pairing code to show while a server pairs with this Mac (six digits).
        var pairingCode: String?
    }

    nonisolated let id = UUID()
    private(set) var state = State()

    private unowned let client: SourceClient
    private let socket: WebSocketConnection
    private let identity: Curve25519.KeyAgreement.PrivateKey
    private let name: String
    private let softwareVersion: String

    private var channel: SecureChannel?
    private var serverKey: Curve25519.KeyAgreement.PublicKey?
    private var matched: PSKCategory = .sentinel
    private var serverCodecs: [String] = []

    // Activation.
    private var activated = false
    private var activeRoles: [String] = []
    /// Between Noise message 1 of a re-handshake and the server/activate under the new keys,
    /// nothing but the handshake may be sent (connection.md, Re-handshake).
    private var rehandshaking = false
    /// We're closing the connection (`close(goodbye:)`), so its end isn't the server's doing.
    private var closing = false

    // Pairing.
    private var pairingIndex = 0
    /// The long-term PSK sent in client/pair-finalize, stored once the server confirms.
    private var pendingPSK: Data?
    private var pairingTimeout: Task<Void, Never>?
    private var codeAttempt: CodeAttempt?

    /// One Dynamic Pairing Code attempt (pairing.md): its code stays the same across rounds,
    /// each round a fresh CPace run.
    private struct CodeAttempt {
        let nonceB = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let pairingIndex: Int
        var round = 0
        /// Waiting for server/pair-init: after client/pair-init, and after client/pair-retry.
        var awaitingRound = true
        /// From the first round's nonce_A on.
        var code: String?
        var cpace: CPace?
        var sid = Data()
    }

    // Clock.
    private var filter = TimeFilter()
    private var timeSync: Task<Void, Never>?
    private var timeReply: CheckedContinuation<(ServerTimeReceived, Int64)?, Never>?
    private var timeExchange = 0
    private var converged: Bool { filter.count >= 3 }

    // Source state.
    /// Whether the Mac's audio may go to the server: `available` in client/state.
    private var available: Bool
    /// Whether to send the Mac's audio or silence. Silence keeps an open stream running, the
    /// way a line-in goes quiet rather than stopping, so the server needn't start it again.
    private var sending: Bool
    private var signalPresent = false
    private var lastSoundUs: Int64?
    private var lastSentState: ClientStateMessage?
    private var startAuthorized = false
    private var pipeline: PlayerAudioPipeline?
    private var droppedChunks = 0

    init(client: SourceClient, connection: IncomingConnection, credentials: SourceCredentials,
         name: String, softwareVersion: String, available: Bool, sending: Bool) {
        self.client = client
        socket = connection.socket
        identity = credentials.identity
        self.name = name
        self.softwareVersion = softwareVersion
        self.available = available
        self.sending = sending
    }

    // MARK: Connection

    func run() async {
        do {
            try await serve()
        } catch {
            // Connections a server opened but never put to use (half-open, superseded) end
            // quietly; one that was in use is worth a line.
            let message = "Source: \(state.serverName ?? socket.remoteDescription): \(error)"
            if activated { Log.info(message) } else { Log.debug(message) }
        }
        timeSync?.cancel()
        pairingTimeout?.cancel()
        timeReply?.resume(returning: nil)
        timeReply = nil
        socket.close()
        await client.sessionEnded(self)
    }

    private func serve() async throws {
        try await socket.open()
        var frames = socket.frames.makeAsyncIterator()
        var timeout = closeAfterTimeout()
        defer { timeout?.cancel() }

        // client/init, then the server's server/init (or server/error) and Noise message 1.
        let suite = NoiseSuite.chaChaPoly
        let clientInit = try MessageCoding.encode(type: "client/init", payload: ClientInitMessage(
            clientID: Base64URL.encode(identity.publicKey.rawRepresentation), suite: suite.rawValue))
        socket.send(text: clientInit)

        guard case let .text(serverInitData, _)? = try await frames.next() else {
            throw SessionError.handshake("expected server/init")
        }
        let type = try MessageCoding.type(of: serverInitData)
        if type == "server/error" {
            let reason = (try? MessageCoding.payload(PairAbortMessage.self, from: serverInitData).reason) ?? "?"
            throw SessionError.handshake("server/error: \(reason)")
        }
        guard type == "server/init", let serverInit = try? MessageCoding.payload(ServerInitMessage.self, from: serverInitData),
              serverInit.version == 1, let keyData = Base64URL.decode(serverInit.serverID), keyData.count == 32,
              let serverKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: keyData)
        else { throw SessionError.handshake("bad server/init") }
        self.serverKey = serverKey
        state.serverID = serverInit.serverID

        guard case let .text(message1Data, _)? = try await frames.next(),
              try MessageCoding.type(of: message1Data) == "noise/handshake",
              let message1 = Base64URL.decode(try MessageCoding.payload(NoiseHandshakeMessage.self, from: message1Data).data)
        else { throw SessionError.handshake("expected Noise message 1") }

        var handshake = NoiseResponderHandshake(suite: suite, prologue: clientInit + serverInitData,
                                                localStatic: identity, remoteStatic: serverKey)
        let (psk, category) = try await choosePSK(try handshake.readMessage1(message1), rehandshake: false)
        let (message2, transport) = try handshake.writeMessage2(payload: Data("{}".utf8), psk: psk)
        socket.send(text: try MessageCoding.encode(type: "noise/handshake",
                                                   payload: NoiseHandshakeMessage(data: Base64URL.encode(message2))))
        channel = SecureChannel(transport: transport)
        handshakeCompleted(category)
        Log.debug("Source: Noise handshake done (\(category.rawValue))")
        if category == .longTerm, !(await client.admitsPairedConnection(self)) {
            Log.info("Source: \(state.serverName ?? "a server") turned away: too many paired connections")
            sendMessage("client/goodbye", ClientGoodbyeMessage(reason: "concurrent_attempt"))
            return
        }
        timeout?.cancel()
        // The server must declare its purpose within 30 s (connection.md, Multiple servers).
        timeout = closeAfterTimeout()

        while let frame = try await frames.next() {
            guard case let .binary(ciphertext, receivedAtUs) = frame else {
                throw SessionError.handshake("cleartext message after the handshake")
            }
            guard let message = try channel?.open(ciphertext) else { continue }
            guard message.type == SecureChannel.jsonType else { continue }
            if try await handle(message.payload, receivedAtUs: receivedAtUs) { return }
            if activated {
                timeout?.cancel()
                timeout = nil
            }
        }
        // The server closed the WebSocket without a goodbye.
        if !closing { throw WebSocketConnection.Failure.closed }
    }

    /// The PSK named in Noise message 1. A miss in the first handshake falls back to the
    /// Sentinel PSK, and the server learns we lost the credential; in a re-handshake it fails.
    private func choosePSK(_ payload: Data, rehandshake: Bool) async throws -> (Data, PSKCategory) {
        guard let named = try? JSONDecoder().decode(NoiseMessage1Received.self, from: payload),
              let category = PSKCategory(rawValue: named.pskCategory)
        else { throw SessionError.handshake("malformed Noise message 1 payload") }
        let credentials = await client.credentials
        switch category {
        case .longTerm:
            if let record = credentials.record(pskID: named.pskID) {
                // The record must be this server's: anything else is a misbinding.
                guard record.serverID == state.serverID else { throw SessionError.handshake("PSK of another server") }
                return (record.psk, .longTerm)
            }
        case .pairing:
            if named.pskID == SendspinPSK.id(for: credentials.pairingPSK) { return (credentials.pairingPSK, .pairing) }
        case .sentinel:
            if named.pskID == SendspinPSK.id(for: SendspinPSK.sentinel) { return (SendspinPSK.sentinel, .sentinel) }
        }
        guard !rehandshake else { throw SessionError.handshake("unknown PSK in a re-handshake") }
        Log.info("Source: server's credential unknown here; continuing unpaired")
        return (SendspinPSK.sentinel, .sentinel)
    }

    /// The server whose pairing record this connection uses, while it uses one.
    var pairedServerID: String? { matched == .longTerm ? state.serverID : nil }

    private func handshakeCompleted(_ category: PSKCategory) {
        matched = category
        pairingIndex = 0
        state.paired = category == .longTerm
        if category == .longTerm, let serverID = state.serverID {
            Task { await client.touchPairing(serverID: serverID) }
        }
    }

    private func closeAfterTimeout() -> Task<Void, Never>? {
        let socket = socket
        return Task {
            try? await Task.sleep(for: .seconds(30))
            if !Task.isCancelled { socket.close() }
        }
    }

    // MARK: Inbound

    /// Handle one JSON message; true when the session is over.
    private func handle(_ data: Data, receivedAtUs: Int64) async throws -> Bool {
        let type = try MessageCoding.type(of: data)
        switch type {
        case "server/hello":
            let hello = try MessageCoding.payload(ServerHelloReceived.self, from: data)
            state.serverName = hello.name
            serverCodecs = hello.sourceSupport?.supportedCodecs ?? []
            sendMessage("client/hello", ClientHelloMessage(
                name: name, deviceInfo: DeviceInfoMessage(productName: "Mac", manufacturer: "Apple",
                                                          softwareVersion: softwareVersion)))
        case "server/activate":
            return try await handleActivate(MessageCoding.payload(ServerActivateReceived.self, from: data))
        case "noise/handshake":
            try await rehandshake(MessageCoding.payload(NoiseHandshakeMessage.self, from: data))
        case _ where !activated:
            Log.debug("Source: ignoring \(type) before activation")
        case "server/time":
            timeReply?.resume(returning: (try MessageCoding.payload(ServerTimeReceived.self, from: data), receivedAtUs))
            timeReply = nil
        case "server/command":
            if let command = try MessageCoding.payload(ServerCommandReceived.self, from: data).source?.command {
                handleSourceCommand(command)
            }
        case "server/pair-init":
            try await beginCodeRound(MessageCoding.payload(ServerPairInitReceived.self, from: data))
        case "server/pair-auth":
            try answerCodeAuth(MessageCoding.payload(ServerPairAuthReceived.self, from: data))
        case "server/pair-confirm":
            try await confirmCode(MessageCoding.payload(ServerPairConfirmReceived.self, from: data))
        case "server/pair-finalize":
            if let psk = pendingPSK, let serverID = state.serverID {
                // The server persisted its record: now ours. It re-handshakes to the new key next.
                await endPairingAttempt()
                await client.storePairing(serverID: serverID, psk: psk)
                Log.info("Source: paired with \(state.serverName ?? serverID)")
            }
        case "pair/abort":
            let reason = (try? MessageCoding.payload(PairAbortMessage.self, from: data).reason) ?? "?"
            Log.info("Source: pairing aborted by the server (\(reason))")
            await endPairingAttempt()
        case "server/unpair":
            guard matched == .longTerm, let serverID = state.serverID else { break }
            await client.removePairing(serverID: serverID)
            Log.info("Source: \(state.serverName ?? serverID) unpaired")
            sendMessage("client/goodbye", ClientGoodbyeMessage(reason: "unpaired"))
            return true
        default:
            break  // group/update, server/state and anything newer: nothing for a source.
        }
        return false
    }

    /// Validate and apply server/activate (messaging.md, server/activate).
    private func handleActivate(_ activate: ServerActivateReceived) async throws -> Bool {
        let activities = Set(activate.activities)
        let unpaired = matched != .longTerm

        func allowed(_ activities: Set<String>, unpairedAccess: Bool) -> Bool {
            switch matched {
            case .longTerm: return activities.isSubset(of: ["playback"])
            case .pairing, .sentinel:
                return activities.isSubset(of: ["pairing"]) || (unpairedAccess && activities.isSubset(of: ["playback", "pairing"]))
            }
        }
        // Roles carry over when omitted, but not onto a connection that can no longer play, as
        // after a re-handshake to the pairing PSK: then they count as empty, and the activation
        // isn't refused for them (messaging.md, server/activate).
        let capable = allowed(activities.union(["playback"]), unpairedAccess: false)
        let roles = activate.activeRoles ?? (activated && capable ? activeRoles : [])
        func admissible(unpairedAccess: Bool) -> Bool {
            guard allowed(activities, unpairedAccess: unpairedAccess) else { return false }
            let capable = allowed(activities.union(["playback"]), unpairedAccess: unpairedAccess)
            return capable || roles.isEmpty
        }
        // We never admit unpaired access: a source sends the Mac's audio, so only paired servers get it.
        if unpaired && !admissible(unpairedAccess: false) && admissible(unpairedAccess: true) {
            Log.info("Source: \(state.serverName ?? "server") wants unpaired playback; pairing is required")
            sendMessage("client/goodbye", ClientGoodbyeMessage(reason: "pairing_required"))
            return true
        }
        guard admissible(unpairedAccess: false) else {
            sendMessage("client/goodbye", ClientGoodbyeMessage(reason: "unauthorized"))
            return true
        }
        // A pairing method we don't offer under this PSK makes the activation inadmissible too:
        // it's answered, the connection stays open, and admission isn't applied to it
        // (messaging.md, server/activate; connection.md, Multiple servers).
        let method: PairingMethod?
        switch (activate.pairing?.method, matched) {
        case ("pairing_psk", .pairing): method = .token
        case ("dynamic_pairing_code", .sentinel) where activate.pairing?.format == "digits": method = .code
        default: method = nil
        }
        if activities.contains("pairing"), method == nil {
            sendMessage("pair/abort", PairAbortMessage(reason: "method_not_supported"))
            return false
        }

        let first = !activated
        if first {
            guard await client.admit(self, activities: activities) else {
                if activities.contains("pairing") {
                    sendMessage("pair/abort", PairAbortMessage(reason: "concurrent_attempt"))
                } else {
                    sendMessage("client/goodbye", ClientGoodbyeMessage(reason: "concurrent_attempt"))
                }
                return true
            }
        }
        activated = true
        rehandshaking = false
        state.activities = activate.activities

        // Roles: only `source@v1` is ours; anything else listed is ignored.
        let wasActive = state.sourceActive
        activeRoles = roles
        state.sourceActive = roles.contains("source@v1")
        if wasActive && !state.sourceActive { endStream(reason: "source role removed") }
        if !state.sourceActive { lastSentState = nil }
        if state.sourceActive && !wasActive { sendState(force: true) }
        if activities.contains("playback"), let serverID = state.serverID {
            await client.recordPlayback(serverID: serverID)
        }
        if timeSync == nil { startTimeSync() }

        // Pairing: the token on a pairing-PSK connection, a code on an unpaired one.
        if activities.contains("pairing") {
            pairingIndex += 1
            await endPairingAttempt()  // each pairing activation admits one attempt of its own
            switch method {
            case .token: startPairingPSK()
            case .code: await startPairingCode()
            case nil: break  // answered above
            }
        } else if pendingPSK != nil || codeAttempt != nil {
            // Left pairing without server/pair-finalize: persist nothing.
            await endPairingAttempt()
        }
        await client.sessionChanged(self)
        return false
    }

    // MARK: Pairing

    private enum PairingMethod { case token, code }

    /// Pairing PSK flow: pair-init and pair-finalize back to back, with a new long-term PSK.
    private func startPairingPSK() {
        let psk = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        pendingPSK = psk
        sendMessage("client/pair-init", ClientPairInitMessage(pairingIndex: pairingIndex))
        sendMessage("client/pair-finalize", ClientPairFinalizeMessage(longTermPSK: Base64URL.encode(psk)))
        startPairingTimeout()
        Log.info("Source: pairing with \(state.serverName ?? "server") (token)")
    }

    /// Dynamic Pairing Code flow: commit to nonce_B; the code follows from the server's
    /// nonce_A in its first server/pair-init. Past the round limit, attempts wait until the
    /// user allows pairing again in Settings (pairing.md, Rounds).
    private func startPairingCode() async {
        if await client.codeRoundLimitReached {
            sendMessage("client/pair-pending", ClientPairPendingMessage(
                pairingIndex: pairingIndex,
                message: "Too many wrong codes. To try again, choose Allow Pairing in macOS Audio for Sendspin's Settings on the Mac."))
            return
        }
        let attempt = CodeAttempt(pairingIndex: pairingIndex)
        codeAttempt = attempt
        sendMessage("client/pair-init", ClientPairInitMessage(
            pairingIndex: pairingIndex, commitB: Base64URL.encode(DynamicPairingCode.commitment(to: attempt.nonceB))))
        startPairingTimeout()
        Log.info("Source: pairing with \(state.serverName ?? "server") (code)")
    }

    /// server/pair-init: a round begins. The first carries nonce_A, which fixes the code; each
    /// shows the code and starts a fresh CPace run on it.
    private func beginCodeRound(_ message: ServerPairInitReceived) async throws {
        guard var attempt = codeAttempt else { return }  // left over from an ended attempt
        guard attempt.awaitingRound, let h = channel?.handshakeHash else {
            throw SessionError.pairing("server/pair-init out of turn")
        }
        attempt.round += 1
        if attempt.round == 1 {
            guard let nonceA = message.nonceA.flatMap(Base64URL.decode), nonceA.count == DynamicPairingCode.nonceSize
            else { throw SessionError.pairing("bad nonce_A") }
            attempt.code = DynamicPairingCode.digits(handshakeHash: h, nonceA: nonceA, nonceB: attempt.nonceB)
        } else if message.nonceA != nil {
            throw SessionError.pairing("nonce_A after the first round")
        }
        guard let code = attempt.code else { throw SessionError.pairing("no pairing code") }
        attempt.sid = DynamicPairingCode.sessionID(handshakeHash: h, pairingIndex: attempt.pairingIndex,
                                                   round: attempt.round)
        attempt.cpace = try CPace(role: .responder, prs: Data(code.utf8), sid: attempt.sid, ad: Data("client".utf8))
        attempt.awaitingRound = false
        codeAttempt = attempt
        if state.pairingCode != code {
            state.pairingCode = code
            await client.sessionChanged(self)
        }
        Log.info("Source: showing the pairing code (round \(attempt.round))")
    }

    /// server/pair-auth: the server has the code the operator entered; answer with our share.
    private func answerCodeAuth(_ message: ServerPairAuthReceived) throws {
        guard var attempt = codeAttempt else { return }
        guard var cpace = attempt.cpace, cpace.isk == nil else { throw SessionError.pairing("server/pair-auth out of turn") }
        guard let ya = Base64URL.decode(message.pakeMsg1) else { throw SessionError.pairing("bad pake_msg_1") }
        do {
            try cpace.derive(peerShare: ya, peerAD: Data("server".utf8))
        } catch {
            throw SessionError.pairing("\(error)")
        }
        attempt.cpace = cpace
        codeAttempt = attempt
        sendMessage("client/pair-auth", ClientPairAuthMessage(pakeMsg2: Base64URL.encode(cpace.publicShare)))
    }

    /// server/pair-confirm: a tag that verifies means the operator entered our code. Then our
    /// tag, the opening of the commitment and the new long-term PSK, the last two wrapped
    /// under the CPace output; otherwise another round, up to the limit.
    private func confirmCode(_ message: ServerPairConfirmReceived) async throws {
        guard var attempt = codeAttempt else { return }
        guard let cpace = attempt.cpace, let isk = cpace.isk else { throw SessionError.pairing("server/pair-confirm out of turn") }
        guard let ta = Base64URL.decode(message.serverKC), ta.count == 64 else { throw SessionError.pairing("bad server_kc") }
        attempt.cpace = nil
        guard cpace.verify(peerTag: ta), let tb = cpace.tag() else {
            if await client.codeRoundFailed() {
                Log.info("Source: wrong pairing code, and the round limit is reached")
                sendMessage("pair/abort", PairAbortMessage(reason: "pairing_code_mismatch"))
                await endPairingAttempt()
            } else {
                Log.info("Source: wrong pairing code; asking for another round")
                attempt.awaitingRound = true
                codeAttempt = attempt
                sendMessage("client/pair-retry", EmptyPayload())
            }
            return
        }
        await client.codeRoundVerified()
        codeAttempt = attempt
        let psk = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let wrappedNonce = try DynamicPairingCode.wrap(attempt.nonceB, .nonce, sid: attempt.sid, isk: isk, suite: .chaChaPoly)
        let wrappedPSK = try DynamicPairingCode.wrap(psk, .psk, sid: attempt.sid, isk: isk, suite: .chaChaPoly)
        pendingPSK = psk
        sendMessage("client/pair-confirm", ClientPairConfirmMessage(clientKC: Base64URL.encode(tb),
                                                                    wrappedNonceB: Base64URL.encode(wrappedNonce)))
        sendMessage("client/pair-finalize", ClientPairFinalizeMessage(wrappedPSK: Base64URL.encode(wrappedPSK)))
        Log.info("Source: \(state.serverName ?? "server") entered the right code")
    }

    /// The operator cancelled on this Mac.
    func cancelPairing() async {
        guard pendingPSK != nil || codeAttempt != nil else { return }
        sendMessage("pair/abort", PairAbortMessage(reason: "user_cancelled"))
        await endPairingAttempt()
        Log.info("Source: pairing cancelled on this Mac")
    }

    /// Each attempt ends within 2 minutes of its first message (pairing.md).
    private func startPairingTimeout() {
        pairingTimeout?.cancel()
        pairingTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled else { return }
            await self?.pairingTimedOut()
        }
    }

    private func pairingTimedOut() async {
        guard pendingPSK != nil || codeAttempt != nil else { return }
        sendMessage("pair/abort", PairAbortMessage(reason: "attempt_timeout"))
        await endPairingAttempt()
    }

    private func endPairingAttempt() async {
        pendingPSK = nil
        codeAttempt = nil
        pairingTimeout?.cancel()
        pairingTimeout = nil
        if state.pairingCode != nil {
            state.pairingCode = nil
            await client.sessionChanged(self)
        }
    }

    /// The server swaps session keys in-band, e.g. to the new long-term PSK after pairing.
    /// Our message 2 still goes under the old keys; everything after under the new.
    private func rehandshake(_ message: NoiseHandshakeMessage) async throws {
        guard let serverKey, let previous = channel, let message1 = Base64URL.decode(message.data) else {
            throw SessionError.handshake("bad re-handshake")
        }
        rehandshaking = true
        var handshake = NoiseResponderHandshake(suite: .chaChaPoly, prologue: previous.handshakeHash,
                                                localStatic: identity, remoteStatic: serverKey)
        // A re-handshake keeps the suite of the session; ours is always ChaChaPoly.
        let (psk, category) = try await choosePSK(try handshake.readMessage1(message1), rehandshake: true)
        let (message2, transport) = try handshake.writeMessage2(payload: Data("{}".utf8), psk: psk)
        sendMessage("noise/handshake", NoiseHandshakeMessage(data: Base64URL.encode(message2)), duringRehandshake: true)
        channel = SecureChannel(transport: transport)
        handshakeCompleted(category)
        await client.sessionChanged(self)
        Log.debug("Source: re-handshake done (\(category.rawValue))")
    }

    // MARK: Clock

    /// Bursts of 8 exchanges, each waiting for its reply, keeping the one with the smallest
    /// error (the time-filter's recommended usage): back to back until the filter converges,
    /// since servers want the first client/state within seconds of activation, then one
    /// starting every 9 s: bursts MUST start no more than 10 s apart, however long one takes
    /// (messaging.md, Clock Synchronization). A re-handshake cuts a burst short; the filter
    /// itself carries over.
    private func startTimeSync() {
        timeSync = Task { [weak self] in
            let clock = ContinuousClock()
            while !Task.isCancelled {
                guard let self else { return }
                let started = clock.now
                await self.syncBurst()
                let next = await self.converged ? started + .seconds(9) : clock.now + .milliseconds(100)
                try? await Task.sleep(until: next, clock: clock)
            }
        }
    }

    private func syncBurst() async {
        var best: (measurement: Int64, maxError: Int64, at: Int64)?
        for _ in 0..<8 {
            guard !rehandshaking else { return }
            let t1 = ServerClock.nowMicros()
            timeExchange += 1
            let exchange = timeExchange
            sendMessage("client/time", ClientTimeMessage(clientTransmitted: t1))
            let reply = await withCheckedContinuation { continuation in
                timeReply = continuation
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    await self?.timeReplyTimedOut(exchange)
                }
            }
            guard let (time, t4) = reply, time.clientTransmitted == t1 else { continue }
            let measurement = ((time.serverReceived - t1) + (time.serverTransmitted - t4)) / 2
            let maxError = ((t4 - t1) - (time.serverTransmitted - time.serverReceived)) / 2
            if best == nil || maxError < best!.maxError { best = (measurement, maxError, t4) }
        }
        guard let best else { return }
        let wasConverged = converged
        // As measured: the filter discards a max_error of 0 or less (messaging.md, Time filter update).
        filter.update(measurement: best.measurement, maxError: best.maxError, timeAdded: best.at)
        if converged && !wasConverged {
            Log.info("Source: clock in sync with \(state.serverName ?? "server") (±\(Int(filter.error)) µs)")
            sendState(force: true)
        }
    }

    /// Only the exchange that's still waiting gives up: a late timer of an earlier one doesn't.
    private func timeReplyTimedOut(_ exchange: Int) {
        guard exchange == timeExchange else { return }
        timeReply?.resume(returning: nil)
        timeReply = nil
    }

    // MARK: Source

    /// Report availability and signal once the clock is in sync (only then may a source be
    /// available), and whenever they change.
    private func sendState(force: Bool = false) {
        guard state.sourceActive, converged, !rehandshaking else { return }
        let message = ClientStateMessage(available: available,
                                         source: .init(signal: signalPresent ? "present" : "absent"))
        guard force || message.available != lastSentState?.available
            || message.source?.signal != lastSentState?.source?.signal else { return }
        lastSentState = message
        sendMessage("client/state", message)
    }

    func setAvailable(_ available: Bool) {
        guard available != self.available else { return }
        self.available = available
        // An open stream ends before the client reports itself unavailable.
        if !available { endStream(reason: "unavailable") }
        sendState()
    }

    func setSending(_ sending: Bool) {
        self.sending = sending
    }

    private func handleSourceCommand(_ command: String) {
        switch command {
        case "start":
            // Ignored while unavailable, pending or open: it never restarts a stream.
            guard state.sourceActive, lastSentState?.available == true, !startAuthorized, !state.streaming else { return }
            startAuthorized = true
            Log.info("Source: \(state.serverName ?? "server") starts the Mac's audio")
        case "stop":
            endStream(reason: "stopped by the server")
        default:
            break
        }
    }

    private func endStream(reason: String) {
        startAuthorized = false
        guard state.streaming else { return }
        sendMessage("client-stream/end", EmptyPayload())
        state.streaming = false
        pipeline = nil
        Log.info("Source: stream ended (\(reason))")
        Task { await client.sessionChanged(self) }
    }

    /// One captured block: updates the signal, and streams it while the server asked for it.
    func deliver(_ pcm: PCMBuffer, captureTimeUs: Int64, bitDepth: Int) {
        let pcm = sending ? pcm : PCMBuffer(samples: [Float](repeating: 0, count: pcm.samples.count),
                                            sampleRate: pcm.sampleRate, channels: pcm.channels)
        if pcm.samples.contains(where: { abs($0) > 1e-4 }) { lastSoundUs = captureTimeUs }
        // Present while sound came in the last 2 s: that's what lets the server start us.
        let present = available && lastSoundUs.map { captureTimeUs - $0 < 2_000_000 } ?? false
        if present != signalPresent {
            signalPresent = present
            sendState()
        }

        guard startAuthorized || state.streaming, converged, !rehandshaking else { return }
        let codec: AudioCodec = serverCodecs.contains("flac") || serverCodecs.isEmpty ? .flac : .pcm
        let format = AudioFormatSpec(codec: codec, channels: pcm.channels, sampleRate: pcm.sampleRate,
                                     bitDepth: bitDepth)
        if pipeline?.format != format || pipeline?.accepts(pcm) == false {
            guard let pipeline = PlayerAudioPipeline(format: format, sourceRate: pcm.sampleRate,
                                                     sourceChannels: pcm.channels) else { return }
            self.pipeline = pipeline
            // client-stream/start opens the stream, or replaces its format in place.
            sendMessage("client-stream/start", ClientStreamStartMessage(source: .init(
                codec: format.codec, channels: format.channels, sampleRate: format.sampleRate,
                bitDepth: format.bitDepth, codecHeader: pipeline.codecHeader?.base64EncodedString())))
            startAuthorized = false
            if !state.streaming {
                state.streaming = true
                Task { await client.sessionChanged(self) }
            }
            Log.info("Source: streaming \(format.codec) \(format.sampleRate) Hz \(format.bitDepth)-bit "
                + "to \(state.serverName ?? "server")")
        }
        guard let chunks = pipeline?.process(pcm, timestampUs: captureTimeUs) else { return }
        for chunk in chunks {
            // After a stall, drop the backlog and carry on live rather than burst stale audio.
            if socket.backlog > 25 {
                droppedChunks += 1
                if droppedChunks == 1 || droppedChunks.isMultiple(of: 50) {
                    Log.warning("Source: send backlog, dropped \(droppedChunks) chunks")
                }
                continue
            }
            let serverTime = filter.serverTime(fromClient: chunk.timestampUs)
            send(SourceAudioChunk.messageType, SourceAudioChunk.body(timestampUs: serverTime, payload: chunk.payload))
        }
    }

    // MARK: Outbound

    /// Another server took over (`another_server`), or the app quits (`shutdown`).
    func close(goodbye reason: String) {
        closing = true
        if state.activities.contains("pairing"), reason == "another_server" {
            sendMessage("pair/abort", PairAbortMessage(reason: "concurrent_attempt"))
        } else {
            endStream(reason: reason)
            sendMessage("client/goodbye", ClientGoodbyeMessage(reason: reason))
        }
        socket.close()
    }

    private func sendMessage<P: Encodable>(_ type: String, _ payload: P, duringRehandshake: Bool = false) {
        guard duringRehandshake || !rehandshaking || type == "client/goodbye" else { return }
        do {
            send(SecureChannel.jsonType, try MessageCoding.encode(type: type, payload: payload))
        } catch {
            Log.error("encoding \(type): \(error)")
        }
    }

    private func send(_ type: UInt8, _ payload: Data) {
        guard channel != nil else { return }
        do {
            for message in try channel!.seal(type: type, payload: payload) {
                socket.send(binary: message)
            }
        } catch {
            Log.error("Source: encrypting: \(error)")
            socket.close()
        }
    }
}
