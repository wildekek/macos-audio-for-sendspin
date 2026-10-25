import Foundation

// Sendspin 1 messages (github.com/Sendspin/spec, messaging.md and roles/player/v1.md).
// JSON messages are `{"type": "...", "payload": {...}}`. Decoders ignore unknown
// fields, as the spec requires.

public enum AudioCodec: String, Codable, Sendable {
    case pcm, flac, opus
}

public struct AudioFormatSpec: Codable, Hashable, Sendable {
    public var codec: String
    public var channels: Int
    public var sampleRate: Int
    public var bitDepth: Int

    public init(codec: AudioCodec, channels: Int, sampleRate: Int, bitDepth: Int) {
        self.codec = codec.rawValue
        self.channels = channels
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
    }

    enum CodingKeys: String, CodingKey {
        case codec, channels
        case sampleRate = "sample_rate"
        case bitDepth = "bit_depth"
    }
}

// MARK: - Handshake (cleartext)

public struct ClientInit: Decodable, Sendable {
    public var clientID: String
    public var version: Int
    public var suite: String

    enum CodingKeys: String, CodingKey {
        case version, suite
        case clientID = "client_id"
    }

    /// Why a client/init isn't accepted: the `server/error` reason.
    enum Failure: String, Error {
        case malformed
        case unsupportedVersion = "unsupported_version"
        case unsupportedSuite = "unsupported_suite"
    }

    private struct VersionField: Decodable { var version: Int }
    private struct SuiteField: Decodable { var suite: String }

    /// Parse client/init, checking `version` first, then `suite`, then the rest: a version
    /// other than 1 is `unsupported_version` whatever the other fields hold
    /// (connection.md, Failure Handling).
    static func parse(_ data: Data) throws(Failure) -> (ClientInit, NoiseSuite) {
        guard (try? MessageCoding.type(of: data)) == "client/init",
              let version = try? MessageCoding.payload(VersionField.self, from: data).version
        else { throw .malformed }
        guard version == 1 else { throw .unsupportedVersion }
        guard let suiteName = try? MessageCoding.payload(SuiteField.self, from: data).suite else { throw .malformed }
        guard let suite = NoiseSuite(rawValue: suiteName) else { throw .unsupportedSuite }
        guard let clientInit = try? MessageCoding.payload(ClientInit.self, from: data) else { throw .malformed }
        return (clientInit, suite)
    }
}

public struct ServerInit: Encodable, Sendable {
    public var serverID: String
    public var version = 1

    enum CodingKeys: String, CodingKey {
        case version
        case serverID = "server_id"
    }
}

public struct ServerError: Encodable, Sendable {
    public var reason: String
}

public struct NoiseHandshakeMessage: Codable, Sendable {
    /// base64url Noise handshake bytes.
    public var data: String
}

/// The encrypted payload of Noise message 1: which PSK the server mixes in.
struct NoiseMessage1Payload: Encodable {
    var pskID: String
    var pskCategory: String

    enum CodingKeys: String, CodingKey {
        case pskID = "psk_id"
        case pskCategory = "psk_category"
    }
}

// MARK: - Client -> server

public struct DeviceInfo: Codable, Sendable {
    public var productName: String?
    public var manufacturer: String?
    public var softwareVersion: String?

    enum CodingKeys: String, CodingKey {
        case manufacturer
        case productName = "product_name"
        case softwareVersion = "software_version"
    }
}

public struct PlayerSupport: Codable, Sendable {
    public var supportedFormats: [AudioFormatSpec]
    public var bufferCapacity: Int

    enum CodingKeys: String, CodingKey {
        case supportedFormats = "supported_formats"
        case bufferCapacity = "buffer_capacity"
    }
}

public struct VisualizerSupport: Codable, Sendable {
    /// Bytes of visualizer messages it can hold.
    public var bufferCapacity: Int

    enum CodingKeys: String, CodingKey {
        case bufferCapacity = "buffer_capacity"
    }
}

public struct UnpairedAccess: Codable, Sendable {
    public var enabled: Bool
}

public struct ClientHello: Decodable, Sendable {
    public var name: String
    public var deviceInfo: DeviceInfo?
    public var supportedRoles: [String]
    public var playerSupport: PlayerSupport?
    public var visualizerSupport: VisualizerSupport?
    public var unpairedAccess: UnpairedAccess?
    public var supportedPairMethods: PairMethods?

    enum CodingKeys: String, CodingKey {
        case name
        case deviceInfo = "device_info"
        case supportedRoles = "supported_roles"
        case playerSupport = "player@v1_support"
        case visualizerSupport = "visualizer@v1_support"
        case unpairedAccess = "unpaired_access"
        case supportedPairMethods = "supported_pair_methods"
    }
}

