import Foundation

/// Sendspin messages over Noise transport mode (messaging.md, Communication): each binary
/// WebSocket message carries one Noise transport message, whose first plaintext byte is
/// the message type. Type 0 is a JSON message, type 1 a fragment of a larger message.
struct SecureChannel {
    enum ChannelError: Error, CustomStringConvertible {
        case malformedFragment(String)

        var description: String {
            switch self {
            case .malformedFragment(let detail): "malformed fragment sequence: \(detail)"
            }
        }
    }

    static let jsonType: UInt8 = 0
    static let fragmentType: UInt8 = 1

    private var transport: NoiseTransport
    private var reassembly: (type: UInt8, data: Data)?

    init(transport: NoiseTransport) {
        self.transport = transport
    }

    var handshakeHash: Data { transport.handshakeHash }

    /// Encrypt one message of `type`; one ciphertext unless it needs fragmenting.
    mutating func seal(type: UInt8, payload: Data) throws -> [Data] {
        let limit = NoiseTransport.maxPlaintextSize
        if 1 + payload.count <= limit {
            return [try transport.encrypt(Data([type]) + payload)]
        }
        // [1][flags][orig_type][data], then [1][flags][data]: bit 1 marks the first, bit 0 the last.
        var messages: [Data] = []
        var offset = payload.startIndex
        var first = true
        while offset < payload.endIndex {
            let room = limit - (first ? 3 : 2)
            let end = payload.index(offset, offsetBy: room, limitedBy: payload.endIndex) ?? payload.endIndex
            let last = end == payload.endIndex
            var plaintext = Data([Self.fragmentType, (first ? 0b10 : 0) | (last ? 0b01 : 0)])
            if first { plaintext.append(type) }
            plaintext.append(payload[offset..<end])
            messages.append(try transport.encrypt(plaintext))
            offset = end
            first = false
        }
        return messages
    }

    mutating func sealJSON(_ json: Data) throws -> [Data] {
        try seal(type: Self.jsonType, payload: json)
    }

    /// Decrypt one binary message. Returns the complete message, or nil while a
    /// fragmented one is still incomplete. Throws on a decryption failure or a malformed
    /// fragment sequence; both mean the connection must close.
    mutating func open(_ ciphertext: Data) throws -> (type: UInt8, payload: Data)? {
        let plaintext = try transport.decrypt(ciphertext)
        guard let type = plaintext.first else { throw NoiseError.invalidMessage }
        let body = plaintext.dropFirst()
        guard type == Self.fragmentType else {
            guard reassembly == nil else { throw ChannelError.malformedFragment("message inside a fragment sequence") }
            return (type, Data(body))
        }
        guard let flags = body.first else { throw ChannelError.malformedFragment("no flags") }
        guard flags & ~0b11 == 0 else { throw ChannelError.malformedFragment("reserved flag bits") }
        var data = body.dropFirst()
        if flags & 0b10 != 0 {
            guard reassembly == nil else { throw ChannelError.malformedFragment("first fragment while one is in flight") }
            guard let originalType = data.first else { throw ChannelError.malformedFragment("no orig_type") }
            guard originalType != Self.fragmentType else { throw ChannelError.malformedFragment("orig_type 1") }
            data = data.dropFirst()
            reassembly = (originalType, Data())
        } else if reassembly == nil {
            throw ChannelError.malformedFragment("continuation without a first fragment")
        }
        reassembly!.data.append(data)
        guard flags & 0b01 != 0, let complete = reassembly else { return nil }
        reassembly = nil
        return (complete.type, complete.data)
    }
}
