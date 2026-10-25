import CryptoKit
import Foundation
import Network

public struct PlayerStatus: Sendable, Equatable {
    public enum Connection: Sendable, Equatable {
        case connecting
        case connected
        /// Another server took the player over (goodbye `another_server`), or held it when we
        /// came with nothing to play (`concurrent_attempt`).
        case taken
        /// The player only admits paired servers, and this Mac isn't paired with it.
        case pairingRequired
        /// We're paired, but the player no longer recognizes this Mac (reset, or it dropped the
        /// record to make room): it can't play until paired again (connection.md, Sentinel
        /// Fallback).
        case notRecognized
        /// The player presents a different identity than the one approved for it.
        case notApproved
        /// A player that connected to us, held until the user allows it (ticks it).
        case awaitingApproval
        /// The player left the group: it's in use by something else (`available: false`) or
        /// sent `client/leave`. It stays connected in a stopped group of its own until the
        /// user selects it again (`rejoin()`): the spec doesn't let us take it back by ourselves.
        case left
        /// The player can't be reached: it dropped off the network, or the connection broke
        /// without a goodbye. The session keeps trying, and plays again once it's back.
        case unavailable
        case disconnected(reason: String?)
        case failed(String)
    }

    public var connection: Connection = .connecting
    public var name: String?
    /// The player's `client_id`: its Curve25519 public key, base64url.
    public var clientID: String?
    /// The connection runs on our pairing's long-term PSK.
    public var paired = false
    /// The pairing methods it offers, from its hello.
    public var pairMethods: PairMethods?
    /// A pairing the operator started on this session.
    public var pairing: PairingProgress?
    public var volume: Int?
    public var muted: Bool?
    public var canSetVolume = false
    public var canMute = false
    /// What the player needs queued: its min_buffer_ms plus output_delay_ms. The server
    /// must schedule audio at least this far ahead (player/v1.md, Server Audio Send Constraints).
    public var requiredBufferMs = 0
    /// PCM and FLAC formats the player accepts (from its hello), its preference first.
    public var supportedFormats: [AudioFormatSpec] = []
    /// Format currently streamed to the player, while streaming.
    public var streamFormat: AudioFormatSpec?

    public init() {}
}

