import CryptoKit
import Foundation

/// Cryptographic primitives for MSE/PE (Message Stream Encryption, the BitTorrent
/// "protocol encryption" handshake). Two pieces Apple's frameworks don't provide:
///
///  1. Diffie-Hellman over MSE's fixed 768-bit prime with generator `G = 2`.
///     CryptoKit only offers named curves / fixed groups, so the modular
///     exponentiation is done here with a small fixed-width big-integer built on
///     `[UInt32]` little-endian limbs. Speed is a non-issue: it runs twice per
///     peer handshake.
///  2. RC4, the stream cipher MSE uses once a key is agreed. It's a few lines and
///     absent from CryptoKit (deliberately — it's weak, but MSE only uses it for
///     light obfuscation to get past ISP/peer plaintext-blocking, not real
///     confidentiality).
///
/// SHA-1 (MSE's `HASH`) comes from `CryptoKit.Insecure.SHA1`.
///
/// Download-only note: this changes the *transport* (an encrypted outbound
/// handshake so we can talk to encryption-required peers), never the seeding
/// policy. We still never listen or upload.
enum MSE {
    /// MSE's fixed 768-bit safe prime `P`, big-endian, 96 bytes. Generator is 2.
    /// This exact constant is what every MSE peer uses; a mismatch makes the
    /// shared secret disagree and every handshake fail.
    static let primeBytes: [UInt8] = [
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xC9, 0x0F, 0xDA, 0xA2,
        0x21, 0x68, 0xC2, 0x34, 0xC4, 0xC6, 0x62, 0x8B, 0x80, 0xDC, 0x1C, 0xD1,
        0x29, 0x02, 0x4E, 0x08, 0x8A, 0x67, 0xCC, 0x74, 0x02, 0x0B, 0xBE, 0xA6,
        0x3B, 0x13, 0x9B, 0x22, 0x51, 0x4A, 0x08, 0x79, 0x8E, 0x34, 0x04, 0xDD,
        0xEF, 0x95, 0x19, 0xB3, 0xCD, 0x3A, 0x43, 0x1B, 0x30, 0x2B, 0x0A, 0x6D,
        0xF2, 0x5F, 0x14, 0x37, 0x4F, 0xE1, 0x35, 0x6D, 0x6D, 0x51, 0xC2, 0x45,
        0xE4, 0x85, 0xB5, 0x76, 0x62, 0x5E, 0x7E, 0xC6, 0xF4, 0x4C, 0x42, 0xE9,
        0xA6, 0x3A, 0x36, 0x21, 0x00, 0x00, 0x00, 0x00, 0x00, 0x09, 0x05, 0x63
    ]

    /// Byte length of `P`, and therefore of the DH public keys and shared secret
    /// (each left-padded with zeros to this width).
    static let keyLength = 96

    // MARK: Diffie-Hellman

    /// A fresh DH private/public key pair. The private exponent `Xa` is 160 random
    /// bits (MSE's standard size); the public key is `2^Xa mod P`, 96 bytes.
    static func generateKeyPair() -> (privateKey: Data, publicKey: Data) {
        var privateBytes = Data(count: 20)
        for i in 0..<privateBytes.count {
            privateBytes[i] = UInt8.random(in: 0...255)
        }
        return (privateBytes, publicKey(forPrivateKey: privateBytes))
    }

    /// `2^privateKey mod P`, big-endian and left-padded to `keyLength` bytes.
    static func publicKey(forPrivateKey privateKey: Data) -> Data {
        let result = BigUInt.modexp(
            base: BigUInt(bytes: [2]),
            exponent: BigUInt(bytes: [UInt8](privateKey)),
            modulus: prime
        )
        return result.bigEndianBytes(paddedTo: keyLength)
    }

    /// The DH shared secret `peerPublicKey^privateKey mod P`, big-endian and
    /// left-padded to `keyLength` bytes — identical on both ends of the exchange.
    static func sharedSecret(peerPublicKey: Data, privateKey: Data) -> Data {
        let result = BigUInt.modexp(
            base: BigUInt(bytes: [UInt8](peerPublicKey)),
            exponent: BigUInt(bytes: [UInt8](privateKey)),
            modulus: prime
        )
        return result.bigEndianBytes(paddedTo: keyLength)
    }

    private static let prime = BigUInt(bytes: primeBytes)

