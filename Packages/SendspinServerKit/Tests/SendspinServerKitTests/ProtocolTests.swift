import CryptoKit
import Foundation
import Testing
@testable import SendspinServerKit

struct AudioFrameTests {
    @Test func headerCarriesTimestampAndSendAhead() {
        let frame = AudioFrame.pack(timestampUs: 0x0102_0304_0506_0708, sendAheadUs: 0x0A0B_0C0D,
                                    payload: Data([0xAA]))
        #expect(Array(frame) == [4, 1, 2, 3, 4, 5, 6, 7, 8, 0x0A, 0x0B, 0x0C, 0x0D, 0xAA])
    }

    /// Late chunks report 0, leads beyond the field report UInt32.max (player/v1.md).
    @Test func sendAheadSaturates() {
        let late = AudioFrame.pack(timestampUs: 0, sendAheadUs: -5, payload: Data())
        #expect(Array(late.suffix(4)) == [0, 0, 0, 0])
        let huge = AudioFrame.pack(timestampUs: 0, sendAheadUs: Int64(UInt32.max) + 10, payload: Data())
        #expect(Array(huge.suffix(4)) == [0xFF, 0xFF, 0xFF, 0xFF])
    }
}

struct MessageTests {
    /// client/hello as sent by an HA Connect AUX-2 (firmware 2026.10.2), probed on the Sentinel PSK.
    static let aux2Hello = Data("""
        {"type":"client/hello","payload":{"name":"Home Assistant Connect AUX-2 170280",
        "device_info":{"product_name":"Home Assistant Connect AUX-2","manufacturer":"Nabu Casa",
        "software_version":"2026.10.2","mac_address":"20:f8:3b:17:02:83"},
        "supported_pair_methods":{"pairing_psk":{}},"unpaired_access":{"enabled":true},
        "supported_roles":["player@v1","controller@v1"],
        "player@v1_support":{"supported_formats":[
        {"codec":"flac","channels":2,"sample_rate":48000,"bit_depth":16},
        {"codec":"flac","channels":1,"sample_rate":48000,"bit_depth":16},
        {"codec":"pcm","channels":2,"sample_rate":48000,"bit_depth":16},
        {"codec":"pcm","channels":1,"sample_rate":48000,"bit_depth":16}],
        "buffer_capacity":621312}}}
        """.utf8)