/// One dialed player: runs the Noise handshake, answers time sync, tracks player state
/// and delivers the group's audio in the negotiated format (Sendspin 1, server-initiated).
public actor PlayerSession {
    /// Asked once per connection with the player's `client_id`: may it play? Unpaired, that's
    /// the operator's approval; paired, whether it's wanted at all.
    public typealias Approval = @Sendable (_ clientID: String, _ paired: Bool) async -> Bool

    public nonisolated let url: URL
    public nonisolated let updates: AsyncStream<PlayerStatus>

    private let identity: ServerIdentity
    private let pairings: PlayerPairings
    private let approve: Approval
    /// The player connected to us (client-initiated); otherwise we dial `url`.
    private let incoming: WebSocketConnection?
    public nonisolated let isIncoming: Bool
    private let updatesContinuation: AsyncStream<PlayerStatus>.Continuation
    private var status = PlayerStatus() {
        didSet { if status != oldValue { updatesContinuation.yield(status) } }
    }

    private var socket: WebSocketConnection?
    private var channel: SecureChannel?
    private var hello: ClientHello?
    /// server/activate made the player ours: its role active, in our group.
    private var activated = false
    /// It answered our long-term PSK on the Sentinel: it lost our pairing.
    private var notRecognized = false

    // Pairing, the server's side (pairing.md).
    /// The pairing the operator started on this session; once done it's an ordinary paired one.
    private let pairingRequest: PairingRequest?
    private var pairingFinished = false
    private var attempt: PairingAttempt?
    /// Pairing activations sent since the last Noise handshake (pairing.md, PAKE: `sid`).
    private var pairingIndex = 0
    /// A wrong static code: the next prompt says so.
    private var staticCodeWasWrong = false
    private var pairingInitTimeout: Task<Void, Never>?
    /// What the connection's handshake needs again for a re-handshake.
    private var suite: NoiseSuite = .chaChaPoly
    private var clientKey: Curve25519.KeyAgreement.PublicKey?
    /// The PSK the connection runs on now.
    private var connectionPSK = SendspinPSK.sentinel
    /// Between our Noise message 1 of a re-handshake and the client's message 2.
    private var rehandshake: (handshake: NoiseInitiatorHandshake, psk: Data, longTerm: Bool, then: AfterRehandshake)?
    /// How the connection ends when we end it ourselves, as when a pairing fails.
    private var endOfConnection: SessionEnd?
    /// The group let go of the player (`shutdown()`): its connection ends by our doing.
    private var shuttingDown = false
    /// The activities last declared: playback only while there's something to play.
    private var declaredActivities: [String] = []
    /// The user just chose the player: declare playback before the sound gets here, as for a
    /// play command, so a server holding it doesn't turn us away first.
    private var claiming: Bool
    /// Any server/activate went out, so the player may send its other messages.
    private var sentActivation = false
    private var available = false
    /// The client/state with the `player` object arrived since the role was activated: only then
    /// may its stream start and commands go out (messaging.md, stream/start).
    private var ready = false
    /// Converts group audio to the player's format; rebuilt when the source or the
    /// preferred bit depth changes.
    private var pipeline: PlayerAudioPipeline?
    private var pipelineBitDepthPreference: Int?
    private var unsupportedSourceWarned = false
    private var streaming = false
    private var droppedChunks = 0
    private var buffer = PlayerBufferAccount()
    private var outputDelayUs: Int64 = 0
    private var capacityDrops = 0
    /// The roles server/activate gives the connection.
    private var activeRoles: [String] = []

    // The visualizer role (roles/visualizer/v1.md).
    /// The client/state visualizer object since the role was activated: only then may its
    /// stream start.
    private var visualizerRequest: VisualizerConfig?
    /// The visualizer stream, while one is active.
    private var visualizer: VisualizerAnalyzer?
    private var visualizerBuffer = VisualizerBufferAccount()
    private var visualizerDrops = 0

    // The controller role (roles/controller/v1.md).
    /// The group the player was added to, which carries out its controller's commands.
    private weak var playbackGroup: PlaybackGroup?
    /// The controller state last sent.
    private var controllerState: ControllerState?

    // The artwork role (roles/artwork/v1.md): its stream, without images.
    /// The client/state artwork object since the role was activated.
    private var artworkRequest: ArtworkConfig?
    /// The channels of the active artwork stream.
    private var artworkStream: ArtworkConfig?

    private var group: (id: String, name: String)?
    private var playing = false
    /// The player left the group (see `PlayerStatus.Connection.left`).
    private var left = false
    /// The stopped group of its own a held player, or one that left, is in.
    private var soloGroupID: String?
    private var lastGroupUpdate: GroupUpdate?

    /// A player we dial and keep connected. One the user just `chosen` is claimed for playback
    /// when it connects.
    public init(url: URL, identity: ServerIdentity, pairings: PlayerPairings = PlayerPairings(),
                chosen: Bool = false, pairing: PairingRequest? = nil, approve: @escaping Approval) {
        self.url = url
        self.identity = identity
        self.pairings = pairings
        pairingRequest = pairing
        self.approve = approve
        claiming = chosen
        incoming = nil
        isIncoming = false
        (updates, updatesContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(16))
    }

    /// A player that connected to us. It's served once: we can't reconnect to it.
    public init(incoming connection: IncomingConnection, identity: ServerIdentity,
                pairings: PlayerPairings = PlayerPairings(), approve: @escaping Approval) {
        url = URL(string: "ws://\(connection.remoteDescription)") ?? URL(string: "ws://incoming")!
        self.identity = identity
        self.pairings = pairings
        pairingRequest = nil
        self.approve = approve
        incoming = connection.socket
        isIncoming = true
        claiming = false
        (updates, updatesContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(16))
    }

    public var currentStatus: PlayerStatus { status }

    // MARK: Connection lifecycle

    /// Connect and keep the player connected until cancelled or the player leaves for good.
    public func run() async {
        defer {
            socket?.close()
            updatesContinuation.finish()
        }
        if isIncoming {
            // A player that connected to us comes back by itself; we can't dial it.
            status.connection = .connecting
            do {
                if case .stop(let connection) = try await connectAndServe() {
                    status.connection = connection
                } else {
                    status.connection = .disconnected(reason: nil)
                }
            } catch where Self.isUnreachable(error) {
                Log.info("\(status.name ?? url.absoluteString): unavailable (\(error))")
                status.connection = .unavailable
            } catch {
                Log.warning("\(url): \(error)")
                status.connection = .failed(String(describing: error))
            }
            resetConnectionState()
            return
        }
        var backoff: Duration = .seconds(1)
        var busyBackoff: Duration = .seconds(5)
        while !Task.isCancelled {
            // An unavailable player stays so while we try again: no "Connecting…" each time.
            if status.connection != .unavailable { status.connection = .connecting }
            var outcome: SessionEnd
            var unreachable = false
            do {
                outcome = try await connectAndServe()
                backoff = .seconds(1)
            } catch is CancellationError {
                break
            } catch where Self.isUnreachable(error) {
                if status.connection != .unavailable {
                    Log.info("\(status.name ?? url.absoluteString): unavailable (\(error)), retrying")
                }
                status.connection = .unavailable
                unreachable = true
                outcome = .reconnect
            } catch {
                Log.warning("\(url): \(error)")
                status.connection = .failed(String(describing: error))
                outcome = .reconnect
            }
            resetConnectionState()
            if Task.isCancelled { break }
            // An attempt ends with its connection: the operator starts another one. Until one
            // started, the session keeps trying to reach the speaker.
            if pairingRequest != nil, !pairingFinished, status.pairing != nil {
                if case .failed = status.pairing {} else {
                    status.pairing = .failed("The connection to the speaker ended.")
                }
                status.connection = .pairingRequired
                return
            }

            switch outcome {
            case .reconnect:
                busyBackoff = .seconds(5)
            case .retryLater:
                // A server MAY retry later (messaging.md, client/goodbye): not every second.
                try? await Task.sleep(for: busyBackoff)
                busyBackoff = min(busyBackoff * 2, .seconds(60))
                continue
            case .stop(let connection):
                status.connection = connection
                return
            }
            // Also the backoff for repeated handshake failures, which the spec asks for. A
            // player that's off the network is tried more often, so it plays again soon after
            // it's back: a connection attempt costs nothing on the network it isn't on.
            try? await Task.sleep(for: backoff)
            backoff = min(backoff * 2, unreachable ? .seconds(5) : .seconds(30))
        }
    }

    /// The network failed, not the player: unreachable, refused, timed out, or gone silent.
    private static func isUnreachable(_ error: any Error) -> Bool {
        error is NWError || error is WebSocketConnection.Failure
    }

    private enum SessionEnd {
        case reconnect
        /// Turned away while another server pairs with it (`concurrent_attempt`).
        case retryLater
        case stop(PlayerStatus.Connection)
    }

    private func connectAndServe() async throws -> SessionEnd {
        let socket = incoming ?? WebSocketConnection(url: url)
        self.socket = socket
        defer { socket.close() }
        try await socket.open()
        Log.debug("\(url): connected")

        var frames = socket.frames.makeAsyncIterator()
        var timeout = Self.closeAfterTimeout(socket)
        defer { timeout?.cancel() }

        // client/init, then server/init and Noise message 1 back to back.
        guard case let .text(clientInitData, _)? = try await frames.next() else {
            reject(socket, reason: "malformed")
            throw SessionError.handshake("expected client/init")
        }
        let (clientInit, suite, clientKey) = try parseClientInit(clientInitData, socket: socket)
        let serverInitData = try MessageCoding.encode(type: "server/init", payload: ServerInit(serverID: identity.id))
        // A paired player gets our pairing's long-term PSK, any other the Sentinel.
        let longTerm = pairings.psk(for: clientInit.clientID)
        var attempt = NoiseInitiatorHandshake(
            suite: suite, prologue: clientInitData + serverInitData, localStatic: identity.privateKey,
            remoteStatic: clientKey, psk: longTerm ?? SendspinPSK.sentinel)
        let message1Payload = try JSONEncoder().encode(
            NoiseMessage1Payload(pskID: SendspinPSK.id(for: longTerm ?? SendspinPSK.sentinel),
                                 pskCategory: longTerm == nil ? "sn" : "lt"))
        let message1 = try attempt.writeMessage1(payload: message1Payload)
        var sentMessage1 = attempt
        socket.send(text: serverInitData)
        socket.send(text: try MessageCoding.encode(type: "noise/handshake",
                                                   payload: NoiseHandshakeMessage(data: Base64URL.encode(message1))))
        timeout?.cancel()
        timeout = Self.closeAfterTimeout(socket)

        // Noise message 2 completes the handshake. Failures from here on are silent: close.
        guard case let .text(message2Data, _)? = try await frames.next(),
              try MessageCoding.type(of: message2Data) == "noise/handshake",
              let message2 = Base64URL.decode(try MessageCoding.payload(NoiseHandshakeMessage.self,
                                                                         from: message2Data).data)
        else { throw SessionError.handshake("expected Noise message 2") }
        let payload: Data, transport: NoiseTransport
        if let result = try? attempt.readMessage2(message2) {
            (payload, transport) = result
            status.paired = longTerm != nil
        } else if longTerm != nil, let result = try? sentMessage1.readMessage2(message2, psk: SendspinPSK.sentinel) {
            // It answered on the Sentinel: it lost our pairing. Authenticated, but it
            // removes nothing by itself (connection.md, Sentinel Fallback).
            (payload, transport) = result
            notRecognized = true
        } else {
            throw SessionError.handshake("Noise message 2 doesn't verify")
        }
        guard (try? JSONSerialization.jsonObject(with: payload)) is [String: Any] else {
            throw SessionError.handshake("Noise message 2 payload isn't a JSON object")
        }
        channel = SecureChannel(transport: transport)
        status.clientID = clientInit.clientID
        self.suite = suite
        self.clientKey = clientKey
        connectionPSK = status.paired ? (longTerm ?? SendspinPSK.sentinel) : SendspinPSK.sentinel
        Log.debug("\(url): Noise handshake done (\(suite.rawValue))")

        sendMessage("server/hello", ServerHello(name: identity.name))
        timeout?.cancel()
        timeout = Self.closeAfterTimeout(socket)

        while let frame = try await frames.next() {
            // After the handshake, a cleartext message is a silent failure.
            guard case let .binary(ciphertext, receivedAtUs) = frame,
                  let message = try channel?.open(ciphertext)
            else {
                if case .text = frame { throw SessionError.handshake("cleartext message after the handshake") }
                continue
            }
            guard message.type == SecureChannel.jsonType else { continue }
            if let end = try await handle(message.payload, receivedAtUs: receivedAtUs) {
                return end
            }
            if hello != nil {
                timeout?.cancel()
                timeout = nil
            }
        }
        if let endOfConnection { return endOfConnection }
        // A drop without client/goodbye: assume `restart` (messaging.md, client/goodbye).
        if hello != nil, !shuttingDown {
            Log.info("\(status.name ?? url.absoluteString): closed without a goodbye, reconnecting")
        }
        if status.connection == .connected { status.connection = .disconnected(reason: nil) }
        return .reconnect
    }

    /// Validate client/init; on an init failure, answer with server/error first.
    private func parseClientInit(_ data: Data, socket: WebSocketConnection)
        throws -> (ClientInit, NoiseSuite, Curve25519.KeyAgreement.PublicKey) {
        let clientInit: ClientInit, suite: NoiseSuite
        do {
            (clientInit, suite) = try ClientInit.parse(data)
        } catch {
            reject(socket, reason: error.rawValue)
            throw SessionError.handshake("client/init: \(error.rawValue)")
        }
        guard let keyData = Base64URL.decode(clientInit.clientID), keyData.count == 32,
              let key = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: keyData)
        else {
            reject(socket, reason: "malformed")
            throw SessionError.handshake("client_id isn't a Curve25519 key")
        }
        return (clientInit, suite, key)
    }

    private func reject(_ socket: WebSocketConnection, reason: String) {
        if let message = try? MessageCoding.encode(type: "server/error", payload: ServerError(reason: reason)) {
            socket.send(text: message)
        }
    }

    /// Each handshake step must arrive within 30 s (connection.md, Failure Handling).
    private static func closeAfterTimeout(_ socket: WebSocketConnection) -> Task<Void, Never>? {
        Task {
            try? await Task.sleep(for: .seconds(30))
            if !Task.isCancelled { socket.close() }
        }
    }

    private func resetConnectionState() {
        socket = nil
        channel = nil
        hello = nil
        activated = false
        notRecognized = false
        attempt = nil
        pairingIndex = 0
        pairingInitTimeout?.cancel()
        rehandshake = nil
        endOfConnection = nil
        status.paired = false
        declaredActivities = []
        // The others' group lost a member.
        controllerChanged()
        activeRoles = []
        visualizerRequest = nil
        controllerState = nil
        artworkRequest = nil
        sentActivation = false
        available = false
        ready = false
        // Its volume and mute may have changed meanwhile: they come with its first client/state
        // (player/v1.md, Volume and mute).
        status.volume = nil
        status.muted = nil
        status.canSetVolume = false
        status.canMute = false
        // A player that left stays out across reconnects: the server MUST NOT auto-rejoin it
        // (messaging.md, External Source Handling).
        lastGroupUpdate = nil
        stopStreaming()
    }

    // MARK: Inbound messages

    /// Handle one JSON message; returns how the session ends when the client leaves.
    private func handle(_ data: Data, receivedAtUs: Int64) async throws -> SessionEnd? {
        let type = try MessageCoding.type(of: data)
        // Mid re-handshake, old-key messages may still come; nothing goes out but the handshake.
        if rehandshake != nil, type != "noise/handshake", type != "client/goodbye" { return nil }
        switch type {
        case "client/goodbye":
            return goodbye(try MessageCoding.payload(ClientGoodbye.self, from: data).reason)
        case "client/hello" where hello == nil:
            return try await handleHello(MessageCoding.payload(ClientHello.self, from: data))
        case _ where !sentActivation:
            // Before server/activate the client may send nothing but goodbye.
            Log.debug("\(status.name ?? "?"): ignoring \(type) before activation")
        case "client/time":
            let time = try MessageCoding.payload(ClientTime.self, from: data)
            sendMessage("server/time", ServerTime(clientTransmitted: time.clientTransmitted,
                                                  serverReceived: receivedAtUs,
                                                  serverTransmitted: ServerClock.nowMicros()))
        case "client/state":
            if let end = handleState(try MessageCoding.payload(ClientState.self, from: data)) { return end }
        case "client/command":
            handleCommand(try MessageCoding.payload(ClientCommand.self, from: data))
        case "client/leave":
            leaveGroup("left the group")
        case "noise/handshake":
            try await finishRehandshake(MessageCoding.payload(NoiseHandshakeMessage.self, from: data))
        case "client/pair-pending":
            try handlePairPending(MessageCoding.payload(ClientPairPendingMessage.self, from: data))
        case "client/pair-init":
            try handlePairInit(MessageCoding.payload(ClientPairInitMessage.self, from: data))
        case "client/pair-auth":
            try handlePairAuth(MessageCoding.payload(ClientPairAuthMessage.self, from: data))
        case "client/pair-retry":
            try handlePairRetry()
        case "client/pair-confirm":
            try handlePairConfirm(MessageCoding.payload(ClientPairConfirmMessage.self, from: data))
        case "client/pair-finalize":
            try await handlePairFinalize(MessageCoding.payload(ClientPairFinalizeMessage.self, from: data))
        case "pair/abort":
            handlePairAbort(try MessageCoding.payload(PairAbortMessage.self, from: data).reason)
        default:
            Log.debug("\(status.name ?? "?"): ignoring \(type)")
        }
        return nil
    }

    private func goodbye(_ reason: String) -> SessionEnd {
        let name = status.name ?? url.absoluteString
        switch reason {
        case "restart":
            Log.info("\(name): goodbye (\(reason)), reconnecting")
            return .reconnect
        case "concurrent_attempt" where declaredActivities.contains("playback"):
            // Playback ranks highest, so only a pairing attempt keeps us out: it ends soon.
            Log.info("\(name): pairing with another server, trying again later")
            return .retryLater
        case "concurrent_attempt":
            Log.info("\(name): in use by another server")
            return .stop(.taken)
        case "another_server":
            Log.info("\(name): taken over by another server")
            return .stop(.taken)
        case "pairing_required":
            Log.info("\(name): requires pairing")
            return .stop(.pairingRequired)
        default:
            Log.info("\(name): left (\(reason))")
            return .stop(.disconnected(reason: reason))
        }
    }

    private func handleHello(_ hello: ClientHello) async -> SessionEnd? {
        self.hello = hello
        status.name = hello.name
        status.supportedFormats = (hello.playerSupport?.supportedFormats ?? [])
            .filter { $0.codec == AudioCodec.pcm.rawValue || $0.codec == AudioCodec.flac.rawValue }
        Log.info("\(hello.name): hello (\(hello.deviceInfo?.productName ?? "unknown device"), "
            + "software \(hello.deviceInfo?.softwareVersion ?? "?"))")

        status.pairMethods = hello.supportedPairMethods
        // A role we don't know may be a newer version than ours (overview.md, Detecting
        // Outdated Servers).
        let unknown = hello.supportedRoles.filter { !$0.hasPrefix("_") && !Self.implementedRoles.contains($0) }
        if !unknown.isEmpty {
            Log.info("\(hello.name): offers roles this server doesn't implement: \(unknown.joined(separator: ", "))")
        }

        guard hello.supportedRoles.contains("player@v1"), hello.playerSupport != nil else {
            sendMessage("server/activate", ServerActivate(activities: [], activeRoles: []))
            return .stop(.failed("not a player"))
        }
        if let pairingRequest, !pairingFinished {
            return startPairing(pairingRequest)
        }
        // While our record exists, a player on the Sentinel MUST NOT play: pairing again fixes it.
        if notRecognized {
            Log.info("\(hello.name): doesn't recognize this Mac any more; it needs pairing again")
            return .stop(.notRecognized)
        }
        if status.paired {
            guard let clientID = status.clientID, await approve(clientID, true) else {
                if isIncoming { return holdIncoming() }
                return .stop(.disconnected(reason: nil))
            }
            activatePlayback()
            return nil
        }
        // There's no pairing record, so this is an unpaired session on the Sentinel PSK:
        // the player must admit unpaired access and the user must have approved it.
        guard hello.unpairedAccess?.enabled == true else {
            Log.info("\(hello.name): doesn't admit unpaired access; it needs pairing")
            return .stop(.pairingRequired)
        }
        guard let clientID = status.clientID, await approve(clientID, false) else {
            if isIncoming { return holdIncoming() }
            Log.warning("\(hello.name): identity \(status.clientID ?? "?") isn't the approved one")
            return .stop(.notApproved)
        }
        activatePlayback()
        return nil
    }

    /// Hold a player that connected to us with no activities, as the spec allows, until the
    /// user allows it.
    private func holdIncoming() -> SessionEnd? {
        sendMessage("server/activate", ServerActivate(activities: [], activeRoles: []))
        sentActivation = true
        sendGroupUpdate()
        status.connection = .awaitingApproval
        return nil
    }

    static let implementedRoles = ["player@v1", "controller@v1", "metadata@v1", "artwork@v1", "visualizer@v1", "color@v1"]

    /// The roles we activate: every one the client lists that we implement, each with the
    /// support object it requires (messaging.md, client/hello). All are v1, so there's no
    /// version to choose (overview.md, Priority and Activation).
    private static func roles(for hello: ClientHello) -> [String] {
        var roles = ["player@v1"]
        for role in ["controller@v1", "metadata@v1", "artwork@v1", "color@v1"] where hello.supportedRoles.contains(role) {
            roles.append(role)
        }
        if hello.supportedRoles.contains("visualizer@v1"), hello.visualizerSupport != nil { roles.append("visualizer@v1") }
        return roles
    }

    private func activatePlayback() {
        activated = true
        activeRoles = hello.map(Self.roles) ?? ["player@v1"]
        // A held player may have sent client/state already, but not for the roles it gets now.
        ready = false
        visualizerRequest = nil
        controllerState = nil
        artworkRequest = nil
        declareActivities(force: true)
        if claiming {
            // Sound normally follows within a moment; without it, the claim lapses.
            Task {
                try? await Task.sleep(for: .seconds(5))
                endClaim()
            }
        }
        sentActivation = true
        sendGroupUpdate()
        status.connection = left ? .left : .connected
        // Each role with a server/state object gets its state at once (messaging.md, server/state):
        // metadata and color here, the controller from the group.
        let now = ServerClock.nowMicros()
        let metadata = activeRoles.contains("metadata@v1") ? TimestampOnlyState(timestamp: now) : nil
        let color = activeRoles.contains("color@v1") ? TimestampOnlyState(timestamp: now) : nil
        if metadata != nil || color != nil { sendMessage("server/state", ServerState(metadata: metadata, color: color)) }
        controllerChanged()
    }

    /// Declare playback only while there's something to play, as the spec asks: a server that
    /// keeps an unused activity wins players it doesn't need (messaging.md, server/activate).
    /// The player role stays active, so the stream starts at once when sound comes.
    private func declareActivities(force: Bool = false) {
        guard activated else { return }
        let activities = (playing || claiming) && !left ? ["playback"] : []
        guard force || activities != declaredActivities else { return }
        declaredActivities = activities
        sendMessage("server/activate", ServerActivate(activities: activities, activeRoles: activeRoles))
    }

    /// The user allowed a held player (ticked it): activate playback on the same connection.
    public func reevaluateApproval() async {
        guard status.connection == .awaitingApproval, let clientID = status.clientID, await approve(clientID, status.paired)
        else { return }
        Log.info("\(status.name ?? "?"): allowed")
        activatePlayback()
    }

    /// The user selected a player that left: back into the group, if it's available again.
    /// Its stream restarts with the next chunk.
    public func rejoin() {
        guard left else { return }
        guard available else {
            Log.info("\(status.name ?? "?"): still in use elsewhere")
            return
        }
        Log.info("\(status.name ?? "?"): back in the group")
        left = false
        soloGroupID = nil
        declareActivities()
        sendGroupUpdate()
        status.connection = .connected
        controllerChanged()
    }

    /// The player stops taking part, being in use by something else or having sent
    /// `client/leave`: move it to a stopped group of its own and end its stream. It stays
    /// there, even once available again, until the user selects it (messaging.md,
    /// External Source Handling).
    private func leaveGroup(_ reason: String) {
        guard activated, !left else { return }
        Log.info("\(status.name ?? "?"): \(reason); out of the group until it's selected again")
        left = true
        soloGroupID = UUID().uuidString
        sendGroupUpdate()
        endStreams()
        declareActivities()
        status.connection = .left
        controllerChanged()
    }

    private func handleState(_ state: ClientState) -> SessionEnd? {
        // Objects for roles that aren't active are ignored (messaging.md, server/activate).
        if let request = state.visualizer, activated, activeRoles.contains("visualizer@v1") {
            guard !request.isMalformed else {
                Log.warning("\(status.name ?? "?"): asks for a spectrum without its configuration")
                return .stop(.failed("protocol error"))
            }
            visualizerRequest = request
            // A change to an active stream restarts it in place; without one it waits for the next.
            // Never to a client that says it's unavailable (messaging.md, stream/start).
            if let current = visualizer, state.available, request.negotiated() != current.config {
                startVisualizer(request.negotiated(), sampleRate: current.sampleRate, channels: current.channels,
                                after: current.lastUs)
            }
        }
        if let request = state.artwork, activated, activeRoles.contains("artwork@v1") {
            guard !request.isMalformed else {
                Log.warning("\(status.name ?? "?"): asks for more than four artwork channels, or one without its format")
                return .stop(.failed("protocol error"))
            }
            artworkRequest = request
            if let current = artworkStream, state.available, request.streamed != current { startArtwork(request.streamed) }
        }
        let wasAvailable = available
        available = state.available
        if let player = state.player {
            if let volume = player.volume { status.volume = volume }
            if let muted = player.muted { status.muted = muted }
            let commands = player.supportedCommands ?? []
            status.canSetVolume = commands.contains("volume")
            status.canMute = commands.contains("mute")
            status.requiredBufferMs = (player.minBufferMs ?? 0) + (player.outputDelayMs ?? 0)
            outputDelayUs = Int64(player.outputDelayMs ?? 0) * 1_000
            if activated { ready = true }
            controllerChanged()
        }
        // Only a change counts: a player says `available: false` until its clock is in sync
        // (messaging.md, Clock Synchronization), so its first state often does.
        if wasAvailable && !available {
            leaveGroup("in use elsewhere")
        }
        return nil
    }

    // MARK: Outbound

    private func sendMessage<P: Encodable>(_ type: String, _ payload: P) {
        // After our Noise message 1, only the handshake until the new keys are in place.
        guard rehandshake == nil || type == "noise/handshake" else { return }
        do {
            send(SecureChannel.jsonType, try MessageCoding.encode(type: type, payload: payload))
        } catch {
            Log.error("encoding \(type): \(error)")
        }
    }

    /// Encrypt and send in one step: Noise nonces must follow the send order.
    private func send(_ type: UInt8, _ payload: Data) {
        guard let socket, channel != nil else { return }
        do {
            for message in try channel!.seal(type: type, payload: payload) {
                socket.send(binary: message)
            }
        } catch {
            Log.error("\(status.name ?? "?"): encrypting: \(error)")
            socket.close()
        }
    }

    /// Send the player its group when it changed: ours while it plays with us, and a
    /// stopped group of its own while it's held or has left. Every connection gets one
    /// after its first server/activate (messaging.md, group/update).
    private func sendGroupUpdate() {
        guard sentActivation else { return }
        let update: GroupUpdate
        if activated && !left {
            guard let group else { return }
            update = GroupUpdate(playbackState: playing ? "playing" : "stopped", groupID: group.id, groupName: group.name)
        } else {
            if soloGroupID == nil { soloGroupID = UUID().uuidString }
            update = GroupUpdate(playbackState: "stopped", groupID: soloGroupID!, groupName: status.name ?? "")
        }
        guard update != lastGroupUpdate else { return }
        lastGroupUpdate = update
        sendMessage("group/update", update)
    }

    // MARK: Group interface

    func join(groupID: String, groupName: String, group playbackGroup: PlaybackGroup? = nil) {
        group = (groupID, groupName)
        self.playbackGroup = playbackGroup
        sendGroupUpdate()
    }

    // MARK: Controller role (roles/controller/v1.md)

    func controllerMember() -> ControllerMember {
        ControllerMember(inGroup: activated && !left && ready, volume: status.volume, muted: status.muted,
                         canSetVolume: ready && status.canSetVolume, canMute: ready && status.canMute)
    }

    /// Send the controller its group's state, when it changed.
    func updateController(_ state: ControllerState) {
        guard activated, activeRoles.contains("controller@v1"), rehandshake == nil, state != controllerState else { return }
        controllerState = state
        sendMessage("server/state", ServerState(controller: state))
    }

    /// Something the group's controller state depends on changed.
    private func controllerChanged() {
        let group = playbackGroup
        Task { await group?.membersChanged() }
    }

    private func handleCommand(_ command: ClientCommand) {
        // Only for an active role, and only what we offer (Controller messages).
        guard let controller = command.controller, activated, activeRoles.contains("controller@v1"),
              controllerState?.supportedCommands.contains(controller.command) == true
        else { return }
        Log.info("\(status.name ?? "?"): controller \(controller.command)"
            + (controller.volume.map { " \($0)" } ?? "") + (controller.mute.map { " \($0)" } ?? ""))
        if controller.command == "switch" {
            // Our group and a stopped one of its own are the whole cycle; from its own, it goes
            // back to the group it left (Switch command cycle).
            if left { rejoin() } else { leaveGroup("switched to a group of its own") }
            return
        }
        let group = playbackGroup
        Task { await group?.command(controller, from: self) }
    }

    func setPlaying(_ playing: Bool) {
        guard playing != self.playing else { return }
        self.playing = playing
        if playing { declareActivities() }
        sendGroupUpdate()
        if playing {
            claiming = false
        } else {
            endStreams()
            // Not at once: a lead change stops and restarts the group in one go.
            Task {
                try? await Task.sleep(for: .seconds(1))
                if !self.playing { self.declareActivities() }
            }
        }
    }

    private func endClaim() {
        guard claiming else { return }
        claiming = false
        declareActivities()
    }

    /// stream/end for every stream that's active.
    private func endStreams() {
        let roles = (streaming ? ["player"] : []) + (artworkStream != nil ? ["artwork"] : [])
            + (visualizer != nil ? ["visualizer"] : [])
        if !roles.isEmpty { sendMessage("stream/end", StreamEnd(roles: roles)) }
        stopStreaming()
    }

    private func stopStreaming() {
        streaming = false
        pipeline = nil
        status.streamFormat = nil
        // stream/end empties the player's and the visualizer's buffer accounting.
        buffer = PlayerBufferAccount()
        visualizer = nil
        visualizerBuffer = VisualizerBufferAccount()
        artworkStream = nil
    }

    /// Send one block of group audio, and its visualization; `timestampUs` is its play time
    /// on the server clock.
    func deliver(_ pcm: PCMBuffer, timestampUs: Int64, preferredBitDepth: Int, leadUs: Int64) {
        guard activated, !left, available, rehandshake == nil else { return }
        deliverAudio(pcm, timestampUs: timestampUs, preferredBitDepth: preferredBitDepth, leadUs: leadUs)
        visualize(pcm, timestampUs: timestampUs)
        if artworkStream == nil, let request = artworkRequest { startArtwork(request.streamed) }
    }

    /// The player gets the format closest to the source (see `FormatChoice`).
    private func deliverAudio(_ pcm: PCMBuffer, timestampUs: Int64, preferredBitDepth: Int, leadUs: Int64) {
        guard let socket, ready else { return }
        // A lead too short for this player's buffer: wait for the group's lead to be raised,
        // which restarts the stream, rather than start it short (player/v1.md, Server Audio
        // Send Constraints).
        guard streaming || leadUs >= Int64(status.requiredBufferMs + PlaybackGroup.sendMarginMs) * 1_000 else { return }
        if pipeline == nil || !pipeline!.accepts(pcm) || pipelineBitDepthPreference != preferredBitDepth {
            guard startPipeline(for: pcm, timestampUs: timestampUs, preferredBitDepth: preferredBitDepth) else { return }
        }

        // A stalled player must not buffer unbounded audio in the network stack.
        if socket.backlog > 100 {
            droppedChunks += 1
            if droppedChunks.isMultiple(of: 50) {
                Log.warning("\(status.name ?? "?"): send backlog, dropped \(droppedChunks) chunks")
            }
            return
        }
        guard let chunks = pipeline?.process(pcm, timestampUs: timestampUs), !chunks.isEmpty,
              let rate = pipeline.map({ Int64($0.format.sampleRate) })
        else { return }
        for chunk in chunks {
            guard fitsBuffer(AudioFrame.headerSize + chunk.payload.count, playAtUs: chunk.timestampUs,
                             durationUs: Int64(chunk.frames) * 1_000_000 / rate)
            else { continue }
            // send_ahead is taken as late as possible: right before encrypting.
            let frame = AudioFrame.pack(timestampUs: chunk.timestampUs,
                                        sendAheadUs: chunk.timestampUs - ServerClock.nowMicros(), payload: chunk.payload)
            send(frame[frame.startIndex], Data(frame.dropFirst()))
        }
    }

    /// The player's buffer_capacity is a hard limit: a chunk is only sent if it fits next
    /// to the chunks whose playback hasn't ended yet. Format choice keeps this rare.
    private func fitsBuffer(_ bytes: Int, playAtUs: Int64, durationUs: Int64) -> Bool {
        let capacity = hello?.playerSupport?.bufferCapacity ?? .max
        guard buffer.admit(bytes: bytes, endUs: playAtUs + durationUs, nowUs: ServerClock.nowMicros(),
                           outputDelayUs: outputDelayUs, capacity: capacity)
        else {
            capacityDrops += 1
            if capacityDrops == 1 || capacityDrops.isMultiple(of: 50) {
                Log.warning("\(status.name ?? "?"): buffer_capacity \(capacity) bytes full, dropped \(capacityDrops) chunks")
            }
            return false
        }
        return true
    }

    /// Choose the stream format for this source and (re)start the stream in it.
    private func startPipeline(for pcm: PCMBuffer, timestampUs: Int64, preferredBitDepth: Int) -> Bool {
        // How far ahead audio goes, so the format fits the player's buffer_capacity.
        let bufferMs = Int(max(0, timestampUs - ServerClock.nowMicros() - outputDelayUs) / 1_000)
        guard let format = FormatChoice.best(from: status.supportedFormats, sourceRate: pcm.sampleRate,
                                             sourceChannels: pcm.channels, preferredBitDepth: preferredBitDepth,
                                             bufferCapacity: hello?.playerSupport?.bufferCapacity, bufferMs: bufferMs),
              let pipeline = PlayerAudioPipeline(format: format, sourceRate: pcm.sampleRate,
                                                 sourceChannels: pcm.channels)
        else {
            if !unsupportedSourceWarned {
                unsupportedSourceWarned = true
                Log.error("\(status.name ?? "?"): no usable PCM or FLAC format for \(pcm.sampleRate) Hz audio")
            }
            return false
        }
        unsupportedSourceWarned = false
        let changed = format != self.pipeline?.format
        self.pipeline = pipeline
        pipelineBitDepthPreference = preferredBitDepth
        if !streaming || changed {
            // stream/start again on a format change: the player reconfigures its decoder.
            sendMessage("stream/start", StreamStart(
                serverTransmitted: ServerClock.nowMicros(),
                player: StreamStartPlayer(codec: format.codec, sampleRate: format.sampleRate,
                                          channels: format.channels, bitDepth: format.bitDepth,
                                          // Standard base64 with padding (player/v1.md).
                                          codecHeader: pipeline.codecHeader?.base64EncodedString())))
            streaming = true
            status.streamFormat = format
            let conversion = format.sampleRate == pcm.sampleRate ? "" : " (resampled from \(pcm.sampleRate) Hz)"
            Log.info("\(status.name ?? "?"): streaming \(format.codec) \(format.sampleRate) Hz "
                + "\(format.bitDepth)-bit \(format.channels) ch\(conversion)")
        }
        return true
    }

    /// The block's visualizer frames, in a stream started once the client said what it wants.
    private func visualize(_ pcm: PCMBuffer, timestampUs: Int64) {
        guard let request = visualizerRequest, let socket else { return }
        if visualizer == nil {
            startVisualizer(request.negotiated(), sampleRate: pcm.sampleRate, channels: pcm.channels, after: nil)
        } else if let current = visualizer, current.sampleRate != pcm.sampleRate || current.channels != pcm.channels {
            // The source changed: the same stream, analysed afresh.
            visualizer = VisualizerAnalyzer(config: current.config, sampleRate: pcm.sampleRate,
                                            channels: pcm.channels, after: current.lastUs)
        }
        guard socket.backlog <= 100, let frames = visualizer?.process(pcm, timestampUs: timestampUs) else { return }
        let capacity = hello?.visualizerSupport?.bufferCapacity ?? .max
        for frame in frames {
            guard visualizerBuffer.admit(bytes: frame.message.count, timestampUs: frame.timestampUs,
                                         nowUs: ServerClock.nowMicros(), capacity: capacity)
            else {
                visualizerDrops += 1
                if visualizerDrops == 1 || visualizerDrops.isMultiple(of: 100) {
                    Log.warning("\(status.name ?? "?"): visualizer buffer_capacity \(capacity) bytes full, "
                        + "dropped \(visualizerDrops) frames")
                }
                continue
            }
            send(frame.message[frame.message.startIndex], Data(frame.message.dropFirst()))
        }
    }

    /// stream/start for the visualizer, new or with a new configuration.
    private func startVisualizer(_ config: VisualizerConfig, sampleRate: Int, channels: Int, after lastUs: Int64?) {
        sendMessage("stream/start", StreamStart(serverTransmitted: ServerClock.nowMicros(), visualizer: config))
        visualizer = VisualizerAnalyzer(config: config, sampleRate: sampleRate, channels: channels, after: lastUs)
        Log.info("\(status.name ?? "?"): visualizing \(config.types.isEmpty ? "nothing" : config.types.joined(separator: ", ")) "
            + "at \(config.rateMax) fps")
    }

    /// stream/start for artwork, new or with new channels. There are no images to send; a
    /// channel turned off is cleared first, as the spec asks, though it never showed one.
    private func startArtwork(_ config: ArtworkConfig) {
        for (index, channel) in (artworkStream?.channels ?? []).enumerated() where channel.source != "none"
            && (index >= config.channels.count || config.channels[index].source == "none") {
            // An empty image: an announce of total_size 0 with a present timestamp.
            var clear = Data([0x02])
            withUnsafeBytes(of: ServerClock.nowMicros().bigEndian) { clear.append(contentsOf: $0) }
            clear.append(contentsOf: [0, 0, 0, 0])
            send(UInt8(8 + index), clear)
        }
        sendMessage("stream/start", StreamStart(serverTransmitted: ServerClock.nowMicros(), artwork: config))
        artworkStream = config
    }

    // MARK: Player control

    /// Only sent when the player offers the command, and after its first client/state.
    public func setVolume(_ volume: Int) {
        guard ready, status.canSetVolume else { return }
        sendMessage("server/command", ServerCommand(player: .volume(max(0, min(100, volume)))))
    }

    public func setMuted(_ muted: Bool) {
        guard ready, status.canMute else { return }
        sendMessage("server/command", ServerCommand(player: .mute(muted)))
    }

    /// End the stream and close the connection.
    func shutdown() {
        shuttingDown = true
        setPlaying(false)
        socket?.close()
    }
}

