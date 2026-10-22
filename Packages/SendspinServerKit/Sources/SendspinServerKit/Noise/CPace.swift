import CryptoKit
import Foundation

// CPACE-X25519-SHA512 (draft-irtf-cfrg-cpace-21), the PAKE of Sendspin's code-based pairing
// (pairing.md, PAKE): initiator-responder mode with explicit mutual confirmation. The server
// is the initiator (A), this Mac as a client the responder (B). Names follow the draft (PRS,
// sid, CI, AD, ISK) and the `cpace` Python package aiosendspin uses, whose test vectors
// the tests reproduce.

enum CPaceError: Error, CustomStringConvertible {
    case lowOrderPoint
    case badShareLength

    var description: String {
        switch self {
        case .lowOrderPoint: "CPace share encodes a low-order point"
        case .badShareLength: "CPace share isn't 32 bytes"
        }
    }
}

struct CPace {
    enum Role {
        case initiator, responder
    }

    static let shareSize = 32
    private static let dsi = Data("CPace255".utf8)
    private static let dsiISK = Data("CPace255_ISK".utf8)
    private static let macLabel = Data("CPaceMac".utf8)

    let role: Role
    let sid: Data
    let ad: Data
    /// This side's public share: `Ya` for the initiator, `Yb` for the responder.
    let publicShare: Data
    private let scalar: Data
    /// Set by `derive`.
    private(set) var isk: Data?
    private var macKey: Data?
    /// ((Ya, ADa), (Yb, ADb)), the initiator's first.
    private var sides: ((share: Data, ad: Data), (share: Data, ad: Data))?

    /// Begin a run: a fresh scalar, and the public share on the generator `prs` and `sid` give.
    init(role: Role, prs: Data, sid: Data, ci: Data = Data(), ad: Data) throws {
        try self.init(role: role, sid: sid, ad: ad, scalar: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) },
                      generator: Self.generator(prs: prs, ci: ci, sid: sid))
    }

    /// A run with a given scalar, for the test vectors.
    init(role: Role, sid: Data, ad: Data, scalar: Data, generator: Data) throws {
        guard let share = Self.scalarMult(scalar, generator) else { throw CPaceError.lowOrderPoint }
        self.role = role
        self.sid = sid
        self.ad = ad
        self.scalar = scalar
        publicShare = share
    }

    /// Take in the peer's share and associated data: derives the ISK and the confirmation key.
    mutating func derive(peerShare: Data, peerAD: Data) throws {
        guard peerShare.count == Self.shareSize else { throw CPaceError.badShareLength }
        guard let k = Self.scalarMult(scalar, peerShare) else { throw CPaceError.lowOrderPoint }
        let own = (share: publicShare, ad: ad), peer = (share: peerShare, ad: peerAD)
        let sides = role == .initiator ? (own, peer) : (peer, own)
        let transcript = Self.lvCat(sides.0.share, sides.0.ad) + Self.lvCat(sides.1.share, sides.1.ad)
        let isk = Data(SHA512.hash(data: Self.lvCat(Self.dsiISK, sid, k) + transcript))
        self.sides = sides
        self.isk = isk
        macKey = Data(SHA512.hash(data: Self.macLabel + sid + isk))
    }

    /// This side's confirmation tag: `Ta` for the initiator, `Tb` for the responder.
    func tag() -> Data? {
        mac(initiatorSide: role == .initiator)
    }

    /// Whether the peer's tag proves it knows the same password.
    func verify(peerTag: Data) -> Bool {
        guard let sides, let expected = mac(initiatorSide: role != .initiator) else { return false }
        // Reflection: our own share played back would make the expected tag our own.
        guard sides.0.share != sides.1.share || sides.0.ad != sides.1.ad else { return false }
        return Self.constantTimeEqual(peerTag, expected)
    }

    private func mac(initiatorSide: Bool) -> Data? {
        guard let macKey, let sides else { return nil }
        let side = initiatorSide ? sides.0 : sides.1
        return Data(HMAC<SHA512>.authenticationCode(for: Self.lvCat(side.share, side.ad), using: SymmetricKey(data: macKey)))
    }

    // MARK: Building blocks

    /// The generator: SHA-512 of the generator string, its first 32 bytes mapped onto the
    /// curve with Elligator2.
    static func generator(prs: Data, ci: Data, sid: Data) -> Data {
        // Zero padding fills the first SHA-512 block, so the hash state after it doesn't
        // depend on the password's length.
        let zeroPad = max(0, 128 - 1 - prependLength(prs).count - prependLength(dsi).count)
        let string = lvCat(dsi, prs, Data(count: zeroPad), ci, sid)
        let hash = Data(SHA512.hash(data: string).prefix(32))
        return FieldElement.elligator2(FieldElement(littleEndian: hash)).littleEndianBytes
    }

    /// X25519, or nil when the result is the identity (a low-order point). The scalar is
    /// clamped and bit 255 of the point cleared, as RFC 7748 asks.
    static func scalarMult(_ scalar: Data, _ point: Data) -> Data? {
        guard let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: scalar),
              let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: point),
              let shared = try? key.sharedSecretFromKeyAgreement(with: peer)
        else { return nil }
        let bytes = shared.withUnsafeBytes { Data($0) }
        return bytes == Data(count: 32) ? nil : bytes
    }

    /// The length as LEB128, then the bytes (the draft's prepend_len).
    static func prependLength(_ data: Data) -> Data {
        var length = data.count
        var out = Data()
        repeat {
            var byte = UInt8(length & 0x7F)
            length >>= 7
            if length > 0 { byte |= 0x80 }
            out.append(byte)
        } while length > 0
        return out + data
    }

    static func lvCat(_ parts: Data...) -> Data {
        parts.reduce(into: Data()) { $0 += prependLength($1) }
    }

    private static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// An element of GF(2^255 - 19), as four little-endian 64-bit limbs below p: just what
