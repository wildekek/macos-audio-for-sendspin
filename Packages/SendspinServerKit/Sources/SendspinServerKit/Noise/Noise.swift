import CryptoKit
import Foundation

// The parts of the Noise Protocol Framework (revision 34, noiseprotocol.org/noise.html)
// that Sendspin needs: the KKpsk2 handshake as initiator, which is the server's side,
// and transport mode. Names follow the specification (CipherState, SymmetricState,
// MixKey, MixHash, ...) so the code reads alongside it.

enum NoiseError: Error, CustomStringConvertible {
    case invalidMessage
    case decryptionFailed
    case nonceExhausted
    case messageTooLarge

    var description: String {
        switch self {
        case .invalidMessage: "malformed Noise message"
        case .decryptionFailed: "Noise decryption failed"
        case .nonceExhausted: "Noise nonce exhausted"
        case .messageTooLarge: "Noise message over 65535 bytes"
        }
    }
}

/// A Sendspin cipher suite: the `<DH>_<cipher>_<hash>` part of the Noise protocol name.
public enum NoiseSuite: String, Sendable, CaseIterable {
    case chaChaPoly = "25519_ChaChaPoly_SHA256"
    case aesGCM = "25519_AESGCM_SHA256"

    static let tagSize = 16

    func encrypt(key: SymmetricKey, nonce n: UInt64, ad: Data, plaintext: Data) throws -> Data {
        switch self {
        case .chaChaPoly:
            let box = try ChaChaPoly.seal(plaintext, using: key, nonce: ChaChaPoly.Nonce(data: nonceBytes(n)),
                                          authenticating: ad)
            return box.ciphertext + box.tag
        case .aesGCM:
            let box = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(data: nonceBytes(n)),
                                       authenticating: ad)
            return box.ciphertext + box.tag
        }
    }

    func decrypt(key: SymmetricKey, nonce n: UInt64, ad: Data, ciphertext: Data) throws -> Data {
        guard ciphertext.count >= Self.tagSize else { throw NoiseError.decryptionFailed }
        let body = ciphertext.prefix(ciphertext.count - Self.tagSize)
        let tag = ciphertext.suffix(Self.tagSize)
        do {
            switch self {
            case .chaChaPoly:
                let box = try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: nonceBytes(n)),
                                                   ciphertext: body, tag: tag)
                return try ChaChaPoly.open(box, using: key, authenticating: ad)
            case .aesGCM:
                let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonceBytes(n)),
                                                ciphertext: body, tag: tag)
                return try AES.GCM.open(box, using: key, authenticating: ad)
            }
        } catch {
            throw NoiseError.decryptionFailed
        }
    }

    /// 32 zero bits, then the counter: little-endian for ChaChaPoly, big-endian for AESGCM.
    private func nonceBytes(_ n: UInt64) -> Data {
        var bytes = Data(count: 4)
        switch self {
        case .chaChaPoly: withUnsafeBytes(of: n.littleEndian) { bytes.append(contentsOf: $0) }
        case .aesGCM: withUnsafeBytes(of: n.bigEndian) { bytes.append(contentsOf: $0) }
        }
        return bytes
    }
}

struct CipherState: Sendable {
    let suite: NoiseSuite
    private var key: SymmetricKey?
    private var nonce: UInt64 = 0

    init(suite: NoiseSuite, key: SymmetricKey? = nil) {
        self.suite = suite
        self.key = key
    }

    mutating func encrypt(ad: Data, plaintext: Data) throws -> Data {
        guard let key else { return plaintext }
        guard nonce < .max else { throw NoiseError.nonceExhausted }  // 2^64-1 is reserved
        let ciphertext = try suite.encrypt(key: key, nonce: nonce, ad: ad, plaintext: plaintext)
        nonce += 1
        return ciphertext
    }

    /// The nonce only advances on success, so a forged message can't desynchronize it.
    mutating func decrypt(ad: Data, ciphertext: Data) throws -> Data {
        guard let key else { return ciphertext }
        guard nonce < .max else { throw NoiseError.nonceExhausted }
        let plaintext = try suite.decrypt(key: key, nonce: nonce, ad: ad, ciphertext: ciphertext)
        nonce += 1
        return plaintext
    }
}

struct SymmetricState {
    private(set) var cipher: CipherState
    private var ck: Data
    private(set) var h: Data

    init(protocolName: String, suite: NoiseSuite) {
        let name = Data(protocolName.utf8)
        h = name.count <= 32 ? name + Data(count: 32 - name.count) : Data(SHA256.hash(data: name))
        ck = h
        cipher = CipherState(suite: suite)
    }

    mutating func mixKey(_ inputKeyMaterial: Data) {
        let output = hkdf(inputKeyMaterial, outputs: 2)
        ck = output[0]
        cipher = CipherState(suite: cipher.suite, key: SymmetricKey(data: output[1]))
    }

    mutating func mixHash(_ data: Data) {
        h = Data(SHA256.hash(data: h + data))
    }

    mutating func mixKeyAndHash(_ inputKeyMaterial: Data) {
        let output = hkdf(inputKeyMaterial, outputs: 3)
        ck = output[0]
        mixHash(output[1])
        cipher = CipherState(suite: cipher.suite, key: SymmetricKey(data: output[2]))
    }