/// The pairing methods a client offers (pairing.md, client/hello pair-method descriptor).
/// Unknown methods, formats and channels are ignored; a dynamic code with no format or
/// channel we know counts as not offered.
public struct PairMethods: Decodable, Sendable, Equatable {
    public enum Location: String, Sendable { case device, leaflet, `operator` }
    public enum OutChannel: String, Sendable { case display, speaker }

    /// Where the operator finds the pairing token, if offered (every client must).
    public var pairingPSK: [Location]?
    /// Where the 8-digit static code is: on the device, a leaflet, or set by the operator.
    public var staticCode: [Location]?
    /// How the device conveys its dynamic code, if it offers one in the digits format.
    public var dynamicCode: [OutChannel]?

    public init(pairingPSK: [Location]? = nil, staticCode: [Location]? = nil, dynamicCode: [OutChannel]? = nil) {
        self.pairingPSK = pairingPSK
        self.staticCode = staticCode
        self.dynamicCode = dynamicCode
    }

    private struct Descriptor: Decodable {
        var locations: [String]?
        var outChannels: [String]?
        var formats: [String]?

        enum CodingKeys: String, CodingKey {
            case locations
            case outChannels = "out_channels"
            case formats
        }
    }

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        func descriptor(_ key: String) -> Descriptor? {
            try? container.decodeIfPresent(Descriptor.self, forKey: Key(stringValue: key))
        }
        func locations(_ descriptor: Descriptor) -> [Location] {
            (descriptor.locations ?? []).compactMap(Location.init(rawValue:))
        }
        if let psk = descriptor("pairing_psk") { pairingPSK = locations(psk) }
        if let code = descriptor("static_pairing_code") { staticCode = locations(code) }
        // QR codes need a camera; a desktop app asks for digits (the implementation guide).
        if let code = descriptor("dynamic_pairing_code"), (code.formats ?? []).contains("digits") {
            let channels = (code.outChannels ?? []).compactMap(OutChannel.init(rawValue:))
            if !channels.isEmpty { dynamicCode = channels }
        }
    }
}

public struct ClientTime: Codable, Sendable {
    public var clientTransmitted: Int64

    enum CodingKeys: String, CodingKey {
        case clientTransmitted = "client_transmitted"
    }
}

/// The `player` object of client/state.
public struct PlayerState: Decodable, Sendable {
    public var volume: Int?
    public var muted: Bool?
    public var outputDelayMs: Int?
    public var requiredLeadTimeMs: Int?
    public var minBufferMs: Int?
    /// Commands the server may send: "volume", "mute", "set_output_delay".
    public var supportedCommands: [String]?

    enum CodingKeys: String, CodingKey {
        case volume, muted
        case outputDelayMs = "output_delay_ms"
        case requiredLeadTimeMs = "required_lead_time_ms"
        case minBufferMs = "min_buffer_ms"
        case supportedCommands = "supported_commands"
    }
}

public struct ClientState: Decodable, Sendable {
    /// `false` while the player is in use by something else and won't yield.
    public var available: Bool
    public var player: PlayerState?
    public var visualizer: VisualizerConfig?
    public var artwork: ArtworkConfig?
}

/// The `artwork` object of client/state, and of stream/start (roles/artwork/v1.md).
public struct ArtworkConfig: Codable, Sendable, Equatable {
    public struct Channel: Codable, Sendable, Equatable {
        /// 'album', 'artist' or 'none'.
        public var source: String
        /// 'jpeg' or 'png'; with the size, required unless the source is 'none'.
        public var format: String?
        public var width: Int?
        public var height: Int?
    }

    public var channels: [Channel]

    static let maxChannels = 4

    /// More than four channels, or a channel without its format and size: a protocol error.
    var isMalformed: Bool {
        channels.count > Self.maxChannels
            || channels.contains { $0.source != "none" && ($0.format == nil || $0.width == nil || $0.height == nil) }
    }

    /// For stream/start: the same channels, without those after the last streamed one.
    var streamed: ArtworkConfig {
        ArtworkConfig(channels: Array(channels.prefix((channels.lastIndex { $0.source != "none" } ?? -1) + 1)))
    }
}

/// The `controller` object of client/command (roles/controller/v1.md).
public struct ControllerCommand: Decodable, Sendable {
    public var command: String
    public var volume: Int?
    public var mute: Bool?
}

public struct ClientCommand: Decodable, Sendable {
    public var controller: ControllerCommand?
}

public struct ClientGoodbye: Decodable, Sendable {
    public var reason: String
}

