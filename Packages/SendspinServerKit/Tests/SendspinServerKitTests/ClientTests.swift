import CryptoKit
import Foundation
import Testing
@testable import SendspinServerKit

struct NoiseResponderTests {
    /// Our initiator (the server's side) and responder (the client's) agree on the keys.
    @Test(arguments: NoiseSuite.allCases)
    func handshakesWithTheInitiator(_ suite: NoiseSuite) throws {
        let server = Curve25519.KeyAgreement.PrivateKey()
        let client = Curve25519.KeyAgreement.PrivateKey()
        let prologue = Data("prologue".utf8)
        let psk = Data(repeating: 7, count: 32)
        var initiator = NoiseInitiatorHandshake(suite: suite, prologue: prologue, localStatic: server,
                                                remoteStatic: client.publicKey, psk: psk)
        var responder = NoiseResponderHandshake(suite: suite, prologue: prologue, localStatic: client,
                                                remoteStatic: server.publicKey)

        let message1 = try initiator.writeMessage1(payload: Data("one".utf8))
        #expect(try responder.readMessage1(message1) == Data("one".utf8))
        let (message2, clientTransport) = try responder.writeMessage2(payload: Data("{}".utf8), psk: psk)
        let (payload, serverTransport) = try initiator.readMessage2(message2)
        #expect(payload == Data("{}".utf8))
        #expect(clientTransport.handshakeHash == serverTransport.handshakeHash)

        var toClient = serverTransport, toServer = clientTransport
        #expect(try toServer.decrypt(toClient.encrypt(Data("hello client".utf8))) == Data("hello client".utf8))
        #expect(try toClient.decrypt(toServer.encrypt(Data("hello server".utf8))) == Data("hello server".utf8))
    }

    /// The wrong PSK fails at the server, which only learns it from message 2.
    @Test func wrongPSKFails() throws {
        let server = Curve25519.KeyAgreement.PrivateKey()
        let client = Curve25519.KeyAgreement.PrivateKey()
        var initiator = NoiseInitiatorHandshake(suite: .chaChaPoly, prologue: Data(), localStatic: server,
                                                remoteStatic: client.publicKey, psk: SendspinPSK.sentinel)
        var responder = NoiseResponderHandshake(suite: .chaChaPoly, prologue: Data(), localStatic: client,
                                                remoteStatic: server.publicKey)
        _ = try responder.readMessage1(try initiator.writeMessage1(payload: Data()))
        let (message2, _) = try responder.writeMessage2(payload: Data("{}".utf8), psk: Data(repeating: 1, count: 32))
        #expect(throws: NoiseError.self) { try initiator.readMessage2(message2) }
    }
}

struct PairingTokenTests {
    /// The reference vector in pairing.md, Pairing PSK Flow.
    @Test func matchesSpecVector() {
        let token = PairingToken.encode(clientKey: Data(0x00...0x1F), pairingPSK: Data(0xE0...0xFF))
        #expect(token == "SP:0AAAQEAYEAUDAOCAJBIFQYDIOB4IBCEQTCQKRMFYYDENBWHA5DYP6BYPC4PSOLZXH5DU6V97M5XXO74HR6LZ7J5PW674PT6X37T6757Y")
    }
}

struct TimeFilterTests {
    /// A server clock 5 s ahead and 20 ppm fast, measured with ±1 ms of symmetric jitter.
    @Test func convergesOnOffsetAndDrift() {
        var filter = TimeFilter()
        var random = SystemRandomNumberGenerator()
        let offset: Int64 = 5_000_000
        let drift = 20e-6
        for i in 1...400 {
            let client = Int64(i) * 1_000_000
            let server = client + offset + Int64(Double(client) * drift)
            let jitter = Int64.random(in: -1_000...1_000, using: &random)
            filter.update(measurement: server - client + jitter, maxError: 2_000, timeAdded: client)
        }
        let client: Int64 = 400_500_000
        let truth = client + offset + Int64(Double(client) * drift)
        #expect(abs(filter.serverTime(fromClient: client) - truth) < 500)
        #expect(abs(filter.clientTime(fromServer: truth) - client) < 500)
    }

    @Test func skipsNonMonotonicAndNonPositiveSamples() {
        var filter = TimeFilter()
        filter.update(measurement: 100, maxError: 10, timeAdded: 1_000)
        filter.update(measurement: 900, maxError: 10, timeAdded: 1_000)
        filter.update(measurement: 900, maxError: 0, timeAdded: 2_000)
        #expect(filter.count == 1)
        #expect(filter.serverTime(fromClient: 5_000) == 5_100)
    }
}

struct SourceCredentialsTests {
    /// At capacity the least recently used record goes, but never one backing an open connection.
    @Test func evictsTheLeastRecentlyUsedRecordNotInUse() {
        var credentials = SourceCredentials.generate()
        for i in 0..<SourceCredentials.recordCapacity {
            credentials.store(serverID: "server\(i)", psk: Data(repeating: UInt8(i), count: 32), keeping: [])
            credentials.records[i].lastUsed = Date(timeIntervalSince1970: TimeInterval(i))
        }
        credentials.store(serverID: "new", psk: Data(repeating: 9, count: 32), keeping: ["server0"])
        let servers = Set(credentials.records.map(\.serverID))
        #expect(credentials.records.count == SourceCredentials.recordCapacity)
        #expect(servers.contains("server0"))  // the oldest, but in use
        #expect(!servers.contains("server1"))  // the oldest not in use
        #expect(servers.contains("new"))
    }

    @Test func storingAgainReplacesTheServersRecord() {
        var credentials = SourceCredentials.generate()
        credentials.store(serverID: "server", psk: Data(repeating: 1, count: 32), keeping: [])
        credentials.store(serverID: "server", psk: Data(repeating: 2, count: 32), keeping: [])
        #expect(credentials.records.count == 1)
        #expect(credentials.record(pskID: SendspinPSK.id(for: Data(repeating: 2, count: 32)))?.serverID == "server")
        #expect(credentials.record(pskID: SendspinPSK.id(for: Data(repeating: 1, count: 32))) == nil)
    }

    @Test func tokenCarriesTheIdentity() {
        let credentials = SourceCredentials.generate()
        #expect(credentials.pairingToken.hasPrefix("SP:0"))
        #expect(credentials.clientID.count == 43)
    }
}
