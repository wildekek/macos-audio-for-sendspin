import Foundation

// JSON messages are `{"type": "...", "payload": {...}}`. Decoders ignore unknown
// fields, as the spec requires. Field spellings follow the wire format, including
// the pre-1.0 ("legacy", unencrypted) variants that current players still send.

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
    public var bufferCapacity: Int?
    public var supportedCommands: [String]?

    enum CodingKeys: String, CodingKey {
        case supportedFormats = "supported_formats"
        case bufferCapacity = "buffer_capacity"
        case supportedCommands = "supported_commands"
    }
}

public struct ClientHello: Decodable, Sendable {
    /// Present on legacy connections; encrypted clients are identified by their Noise key.
    public var clientID: String?
    public var name: String
    public var version: Int?
    public var supportedRoles: [String]
    public var deviceInfo: DeviceInfo?
    public var playerSupport: PlayerSupport?

    enum CodingKeys: String, CodingKey {
        case name, version
        case clientID = "client_id"
        case supportedRoles = "supported_roles"
        case deviceInfo = "device_info"
        case playerSupport = "player@v1_support"
        case legacyPlayerSupport = "player_support"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clientID = try c.decodeIfPresent(String.self, forKey: .clientID)
        name = try c.decode(String.self, forKey: .name)
        version = try c.decodeIfPresent(Int.self, forKey: .version)
        supportedRoles = try c.decode([String].self, forKey: .supportedRoles)
        deviceInfo = try c.decodeIfPresent(DeviceInfo.self, forKey: .deviceInfo)
        playerSupport = try c.decodeIfPresent(PlayerSupport.self, forKey: .playerSupport)
            ?? c.decodeIfPresent(PlayerSupport.self, forKey: .legacyPlayerSupport)
    }
}

public struct ClientTime: Codable, Sendable {
    public var clientTransmitted: Int64

    enum CodingKeys: String, CodingKey {
        case clientTransmitted = "client_transmitted"
    }
}

public struct PlayerState: Decodable, Sendable {
    public var volume: Int?
    public var muted: Bool?
    public var minBufferMs: Int?

    enum CodingKeys: String, CodingKey {
        case volume, muted
        case minBufferMs = "min_buffer_ms"
    }
}

public struct ClientState: Decodable, Sendable {
    /// Spec field; `false` means the player can't take a stream right now.
    public var available: Bool?
    /// Legacy field: "synchronized", "error" or "external_source".
    public var state: String?
    public var player: PlayerState?

    /// Whether the client can currently play a stream. A legacy "error" state doesn't
    /// count against it (aiosendspin keeps streaming then too): only "external_source",
    /// a player busy with another source, does.
    public var isAvailable: Bool {
        if let available { return available }
        return state != "external_source"
    }

    /// Legacy players report "error" when something went wrong on their side.
    public var reportsError: Bool { state == "error" }
}

public struct ClientGoodbye: Decodable, Sendable {
    public var reason: String
}

// MARK: - Server -> client

/// server/hello for legacy (unencrypted) clients; it doubles as the activation.
public struct LegacyServerHello: Encodable, Sendable {
    public var serverID: String
    public var name: String
    public var version = 1
    public var connectionReason: String
    public var activeRoles: [String]

    enum CodingKeys: String, CodingKey {
        case name, version
        case serverID = "server_id"
        case connectionReason = "connection_reason"
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

public struct GroupUpdate: Encodable, Sendable {
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
    public var player: StreamStartPlayer
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

    static func encode<P: Encodable>(type: String, payload: P) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return String(decoding: try encoder.encode(Outgoing(type: type, payload: payload)), as: UTF8.self)
    }
}