/// The audio a player may still hold (player/v1.md, Player Buffer Accounting): each chunk
/// counts from when it's sent until its completion time, its end minus the player's output
/// delay. Chunks stay listed until they've ended outright, so a lower output delay counts
/// them again.
struct PlayerBufferAccount {
    /// Wire size, and when playback ends on the server clock, in send order.
    private var chunks: [(endUs: Int64, bytes: Int)] = []

    /// Count a chunk in if it fits within `capacity` next to the counted ones.
    mutating func admit(bytes: Int, endUs: Int64, nowUs: Int64, outputDelayUs: Int64, capacity: Int) -> Bool {
        // A chunk that has ended can't count again: the output delay is never negative.
        while let first = chunks.first, first.endUs <= nowUs { chunks.removeFirst() }
        let counted = chunks.reduce(0) { $1.endUs - outputDelayUs > nowUs ? $0 + $1.bytes : $0 }
        guard counted + bytes <= capacity else { return false }
        chunks.append((endUs, bytes))
        return true
    }
}

// MARK: - Pairing, the server's side (pairing.md)

/// One pairing attempt: from the pairing server/activate until success or pair/abort.
private struct PairingAttempt {
    let method: PairingMethod
    let index: Int
    /// client/pair-init arrived.
    var started = false
    /// Dynamic code: the client's commitment, and our nonce from the first round.
    var commitB: Data?
    var nonceA: Data?
    var round = 0
    /// This round's code, CPace run and session id, once the operator entered it.
    var code: String?
    var cpace: CPace?
    var sid: Data?
    /// CPace derived the key from the client's share.
    var derived = false
    /// client/pair-confirm checked out: client/pair-finalize may follow.
    var confirmed = false
}