    // MARK: MSE hashes & RC4 keys

    /// `HASH(prefix, data...)` = SHA-1 of the ASCII prefix followed by the given
    /// byte blobs, as used throughout the MSE handshake.
    static func hash(_ prefix: String, _ blobs: Data...) -> Data {
        var input = Data(prefix.utf8)
        for blob in blobs { input.append(blob) }
        return Data(Insecure.SHA1.hash(data: input))
    }

    /// The RC4 cipher for our outgoing (A→B) stream: keyed `HASH('keyA', S, SKEY)`
    /// with the first 1024 keystream bytes discarded, per the MSE spec.
    static func outgoingCipher(secret: Data, skey: Data) -> RC4 {
        primedCipher(prefix: "keyA", secret: secret, skey: skey)
    }

    /// The RC4 cipher for the peer's incoming (B→A) stream: keyed
    /// `HASH('keyB', S, SKEY)`, first 1024 keystream bytes discarded.
    static func incomingCipher(secret: Data, skey: Data) -> RC4 {
        primedCipher(prefix: "keyB", secret: secret, skey: skey)
    }

    private static func primedCipher(prefix: String, secret: Data, skey: Data) -> RC4 {
        var cipher = RC4(key: [UInt8](hash(prefix, secret, skey)))
        cipher.discard(1024)
        return cipher
    }
}

/// RC4 stream cipher. `process` XORs input against the keystream; since it is a
/// stream, feeding bytes through in order encrypts or decrypts regardless of how
/// the caller chunks them.
struct RC4 {
    private var s: [UInt8]
    private var i = 0
    private var j = 0

    init(key: [UInt8]) {
        s = Array(0...255)
        var j = 0
        for i in 0..<256 {
            j = (j + Int(s[i]) + Int(key[i % key.count])) & 0xFF
            s.swapAt(i, j)
        }
    }

    mutating func process(_ data: [UInt8]) -> [UInt8] {
        var output = data
        output.withUnsafeMutableBytes { apply(to: $0) }
        return output
    }

    mutating func process(_ data: Data) -> Data {
        var output = data
        output.withUnsafeMutableBytes { apply(to: $0) }
        return output
    }

    /// Advances the keystream by `count` bytes without producing output — MSE
    /// discards the first 1024 bytes of each direction's keystream.
    mutating func discard(_ count: Int) {
        var scratch = [UInt8](repeating: 0, count: count)
        scratch.withUnsafeMutableBytes { apply(to: $0) }
    }

    /// XORs the keystream into `bytes` in place. Every peer byte on an encrypted
    /// connection passes through here, so the state is walked through a buffer
    /// pointer (indices are masked to 0...255) instead of per-byte array calls.
    private mutating func apply(to bytes: UnsafeMutableRawBufferPointer) {
        var i = self.i
        var j = self.j
        s.withUnsafeMutableBufferPointer { s in
            for index in bytes.indices {
                i = (i + 1) & 0xFF
                let si = s[i]
                j = (j + Int(si)) & 0xFF
                let sj = s[j]
                s[i] = sj
                s[j] = si
                bytes[index] ^= s[Int(si &+ sj)]
            }
        }
        self.i = i
        self.j = j
    }
}

/// A minimal non-negative big integer as little-endian `UInt32` limbs (index 0 is
/// least significant), just enough for MSE's fixed-modulus modular exponentiation.
/// Not general-purpose: no subtraction of a larger value, no signed values.
struct BigUInt {
    /// Little-endian limbs, no trailing zero limbs (except the single `[0]` for zero).
    private(set) var limbs: [UInt32]

    init(limbs: [UInt32]) {
        self.limbs = BigUInt.normalized(limbs)
    }

    /// Interprets `bytes` as a big-endian unsigned integer.
    init(bytes: [UInt8]) {
        var result = [UInt32]()
        var limb: UInt32 = 0
        var shift: UInt32 = 0
        // Walk from least significant byte (end of big-endian input) upward.
        for byte in bytes.reversed() {
            limb |= UInt32(byte) << shift
            shift += 8
            if shift == 32 {
                result.append(limb)
                limb = 0
                shift = 0
            }
        }
        if shift > 0 || result.isEmpty { result.append(limb) }
        limbs = BigUInt.normalized(result)
    }