/// Elligator2 needs. Not constant time: it only maps the hash of a pairing code, which the
/// code's own display already reveals to anyone close enough to measure this Mac's timing.
struct FieldElement: Equatable {
    private(set) var limbs: [UInt64]

    static let zero = FieldElement(limbs: [0, 0, 0, 0])
    static let one = FieldElement(limbs: [1, 0, 0, 0])
    private static let p: [UInt64] = [0xFFFF_FFFF_FFFF_FFED, .max, .max, 0x7FFF_FFFF_FFFF_FFFF]
    /// p - 2, for inversion by Fermat's little theorem.
    private static let pMinus2: [UInt64] = [0xFFFF_FFFF_FFFF_FFEB, .max, .max, 0x7FFF_FFFF_FFFF_FFFF]
    /// (p - 1) / 2, for the Legendre symbol.
    private static let halfPMinus1: [UInt64] = [0xFFFF_FFFF_FFFF_FFF6, .max, .max, 0x3FFF_FFFF_FFFF_FFFF]
    /// Curve25519's A, the non-square Z Elligator2 uses on it, and 1/2.
    private static let a = FieldElement(limbs: [486_662, 0, 0, 0])
    private static let z = FieldElement(limbs: [2, 0, 0, 0])
    private static let inverseOf2 = FieldElement(limbs: [0xFFFF_FFFF_FFFF_FFF7, .max, .max, 0x3FFF_FFFF_FFFF_FFFF])

    private init(limbs: [UInt64]) {
        self.limbs = limbs
    }

    /// 32 little-endian bytes, bit 255 ignored (RFC 7748's decodeUCoordinate), reduced mod p.
    init(littleEndian bytes: Data) {
        var bytes = [UInt8](bytes)
        bytes[31] &= 0x7F
        let limbs = (0..<4).map { i in
            (0..<8).reduce(UInt64(0)) { $0 | UInt64(bytes[i * 8 + $1]) << (8 * $1) }
        }
        self.init(limbs: Self.reduced(limbs + [0]))
    }

    var littleEndianBytes: Data {
        Data(limbs.flatMap { limb in (0..<8).map { UInt8(truncatingIfNeeded: limb >> (8 * $0)) } })
    }

    static func + (lhs: FieldElement, rhs: FieldElement) -> FieldElement {
        var sum = [UInt64](repeating: 0, count: 5)
        var carry: UInt64 = 0
        for i in 0..<4 {
            let (s1, o1) = lhs.limbs[i].addingReportingOverflow(rhs.limbs[i])
            let (s2, o2) = s1.addingReportingOverflow(carry)
            sum[i] = s2
            carry = (o1 ? 1 : 0) + (o2 ? 1 : 0)
        }
        sum[4] = carry
        return FieldElement(limbs: reduced(sum))
    }