// MARK: - Server -> client

public struct ServerHello: Encodable, Sendable {
    public var name: String
}

public struct ServerActivate: Encodable, Sendable {
    /// The pairing attempt a `pairing` activity admits (messaging.md, server/activate).
    public struct Pairing: Encodable, Sendable {
        public var method: String
        /// The dynamic code's emission format; absent for the other methods.
        public var format: String?
    }

    public var activities: [String]
    public var activeRoles: [String]
    public var pairing: Pairing?

    public init(activities: [String], activeRoles: [String], pairing: Pairing? = nil) {
        self.activities = activities
        self.activeRoles = activeRoles
        self.pairing = pairing
    }

    enum CodingKeys: String, CodingKey {
        case activities, pairing
        case activeRoles = "active_roles"
    }
}

public struct ServerTime: Encodable, Sendable {
    public var clientTransmitted: Int64
    public var serverReceived: Int64
    public var serverTransmitted: Int64

    enum CodingKeys: String, CodingKey {
        case clientTransmitted = "client_transmitted"
        case serverReceived = "server_received"
        case serverTransmitted = "server_transmitted"
    }
}

public struct GroupUpdate: Encodable, Equatable, Sendable {
    public var playbackState: String
    public var groupID: String
    public var groupName: String

    enum CodingKeys: String, CodingKey {
        case playbackState = "playback_state"
        case groupID = "group_id"
        case groupName = "group_name"
    }
}

public struct StreamStartPlayer: Encodable, Sendable {
    public var codec: String
    public var sampleRate: Int
    public var channels: Int
    public var bitDepth: Int
    public var codecHeader: String?

    enum CodingKeys: String, CodingKey {
        case codec, channels
        case sampleRate = "sample_rate"
        case bitDepth = "bit_depth"
        case codecHeader = "codec_header"
    }
}

public struct StreamStart: Encodable, Sendable {
    public var serverTransmitted: Int64
    public var player: StreamStartPlayer?
    public var visualizer: VisualizerConfig?
    public var artwork: ArtworkConfig?

    enum CodingKeys: String, CodingKey {
        case player, visualizer, artwork
        case serverTransmitted = "server_transmitted"
    }
}

/// The `controller` object of server/state: the state of the client's whole group.
public struct ControllerState: Encodable, Equatable, Sendable {
    public var supportedCommands: [String]
    public var volume: Int
    public var muted: Bool
    /// There's no queue to repeat or shuffle: the group plays the Mac's live sound.
    public var repeatMode = "off"
    public var shuffle = false

    enum CodingKeys: String, CodingKey {
        case volume, muted, shuffle
        case supportedCommands = "supported_commands"
        case repeatMode = "repeat"
    }
}

/// The `metadata` and `color` objects of server/state, with a timestamp and nothing else: the
/// Mac's sound comes without track details or artwork to take colors from.
public struct TimestampOnlyState: Encodable, Sendable {
    public var timestamp: Int64
}

public struct ServerState: Encodable, Sendable {
    public var controller: ControllerState?
    public var metadata: TimestampOnlyState?
    public var color: TimestampOnlyState?
}

public struct StreamEnd: Encodable, Sendable {
    public var roles: [String]
}

public struct PlayerCommand: Encodable, Sendable {
    public var command: String
    public var volume: Int?
    public var mute: Bool?

    public static func volume(_ level: Int) -> PlayerCommand {
        PlayerCommand(command: "volume", volume: level)
    }

    public static func mute(_ muted: Bool) -> PlayerCommand {
        PlayerCommand(command: "mute", mute: muted)
    }
}

public struct ServerCommand: Encodable, Sendable {
    public var player: PlayerCommand
}

// MARK: - Envelope

enum MessageCoding {
    /// A JSON message isn't an object with a `type` string and a `payload` object: a protocol
    /// error, on which the receiver MUST close (messaging.md, Binary Message ID Structure).
    struct Malformed: Error {}

    private struct Incoming<Payload: Decodable>: Decodable {
        var payload: Payload
    }

    private struct Outgoing<Payload: Encodable>: Encodable {
        var type: String
        var payload: Payload
    }

    static func type(of data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String, object["payload"] is [String: Any]
        else { throw Malformed() }
        return type
    }

    static func payload<P: Decodable>(_: P.Type, from data: Data) throws -> P {
        try JSONDecoder().decode(Incoming<P>.self, from: data).payload
    }

    /// The UTF-8 JSON bytes, exactly as they go on the wire.
    static func encode<P: Encodable>(type: String, payload: P) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return try encoder.encode(Outgoing(type: type, payload: payload))
    }
}