private enum AfterRehandshake {
    /// To the pairing PSK, for the Pairing PSK flow.
    case pairing
    /// To the new long-term PSK, after a pairing.
    case paired
}

extension PlayerSession {
    /// The attempts, rounds and flows of pairing.md, Methods; the operator's codes come
    /// from `PairingRequest.code`.
    private func startPairing(_ request: PairingRequest) -> SessionEnd? {
        status.pairing = .starting
        // Only a method the speaker offers (pairing.md, client/hello pair-method descriptor).
        let offered = switch request.method {
        case .token: status.pairMethods?.pairingPSK != nil
        case .staticCode: status.pairMethods?.staticCode != nil
        case .dynamicCode: status.pairMethods?.dynamicCode != nil
        }
        guard offered else {
            status.pairing = .failed("The speaker doesn't offer this way of pairing.")
            return .stop(.pairingRequired)
        }
        if case .token(let token) = request.method {
            // The token must be this device's (pairing.md, Pairing PSK Flow).
            guard token.clientID == status.clientID else {
                Log.warning("\(status.name ?? "?"): the pairing token is another device's")
                status.pairing = .failed("That pairing token belongs to another device.")
                return .stop(.pairingRequired)
            }
            // The connection runs on the Sentinel or an old pairing: switch to its pairing PSK.
            // Nothing but server/activate may come first (messaging.md, Communication).
            sendMessage("server/activate", ServerActivate(activities: [], activeRoles: []))
            sentActivation = true
            beginRehandshake(to: token.pairingPSK, longTerm: false, then: .pairing)
            return nil
        }
        activatePairing()
        return nil
    }

