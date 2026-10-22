import Foundation

// The messages of this Mac's client side: a Sendspin client with the `source@v1` role
// (messaging.md, pairing.md, roles/source/v1.md). Decoders ignore unknown fields.

// MARK: - Handshake (cleartext)

struct ClientInitMessage: Encodable {
    var clientID: String
    var version = 1
    var suite: String

    enum CodingKeys: String, CodingKey {
        case version, suite
        case clientID = "client_id"
    }
}

struct ServerInitMessage: Decodable {
    var serverID: String
    var version: Int

    enum CodingKeys: String, CodingKey {
        case version
        case serverID = "server_id"
    }
}

/// The payload of Noise message 1: which PSK the server mixes in.
struct NoiseMessage1Received: Decodable {
    var pskID: String
    var pskCategory: String

    enum CodingKeys: String, CodingKey {
        case pskID = "psk_id"
        case pskCategory = "psk_category"
    }
}

// MARK: - Server -> client

struct ServerHelloReceived: Decodable {
    struct SourceSupport: Decodable {
        var supportedCodecs: [String]

        enum CodingKeys: String, CodingKey {
            case supportedCodecs = "supported_codecs"
        }
    }

    var name: String
    var sourceSupport: SourceSupport?

    enum CodingKeys: String, CodingKey {
        case name
        case sourceSupport = "source@v1_support"
    }
}

struct ServerActivateReceived: Decodable {
    struct Pairing: Decodable {
        var method: String
        /// The dynamic code's emission format: "digits" or "qr_code".
        var format: String?
    }

    var activities: [String]
    var activeRoles: [String]?
    var pairing: Pairing?

    enum CodingKeys: String, CodingKey {
        case activities, pairing
        case activeRoles = "active_roles"
    }
}

struct ServerTimeReceived: Decodable {
    var clientTransmitted: Int64
    var serverReceived: Int64
    var serverTransmitted: Int64

    enum CodingKeys: String, CodingKey {
        case clientTransmitted = "client_transmitted"
        case serverReceived = "server_received"
        case serverTransmitted = "server_transmitted"
    }
}

struct ServerCommandReceived: Decodable {
    struct Source: Decodable {
        var command: String
    }

    var source: Source?
}

struct PairAbortMessage: Codable {
    var reason: String
}

// Dynamic Pairing Code flow (pairing.md, Messages). Binary values are base64url.

struct ServerPairInitReceived: Decodable {
    /// In the first round only.
    var nonceA: String?

    enum CodingKeys: String, CodingKey {
        case nonceA = "nonce_A"
    }
}

struct ServerPairAuthReceived: Decodable {
    /// The server's CPace share `Ya`.
    var pakeMsg1: String

    enum CodingKeys: String, CodingKey {
        case pakeMsg1 = "pake_msg_1"
    }
}

struct ServerPairConfirmReceived: Decodable {
    /// The server's confirmation tag `Ta`.
    var serverKC: String

    enum CodingKeys: String, CodingKey {
        case serverKC = "server_kc"
    }
}

// MARK: - Client -> server

struct ClientHelloMessage: Encodable {
    struct SourceSupport: Encodable {
        struct Features: Encodable {
            var lineSense = true

            enum CodingKeys: String, CodingKey {
                case lineSense = "line_sense"
            }
        }

        var features = Features()
    }

    /// The pairing PSK: every client implements it, for automated pairing between systems.
    /// No `locations`: the app shows the token nowhere (implementation guide).
    struct PairMethodDescriptor: Encodable {}

    /// The code is shown on this Mac's screen, as six digits.
    struct DynamicCodeDescriptor: Encodable {
        var outChannels = ["display"]
        var formats = ["digits"]

        enum CodingKeys: String, CodingKey {
            case formats
            case outChannels = "out_channels"
        }
    }

    struct PairMethods: Encodable {
        var pairingPSK = PairMethodDescriptor()
        var dynamicPairingCode = DynamicCodeDescriptor()

