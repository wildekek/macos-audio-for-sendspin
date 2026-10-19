import Foundation

/// Identity this server presents to players.
public struct ServerIdentity: Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct PlayerStatus: Sendable, Equatable {
    public enum Connection: Sendable, Equatable {
        case connecting
        case connected
        /// Another server took the player over (goodbye `another_server`).
        case taken
        case disconnected(reason: String?)
        case failed(String)
    }

    public var connection: Connection = .connecting
    public var name: String?
    public var volume: Int?
    public var muted: Bool?
    /// PCM formats the player accepts (from its hello).
    public var supportedFormats: [AudioFormatSpec] = []
    /// Format currently streamed to the player, while streaming.
    public var streamFormat: AudioFormatSpec?

    public init() {}
}

/// One dialed player: owns the WebSocket, runs the handshake, answers time sync,
/// tracks player state and delivers the group's audio in the negotiated format.
public actor PlayerSession {
    public nonisolated let url: URL
    public nonisolated let updates: AsyncStream<PlayerStatus>

    private let identity: ServerIdentity
    private let updatesContinuation: AsyncStream<PlayerStatus>.Continuation
    private var status = PlayerStatus() {
        didSet { if status != oldValue { updatesContinuation.yield(status) } }
    }

    private var socket: WebSocketConnection?
    private var hello: ClientHello?
    private var available = true
    /// Handshake done and initial client/state received (or waited for long enough).
    private var ready = false
    /// Converts group audio to the player's format; rebuilt when the source or the
    /// preferred bit depth changes.
    private var pipeline: PlayerAudioPipeline?
    private var pipelineBitDepthPreference: Int?
    private var unsupportedSourceWarned = false
    private var streaming = false
    private var droppedChunks = 0
    private var reportedError = false
    private var lastErrorRestart: ContinuousClock.Instant?

    private var group: (id: String, name: String)?
    private var playing = false
    private var isFirstConnection = true

    public init(url: URL, identity: ServerIdentity) {
        self.url = url
        self.identity = identity
        (updates, updatesContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(16))
    }

    public var currentStatus: PlayerStatus { status }

    // MARK: Connection lifecycle

    /// Connect and keep the player connected until cancelled, the player leaves for
    /// good (goodbye other than `restart`), or another server takes it over.
    public func run() async {
        defer {
            socket?.close()
            updatesContinuation.finish()
        }
        var backoff: Duration = .seconds(1)
        while !Task.isCancelled {
            status.connection = .connecting
            let goodbye: String?
            do {
                goodbye = try await connectAndServe()
                backoff = .seconds(1)
            } catch is CancellationError {
                break
            } catch {
                Log.warning("\(url): \(error)")
                status.connection = .failed(String(describing: error))
                goodbye = nil
            }
            resetConnectionState()
            if Task.isCancelled { break }

            switch goodbye {
            case "another_server":
                Log.info("\(status.name ?? url.absoluteString): taken over by another server")
                status.connection = .taken
                return
            case nil, "restart":
                break
            default:
                Log.info("\(status.name ?? url.absoluteString): left (\(goodbye!))")
                status.connection = .disconnected(reason: goodbye)
                return
            }
            try? await Task.sleep(for: backoff)
            backoff = min(backoff * 2, .seconds(30))
        }
    }

    /// Returns the client's goodbye reason, or nil when the connection just dropped.
    private func connectAndServe() async throws -> String? {
        let socket = WebSocketConnection(url: url)
        self.socket = socket
        defer { socket.close() }
        try await socket.open()
        Log.debug("\(url): connected")

        var goodbye: String?
        let stateTimeout = Task { [weak self] in
            try await Task.sleep(for: .seconds(5))
            await self?.markReady(reason: "no client/state within 5 s")
        }
        defer { stateTimeout.cancel() }

        for try await frame in socket.frames {
            guard case let .text(data, receivedAtUs) = frame else { continue }
            if let reason = try handle(data, receivedAtUs: receivedAtUs) {
                goodbye = reason
                break
            }
        }
        if status.connection == .connected {
            status.connection = .disconnected(reason: goodbye)
        }
        return goodbye
    }

    private func resetConnectionState() {
        socket = nil
        hello = nil
        ready = false
        stopStreaming()
        available = true
    }

    // MARK: Inbound messages

    /// Handle one text message; returns a goodbye reason when the client leaves.
    private func handle(_ data: Data, receivedAtUs: Int64) throws -> String? {
        let type = try MessageCoding.type(of: data)
        if hello == nil, type != "client/hello" {
            if type == "client/init" {
                throw SessionError.encryptionUnsupported
            }
            throw SessionError.unexpectedFirstMessage(type)
        }

        switch type {
        case "client/hello":
            try handleHello(MessageCoding.payload(ClientHello.self, from: data))
        case "client/time":
            let time = try MessageCoding.payload(ClientTime.self, from: data)
            send("server/time", ServerTime(clientTransmitted: time.clientTransmitted,
                                           serverReceived: receivedAtUs,
                                           serverTransmitted: ServerClock.nowMicros()))
        case "client/state":
            handleState(try MessageCoding.payload(ClientState.self, from: data))
        case "client/goodbye":
            return try MessageCoding.payload(ClientGoodbye.self, from: data).reason
        default:
            Log.debug("\(status.name ?? "?"): ignoring \(type)")
        }
        return nil
    }

    private func handleHello(_ hello: ClientHello) {
        self.hello = hello
        status.name = hello.name
        status.supportedFormats = (hello.playerSupport?.supportedFormats ?? [])
            .filter { $0.codec == AudioCodec.pcm.rawValue }
        Log.info("\(hello.name): hello (\(hello.deviceInfo?.productName ?? "unknown device"), "
            + "software \(hello.deviceInfo?.softwareVersion ?? "?"))")

        let roles = hello.supportedRoles.contains("player@v1") ? ["player@v1"] : []
        // Ask for playback only on the first connection, so a reconnect doesn't pull the
        // player away from a server the user switched to in the meantime.
        let reason = isFirstConnection ? "playback" : "discovery"
        isFirstConnection = false
        send("server/hello", LegacyServerHello(serverID: identity.id, name: identity.name,
                                               connectionReason: reason, activeRoles: roles))
        sendGroupUpdate()
        status.connection = .connected
    }

    private func handleState(_ state: ClientState) {
        let wasAvailable = available
        available = state.isAvailable
        if let player = state.player {
            if let volume = player.volume { status.volume = volume }
            if let muted = player.muted { status.muted = muted }
        }
        if wasAvailable && !available {
            Log.info("\(status.name ?? "?"): unavailable (\(state.state ?? "available=false"))")
            stopStreaming()
        }
        // On an error report, give the player a fresh stream (a new stream/start with the
        // next chunk), at most every 10 s so a player that keeps failing can't make us loop.
        if state.reportsError && !reportedError {
            let now = ContinuousClock.now
            if streaming, lastErrorRestart.map({ now - $0 > .seconds(10) }) ?? true {
                Log.warning("\(status.name ?? "?"): reports an error; restarting its stream")
                lastErrorRestart = now
                send("stream/end", StreamEnd(roles: ["player"]))
                stopStreaming()
            } else {
                Log.warning("\(status.name ?? "?"): reports an error")
            }
        }
        if state.state != nil { reportedError = state.reportsError }
        markReady(reason: nil)
    }

    private func markReady(reason: String?) {
        guard hello != nil, !ready else { return }
        if let reason { Log.debug("\(status.name ?? "?"): ready (\(reason))") }
        ready = true
    }

    // MARK: Outbound

    private func send<P: Encodable>(_ type: String, _ payload: P) {
        guard let socket else { return }
        do {
            socket.send(text: try MessageCoding.encode(type: type, payload: payload))
        } catch {
            Log.error("encoding \(type): \(error)")
        }
    }

    private func sendGroupUpdate() {
        guard let group else { return }
        send("group/update", GroupUpdate(playbackState: playing ? "playing" : "stopped",
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
            send("stream/end", StreamEnd(roles: ["player"]))
        }
        if !playing { stopStreaming() }
    }

    private func stopStreaming() {
        streaming = false
        pipeline = nil
        status.streamFormat = nil
    }

    /// Send one chunk of group audio; `timestampUs` is its play time on the server clock.
    /// The player gets the format closest to the source (see `FormatChoice`).
    func deliver(_ pcm: PCMBuffer, timestampUs: Int64, preferredBitDepth: Int) {
        guard let socket, ready, available else { return }
        if pipeline == nil || !pipeline!.accepts(pcm) || pipelineBitDepthPreference != preferredBitDepth {
            guard startPipeline(for: pcm, preferredBitDepth: preferredBitDepth) else { return }
        }

        // A stalled player must not buffer unbounded audio in the network stack.
        if socket.backlog > 100 {
            droppedChunks += 1
            if droppedChunks.isMultiple(of: 50) {
                Log.warning("\(status.name ?? "?"): send backlog, dropped \(droppedChunks) chunks")
            }
            return
        }
        guard let (playAtUs, payload) = pipeline?.process(pcm, timestampUs: timestampUs) else { return }
        // Legacy clients get the 9-byte header without send-ahead.
        socket.send(binary: AudioFrame.pack(timestampUs: playAtUs, sendAheadUs: nil, payload: payload))
    }

    /// Choose the stream format for this source and (re)start the stream in it.
    private func startPipeline(for pcm: PCMBuffer, preferredBitDepth: Int) -> Bool {
        guard let format = FormatChoice.best(from: status.supportedFormats, sourceRate: pcm.sampleRate,
                                             sourceChannels: pcm.channels, preferredBitDepth: preferredBitDepth),
              let pipeline = PlayerAudioPipeline(format: format, sourceRate: pcm.sampleRate,
                                                 sourceChannels: pcm.channels)
        else {
            if !unsupportedSourceWarned {
                unsupportedSourceWarned = true
                Log.error("\(status.name ?? "?"): no usable PCM format for \(pcm.sampleRate) Hz audio")
            }
            return false
        }
        unsupportedSourceWarned = false
        let changed = format != self.pipeline?.format
        self.pipeline = pipeline
        pipelineBitDepthPreference = preferredBitDepth
        if !streaming || changed {
            // stream/start again on a format change: the player reconfigures its decoder.
            send("stream/start", StreamStart(player: StreamStartPlayer(
                codec: format.codec, sampleRate: format.sampleRate,
                channels: format.channels, bitDepth: format.bitDepth)))
            streaming = true
            status.streamFormat = format
            let conversion = format.sampleRate == pcm.sampleRate ? "" : " (resampled from \(pcm.sampleRate) Hz)"
            Log.info("\(status.name ?? "?"): streaming \(format.codec) \(format.sampleRate) Hz "
                + "\(format.bitDepth)-bit \(format.channels) ch\(conversion)")
        }
        return true
    }

    // MARK: Player control

    public func setVolume(_ volume: Int) {
        send("server/command", ServerCommand(player: .volume(max(0, min(100, volume)))))
    }

    public func setMuted(_ muted: Bool) {
        send("server/command", ServerCommand(player: .mute(muted)))
    }

    /// End the stream and close the connection.
    func shutdown() {
        setPlaying(false)
        socket?.close()
    }
}

enum SessionError: Error, CustomStringConvertible {
    case encryptionUnsupported
    case unexpectedFirstMessage(String)

    var description: String {
        switch self {
        case .encryptionUnsupported:
            "player requires an encrypted (Noise) connection, which is not implemented yet"
        case .unexpectedFirstMessage(let type):
            "unexpected first message \(type)"
        }
    }
}
