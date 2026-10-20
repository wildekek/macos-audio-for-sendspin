import CryptoKit
import Foundation

public struct PlayerStatus: Sendable, Equatable {
    public enum Connection: Sendable, Equatable {
        case connecting
        case connected
        /// Another server took the player over (goodbye `another_server`).
        case taken
        /// The player only admits paired servers, and pairing isn't implemented.
        case pairingRequired
        /// The player presents a different identity than the one approved for it.
        case notApproved
        /// A player that connected to us, held until the user allows it (ticks it).
        case awaitingApproval
        case disconnected(reason: String?)
        case failed(String)
    }

    public var connection: Connection = .connecting
    public var name: String?
    /// The player's `client_id`: its Curve25519 public key, base64url.
    public var clientID: String?
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
    /// Asked once per connection with the player's `client_id`: may it play unpaired?
    public typealias Approval = @Sendable (_ clientID: String) async -> Bool

    public nonisolated let url: URL
    public nonisolated let updates: AsyncStream<PlayerStatus>

    private let identity: ServerIdentity
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
    /// server/activate declared playback.
    private var activated = false
    /// Any server/activate went out, so the player may send its other messages.
    private var sentActivation = false
    private var available = false
    /// The first client/state arrived: only then may streams start and commands go out.
    private var ready = false
    /// Converts group audio to the player's format; rebuilt when the source or the
    /// preferred bit depth changes.
    private var pipeline: PlayerAudioPipeline?
    private var pipelineBitDepthPreference: Int?
    private var unsupportedSourceWarned = false
    private var streaming = false
    private var droppedChunks = 0
    /// Chunks the player may still hold (player/v1.md, Player Buffer Accounting): their
    /// wire size, and when their playback ends on the server clock.
    private var inFlight: [(endUs: Int64, bytes: Int)] = []
    private var inFlightBytes = 0
    private var outputDelayUs: Int64 = 0
    private var capacityDrops = 0

    private var group: (id: String, name: String)?
    private var playing = false

    /// A player we dial and keep connected.
    public init(url: URL, identity: ServerIdentity, approve: @escaping Approval) {
        self.url = url
        self.identity = identity
        self.approve = approve
        incoming = nil
        isIncoming = false
        (updates, updatesContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(16))
    }

