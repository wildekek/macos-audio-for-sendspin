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

public struct UnpairedAccess: Codable, Sendable {
    public var enabled: Bool
}

public struct ClientHello: Decodable, Sendable {
    public var name: String
    public var deviceInfo: DeviceInfo?
    public var supportedRoles: [String]
    public var playerSupport: PlayerSupport?
    public var unpairedAccess: UnpairedAccess?

    enum CodingKeys: String, CodingKey {
        case name
        case deviceInfo = "device_info"
        case supportedRoles = "supported_roles"
        case playerSupport = "player@v1_support"
        case unpairedAccess = "unpaired_access"
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
}

public struct ClientGoodbye: Decodable, Sendable {
    public var reason: String
}

// MARK: - Server -> client

public struct ServerHello: Encodable, Sendable {
    public var name: String
}

public struct ServerActivate: Encodable, Sendable {
    public var activities: [String]
    public var activeRoles: [String]

    enum CodingKeys: String, CodingKey {
        case activities
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
    public var player: StreamStartPlayer

    enum CodingKeys: String, CodingKey {
        case player
        case serverTransmitted = "server_transmitted"
    }
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
    private struct Envelope: Decodable {
        var type: String
    }

    private struct Incoming<Payload: Decodable>: Decodable {
        var payload: Payload
    }

    private struct Outgoing<Payload: Encodable>: Encodable {
        var type: String
        var payload: Payload
    }

    static func type(of data: Data) throws -> String {
        try JSONDecoder().decode(Envelope.self, from: data).type
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