    @Test func decodesAux2Hello() throws {
        #expect(try MessageCoding.type(of: Self.aux2Hello) == "client/hello")
        let hello = try MessageCoding.payload(ClientHello.self, from: Self.aux2Hello)
        #expect(hello.name == "Home Assistant Connect AUX-2 170280")
        #expect(hello.supportedRoles.contains("player@v1"))
        #expect(hello.unpairedAccess?.enabled == true)
        #expect(hello.playerSupport?.bufferCapacity == 621312)
        #expect(hello.playerSupport?.supportedFormats[2]
            == AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48000, bitDepth: 16))
    }

    @Test func decodesClientInit() throws {
        let data = Data(#"{"type":"client/init","payload":{"client_id":"zlv4WNt6J7ohdTFO5SoA_6Y-Xe4uPSHsNT3lXmhS91A","version":1,"suite":"25519_ChaChaPoly_SHA256"}}"#.utf8)
        let clientInit = try MessageCoding.payload(ClientInit.self, from: data)
        #expect(clientInit.version == 1)
        #expect(NoiseSuite(rawValue: clientInit.suite) == .chaChaPoly)
        #expect(Base64URL.decode(clientInit.clientID)?.count == 32)
    }

    /// Version first, then suite, then the rest (connection.md, Failure Handling).
    @Test(arguments: [
        (#"{"type":"client/init","payload":{"version":2}}"#, ClientInit.Failure.unsupportedVersion),
        (#"{"type":"client/init","payload":{"version":2,"suite":7}}"#, .unsupportedVersion),
        (#"{"type":"client/init","payload":{"version":"1","suite":"25519_ChaChaPoly_SHA256"}}"#, .malformed),
        (#"{"type":"client/init","payload":{"suite":"25519_ChaChaPoly_SHA256"}}"#, .malformed),
        (#"{"type":"client/init","payload":{"version":1,"suite":"448_ChaChaPoly_BLAKE2b"}}"#, .unsupportedSuite),
        (#"{"type":"client/init","payload":{"version":1,"suite":"25519_AESGCM_SHA256"}}"#, .malformed),
        (#"{"type":"client/hello","payload":{"version":1}}"#, .malformed),
        ("not json", .malformed),
    ])
    func rejectsClientInit(json: String, failure: ClientInit.Failure) {
        #expect(throws: failure) { try ClientInit.parse(Data(json.utf8)) }
    }

    @Test func acceptsClientInit() throws {
        let data = Data(#"{"type":"client/init","payload":{"client_id":"zlv4WNt6J7ohdTFO5SoA_6Y-Xe4uPSHsNT3lXmhS91A","version":1,"suite":"25519_AESGCM_SHA256"}}"#.utf8)
        let (clientInit, suite) = try ClientInit.parse(data)
        #expect(suite == .aesGCM)
        #expect(clientInit.clientID == "zlv4WNt6J7ohdTFO5SoA_6Y-Xe4uPSHsNT3lXmhS91A")
    }

    @Test func decodesPlayerState() throws {
        let data = Data(#"{"type":"client/state","payload":{"available":true,"player":{"volume":40,"muted":false,"output_delay_ms":0,"required_lead_time_ms":120,"min_buffer_ms":200,"supported_commands":["volume","mute"]}}}"#.utf8)
        let state = try MessageCoding.payload(ClientState.self, from: data)
        #expect(state.available)
        #expect(state.player?.volume == 40)
        #expect(state.player?.minBufferMs == 200)
        #expect(state.player?.supportedCommands == ["volume", "mute"])
    }

    @Test func encodesActivation() throws {
        let json = try MessageCoding.encode(type: "server/activate",
                                            payload: ServerActivate(activities: ["playback"], activeRoles: ["player@v1"]))
        let object = try JSONSerialization.jsonObject(with: json) as? NSDictionary
        #expect(object == ["type": "server/activate",
                           "payload": ["activities": ["playback"], "active_roles": ["player@v1"]]])
    }

    @Test func encodesStreamStartWithTransmitTime() throws {
        let json = try MessageCoding.encode(type: "stream/start", payload: StreamStart(
            serverTransmitted: 42, player: StreamStartPlayer(codec: "pcm", sampleRate: 48000, channels: 2, bitDepth: 16)))
        let object = try JSONSerialization.jsonObject(with: json) as? NSDictionary
        #expect(object == ["type": "stream/start", "payload": [
            "server_transmitted": 42,
            "player": ["codec": "pcm", "sample_rate": 48000, "channels": 2, "bit_depth": 16]]])
    }

    @Test func omitsNilCommandFields() throws {
        let json = try MessageCoding.encode(type: "server/command", payload: ServerCommand(player: .volume(30)))
        let object = try JSONSerialization.jsonObject(with: json) as? NSDictionary
        #expect(object == ["type": "server/command", "payload": ["player": ["command": "volume", "volume": 30]]])
    }
}

struct SecureChannelTests {
    /// A server channel and the matching client-side transport, sharing two keys.
    static func pair() -> (server: SecureChannel, client: NoiseTransport) {
        let up = SymmetricKey(size: .bits256), down = SymmetricKey(size: .bits256)
        let server = NoiseTransport(send: CipherState(suite: .chaChaPoly, key: down),
                                    receive: CipherState(suite: .chaChaPoly, key: up), handshakeHash: Data())
        let client = NoiseTransport(send: CipherState(suite: .chaChaPoly, key: up),
                                    receive: CipherState(suite: .chaChaPoly, key: down), handshakeHash: Data())
        return (SecureChannel(transport: server), client)
    }

    @Test func roundTripsJSON() throws {
        var (server, client) = Self.pair()
        let json = Data(#"{"type":"server/hello","payload":{"name":"Mac"}}"#.utf8)
        let sealed = try server.sealJSON(json)
        #expect(sealed.count == 1)
        #expect(try client.decrypt(sealed[0]) == Data([0]) + json)

        let reply = try client.encrypt(Data([0]) + json)
        let opened = try #require(try server.open(reply))
        #expect(opened.type == 0 && opened.payload == json)
    }

    /// Over 65518 bytes of payload is split into fragments: [1][flags][orig_type][data], then [1][flags][data].
    @Test func fragmentsLargeMessages() throws {
        var (server, client) = Self.pair()
        let payload = Data((0..<150_000).map { UInt8(truncatingIfNeeded: $0) })
        let sealed = try server.seal(type: 4, payload: payload)
        #expect(sealed.count == 3)
        var reassembled = Data()
        for (index, message) in sealed.enumerated() {
            let plaintext = try client.decrypt(message)
            #expect(plaintext.count <= NoiseTransport.maxPlaintextSize)
            #expect(plaintext[0] == 1)
            let first = index == 0, last = index == sealed.count - 1
            #expect(plaintext[1] == (first ? 0b10 : 0) | (last ? 0b01 : 0))
            reassembled.append(plaintext.dropFirst(first ? 3 : 2))
            if first { #expect(plaintext[2] == 4) }
        }
        #expect(reassembled == payload)
    }

    @Test func reassemblesIncomingFragments() throws {
        var (server, client) = Self.pair()
        let parts = [Data([1, 0b10, 0]) + Data("{\"type\":".utf8),
                     Data([1, 0]) + Data("\"client/state\",".utf8),
                     Data([1, 0b01]) + Data("\"payload\":{}}".utf8)]
        #expect(try server.open(client.encrypt(parts[0])) == nil)
        #expect(try server.open(client.encrypt(parts[1])) == nil)
        let message = try #require(try server.open(client.encrypt(parts[2])))
        #expect(message.type == 0)
        #expect(String(decoding: message.payload, as: UTF8.self) == #"{"type":"client/state","payload":{}}"#)
    }

    @Test func rejectsMalformedFragmentSequences() throws {
        var (server, client) = Self.pair()
        // A continuation with no first fragment.
        #expect(throws: (any Error).self) { try server.open(client.encrypt(Data([1, 0b01, 0x41]))) }

        (server, client) = Self.pair()
        // A regular message while a fragmented one is in flight.
        _ = try server.open(client.encrypt(Data([1, 0b10, 0, 0x41])))
        #expect(throws: (any Error).self) { try server.open(client.encrypt(Data([0, 0x41]))) }

        (server, client) = Self.pair()
        // Reserved flag bits.
        #expect(throws: (any Error).self) { try server.open(client.encrypt(Data([1, 0b111, 0, 0x41]))) }
    }
}

struct PlayerBufferAccountTests {
    /// Capacity 1000 bytes; returns whether each chunk was admitted.
    private func admits(_ chunks: [(bytes: Int, endUs: Int64, nowUs: Int64, delayUs: Int64)]) -> [Bool] {
        var buffer = PlayerBufferAccount()
        return chunks.map {
            buffer.admit(bytes: $0.bytes, endUs: $0.endUs, nowUs: $0.nowUs, outputDelayUs: $0.delayUs, capacity: 1_000)
        }
    }

    @Test func countsChunksUntilTheirCompletionTime() {
        // The second doesn't fit next to the first; at 1000 the first has completed.
        #expect(admits([(600, 1_000, 0, 0), (600, 2_000, 0, 0), (600, 2_000, 1_000, 0)]) == [true, false, true])
    }

    @Test func outputDelayMovesCompletionEarlier() {
        // With 500 µs of output delay the first chunk completes at 500.
        #expect(admits([(600, 1_000, 0, 0), (600, 2_000, 600, 500)]) == [true, true])
    }

    @Test func lowerOutputDelayCountsChunksAgain() {
        // Back to no delay at 700: the first chunk (completing at 1000) counts again.
        #expect(admits([(600, 1_000, 0, 0), (300, 2_000, 600, 500), (300, 3_000, 700, 0)]) == [true, true, false])
    }
}
