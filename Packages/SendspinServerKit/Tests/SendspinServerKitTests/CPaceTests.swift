import CryptoKit
import Foundation
import Testing
@testable import SendspinServerKit

/// CPACE-X25519-SHA512 against the draft's G_25519 test vectors (as shipped with the `cpace`
/// Python package aiosendspin uses).
struct CPaceTests {
    private static func hex(_ string: String) -> Data {
        var data = Data()
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            data.append(UInt8(string[index..<next], radix: 16)!)
            index = next
        }
        return data
    }

    private let prs = hex("50617373776F7264")
    private let ci = hex("0B415F696E69746961746F720B425F726573706F6E646572")
    private let sid = hex("7E4B4791D6A8EF019B936C79FB7F2C57")
    private let g = hex("D04BF6D41F6A289632A2E929FA29BEBD51092512A7829FDDE7D314B62F05A73F")
    private let ya = hex("21B4F4BD9E64ED355C3EB676A28EBEDAF6D8F17BDC365995B319097153044080")
    private let adA = hex("414461")
    private let bigYa = hex("1D13C89278CDADD826F6D8D7F887701430F8380DDC17611CDD6DC989CE0C9F32")
    private let yb = hex("848B0779FF415F0AF4EA14DF9DD1D3C29AC41D836C7808896C4EBA19C51AC40A")
    private let adB = hex("414462")
    private let bigYb = hex("248CCCF6D5CDC3646F0AD593F9E6CEF4E69D4945F8372E623512ECEA32185623")
    private let k = hex("5B067EFFBDC0B2A0E1D907B21EBB25CFEDB96A852179A847C37E43EE71322C6B")
    private let iskIR = hex("6E19B875F7A561D6B3CA3DBB9EF42AC55DE3E717881018204B8922B4D5E53BB2"
                            + "AA82C300BEA7B65D2B671DA71922DDF6472301B79BC270ADFA8BF413285F2263")

    @Test func generator() {
        #expect(CPace.generator(prs: prs, ci: ci, sid: sid) == g)
    }

    @Test func publicSharesAndSharedSecret() {
        #expect(CPace.scalarMult(ya, g) == bigYa)
        #expect(CPace.scalarMult(yb, g) == bigYb)
        #expect(CPace.scalarMult(ya, bigYb) == k)
        #expect(CPace.scalarMult(yb, bigYa) == k)
    }

    @Test func bothSidesDeriveTheISKAndConfirmEachOther() throws {
        var initiator = try CPace(role: .initiator, sid: sid, ad: adA, scalar: ya, generator: g)
        var responder = try CPace(role: .responder, sid: sid, ad: adB, scalar: yb, generator: g)
        #expect(initiator.publicShare == bigYa)
        #expect(responder.publicShare == bigYb)
        try initiator.derive(peerShare: bigYb, peerAD: adB)
        try responder.derive(peerShare: bigYa, peerAD: adA)
        #expect(initiator.isk == iskIR)
        #expect(responder.isk == iskIR)
        let ta = try #require(initiator.tag()), tb = try #require(responder.tag())
        #expect(ta != tb)
        #expect(responder.verify(peerTag: ta))
        #expect(initiator.verify(peerTag: tb))
        #expect(!responder.verify(peerTag: tb))
    }

    @Test func wrongPasswordFailsConfirmation() throws {
        let sid = Data(repeating: 0x11, count: 16)
        var initiator = try CPace(role: .initiator, prs: Data("123456".utf8), sid: sid, ad: Data("server".utf8))
        var responder = try CPace(role: .responder, prs: Data("123457".utf8), sid: sid, ad: Data("client".utf8))
        try initiator.derive(peerShare: responder.publicShare, peerAD: Data("client".utf8))
        try responder.derive(peerShare: initiator.publicShare, peerAD: Data("server".utf8))
        #expect(initiator.isk != responder.isk)
        #expect(!responder.verify(peerTag: try #require(initiator.tag())))
    }

    /// The draft's low-order points: u0–u5 and u7 must abort; u6, u8–u11 are low order only
    /// if bit 255 isn't cleared, and must give these results instead.
    @Test func lowOrderPoints() {
        let scalar = Self.hex("af46e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449aff")
        let aborting = [
            "0000000000000000000000000000000000000000000000000000000000000000",
            "0100000000000000000000000000000000000000000000000000000000000000",
            "ECFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF7F",
            "E0EB7A7C3B41B8AE1656E3FAF19FC46ADA098DEB9C32B1FD866205165F49B800",
            "5F9C95BCA3508C24B1D0B1559C83EF5B04445CC4581C8E86D8224EDDD09F1157",
            "EDFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF7F",
            "EEFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF7F",
        ]
        for point in aborting {
            #expect(CPace.scalarMult(scalar, Self.hex(point)) == nil, "\(point)")
        }
        let clearedBit255 = [
            ("DAFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF",
             "d8e2c776bbacd510d09fd9278b7edcd25fc5ae9adfba3b6e040e8d3b71b21806"),
            ("DBFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF",
             "c85c655ebe8be44ba9c0ffde69f2fe10194458d137f09bbff725ce58803cdb38"),
            ("D9FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF",
             "db64dafa9b8fdd136914e61461935fe92aa372cb056314e1231bc4ec12417456"),
            ("CDEB7A7C3B41B8AE1656E3FAF19FC46ADA098DEB9C32B1FD866205165F49B880",
             "e062dcd5376d58297be2618c7498f55baa07d7e03184e8aada20bca28888bf7a"),
            ("4C9C95BCA3508C24B1D0B1559C83EF5B04445CC4581C8E86D8224EDDD09F11D7",
             "993c6ad11c4c29da9a56f7691fd0ff8d732e49de6250b6c2e80003ff4629a175"),
        ]
        for (point, expected) in clearedBit255 {
            #expect(CPace.scalarMult(scalar, Self.hex(point)) == Self.hex(expected), "\(point)")
        }
    }

    @Test func fieldArithmetic() {
        let x = FieldElement(littleEndian: Data((1...32).map { UInt8($0) }))
        #expect(x * x.inverse == .one)
        #expect(x - x == .zero)
        #expect(-(-x) == x)
        #expect(FieldElement.zero.inverse == .zero)
    }
}