    /// A player that connected to us. It's served once: we can't reconnect to it.
    public init(incoming connection: IncomingConnection, identity: ServerIdentity, approve: @escaping Approval) {
        url = URL(string: "ws://\(connection.remoteDescription)") ?? URL(string: "ws://incoming")!
        self.identity = identity
        self.approve = approve
        incoming = connection.socket
        isIncoming = true
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
            } catch {
                Log.warning("\(url): \(error)")
                status.connection = .failed(String(describing: error))
            }
            resetConnectionState()
            return
        }
        var backoff: Duration = .seconds(1)
        while !Task.isCancelled {
            status.connection = .connecting
            var outcome: SessionEnd
            do {
                outcome = try await connectAndServe()
                backoff = .seconds(1)
            } catch is CancellationError {
                break
            } catch {
                Log.warning("\(url): \(error)")
                status.connection = .failed(String(describing: error))
                outcome = .reconnect
            }
            resetConnectionState()
            if Task.isCancelled { break }

            switch outcome {
            case .reconnect:
                break
            case .stop(let connection):
                status.connection = connection
                return
            }
            // Also the backoff for repeated handshake failures, which the spec asks for.
            try? await Task.sleep(for: backoff)
            backoff = min(backoff * 2, .seconds(30))
        }
    }

    private enum SessionEnd {
        case reconnect
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
        var handshake = NoiseInitiatorHandshake(
            suite: suite, prologue: clientInitData + serverInitData, localStatic: identity.privateKey,
            remoteStatic: clientKey, psk: SendspinPSK.sentinel)
        let message1Payload = try JSONEncoder().encode(
            NoiseMessage1Payload(pskID: SendspinPSK.id(for: SendspinPSK.sentinel), pskCategory: "sn"))
        let message1 = try handshake.writeMessage1(payload: message1Payload)
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
        let (payload, transport) = try handshake.readMessage2(message2)
        guard (try? JSONSerialization.jsonObject(with: payload)) is [String: Any] else {
            throw SessionError.handshake("Noise message 2 payload isn't a JSON object")
        }
        channel = SecureChannel(transport: transport)
        status.clientID = clientInit.clientID
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
        if status.connection == .connected { status.connection = .disconnected(reason: nil) }
        // A drop without client/goodbye: assume `restart` (messaging.md, client/goodbye).
        return .reconnect
    }

    /// Validate client/init; on an init failure, answer with server/error first.
    private func parseClientInit(_ data: Data, socket: WebSocketConnection)
        throws -> (ClientInit, NoiseSuite, Curve25519.KeyAgreement.PublicKey) {
        guard (try? MessageCoding.type(of: data)) == "client/init",
              let clientInit = try? MessageCoding.payload(ClientInit.self, from: data)
        else {
            reject(socket, reason: "malformed")
            throw SessionError.handshake("expected client/init")
        }
        guard clientInit.version == 1 else {
            reject(socket, reason: "unsupported_version")
            throw SessionError.handshake("unsupported version \(clientInit.version)")
        }
        guard let suite = NoiseSuite(rawValue: clientInit.suite) else {
            reject(socket, reason: "unsupported_suite")
            throw SessionError.handshake("unsupported suite \(clientInit.suite)")
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
        sentActivation = false
        available = false
        ready = false
        stopStreaming()
    }

    // MARK: Inbound messages

    /// Handle one JSON message; returns how the session ends when the client leaves.
    private func handle(_ data: Data, receivedAtUs: Int64) async throws -> SessionEnd? {
        let type = try MessageCoding.type(of: data)
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
            handleState(try MessageCoding.payload(ClientState.self, from: data))
        default:
            Log.debug("\(status.name ?? "?"): ignoring \(type)")
        }
        return nil
    }

    private func goodbye(_ reason: String) -> SessionEnd {
        let name = status.name ?? url.absoluteString
        switch reason {
        case "restart", "concurrent_attempt":
            Log.info("\(name): goodbye (\(reason)), reconnecting")
            return .reconnect
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

        guard hello.supportedRoles.contains("player@v1"), hello.playerSupport != nil else {
            sendMessage("server/activate", ServerActivate(activities: [], activeRoles: []))
            return .stop(.failed("not a player"))
        }
        // There's no pairing record, so this is an unpaired session on the Sentinel PSK:
        // the player must admit unpaired access and the user must have approved it.
        guard hello.unpairedAccess?.enabled == true else {
            Log.info("\(hello.name): doesn't admit unpaired access; it needs pairing")
            return .stop(.pairingRequired)
        }
        guard let clientID = status.clientID, await approve(clientID) else {
            if isIncoming {
                // Hold it with no activities, as the spec allows, until the user allows it.
                sendMessage("server/activate", ServerActivate(activities: [], activeRoles: []))
                sentActivation = true
                status.connection = .awaitingApproval
                return nil
            }
            Log.warning("\(hello.name): identity \(status.clientID ?? "?") isn't the approved one")
            return .stop(.notApproved)
        }
        activatePlayback()
        return nil
    }

    private func activatePlayback() {
        sendMessage("server/activate", ServerActivate(activities: ["playback"], activeRoles: ["player@v1"]))
        sentActivation = true
        activated = true
        sendGroupUpdate()
        status.connection = .connected
    }

    /// The user allowed a held player (ticked it): activate playback on the same connection.
    public func reevaluateApproval() async {
        guard status.connection == .awaitingApproval, let clientID = status.clientID, await approve(clientID)
        else { return }
        Log.info("\(status.name ?? "?"): allowed")
        activatePlayback()
    }

    private func handleState(_ state: ClientState) {
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
        }
        if wasAvailable && !available && ready {
            Log.info("\(status.name ?? "?"): unavailable")
            if streaming { sendMessage("stream/end", StreamEnd(roles: ["player"])) }
            stopStreaming()
        }
        ready = true
    }

    // MARK: Outbound

    private func sendMessage<P: Encodable>(_ type: String, _ payload: P) {
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

    private func sendGroupUpdate() {
        guard activated, let group else { return }
        sendMessage("group/update", GroupUpdate(playbackState: playing ? "playing" : "stopped",
                                                groupID: group.id, groupName: group.name))
    }

    // MARK: Group interface

    func join(groupID: String, groupName: String) {
        group = (groupID, groupName)
        sendGroupUpdate()
    }

    func setPlaying(_ playing: Bool) {
        guard playing != self.playing else { return }
        self.playing = playing
        sendGroupUpdate()
        if !playing, streaming {
            sendMessage("stream/end", StreamEnd(roles: ["player"]))
        }
        if !playing { stopStreaming() }
    }

    private func stopStreaming() {
        streaming = false
        pipeline = nil
        status.streamFormat = nil
        // stream/end empties the player's buffer accounting.
        inFlight.removeAll()
        inFlightBytes = 0
    }

    /// Send one chunk of group audio; `timestampUs` is its play time on the server clock.
    /// The player gets the format closest to the source (see `FormatChoice`).
    func deliver(_ pcm: PCMBuffer, timestampUs: Int64, preferredBitDepth: Int) {
        guard let socket, activated, ready, available else { return }
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
        let now = ServerClock.nowMicros()
        while let first = inFlight.first, first.endUs - outputDelayUs <= now {
            inFlightBytes -= first.bytes
            inFlight.removeFirst()
        }
        if let capacity = hello?.playerSupport?.bufferCapacity, inFlightBytes + bytes > capacity {
            capacityDrops += 1
            if capacityDrops == 1 || capacityDrops.isMultiple(of: 50) {
                Log.warning("\(status.name ?? "?"): buffer_capacity \(capacity) bytes full, dropped \(capacityDrops) chunks")
            }
            return false
        }
        inFlight.append((playAtUs + durationUs, bytes))
        inFlightBytes += bytes
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
        setPlaying(false)
        socket?.close()
    }
}

enum SessionError: Error, CustomStringConvertible {
    case handshake(String)

    var description: String {
        switch self {
        case .handshake(let detail): "handshake failed: \(detail)"
        }
    }
}
