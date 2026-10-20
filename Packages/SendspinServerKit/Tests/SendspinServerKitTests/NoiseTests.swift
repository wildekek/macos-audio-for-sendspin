import CryptoKit
import Foundation
import Testing
@testable import SendspinServerKit

/// Reference vectors from the `noiseprotocol` Python library (the one aiosendspin uses),
/// with fixed static and ephemeral keys so the handshake is deterministic.
struct NoiseVectorTests {
    struct Vector: Sendable, CustomTestStringConvertible {
        var suite: NoiseSuite
        var message1: String
        var message2: String
        var handshakeHash: String
        var serverTransport0: String
        var clientTransport0: String
        var serverTransport1: String

        var testDescription: String { suite.rawValue }
    }

    static let vectors = [
        Vector(
            suite: .chaChaPoly,
            message1: "79a631eede1bf9c98f12032cdeadd0e7a079398fc786b88cc846ec89af85a51a29745dec00fc92d610f74ede3b303cead9c3fed1271214c3f97c9f632ef2ff6db6c67e873149918adac627b1082a0d9d76fb1a554f00e3afb7a3cfeda895162a8e57cbb314dae65780c9a994c2be7605be3e0ccb8923b7218c2c81e2",
            message2: "675dd574ed7789310b3d2e7681f3790b466c773b1521fecf36577958371ea52f56b9f11dc36c2151d58b02ffeffcbe80d41e",
            handshakeHash: "a370b94e8723d84b91c0c0c4ca3808c36ca1aa740bd26791598e308b5cc93bcf",
            serverTransport0: "9a6e88d778e190f516c6b82d596651e8488d89481520d23fba62ddf96df123aae96220b0fe4ef2f1bf9ed68de0d7c8e31e0e7bd75cce87c2787365c827af2d0efc6f",
            clientTransport0: "815b13b98ad625d97aee37345c544fde05ab707c28c63b380eb9e38ff4dc3802b76b8bea1e27d63265e84395bbc6f4fa6ccfadce0e",
            serverTransport1: "7e13a7fc1dd4050eb277b9ae3445ec4e8a9a67a30a97198eb63c41a9996a1e6fd772a8e7bc407601649e692bf8464947350f6dcde1103851f60e70400626e059f52a"),
        Vector(
            suite: .aesGCM,
            message1: "79a631eede1bf9c98f12032cdeadd0e7a079398fc786b88cc846ec89af85a51a03d850b20dd9947dac6ff9ade2250c718109aa3468a3d808a31ec448be41a4dfbc43f58971f69a7f754d75b46b31f7eb344b57acee7cdf7abab65077ca11bf8b75d1f1d54e86383d48f0936558310e6d4a9ce5570637db924f7f300b",
            message2: "675dd574ed7789310b3d2e7681f3790b466c773b1521fecf36577958371ea52f78af43e41a141e0eb397a5194d0233dd874e",
            handshakeHash: "79222c51d48a776da09b34dcaf1439e95817c423b5f1312e8251066958366898",
            serverTransport0: "8f92dcb2e5ee8949c484faab64059e16e5e738d3e15f9e631f2b2fff61e7c0b9bcc1432c796ddd99022a4fb2852fd72481d2c7db726c6885efc520721e9d66db2f8a",
            clientTransport0: "9ee35d78813792a5d5cef01eb5c05e2ba4cc2685e7fab170dea172781116265a2dd1b94e626665b666c2a74e37567c0491f3f82ec5",
            serverTransport1: "7259525a0a1879dfd9bb5e7aaf68d8370a41562af07d9e32367f2bb7c97a51077faa16eaa33daf97c18e244753489664a07385bb936f804d66b7252b5a0ac0623254"),
    ]

