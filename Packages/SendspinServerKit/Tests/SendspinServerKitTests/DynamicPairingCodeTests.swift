import Foundation
import Testing
@testable import SendspinServerKit

/// Checked against aiosendspin's helpers (`aiosendspin.noise.pairing_code`, and its wrapping)
/// with the same fixed inputs.
struct DynamicPairingCodeTests {
    private let h = Data(0..<32)
    private let nonceA = Data(32..<64)
    private let nonceB = Data(64..<96)

    private static func hex(_ string: String) -> Data {
        Data(stride(from: 0, to: string.count, by: 2).map { offset in
            let start = string.index(string.startIndex, offsetBy: offset)
            return UInt8(string[start..<string.index(start, offsetBy: 2)], radix: 16)!
        })
    }

    @Test func commitmentAndDigits() {
        #expect(DynamicPairingCode.commitment(to: nonceB)
                == Self.hex("f6d431646ea17a4488f6008d0da4dbd79b7c0a898c3631453fb6ffc912d29c18"))
        #expect(DynamicPairingCode.digits(handshakeHash: h, nonceA: nonceA, nonceB: nonceB) == "806729")
        #expect(DynamicPairingCode.presented("012345") == "012-345")
        // The qr_code format: the digest's first 24 bytes (aiosendspin's derive_qr_code).
        #expect(DynamicPairingCode.qrCode(handshakeHash: h, nonceA: nonceA, nonceB: nonceB)
                == Self.hex("9f26c48e69443b7fab8d1be2052017a0f69b4a1f0e49033d"))
    }

    @Test func sessionIDAndWrapping() throws {
        let sid = DynamicPairingCode.sessionID(handshakeHash: h, pairingIndex: 1, round: 2)
        #expect(sid == Data("sendspin-pair-pake-v1".utf8) + h + Data([0, 0, 0, 1, 0, 0, 0, 2]))
        let isk = Data(repeating: 0xAA, count: 64)
        #expect(try DynamicPairingCode.wrap(Data(repeating: 0x55, count: 32), .psk, sid: sid, isk: isk, suite: .chaChaPoly)
                == Self.hex("fb7207365ae8362b743ea230f1f32ee2c0548073764f9ba2a471b8b40b42641e"
                            + "8bb35a07716418fd833472bace9714ee"))
        #expect(try DynamicPairingCode.wrap(nonceB, .nonce, sid: sid, isk: isk, suite: .chaChaPoly)
                == Self.hex("15703718a09271455d53a7750193bde7e7ecc3ff0c20cb124c02069eb5798901"
                            + "1bbb99db443a1f0eac9639c7c417fc81"))
        // The server's side opens it again, and only with the same label, sid and ISK.
        let sealed = try DynamicPairingCode.wrap(nonceB, .nonce, sid: sid, isk: isk, suite: .chaChaPoly)
        #expect(try DynamicPairingCode.unwrap(sealed, .nonce, sid: sid, isk: isk, suite: .chaChaPoly) == nonceB)
        #expect(throws: (any Error).self) {
            try DynamicPairingCode.unwrap(sealed, .psk, sid: sid, isk: isk, suite: .chaChaPoly)
        }
    }
}