    mutating func encryptAndHash(_ plaintext: Data) throws -> Data {
        let ciphertext = try cipher.encrypt(ad: h, plaintext: plaintext)
        mixHash(ciphertext)
        return ciphertext
    }

    mutating func decryptAndHash(_ ciphertext: Data) throws -> Data {
        let plaintext = try cipher.decrypt(ad: h, ciphertext: ciphertext)
        mixHash(ciphertext)
        return plaintext
    }

    /// The initiator's sending and receiving cipher states.
    func split() -> (initiatorToResponder: CipherState, responderToInitiator: CipherState) {
        let output = hkdf(Data(), outputs: 2)
        return (CipherState(suite: cipher.suite, key: SymmetricKey(data: output[0])),
                CipherState(suite: cipher.suite, key: SymmetricKey(data: output[1])))
    }

    /// Noise's HKDF over HMAC-SHA256, chaining key as salt.
    private func hkdf(_ inputKeyMaterial: Data, outputs: Int) -> [Data] {
        let tempKey = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: inputKeyMaterial,
                                                                             using: SymmetricKey(data: ck))))
        var result: [Data] = []
        var previous = Data()
        for i in 1...outputs {
            previous = Data(HMAC<SHA256>.authenticationCode(for: previous + [UInt8(i)], using: tempKey))
            result.append(previous)
        }
        return result
    }
}

/// `Noise_KKpsk2_<suite>` as the initiator, which is always the server in Sendspin:
///
///     KKpsk2:
///       -> s
///       <- s
///       ...
///       -> e, es, ss
///       <- e, ee, se, psk
struct NoiseInitiatorHandshake {
    private var state: SymmetricState
    private let localStatic: Curve25519.KeyAgreement.PrivateKey
    private let remoteStatic: Curve25519.KeyAgreement.PublicKey
    private let ephemeral: Curve25519.KeyAgreement.PrivateKey
    private let psk: Data

    /// `ephemeral` is only passed by tests, to reproduce reference vectors.
    init(suite: NoiseSuite, prologue: Data, localStatic: Curve25519.KeyAgreement.PrivateKey,
         remoteStatic: Curve25519.KeyAgreement.PublicKey, psk: Data,
         ephemeral: Curve25519.KeyAgreement.PrivateKey = .init()) {
        state = SymmetricState(protocolName: "Noise_KKpsk2_\(suite.rawValue)", suite: suite)
        self.localStatic = localStatic
        self.remoteStatic = remoteStatic
        self.ephemeral = ephemeral
        self.psk = psk
        state.mixHash(prologue)
        // Pre-messages: the initiator's static key, then the responder's.
        state.mixHash(localStatic.publicKey.rawRepresentation)
        state.mixHash(remoteStatic.rawRepresentation)
    }

    /// `-> e, es, ss` with the (PSK-less, but encrypted) payload.
    mutating func writeMessage1(payload: Data) throws -> Data {
        let e = ephemeral.publicKey.rawRepresentation
        state.mixHash(e)
        state.mixKey(e)  // in a PSK handshake, an `e` token also mixes the key
        state.mixKey(try dh(ephemeral, remoteStatic))
        state.mixKey(try dh(localStatic, remoteStatic))
        return e + (try state.encryptAndHash(payload))
    }

    /// `<- e, ee, se, psk`; returns the payload and the transport cipher states.
    mutating func readMessage2(_ message: Data) throws -> (payload: Data, transport: NoiseTransport) {
        guard message.count >= 32 + NoiseSuite.tagSize else { throw NoiseError.invalidMessage }
        let re = Data(message.prefix(32))
        let remoteEphemeral = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: re)
        state.mixHash(re)
        state.mixKey(re)
        state.mixKey(try dh(ephemeral, remoteEphemeral))
        state.mixKey(try dh(localStatic, remoteEphemeral))
        state.mixKeyAndHash(psk)
        let payload = try state.decryptAndHash(Data(message.dropFirst(32)))
        let (send, receive) = state.split()
        return (payload, NoiseTransport(send: send, receive: receive, handshakeHash: state.h))
    }

    private func dh(_ privateKey: Curve25519.KeyAgreement.PrivateKey,
                    _ publicKey: Curve25519.KeyAgreement.PublicKey) throws -> Data {
        try privateKey.sharedSecretFromKeyAgreement(with: publicKey).withUnsafeBytes { Data($0) }
    }
}

/// Transport mode after the handshake: one cipher state per direction, empty associated data.
struct NoiseTransport: Sendable {
    /// A Noise message, ciphertext and tag included, is at most this long.
    static let maxMessageSize = 65535
    static let maxPlaintextSize = maxMessageSize - NoiseSuite.tagSize

    private var send: CipherState
    private var receive: CipherState
    /// The handshake hash `h`.
    let handshakeHash: Data

    init(send: CipherState, receive: CipherState, handshakeHash: Data) {
        self.send = send
        self.receive = receive
        self.handshakeHash = handshakeHash
    }

    mutating func encrypt(_ plaintext: Data) throws -> Data {
        guard plaintext.count <= Self.maxPlaintextSize else { throw NoiseError.messageTooLarge }
        return try send.encrypt(ad: Data(), plaintext: plaintext)
    }

    mutating func decrypt(_ ciphertext: Data) throws -> Data {
        guard ciphertext.count <= Self.maxMessageSize else { throw NoiseError.messageTooLarge }
        return try receive.decrypt(ad: Data(), ciphertext: ciphertext)
    }
}