    static let serverStatic = Data(0x00..<0x20)
    static let clientStatic = Data(0x20..<0x40)
    static let serverEphemeral = Data(0x40..<0x60)
    static let prologue = Data(#"{"type":"client/init"}{"type":"server/init"}"#.utf8)
    static let payload1 = Data(#"{"psk_id":"GFsV9tLaSQm9HcFWpKsgYQOr7wFTvNUtkmFwuVz3zoo","psk_category":"sn"}"#.utf8)
    static let serverHello = Data([0]) + Data(#"{"type":"server/hello","payload":{"name":"Test"}}"#.utf8)
    static let clientHello = Data([0]) + Data(#"{"type":"client/hello","payload":{}}"#.utf8)

    @Test(arguments: vectors)
    func handshakeAndTransportMatchReference(_ vector: Vector) throws {
        let clientPublic = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Self.clientStatic).publicKey
        var handshake = NoiseInitiatorHandshake(
            suite: vector.suite, prologue: Self.prologue,
            localStatic: try .init(rawRepresentation: Self.serverStatic), remoteStatic: clientPublic,
            psk: SendspinPSK.sentinel, ephemeral: try .init(rawRepresentation: Self.serverEphemeral))

        #expect(try handshake.writeMessage1(payload: Self.payload1).hex == vector.message1)
        let (payload, transport) = try handshake.readMessage2(Data(hex: vector.message2))
        #expect(payload == Data("{}".utf8))
        #expect(transport.handshakeHash.hex == vector.handshakeHash)

        var channel = transport
        #expect(try channel.encrypt(Self.serverHello).hex == vector.serverTransport0)
        #expect(try channel.decrypt(Data(hex: vector.clientTransport0)) == Self.clientHello)
        #expect(try channel.encrypt(Self.serverHello).hex == vector.serverTransport1)
    }

    @Test func tamperedMessage2Fails() throws {
        let vector = Self.vectors[0]
        let clientPublic = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Self.clientStatic).publicKey
        var handshake = NoiseInitiatorHandshake(
            suite: vector.suite, prologue: Self.prologue,
            localStatic: try .init(rawRepresentation: Self.serverStatic), remoteStatic: clientPublic,
            psk: SendspinPSK.sentinel, ephemeral: try .init(rawRepresentation: Self.serverEphemeral))
        _ = try handshake.writeMessage1(payload: Self.payload1)
        var message2 = Data(hex: vector.message2)
        message2[message2.count - 1] ^= 1
        #expect(throws: NoiseError.self) { try handshake.readMessage2(message2) }
    }

    @Test func transportRejectsReplay() throws {
        let vector = Self.vectors[0]
        let clientPublic = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Self.clientStatic).publicKey
        var handshake = NoiseInitiatorHandshake(
            suite: vector.suite, prologue: Self.prologue,
            localStatic: try .init(rawRepresentation: Self.serverStatic), remoteStatic: clientPublic,
            psk: SendspinPSK.sentinel, ephemeral: try .init(rawRepresentation: Self.serverEphemeral))
        _ = try handshake.writeMessage1(payload: Self.payload1)
        var transport = try handshake.readMessage2(Data(hex: vector.message2)).transport
        let message = Data(hex: vector.clientTransport0)
        _ = try transport.decrypt(message)
        #expect(throws: NoiseError.self) { try transport.decrypt(message) }
    }
}

struct SendspinKeyTests {
    /// Published constants from the spec (connection.md, Pre-Shared Key).
    @Test func sentinelMatchesSpec() {
        #expect(SendspinPSK.sentinel.hex == "1b5e24dbc1aed95fc2a5a338a90c05df44bd10f5ec1f4cd66cbf86272767b9d3")
        #expect(SendspinPSK.id(for: SendspinPSK.sentinel) == "GFsV9tLaSQm9HcFWpKsgYQOr7wFTvNUtkmFwuVz3zoo")
    }

    @Test func base64URLRoundTripsWithoutPadding() throws {
        let key = Data(hex: "8f40c5adb68f25624ae5b214ea767a6ec94d829d3d7b5e1ad1ba6f3e2138285f")
        let encoded = Base64URL.encode(key)
        #expect(encoded.count == 43)
        #expect(!encoded.contains("="))
        #expect(Base64URL.decode(encoded) == key)
    }

    @Test func base64URLRejectsNonCanonicalInput() {
        #expect(Base64URL.decode("AB==") == nil)  // padding
        #expect(Base64URL.decode("AB+/") == nil)  // standard alphabet
        #expect(Base64URL.decode("AQ") == Data([0x01]))
        #expect(Base64URL.decode("AB") == nil)  // nonzero trailing bits
    }
}

extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
