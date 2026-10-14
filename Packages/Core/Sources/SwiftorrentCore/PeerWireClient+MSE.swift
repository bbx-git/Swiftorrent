import Foundation

extension PeerWireClient {
    /// MSE `crypto_select` value for RC4 (BEP-8 / MSE spec).
    private static let cryptoRC4: UInt32 = 0x02
    /// What we advertise in `crypto_provide`: RC4 only, so a completed MSE
    /// handshake always yields an encrypted stream (the whole point here). A peer
    /// without RC4 simply fails MSE and we fall back to plaintext.
    private static let cryptoProvide: UInt8 = 0x02
    /// Upper bound on bytes scanned while resyncing on the encrypted VC — MSE PadB
    /// is at most 512 bytes, so this caps a hostile peer streaming padding forever.
    private static let maxResyncBytes = 8 + 600

    /// Performs the MSE/PE handshake as the initiator (BEP-8 message-stream
    /// encryption): Diffie-Hellman key exchange, the `req1`/`req2⊕req3` hashes and
    /// `crypto_provide`, then resync on the peer's encrypted VC to read
    /// `crypto_select`. On RC4 selection it installs the stream ciphers so all
    /// subsequent traffic — starting with the BitTorrent handshake — is encrypted.
    /// Throws on any mismatch so `connect()` can fall back to plaintext.
    ///
    /// Download-only: this changes the transport so we can reach the
    /// encryption-required peers that accept our TCP connection then go silent on a
    /// plaintext handshake. It adds no listener and no upload.
    func mseHandshake() async throws {
        // Step 1 — A→B: DH public key Ya, then random padding PadA.
        let keyPair = MSE.generateKeyPair()
        try await send(keyPair.publicKey + Self.randomPad())

        // Step 2 — B→A: DH public key Yb (first 96 bytes). PadB follows and is
        // skipped during the VC resync below.
        let yb = try await rawReceive(MSE.keyLength, timeout: ioTimeout)

        // Step 3 — derive the shared secret and directional RC4 ciphers, then send
        // HASH('req1',S) · HASH('req2',SKEY)⊕HASH('req3',S) · ENCRYPT(payload).
        let secret = MSE.sharedSecret(peerPublicKey: yb, privateKey: keyPair.privateKey)
        var outCipher = MSE.outgoingCipher(secret: secret, skey: infoHash)
        var inCipher = MSE.incomingCipher(secret: secret, skey: infoHash)

        let req2 = MSE.hash("req2", infoHash)
        let req3 = MSE.hash("req3", secret)
        var req2xor3 = Data(count: 20)
        for i in 0..<20 { req2xor3[i] = req2[i] ^ req3[i] }

        var cleartext = Data(count: 8)                          // VC = 8 zero bytes
        cleartext.append(contentsOf: [0, 0, 0, Self.cryptoProvide]) // crypto_provide
        cleartext.append(contentsOf: [0, 0])                    // len(PadC) = 0
        cleartext.append(contentsOf: [0, 0])                    // len(IA)  = 0
        let step3 = MSE.hash("req1", secret) + req2xor3 + outCipher.process(cleartext)
        try await send(step3)

        // Step 4 — resync on the encrypted VC, then read crypto_select + PadD.
        let selected = try await readCryptoSelect(inCipher: &inCipher)
        guard selected == Self.cryptoRC4 else {
            // We only offered RC4; anything else (incl. plaintext) is unusable here.
            throw PeerWireError.invalidHandshake
        }
        sendCipher = outCipher
        recvCipher = inCipher
    }

    /// Skips PadB by scanning for the peer's encrypted VC (`inCipher` applied to 8
    /// zero bytes), then decrypts and returns the 4-byte `crypto_select`, consuming
    /// the trailing PadD. Advances `inCipher` exactly across VC + select + PadD so
    /// it is aligned to decrypt the payload stream that follows.
    private func readCryptoSelect(inCipher: inout RC4) async throws -> UInt32 {
        // Peek the expected encrypted VC from a copy, leaving the real cipher intact.
        var probe = inCipher
        let encVC = [UInt8](probe.process(Data(count: 8)))

        var searchFrom = 0
        var vcEnd: Int?
        while vcEnd == nil {
            if let start = Self.firstIndex(of: encVC, in: inputBuffer, from: searchFrom) {
                vcEnd = start + encVC.count
            } else {
                guard inputBuffer.count <= Self.maxResyncBytes else {
                    throw PeerWireError.invalidHandshake
                }
                searchFrom = max(0, inputBuffer.count - encVC.count + 1)
                try await fillInputBuffer(timeout: ioTimeout)
            }
        }
        // Drop PadB + VC; advance the real cipher past the 8 VC bytes it encrypted.
        inputBuffer.removeFirst(vcEnd!)
        _ = inCipher.process(Data(count: 8))

        let select = inCipher.process(try await rawReceive(4, timeout: ioTimeout))
        let padDLenBytes = inCipher.process(try await rawReceive(2, timeout: ioTimeout))
        let padDLen = Int(padDLenBytes[0]) << 8 | Int(padDLenBytes[1])
        if padDLen > 0 {
            guard padDLen <= 1024 else { throw PeerWireError.invalidHandshake }
            _ = inCipher.process(try await rawReceive(padDLen, timeout: ioTimeout))
        }
        return UInt32(select[0]) << 24 | UInt32(select[1]) << 16 | UInt32(select[2]) << 8 | UInt32(select[3])
    }

    /// First index of `pattern` in `buffer` at or after `from`, or `nil`.
    static func firstIndex(of pattern: [UInt8], in buffer: [UInt8], from: Int) -> Int? {
        guard pattern.count <= buffer.count else { return nil }
        let last = buffer.count - pattern.count
        guard from <= last else { return nil }
        for start in from...last {
            var matched = true
            for k in 0..<pattern.count where buffer[start + k] != pattern[k] {
                matched = false
                break
            }
            if matched { return start }
        }
        return nil
    }

    /// 0–512 random bytes of MSE PadA, obscuring the fixed-length key exchange.
    private static func randomPad() -> Data {
        let length = Int.random(in: 0...512)
        var pad = Data(count: length)
        for i in 0..<length { pad[i] = UInt8.random(in: 0...255) }
        return pad
    }
}