    /// Big-endian bytes, left-padded (or truncated) to exactly `count` bytes.
    func bigEndianBytes(paddedTo count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        for outputIndex in 0..<count {
            let byteFromLSB = count - 1 - outputIndex
            let limbIndex = byteFromLSB / 4
            guard limbIndex < limbs.count else { continue }
            let shift = UInt32((byteFromLSB % 4) * 8)
            bytes[outputIndex] = UInt8((limbs[limbIndex] >> shift) & 0xFF)
        }
        return Data(bytes)
    }

    // MARK: Modular exponentiation

    /// `base^exponent mod modulus`, via right-to-left square-and-multiply.
    static func modexp(base: BigUInt, exponent: BigUInt, modulus: BigUInt) -> BigUInt {
        var result = BigUInt(limbs: [1])
        var b = base.mod(modulus)
        let bitCount = exponent.bitLength
        for bit in 0..<bitCount {
            if exponent.bit(at: bit) {
                result = result.multiplied(by: b).mod(modulus)
            }
            b = b.multiplied(by: b).mod(modulus)
        }
        return result
    }

    // MARK: Primitives

    private var bitLength: Int {
        guard let top = limbs.last, limbs != [0] else { return 0 }
        return (limbs.count - 1) * 32 + (32 - top.leadingZeroBitCount)
    }

    private func bit(at index: Int) -> Bool {
        let limbIndex = index / 32
        guard limbIndex < limbs.count else { return false }
        return (limbs[limbIndex] >> UInt32(index % 32)) & 1 == 1
    }

    private func multiplied(by other: BigUInt) -> BigUInt {
        var product = [UInt32](repeating: 0, count: limbs.count + other.limbs.count)
        for (i, a) in limbs.enumerated() {
            var carry: UInt64 = 0
            let a64 = UInt64(a)
            for (j, b) in other.limbs.enumerated() {
                let sum = a64 * UInt64(b) + UInt64(product[i + j]) + carry
                product[i + j] = UInt32(sum & 0xFFFFFFFF)
                carry = sum >> 32
            }
            product[i + other.limbs.count] += UInt32(carry)
        }
        return BigUInt(limbs: product)
    }

    /// `self mod modulus`, via bitwise long division (MSB→LSB). The remainder is a
    /// fixed-size buffer (`modulus` width + 1 limb, always enough since it stays
    /// below `2·modulus`), so the hot loop does no allocation — this runs once per
    /// square/multiply and dominates the DH cost.
    private func mod(_ modulus: BigUInt) -> BigUInt {
        let mLen = modulus.limbs.count
        let bitCount = bitLength
        var rem = [UInt32](repeating: 0, count: mLen + 1)
        let remLen = rem.count
        rem.withUnsafeMutableBufferPointer { r in
            modulus.limbs.withUnsafeBufferPointer { m in
                self.limbs.withUnsafeBufferPointer { x in
                    for bit in stride(from: bitCount - 1, through: 0, by: -1) {
                        // rem <<= 1
                        var carry: UInt32 = 0
                        for i in 0..<remLen {
                            let next = r[i] >> 31
                            r[i] = (r[i] << 1) | carry
                            carry = next
                        }
                        // Shift in bit `bit` of self.
                        if (x[bit >> 5] >> UInt32(bit & 31)) & 1 == 1 { r[0] |= 1 }
                        // rem >= m ? (top-down compare over the fixed-width buffer)
                        var geq = true
                        var idx = remLen - 1
                        while idx >= 0 {
                            let mv = idx < mLen ? m[idx] : 0
                            if r[idx] != mv { geq = r[idx] > mv; break }
                            idx -= 1
                        }
                        if geq {
                            var borrow: Int64 = 0
                            for i in 0..<remLen {
                                let mv = i < mLen ? Int64(m[i]) : 0
                                var diff = Int64(r[i]) - mv - borrow
                                if diff < 0 { diff += 0x100000000; borrow = 1 } else { borrow = 0 }
                                r[i] = UInt32(diff)
                            }
                        }
                    }
                }
            }
        }
        return BigUInt(limbs: rem)
    }

    private static func normalized(_ limbs: [UInt32]) -> [UInt32] {
        var limbs = limbs
        while limbs.count > 1 && limbs.last == 0 { limbs.removeLast() }
        if limbs.isEmpty { limbs = [0] }
        return limbs
    }
}
