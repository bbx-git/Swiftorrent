import CryptoKit
import Foundation
import Network

public struct PieceBlock: Sendable {
    public let begin: Int
    public let data: Data
}

public enum PeerWireError: Error, LocalizedError {
    case connectionFailed
    case invalidHandshake
    case disconnected
    case choked
    case unexpectedMessage
    case invalidPieceHash
    case extensionProtocolUnavailable
    case metadataUnavailable
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .connectionFailed: "Could not connect to peer."
        case .invalidHandshake: "Peer returned an invalid BitTorrent handshake."
        case .disconnected: "Peer disconnected."
        case .choked: "Peer choked this client."
        case .unexpectedMessage: "Peer returned an unexpected message."
        case .invalidPieceHash: "Downloaded piece failed SHA-1 verification."
        case .extensionProtocolUnavailable: "Peer does not support the BitTorrent extension protocol."
        case .metadataUnavailable: "Peer does not provide magnet metadata."
        case .timedOut: "Peer stopped responding."
        }
    }
}

public actor PeerWireClient {
    /// Upper bound on a peer-advertised wire-message length, guarding against OOM from hostile peers.
    static let maxMessageLength = 1024 * 1024
    /// Upper bound on peer-advertised `metadata_size`, guarding against OOM from hostile peers.
    static let maxMetadataSize = 10 * 1024 * 1024
    /// Local extension-message id we advertise for BEP 11 PEX. Peers address their
    /// `ut_pex` messages to us using this id. Download-only: we declare support so
    /// peers gossip more peers to us, but we never send an `added` list ourselves.
    static let localPexExtensionID: UInt8 = 2
    /// Local extension-message id we advertise for BEP 9 `ut_metadata`. Per BEP 10,
    /// a peer addresses its metadata replies to us using *this* id (the one we
    /// advertised), not the id it advertised for itself, so incoming metadata
    /// pieces must be matched against this constant.
    static let localMetadataExtensionID: UInt8 = 1
    /// Cap on peers retained from inbound PEX, so a hostile peer flooding `added`
    /// lists cannot grow this set without bound.
    static let maxDiscoveredPeers = 500

    /// How `connect()` negotiates the transport.
    public enum EncryptionPolicy: Sendable {
        /// Try the MSE/PE encrypted handshake first; if the peer isn't MSE-capable,
        /// retry once over a fresh plaintext connection. Reaches both the
        /// encryption-required majority of public-swarm peers and plaintext peers.
        case preferEncrypted
        /// Plaintext BitTorrent handshake only.
        case plaintextOnly
    }

    /// MSE `crypto_select` value for RC4 (BEP-8 / MSE spec).
    private static let cryptoRC4: UInt32 = 0x02
    /// What we advertise in `crypto_provide`: RC4 only, so a completed MSE
    /// handshake always yields an encrypted stream (the whole point here). A peer
    /// without RC4 simply fails MSE and we fall back to plaintext.
    private static let cryptoProvide: UInt8 = 0x02
    /// Upper bound on bytes scanned while resyncing on the encrypted VC — MSE PadB
    /// is at most 512 bytes, so this caps a hostile peer streaming padding forever.
    private static let maxResyncBytes = 8 + 600

    private let endpoint: PeerEndpoint
    private let infoHash: Data
    private let peerID: Data
    /// Upper bound on how long the TCP connection may take to become ready.
    private let connectTimeout: TimeInterval
    /// Upper bound on any single send/receive wire operation. A peer that goes
    /// silent mid-message is torn down within this window instead of parking a
    /// download slot forever.
    private let ioTimeout: TimeInterval
    private let encryptionPolicy: EncryptionPolicy
    private var connection: NWConnection?
    /// Once the MSE handshake selects RC4, `sendCipher` encrypts our outgoing
    /// bytes and `recvCipher` decrypts the peer's — both `nil` on a plaintext
    /// connection. RC4 is a stream cipher, so running bytes through in order works
    /// regardless of how sends/receives are chunked.
    private var sendCipher: RC4?
    private var recvCipher: RC4?
    /// Raw (still-encrypted) bytes received from the socket but not yet consumed.
    /// Every receive drains this first, so the MSE VC resync can over-read while
    /// scanning without losing the payload bytes that follow.
    private var inputBuffer = [UInt8]()
    private var isChoked = true
    private var peerSupportsExtensions = false
    private var peerMetadataExtensionID: UInt8?
    private var metadataSize: Int?
    private var availablePieces = Set<Int>()
    private var availabilityIsKnown = false
    /// Guards against re-sending our extension handshake when both `connect()` and
    /// `fetchMetadata()` would otherwise send one.
    private var sentExtendedHandshake = false
    /// Set once the peer's BEP 10 extension handshake (extended id 0) arrives.
    /// Lets the metadata path stop waiting as soon as we know whether the peer
    /// offers `ut_metadata`, rather than blocking until the I/O timeout.
    private var receivedExtendedHandshake = false
    /// Peers learned from inbound BEP 11 PEX `added` lists during this session,
    /// drained by the swarm so dead connections are replaced from gossiped peers.
    private var discoveredPeers = Set<PeerEndpoint>()

    public init(
        endpoint: PeerEndpoint,
        infoHash: Data,
        peerID: Data,
        connectTimeout: TimeInterval = 10,
        ioTimeout: TimeInterval = 30,
        encryptionPolicy: EncryptionPolicy = .preferEncrypted
    ) {
        self.endpoint = endpoint
        self.infoHash = infoHash
        self.peerID = peerID
        self.connectTimeout = connectTimeout
        self.ioTimeout = ioTimeout
        self.encryptionPolicy = encryptionPolicy
    }

    /// Whether the active connection negotiated MSE/RC4 encryption rather than
    /// falling back to (or being configured for) plaintext.
    public var isEncrypted: Bool { sendCipher != nil }

    public func connect() async throws {
        try await openConnection()
        switch encryptionPolicy {
        case .plaintextOnly:
            try await bittorrentHandshake()
        case .preferEncrypted:
            do {
                try await mseHandshake()
                try await bittorrentHandshake()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // The peer isn't MSE-capable (or stalled mid-encryption). Retry once
                // over a fresh plaintext connection so plaintext peers aren't lost.
                close()
                resetForReconnect()
                try await openConnection()
                try await bittorrentHandshake()
            }
        }
    }

    /// Opens the TCP connection and waits for it to become ready (bounded by
    /// `connectTimeout`). Resets any buffered input from a prior attempt.
    private func openConnection() async throws {
        try Task.checkCancellation()
        inputBuffer.removeAll(keepingCapacity: true)
        guard let port = NWEndpoint.Port(rawValue: endpoint.port) else {
            throw PeerWireError.connectionFailed
        }
        let connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: port, using: .tcp)
        self.connection = connection
        try await withTimeout(connectTimeout) {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            connection.stateUpdateHandler = nil
                            continuation.resume()
                        case let .failed(error):
                            connection.stateUpdateHandler = nil
                            continuation.resume(throwing: error)
                        case let .waiting(error):
                            // Without waitForConnectivity, NWConnection parks unreachable or
                            // refused peers in `.waiting` indefinitely. Fail fast instead.
                            connection.stateUpdateHandler = nil
                            connection.cancel()
                            continuation.resume(throwing: error)
                        case .cancelled:
                            // Reached when `onCancel` (or `.waiting` above) cancels the
                            // connection; resume so the continuation never leaks.
                            connection.stateUpdateHandler = nil
                            continuation.resume(throwing: CancellationError())
                        default:
                            break
                        }
                    }
                    connection.start(queue: .global(qos: .utility))
                }
            } onCancel: {
                connection.cancel()
            }
        }
    }

    /// The plaintext BitTorrent handshake. Runs over whatever transport is in
    /// place: raw TCP for a plaintext connection, or the RC4 stream cipher once
    /// the MSE handshake has installed `sendCipher`/`recvCipher`.
    private func bittorrentHandshake() async throws {
        try await send(handshake())
        let response = try await receiveExactly(68)
        guard response.count == 68,
              response[0] == 19,
              String(data: response[1..<20], encoding: .ascii) == "BitTorrent protocol",
              Data(response[28..<48]) == infoHash else {
            throw PeerWireError.invalidHandshake
        }
        peerSupportsExtensions = (response[25] & 0x10) != 0
        // Advertise our extension map (incl. `ut_pex`) before declaring interest so
        // peers begin gossiping more peers to us over the lifetime of the download.
        if peerSupportsExtensions {
            try await sendExtendedHandshake()
        }
        try await sendMessage(id: 2, payload: Data())
    }

    /// Clears per-connection state so a fresh `openConnection` + plaintext
    /// handshake can be attempted after MSE failed. Availability/metadata state is
    /// untouched — no wire messages were processed yet.
    private func resetForReconnect() {
        inputBuffer.removeAll(keepingCapacity: true)
        sendCipher = nil
        recvCipher = nil
        isChoked = true
        peerSupportsExtensions = false
        sentExtendedHandshake = false
        receivedExtendedHandshake = false
    }

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
    private func mseHandshake() async throws {
        // Step 1 — A→B: DH public key Ya, then random padding PadA.
        let keyPair = MSE.generateKeyPair()
        try await send(keyPair.publicKey + Self.randomPad())

        // Step 2 — B→A: DH public key Yb (first 96 bytes). PadB follows and is
        // skipped during the VC resync below.
        let yb = try await rawReceive(MSE.keyLength)

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
                try await fillInputBuffer()
            }
        }
        // Drop PadB + VC; advance the real cipher past the 8 VC bytes it encrypted.
        inputBuffer.removeFirst(vcEnd!)
        _ = inCipher.process(Data(count: 8))

        let select = inCipher.process(try await rawReceive(4))
        let padDLenBytes = inCipher.process(try await rawReceive(2))
        let padDLen = Int(padDLenBytes[0]) << 8 | Int(padDLenBytes[1])
        if padDLen > 0 {
            guard padDLen <= 1024 else { throw PeerWireError.invalidHandshake }
            _ = inCipher.process(try await rawReceive(padDLen))
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

    /// Returns peers learned from inbound PEX since the last call and clears the
    /// buffer, so the swarm can fold them into its replacement reserve.
    public func takeDiscoveredPeers() -> [PeerEndpoint] {
        defer { discoveredPeers.removeAll(keepingCapacity: true) }
        return Array(discoveredPeers)
    }

    public func readInitialAvailability(pieceCount: Int) async throws -> Set<Int> {
        while !availabilityIsKnown && isChoked {
            try Task.checkCancellation()
            let message = try await readMessage()
            handlePeerStateMessage(message, pieceCount: pieceCount)
        }
        return availablePieces
    }

    /// Current piece availability for this peer, plus whether the peer has
    /// actually declared it. `isKnown` is `false` only when the peer unchoked
    /// before sending any `bitfield`/`have`, so the caller can decide how to
    /// treat the ambiguous case instead of assuming an empty set means "no
    /// pieces". Availability stays current because `bitfield`/`have` messages
    /// received while downloading also update `availablePieces`.
    public func currentAvailability() -> (pieces: Set<Int>, isKnown: Bool) {
        (availablePieces, availabilityIsKnown)
    }

    public func fetchMetadata(pieceSize: Int = 16 * 1024) async throws -> Data {
        try Task.checkCancellation()
        guard peerSupportsExtensions else { throw PeerWireError.extensionProtocolUnavailable }
        try await sendExtendedHandshake()
        try await readUntilMetadataHandshake()
        guard let extensionID = peerMetadataExtensionID, let metadataSize else {
            throw PeerWireError.metadataUnavailable
        }
        guard metadataSize <= Self.maxMetadataSize else {
            throw PeerWireError.metadataUnavailable
        }

        let pieceCount = Int(ceil(Double(metadataSize) / Double(pieceSize)))
        var metadata = Data()
        metadata.reserveCapacity(metadataSize)

        for piece in 0..<pieceCount {
            try Task.checkCancellation()
            try await requestMetadataPiece(piece, extensionID: extensionID)
            let response = try await readMetadataPiece(expectedPiece: piece)
            metadata.append(response)
        }

        guard metadata.count >= metadataSize else { throw PeerWireError.metadataUnavailable }
        return Data(metadata.prefix(metadataSize))
    }

    /// Downloads a piece block by block. `onBlock` is awaited after each 16 KB
    /// block arrives, carrying that block's byte count — the caller uses it to
    /// charge the shared rate limiter at block granularity, so the throttle holds
    /// the combined cap smoothly rather than letting a whole piece burst through
    /// before any pacing is applied.
    public func downloadPiece(index: Int, length: Int, expectedHash: Data, blockSize: Int = 16 * 1024, onBlock: (@Sendable (Int) async -> Void)? = nil) async throws -> Data {
        try Task.checkCancellation()
        var piece = Data(count: length)
        var downloaded = 0

        while downloaded < length {
            try Task.checkCancellation()
            if isChoked {
                try await drainUntilUnchoked()
            }

            let requestLength = min(blockSize, length - downloaded)
            var payload = Data()
            payload.appendUInt32(UInt32(index))
            payload.appendUInt32(UInt32(downloaded))
            payload.appendUInt32(UInt32(requestLength))
            try await sendMessage(id: 6, payload: payload)

            let block = try await readPieceBlock(expectedIndex: index)
            guard block.begin >= 0, block.begin + block.data.count <= piece.count else {
                throw PeerWireError.unexpectedMessage
            }
            piece.replaceSubrange(block.begin..<(block.begin + block.data.count), with: block.data)
            downloaded += block.data.count
            await onBlock?(block.data.count)
        }

        guard Data(Insecure.SHA1.hash(data: piece)) == expectedHash else {
            throw PeerWireError.invalidPieceHash
        }
        return piece
    }

    public func close() {
        connection?.cancel()
        connection = nil
    }

    private func drainUntilUnchoked() async throws {
        while isChoked {
            try Task.checkCancellation()
            let message = try await readMessage()
            handlePeerStateMessage(message)
        }
    }

    private func readPieceBlock(expectedIndex: Int) async throws -> PieceBlock {
        while true {
            try Task.checkCancellation()
            let message = try await readMessage()
            switch message.id {
            case 0:
                isChoked = true
                throw PeerWireError.choked
            case 1:
                isChoked = false
            case 4, 5:
                handlePeerStateMessage(message)
            case 7:
                guard message.payload.count >= 8 else { throw PeerWireError.unexpectedMessage }
                let pieceIndex = Int(message.payload.readUInt32(at: 0))
                guard pieceIndex == expectedIndex else { continue }
                let begin = Int(message.payload.readUInt32(at: 4))
                return PieceBlock(begin: begin, data: Data(message.payload.dropFirst(8)))
            case 20:
                handleExtendedMessage(message.payload)
            default:
                continue
            }
        }
    }

    private func handlePeerStateMessage(_ message: (id: UInt8, payload: Data), pieceCount: Int? = nil) {
        switch message.id {
        case 1:
            isChoked = false
        case 4:
            guard message.payload.count == 4 else { return }
            availablePieces.insert(Int(message.payload.readUInt32(at: 0)))
            availabilityIsKnown = true
        case 5:
            availablePieces = Self.parseBitfield(message.payload, pieceCount: pieceCount)
            availabilityIsKnown = true
        case 20:
            handleExtendedMessage(message.payload)
        default:
            break
        }
    }

    static func parseBitfield(_ payload: Data, pieceCount: Int? = nil) -> Set<Int> {
        var pieces = Set<Int>()
        for (byteOffset, byte) in payload.enumerated() {
            for bit in 0..<8 {
                let pieceIndex = byteOffset * 8 + bit
                if let pieceCount, pieceIndex >= pieceCount { return pieces }
                if byte & (0x80 >> UInt8(bit)) != 0 {
                    pieces.insert(pieceIndex)
                }
            }
        }
        return pieces
    }

    private func sendExtendedHandshake() async throws {
        guard !sentExtendedHandshake else { return }
        sentExtendedHandshake = true
        let payload = Data([0]) + BencodeEncoder.encode([
            "m": .dictionary([
                "ut_metadata": .integer(Int64(Self.localMetadataExtensionID)),
                "ut_pex": .integer(Int64(Self.localPexExtensionID))
            ]),
            "p": .integer(0)
        ])
        try await sendMessage(id: 20, payload: payload)
    }

    private func readUntilMetadataHandshake() async throws {
        // The peer's extension handshake (extended id 0) carries its `ut_metadata`
        // id and `metadata_size`, and is sent once, up front. Loop only until we
        // receive it — not until metadata appears — so a reachable peer that
        // simply doesn't have the metadata (a leecher) is abandoned in ~1 RTT
        // instead of pinning the slot for the full I/O timeout. The caller then
        // sees `peerMetadataExtensionID`/`metadataSize` still nil and fails fast.
        while !receivedExtendedHandshake {
            try Task.checkCancellation()
            let message = try await readMessage()
            if message.id == 20 {
                handleExtendedMessage(message.payload)
            }
        }
    }

    private func requestMetadataPiece(_ piece: Int, extensionID: UInt8) async throws {
        let payload = Data([extensionID]) + BencodeEncoder.encode([
            "msg_type": .integer(0),
            "piece": .integer(Int64(piece))
        ])
        try await sendMessage(id: 20, payload: payload)
    }

    private func readMetadataPiece(expectedPiece: Int) async throws -> Data {
        while true {
            try Task.checkCancellation()
            let message = try await readMessage()
            guard message.id == 20 else { continue }
            guard let extendedID = message.payload.first else { throw PeerWireError.unexpectedMessage }
            if extendedID == 0 {
                handleExtendedMessage(message.payload)
                continue
            }
            // Per BEP 10 the peer tags its metadata reply with the id *we*
            // advertised for `ut_metadata` (not the id it advertised for itself).
            // Route any other extended id (e.g. `ut_pex`) through the normal
            // handler so PEX peers gossiped mid-fetch aren't lost.
            guard extendedID == Self.localMetadataExtensionID else {
                handleExtendedMessage(message.payload)
                continue
            }

            let payload = Data(message.payload.dropFirst())
            let header = try BencodeParser(data: payload).parsePrefix()
            guard case let .dictionary(dictionary) = header.value,
                  dictionary["msg_type"]?.value.intValue == 1,
                  dictionary["piece"]?.value.intValue == Int64(expectedPiece) else {
                continue
            }
            return Data(payload[header.range.upperBound..<payload.endIndex])
        }
    }

    private func handleExtendedMessage(_ payload: Data) {
        guard let extendedID = payload.first else { return }
        let body = Data(payload.dropFirst())
        switch extendedID {
        case 0:
            handleExtendedHandshake(body)
        case Self.localPexExtensionID:
            // A `ut_pex` message addressed to the id we advertised: fold its gossiped
            // peers in (download-only — we consume `added`, never send our own).
            for peer in Self.parsePexAddedPeers(body) where discoveredPeers.count < Self.maxDiscoveredPeers {
                discoveredPeers.insert(peer)
            }
        default:
            break
        }
    }

    private func handleExtendedHandshake(_ body: Data) {
        receivedExtendedHandshake = true
        guard let node = try? BencodeParser(data: body).parse(),
              case let .dictionary(dictionary) = node.value else {
            return
        }
        if case let .dictionary(messages)? = dictionary["m"]?.value,
           let id = messages["ut_metadata"]?.value.intValue,
           id > 0,
           id < 256 {
            peerMetadataExtensionID = UInt8(id)
        }
        if let size = dictionary["metadata_size"]?.value.intValue, size > 0 {
            metadataSize = Int(size)
        }
    }

    /// Parses the compact IPv4 `added` list from a bencoded BEP 11 PEX message
    /// body. IPv6 (`added6`) is ignored, matching the IPv4-only tracker/DHT paths.
    static func parsePexAddedPeers(_ body: Data) -> [PeerEndpoint] {
        guard let node = try? BencodeParser(data: body).parse(),
              case let .dictionary(dictionary) = node.value,
              case let .bytes(added)? = dictionary["added"]?.value else {
            return []
        }
        return TrackerClient.parseCompactPeers(added)
    }

    private func readMessage() async throws -> (id: UInt8, payload: Data) {
        while true {
            let lengthData = try await receiveExactly(4)
            let length = Int(lengthData.readUInt32(at: 0))
            if length == 0 { continue }
            guard length <= Self.maxMessageLength else { throw PeerWireError.unexpectedMessage }
            let body = try await receiveExactly(length)
            guard let id = body.first else { throw PeerWireError.unexpectedMessage }
            return (id, Data(body.dropFirst()))
        }
    }

    private func sendMessage(id: UInt8, payload: Data) async throws {
        var data = Data()
        data.appendUInt32(UInt32(payload.count + 1))
        data.append(id)
        data.append(payload)
        try await send(data)
    }

    private func handshake() -> Data {
        var data = Data()
        data.append(19)
        data.append(Data("BitTorrent protocol".utf8))
        data.append(Data([0, 0, 0, 0, 0, 0x10, 0, 0]))
        data.append(infoHash)
        data.append(peerID)
        return data
    }

    private func send(_ data: Data) async throws {
        try Task.checkCancellation()
        guard let connection else { throw PeerWireError.disconnected }
        let outgoing: Data
        if var cipher = sendCipher {
            outgoing = cipher.process(data)
            sendCipher = cipher
        } else {
            outgoing = data
        }
        try await withTimeout(ioTimeout) {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    connection.send(content: outgoing, completion: .contentProcessed { error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    })
                }
            } onCancel: {
                connection.cancel()
            }
        }
    }

    /// Reads exactly `count` bytes, decrypting through `recvCipher` when the MSE
    /// handshake selected RC4 (raw bytes otherwise). Drains the input buffer first
    /// so bytes over-read during the MSE resync are consumed in order.
    private func receiveExactly(_ count: Int) async throws -> Data {
        let raw = try await rawReceive(count)
        guard var cipher = recvCipher else { return raw }
        let plain = cipher.process(raw)
        recvCipher = cipher
        return plain
    }

    /// Removes and returns exactly `count` raw (undecrypted) bytes from the input
    /// buffer, reading from the socket as needed.
    private func rawReceive(_ count: Int) async throws -> Data {
        while inputBuffer.count < count {
            try await fillInputBuffer()
        }
        let head = Data(inputBuffer[0..<count])
        inputBuffer.removeFirst(count)
        return head
    }

    /// Appends one socket read to the raw input buffer.
    private func fillInputBuffer() async throws {
        try Task.checkCancellation()
        guard let connection else { throw PeerWireError.disconnected }
        let chunk = try await withTimeout(ioTimeout) {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else if let data, !data.isEmpty {
                            continuation.resume(returning: data)
                        } else {
                            continuation.resume(throwing: PeerWireError.disconnected)
                        }
                    }
                }
            } onCancel: {
                connection.cancel()
            }
        }
        inputBuffer.append(contentsOf: chunk)
    }

    /// Races `operation` against a sleeping timer. If the timer wins, the
    /// structured task group cancels the operation task on scope exit, whose
    /// `onCancel` cancels the underlying `NWConnection`, so the parked
    /// continuation resumes and nothing leaks. Surfaced error is `.timedOut`.
    private func withTimeout<T: Sendable>(
        _ seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw PeerWireError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw PeerWireError.timedOut
            }
            return result
        }
    }
}

extension Data {
    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    func readUInt32(at offset: Int) -> UInt32 {
        UInt32(self[offset]) << 24 | UInt32(self[offset + 1]) << 16 | UInt32(self[offset + 2]) << 8 | UInt32(self[offset + 3])
    }
}