        enum CodingKeys: String, CodingKey {
            case pairingPSK = "pairing_psk"
            case dynamicPairingCode = "dynamic_pairing_code"
        }
    }

    struct UnpairedAccess: Encodable {
        var enabled: Bool
    }

    var name: String
    var deviceInfo: DeviceInfoMessage
    var supportedRoles = ["source@v1"]
    var sourceSupport = SourceSupport()
    var supportedPairMethods = PairMethods()
    var unpairedAccess = UnpairedAccess(enabled: false)

    enum CodingKeys: String, CodingKey {
        case name
        case deviceInfo = "device_info"
        case supportedRoles = "supported_roles"
        case sourceSupport = "source@v1_support"
        case supportedPairMethods = "supported_pair_methods"
        case unpairedAccess = "unpaired_access"
    }
}

struct DeviceInfoMessage: Encodable {
    var productName: String
    var manufacturer: String
    var softwareVersion: String

    enum CodingKeys: String, CodingKey {
        case manufacturer
        case productName = "product_name"
        case softwareVersion = "software_version"
    }
}

struct ClientTimeMessage: Encodable {
    var clientTransmitted: Int64

    enum CodingKeys: String, CodingKey {
        case clientTransmitted = "client_transmitted"
    }
}

struct ClientStateMessage: Encodable {
    struct Source: Encodable {
        /// "present" or "absent" (line sensing).
        var signal: String
    }

    var available: Bool
    var source: Source?
}

struct ClientStreamStartMessage: Encodable {
    struct Source: Encodable {
        var codec: String
        var channels: Int
        var sampleRate: Int
        var bitDepth: Int
        var codecHeader: String?

        enum CodingKeys: String, CodingKey {
            case codec, channels
            case sampleRate = "sample_rate"
            case bitDepth = "bit_depth"
            case codecHeader = "codec_header"
        }
    }

    var source: Source
}

struct ClientPairInitMessage: Encodable {
    var pairingIndex: Int
    /// The commitment to nonce_B, in the Dynamic Pairing Code flow.
    var commitB: String?

    enum CodingKeys: String, CodingKey {
        case pairingIndex = "pairing_index"
        case commitB = "commit_B"
    }
}

struct ClientPairAuthMessage: Encodable {
    /// This Mac's CPace share `Yb`.
    var pakeMsg2: String

    enum CodingKeys: String, CodingKey {
        case pakeMsg2 = "pake_msg_2"
    }
}

struct ClientPairConfirmMessage: Encodable {
    /// This Mac's confirmation tag `Tb`.
    var clientKC: String
    var wrappedNonceB: String

    enum CodingKeys: String, CodingKey {
        case clientKC = "client_kc"
        case wrappedNonceB = "wrapped_nonce_B"
    }
}

struct ClientPairPendingMessage: Encodable {
    var pairingIndex: Int
    var message: String?

    enum CodingKeys: String, CodingKey {
        case message
        case pairingIndex = "pairing_index"
    }
}

/// The new long-term PSK: plain in the Pairing PSK flow, wrapped in the code flows.
struct ClientPairFinalizeMessage: Encodable {
    /// base64url, 43 characters.
    var longTermPSK: String?
    /// base64url, 64 characters.
    var wrappedPSK: String?

    enum CodingKeys: String, CodingKey {
        case longTermPSK = "long_term_psk"
        case wrappedPSK = "wrapped_psk"
    }
}

struct ClientGoodbyeMessage: Encodable {
    var reason: String
}

struct EmptyPayload: Codable {}

/// Binary message type of source audio chunks (roles/source/v1.md).
enum SourceAudioChunk {
    static let messageType: UInt8 = 12

    /// What follows the type byte: the capture time of the first sample in the server's
    /// clock (big-endian µs), then the encoded audio.
    static func body(timestampUs: Int64, payload: Data) -> Data {
        var body = Data(capacity: 8 + payload.count)
        withUnsafeBytes(of: timestampUs.bigEndian) { body.append(contentsOf: $0) }
        body.append(payload)
        return body
    }
}
