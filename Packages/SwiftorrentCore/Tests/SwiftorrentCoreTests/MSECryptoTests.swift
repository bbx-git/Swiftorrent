import Foundation
@testable import SwiftorrentCore
import Testing

@Suite("MSE crypto")
struct MSECryptoTests {
    @Test("RC4 matches the classic Key/Plaintext known-answer vector")
    func rc4KnownAnswer() {
        var cipher = RC4(key: [UInt8]("Key".utf8))
        let output = cipher.process([UInt8]("Plaintext".utf8))
        #expect(Data(output) == Data([0xBB, 0xF3, 0x16, 0xE8, 0xD9, 0x40, 0xAF, 0x0A, 0xD3]))
    }

    @Test("RC4 is symmetric: a second cipher with the same key decrypts")
    func rc4RoundTrip() {
        let key: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05]
        let plaintext = [UInt8]("The quick brown fox".utf8)
        var enc = RC4(key: key)
        var dec = RC4(key: key)
        #expect(dec.process(enc.process(plaintext)) == plaintext)
    }

    @Test("BigUInt modexp matches a small known value (4^13 mod 497 = 445)")
    func modexpSmall() {
        let result = BigUInt.modexp(
            base: BigUInt(bytes: [4]),
            exponent: BigUInt(bytes: [13]),
            modulus: BigUInt(bytes: [0x01, 0xF1]) // 497
        )
        #expect(result.bigEndianBytes(paddedTo: 2) == Data([0x01, 0xBD])) // 445
    }

    @Test("MSE public keys are 96 bytes over the fixed prime")
    func publicKeyWidth() {
        let (_, publicKey) = MSE.generateKeyPair()
        #expect(publicKey.count == MSE.keyLength)
    }

    @Test("Diffie-Hellman shared secret agrees on both ends")
    func diffieHellmanRoundTrip() {
        let alice = MSE.generateKeyPair()
        let bob = MSE.generateKeyPair()
        let secretA = MSE.sharedSecret(peerPublicKey: bob.publicKey, privateKey: alice.privateKey)
        let secretB = MSE.sharedSecret(peerPublicKey: alice.publicKey, privateKey: bob.privateKey)
        #expect(secretA == secretB)
        #expect(secretA.count == MSE.keyLength)
        #expect(secretA != Data(count: MSE.keyLength)) // not all-zero
    }

    @Test("VC resync scan finds the encrypted VC after arbitrary PadB")
    func vcResyncScan() {
        let vc: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03, 0x04]
        let padB: [UInt8] = [0x11, 0x22, 0xDE, 0xAD, 0x33] // contains a partial false start
        let stream = padB + vc + [0xAA, 0xBB]
        let index = PeerWireClient.firstIndex(of: vc, in: stream, from: 0)
        #expect(index == padB.count)
    }

    @Test("VC resync scan returns nil when the pattern is absent")
    func vcResyncScanMiss() {
        let stream: [UInt8] = [0x00, 0x01, 0x02, 0x03]
        #expect(PeerWireClient.firstIndex(of: [0xFF, 0xFF], in: stream, from: 0) == nil)
        // `from` past the last possible start is a miss, not a trap.
        #expect(PeerWireClient.firstIndex(of: [0x02, 0x03], in: stream, from: 3) == nil)
    }

    @Test("An MSE peer keyed identically recovers our encrypted stream")
    func mseStreamRoundTrip() {
        let secret = Data((0..<96).map { _ in UInt8.random(in: 0...255) })
        let skey = Data((0..<20).map { _ in UInt8.random(in: 0...255) })
        // Initiator encrypts A→B with keyA; the peer decrypts A→B with the same key.
        var initiatorOut = MSE.outgoingCipher(secret: secret, skey: skey)
        var peerInFromA = MSE.outgoingCipher(secret: secret, skey: skey)
        let message = [UInt8]("BitTorrent protocol payload".utf8)
        #expect(peerInFromA.process(initiatorOut.process(message)) == message)
    }

    @Test("outgoing/incoming ciphers differ (keyA vs keyB) and are deterministic")
    func directionalCiphers() {
        let secret = Data((0..<96).map { UInt8($0) })
        let skey = Data((0..<20).map { UInt8($0 &* 3) })
        var out1 = MSE.outgoingCipher(secret: secret, skey: skey)
        var out2 = MSE.outgoingCipher(secret: secret, skey: skey)
        var incoming = MSE.incomingCipher(secret: secret, skey: skey)
        let probe = [UInt8](repeating: 0, count: 16)
        let a = out1.process(probe)
        let b = out2.process(probe)
        let c = incoming.process(probe)
        #expect(a == b)      // same key + discard => deterministic keystream
        #expect(a != c)      // keyA stream differs from keyB stream
    }
}