    static prefix func - (value: FieldElement) -> FieldElement {
        value == .zero ? .zero : FieldElement(limbs: subtract(p, value.limbs))
    }

    static func - (lhs: FieldElement, rhs: FieldElement) -> FieldElement {
        lhs + (-rhs)
    }

    static func * (lhs: FieldElement, rhs: FieldElement) -> FieldElement {
        var product = [UInt64](repeating: 0, count: 8)
        for i in 0..<4 {
            var carry: UInt64 = 0
            for j in 0..<4 {
                let (high, low) = lhs.limbs[i].multipliedFullWidth(by: rhs.limbs[j])
                let (s1, o1) = product[i + j].addingReportingOverflow(low)
                let (s2, o2) = s1.addingReportingOverflow(carry)
                product[i + j] = s2
                carry = high &+ (o1 ? 1 : 0) &+ (o2 ? 1 : 0)
            }
            product[i + 4] = carry
        }
        // 2^256 = 38 (mod p): fold the high half in, times 38.
        var folded = Array(product[0..<4]) + [0]
        var carry: UInt64 = 0
        for i in 0..<4 {
            let (high, low) = product[i + 4].multipliedFullWidth(by: 38)
            let (s1, o1) = folded[i].addingReportingOverflow(low)
            let (s2, o2) = s1.addingReportingOverflow(carry)
            folded[i] = s2
            carry = high + (o1 ? 1 : 0) + (o2 ? 1 : 0)
        }
        folded[4] = carry
        return FieldElement(limbs: reduced(folded))
    }

    func power(_ exponent: [UInt64]) -> FieldElement {
        var result = FieldElement.one
        for bit in (0..<256).reversed() {
            result = result * result
            if exponent[bit / 64] >> (bit % 64) & 1 == 1 { result = result * self }
        }
        return result
    }

    /// The inverse, with 0 mapping to 0 (RFC 9380's inv0).
    var inverse: FieldElement { power(Self.pMinus2) }

    /// Elligator2 onto Curve25519 (RFC 9380, map_to_curve_elligator2 with Z = 2, B = 1): the
    /// u-coordinate the CPace generator is.
    static func elligator2(_ r: FieldElement) -> FieldElement {
        let v = -(a * (one + z * r * r).inverse)
        let epsilon = (v * v * v + a * v * v + v).power(halfPMinus1)  // 1, 0 or -1
        return epsilon * v - (one - epsilon) * a * inverseOf2
    }

    // MARK: Limb arithmetic

    /// Five limbs (the fifth small) reduced below p.
    private static func reduced(_ value: [UInt64]) -> [UInt64] {
        var limbs = Array(value[0..<4])
        // The fifth limb is a multiple of 2^256 = 38 (mod p).
        var carry = value[4] * 38
        for i in 0..<4 {
            let (sum, overflow) = limbs[i].addingReportingOverflow(carry)
            limbs[i] = sum
            carry = overflow ? 1 : 0
        }
        if carry == 1 {
            // Wrapped past 2^256 once more: another 38, which can't wrap again.
            carry = 38
            for i in 0..<4 {
                let (sum, overflow) = limbs[i].addingReportingOverflow(carry)
                limbs[i] = sum
                carry = overflow ? 1 : 0
            }
        }
        while !isBelow(limbs, p) { limbs = subtract(limbs, p) }
        return limbs
    }

    private static func isBelow(_ lhs: [UInt64], _ rhs: [UInt64]) -> Bool {
        for i in (0..<4).reversed() where lhs[i] != rhs[i] {
            return lhs[i] < rhs[i]
        }
        return false
    }

    /// lhs - rhs for lhs >= rhs.
    private static func subtract(_ lhs: [UInt64], _ rhs: [UInt64]) -> [UInt64] {
        var difference = [UInt64](repeating: 0, count: 4)
        var borrow: UInt64 = 0
        for i in 0..<4 {
            let (d1, o1) = lhs[i].subtractingReportingOverflow(rhs[i])
            let (d2, o2) = d1.subtractingReportingOverflow(borrow)
            difference[i] = d2
            borrow = (o1 ? 1 : 0) + (o2 ? 1 : 0)
        }
        return difference
    }
}