    private var methodName: (method: String, format: String?) {
        switch pairingRequest?.method {
        case .token: ("pairing_psk", nil)
        case .staticCode: ("static_pairing_code", nil)
        case .dynamicCode, nil: ("dynamic_pairing_code", "digits")
        }
    }

    /// A pairing activation admits one attempt; it doesn't touch roles or streams.
    private func activatePairing() {
        guard let pairingRequest else { return }
        pairingIndex += 1
        attempt = PairingAttempt(method: pairingRequest.method, index: pairingIndex)
        let (method, format) = methodName
        sendMessage("server/activate", ServerActivate(activities: ["pairing"], activeRoles: [],
                                                      pairing: .init(method: method, format: format)))
        sentActivation = true
        sendGroupUpdate()
        // Our own timeout while waiting for client/pair-init (pairing.md, Entering and leaving
        // pairing), long enough for a button press or a pairing window to be opened.
        let index = pairingIndex
        pairingInitTimeout?.cancel()
        pairingInitTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(180))
            guard !Task.isCancelled else { return }
            await self?.pairingInitTimedOut(index)
        }
    }

    private func pairingInitTimedOut(_ index: Int) {
        guard let attempt, attempt.index == index, !attempt.started else { return }
        failPairing("The speaker didn't start pairing.", abort: "user_cancelled")
    }

    /// A lower index is a leftover from a superseded pairing, discarded; a higher one is an error.
    private func isCurrent(_ index: Int) throws -> Bool {
        guard index <= pairingIndex else { throw SessionError.pairing("pairing_index \(index) ahead of \(pairingIndex)") }
        return index == pairingIndex && attempt != nil
    }

    private func handlePairPending(_ message: ClientPairPendingMessage) throws {
        guard try isCurrent(message.pairingIndex) else { return }
        // From an unauthenticated peer: plain text, at most 200 bytes.
        status.pairing = .waiting(message: message.message?.truncated(toUTF8Bytes: 200))
    }

    private func handlePairInit(_ message: ClientPairInitMessage) throws {
        guard try isCurrent(message.pairingIndex), var attempt, !attempt.started else { return }
        attempt.started = true
        pairingInitTimeout?.cancel()
        switch attempt.method {
        case .token:
            status.pairing = .checking  // client/pair-finalize follows at once
        case .staticCode:
            attempt.round = 1
            self.attempt = attempt
            askForCode(.staticCode(again: staticCodeWasWrong))
            return
        case .dynamicCode:
            guard let commit = message.commitB.flatMap(Base64URL.decode), commit.count == 32 else {
                throw SessionError.pairing("client/pair-init without commit_B")
            }
            let nonceA = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            attempt.commitB = commit
            attempt.nonceA = nonceA
            attempt.round = 1
            self.attempt = attempt
            sendMessage("server/pair-init", ServerPairInitReceived(nonceA: Base64URL.encode(nonceA)))
            askForCode(.dynamicCode(again: false))
            return
        }
        self.attempt = attempt
    }

    /// The operator enters the code; the session goes on meanwhile.
    private func askForCode(_ prompt: PairingPrompt) {
        guard let pairingRequest, let attempt else { return }
        status.pairing = .enteringCode(prompt)
        let index = attempt.index, round = attempt.round
        Task { [weak self] in
            let code = await pairingRequest.code(prompt)
            await self?.codeEntered(code, prompt: prompt, index: index, round: round)
        }
    }

    private func codeEntered(_ code: String?, prompt: PairingPrompt, index: Int, round: Int) {
        guard var attempt, attempt.index == index, attempt.round == round, attempt.code == nil,
              let channel else { return }
        guard let code else {
            failPairing(nil, abort: "user_cancelled")
            return
        }
        // Separators never count (pairing.md, Pairing Code Presentation).
        let digits = code.filter(\.isASCII).filter(\.isNumber)
        guard digits.count == prompt.length else {
            askForCode(prompt)
            return
        }
        let sid = DynamicPairingCode.sessionID(handshakeHash: channel.handshakeHash, pairingIndex: index, round: round)
        do {
            let cpace = try CPace(role: .initiator, prs: Data(digits.utf8), sid: sid, ad: Data("server".utf8))
            attempt.code = digits
            attempt.sid = sid
            attempt.cpace = cpace
            self.attempt = attempt
            status.pairing = .checking
            sendMessage("server/pair-auth", ServerPairAuthReceived(pakeMsg1: Base64URL.encode(cpace.publicShare)))
        } catch {
            failPairing("Pairing failed: \(error)", abort: nil)
        }
    }

    private func handlePairAuth(_ message: ClientPairAuthMessage) throws {
        guard var attempt, var cpace = attempt.cpace, !attempt.derived else {
            throw SessionError.pairing("client/pair-auth out of sequence")
        }
        guard let share = Base64URL.decode(message.pakeMsg2) else { throw SessionError.pairing("malformed pake_msg_2") }
        try cpace.derive(peerShare: share, peerAD: Data("client".utf8))
        guard let tag = cpace.tag() else { throw SessionError.pairing("no confirmation tag") }
        attempt.cpace = cpace
        attempt.derived = true
        self.attempt = attempt
        sendMessage("server/pair-confirm", ServerPairConfirmReceived(serverKC: Base64URL.encode(tag)))
    }

    /// The client's check of our tag failed: the code was wrong. Another round, same code.
    private func handlePairRetry() throws {
        guard var attempt, case .dynamicCode = attempt.method, attempt.derived else {
            throw SessionError.pairing("client/pair-retry out of sequence")
        }
        guard attempt.round < 20 else {
            failPairing("Too many wrong codes.", abort: "pairing_code_mismatch")
            return
        }
        attempt.round += 1
        attempt.code = nil
        attempt.cpace = nil
        attempt.sid = nil
        attempt.derived = false
        self.attempt = attempt
        sendMessage("server/pair-init", ServerPairInitReceived(nonceA: nil))
        askForCode(.dynamicCode(again: true))
    }

    private func handlePairConfirm(_ message: ClientPairConfirmMessage) throws {
        guard var attempt, let cpace = attempt.cpace, attempt.derived, !attempt.confirmed,
              let sid = attempt.sid, let isk = cpace.isk else {
            throw SessionError.pairing("client/pair-confirm out of sequence")
        }
        guard let tag = Base64URL.decode(message.clientKC), cpace.verify(peerTag: tag) else {
            failPairing("That code didn't match.", abort: "pairing_code_mismatch")
            return
        }
        // The dynamic code is bound to this handshake: the client's committed nonce must
        // open, and give the code the operator entered (pairing.md, Server verification).
        if case .dynamicCode = attempt.method {
            guard let sealed = message.wrappedNonceB.flatMap(Base64URL.decode),
                  let nonceB = try? DynamicPairingCode.unwrap(sealed, .nonce, sid: sid, isk: isk, suite: suite),
                  DynamicPairingCode.commitment(to: nonceB) == attempt.commitB,
                  let channel, let nonceA = attempt.nonceA,
                  DynamicPairingCode.digits(handshakeHash: channel.handshakeHash, nonceA: nonceA, nonceB: nonceB) == attempt.code
            else { throw SessionError.pairing("the pairing code isn't bound to this handshake") }
        }
        attempt.confirmed = true
        self.attempt = attempt
    }

    private func handlePairFinalize(_ message: ClientPairFinalizeMessage) async throws {
        guard let attempt, attempt.started, let clientID = status.clientID else {
            throw SessionError.pairing("client/pair-finalize out of sequence")
        }
        let psk: Data
        switch attempt.method {
        case .token:
            guard let value = message.longTermPSK.flatMap(Base64URL.decode) else {
                throw SessionError.pairing("client/pair-finalize without long_term_psk")
            }
            psk = value
        case .staticCode, .dynamicCode:
            guard attempt.confirmed, let sid = attempt.sid, let isk = attempt.cpace?.isk,
                  let sealed = message.wrappedPSK.flatMap(Base64URL.decode),
                  let value = try? DynamicPairingCode.unwrap(sealed, .psk, sid: sid, isk: isk, suite: suite) else {
                throw SessionError.pairing("wrapped_psk doesn't open")
            }
            psk = value
        }
        guard psk.count == 32, psk != SendspinPSK.sentinel, psk != connectionPSK else {
            throw SessionError.pairing("unusable long-term PSK")
        }
        // Persisted before we say so; the client persists its record on server/pair-finalize.
        pairings.store(psk, for: clientID)
        sendMessage("server/pair-finalize", EmptyPayload())
        self.attempt = nil
        pairingFinished = true
        notRecognized = false
        status.pairing = .paired
        Log.info("\(status.name ?? clientID): paired")
        beginRehandshake(to: psk, longTerm: true, then: .paired)
    }

    private func handlePairAbort(_ reason: String) {
        guard let attempt else { return }
        if reason == "pairing_code_mismatch", case .staticCode = attempt.method {
            // The client found our tag wrong: the static code was. A new attempt, in the
            // pairing window the device keeps open.
            staticCodeWasWrong = true
            activatePairing()
            return
        }
        let text = switch reason {
        case "attempt_timeout": "The speaker stopped waiting for the code."
        case "method_not_supported": "The speaker doesn't offer this way of pairing."
        case "user_cancelled": "Pairing was cancelled on the speaker."
        case "pairing_code_mismatch": "Too many wrong codes. Check the speaker, then try again."
        case "concurrent_attempt": "The speaker is pairing with another server."
        default: "The speaker ended pairing (\(reason))."
        }
        failPairing(text, abort: nil)
    }

    /// Leave pairing, and end the connection: the operator starts a new attempt. A cancel
    /// says why first (pairing.md, Entering and leaving pairing).
    private func failPairing(_ text: String?, abort reason: String?) {
        if let reason { sendMessage("pair/abort", PairAbortMessage(reason: reason)) }
        sendMessage("server/activate", ServerActivate(activities: [], activeRoles: []))
        attempt = nil
        pairingInitTimeout?.cancel()
        status.pairing = text.map { .failed($0) } ?? .failed("Pairing was cancelled.")
        endOfConnection = .stop(.pairingRequired)
        socket?.close()
    }

    /// Forget the pairing. A connected speaker is told to forget it too (server/unpair), and
    /// says goodbye with `unpaired`; one that isn't keeps its record until it's paired again,
    /// which replaces it.
    public func unpair() {
        guard let clientID = status.clientID else { return }
        if status.paired, channel != nil { sendMessage("server/unpair", EmptyPayload()) }
        pairings.remove(clientID)
        Log.info("\(status.name ?? clientID): pairing forgotten")
    }

    /// Cancel the pairing in progress, from this Mac.
    public func cancelPairing() {
        guard attempt != nil || status.pairing == .starting else { return }
        failPairing(nil, abort: "user_cancelled")
    }

    // MARK: Re-handshake (connection.md, Re-handshake)

    /// New session keys on the same connection: the prologue is the old handshake hash, and
    /// nothing else goes out until the new keys are in place.
    private func beginRehandshake(to psk: Data, longTerm: Bool, then next: AfterRehandshake) {
        guard let channel, let clientKey else { return }
        var handshake = NoiseInitiatorHandshake(suite: suite, prologue: channel.handshakeHash,
                                                localStatic: identity.privateKey, remoteStatic: clientKey, psk: psk)
        do {
            let payload = try JSONEncoder().encode(
                NoiseMessage1Payload(pskID: SendspinPSK.id(for: psk), pskCategory: longTerm ? "lt" : "pr"))
            let message1 = try handshake.writeMessage1(payload: payload)
            sendMessage("noise/handshake", NoiseHandshakeMessage(data: Base64URL.encode(message1)))
            rehandshake = (handshake, psk, longTerm, next)
        } catch {
            failPairing("Pairing failed: \(error)", abort: nil)
        }
    }

    private func finishRehandshake(_ message: NoiseHandshakeMessage) async throws {
        guard var state = rehandshake, let message2 = Base64URL.decode(message.data) else {
            throw SessionError.handshake("noise/handshake out of sequence")
        }
        // A miss fails: no Sentinel fallback in a re-handshake.
        let (_, transport) = try state.handshake.readMessage2(message2)
        channel = SecureChannel(transport: transport)
        rehandshake = nil
        connectionPSK = state.psk
        pairingIndex = 0
        status.paired = state.longTerm
        Log.debug("\(status.name ?? "?"): re-handshake done (\(state.longTerm ? "lt" : "pr"))")
        // The first message under the new keys is server/activate.
        switch state.then {
        case .pairing:
            activatePairing()
        case .paired:
            guard let clientID = status.clientID, await approve(clientID, true) else {
                sendMessage("server/activate", ServerActivate(activities: [], activeRoles: []))
                return
            }
            activatePlayback()
        }
    }
}

enum SessionError: Error, CustomStringConvertible {
    case handshake(String)
    /// A pairing protocol error (pairing.md): the connection closes without a message.
    case pairing(String)

    var description: String {
        switch self {
        case .handshake(let detail): "handshake failed: \(detail)"
        case .pairing(let detail): "pairing protocol error: \(detail)"
        }
    }
}
