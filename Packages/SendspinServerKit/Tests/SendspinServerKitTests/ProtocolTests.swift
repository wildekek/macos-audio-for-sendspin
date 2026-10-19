import Foundation
import Testing
@testable import SendspinServerKit

struct AudioFrameTests {
    @Test func legacyHeaderIsNineBytes() {
        let frame = AudioFrame.pack(timestampUs: 0x0102_0304_0506_0708, sendAheadUs: nil, payload: Data([0xAA]))
        #expect(Array(frame) == [4, 1, 2, 3, 4, 5, 6, 7, 8, 0xAA])
    }

    @Test func specHeaderAppendsSendAhead() {
        let frame = AudioFrame.pack(timestampUs: 1, sendAheadUs: 0x0102_0304, payload: Data())
        #expect(Array(frame) == [4, 0, 0, 0, 0, 0, 0, 0, 1, 1, 2, 3, 4])
    }

    @Test func sendAheadClampsToUInt32() {
        let negative = AudioFrame.pack(timestampUs: 0, sendAheadUs: -5, payload: Data())
        #expect(Array(negative.suffix(4)) == [0, 0, 0, 0])
        let huge = AudioFrame.pack(timestampUs: 0, sendAheadUs: Int64(UInt32.max) + 10, payload: Data())
        #expect(Array(huge.suffix(4)) == [0xFF, 0xFF, 0xFF, 0xFF])
    }
}

struct MessageTests {
    /// client/hello as sent by an HA Connect AUX-2 (firmware 2026.10.1, legacy protocol).
    static let aux2Hello = Data("""
        {"type":"client/hello","payload":{"client_id":"20:F8:3B:17:02:83",
        "name":"Home Assistant Connect AUX-2 170280","version":1,
        "supported_roles":["player@v1","controller@v1"],
        "device_info":{"product_name":"Home Assistant Connect AUX-2","manufacturer":"Nabu Casa",
        "software_version":"2026.10.1","mac_address":"20:f8:3b:17:02:80"},
        "player@v1_support":{"supported_formats":[
        {"codec":"flac","channels":2,"sample_rate":48000,"bit_depth":16},
        {"codec":"pcm","channels":2,"sample_rate":48000,"bit_depth":16}],
        "buffer_capacity":800000,"supported_commands":["volume","mute"]}}}
        """.utf8)

    @Test func decodesLegacyHello() throws {
        #expect(try MessageCoding.type(of: Self.aux2Hello) == "client/hello")
        let hello = try MessageCoding.payload(ClientHello.self, from: Self.aux2Hello)
        #expect(hello.clientID == "20:F8:3B:17:02:83")
        #expect(hello.supportedRoles.contains("player@v1"))
        #expect(hello.playerSupport?.supportedFormats.count == 2)
        #expect(hello.playerSupport?.supportedFormats[1]
            == AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48000, bitDepth: 16))
    }

    @Test func decodesUnversionedPlayerSupportKey() throws {
        let data = Data("""
            {"type":"client/hello","payload":{"name":"Old","supported_roles":["player@v1"],
            "player_support":{"supported_formats":[]}}}
            """.utf8)
        let hello = try MessageCoding.payload(ClientHello.self, from: data)
        #expect(hello.playerSupport != nil)
    }

    @Test func clientStateAvailability() throws {
        func state(_ json: String) throws -> ClientState {
            try MessageCoding.payload(ClientState.self, from: Data(json.utf8))
        }
        #expect(try state(#"{"type":"client/state","payload":{"state":"synchronized"}}"#).isAvailable)
        #expect(try !state(#"{"type":"client/state","payload":{"state":"external_source"}}"#).isAvailable)
        let error = try state(#"{"type":"client/state","payload":{"state":"error"}}"#)
        #expect(error.isAvailable && error.reportsError)
        #expect(try !state(#"{"type":"client/state","payload":{"available":false}}"#).isAvailable)
        let legacy = try state(#"{"type":"client/state","payload":{"state":"synchronized","player":{"volume":40,"muted":true,"static_delay_ms":0}}}"#)
        #expect(legacy.player?.volume == 40)
        #expect(legacy.player?.muted == true)
    }

    @Test func encodesServerHello() throws {
        let json = try MessageCoding.encode(type: "server/hello", payload: LegacyServerHello(
            serverID: "id", name: "Bridge", connectionReason: "playback", activeRoles: ["player@v1"]))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["type"] as? String == "server/hello")
        let payload = try #require(object["payload"] as? [String: Any])
        #expect(payload["server_id"] as? String == "id")
        #expect(payload["version"] as? Int == 1)
        #expect(payload["connection_reason"] as? String == "playback")
        #expect(payload["active_roles"] as? [String] == ["player@v1"])
    }

    @Test func omitsNilCommandFields() throws {
        let json = try MessageCoding.encode(type: "server/command", payload: ServerCommand(player: .volume(30)))
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary
        #expect(object == ["type": "server/command", "payload": ["player": ["command": "volume", "volume": 30]]])
    }
}
