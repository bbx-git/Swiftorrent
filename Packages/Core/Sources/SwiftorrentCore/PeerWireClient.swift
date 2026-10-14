import CryptoKit
import Foundation
import Network

public enum PeerWireError: Error, LocalizedError {
    case connectionFailed
    case invalidHandshake
    case disconnected
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
    /// Floor/ceiling on the in-flight block-request window, which `downloadPieces`
    /// sizes **adaptively** per peer (like libtorrent): the target is roughly
    /// `requestQueueTargetSeconds` of the peer's *measured* rate, so a slow peer keeps
    /// a shallow queue (little wasted memory across a large pool) while a fast seed
    /// gets a deep one that covers its bandwidth × RTT. The window spans piece
    /// boundaries, so it never drains between pieces. 256 blocks = 4 MB caps a very
    /// fast peer; 16 is the warm-up floor before any rate is known.
    static let minPipelinedBlocks = 16
    static let maxPipelinedBlocks = 256
    /// How many seconds of the peer's measured throughput to keep queued as requests.
    static let requestQueueTargetSeconds: Double = 2
    /// Snub timeout: once we are unchoked with requests outstanding, a peer that
    /// sends no data for this long is snubbing us — drop it and let the worker draw
    /// a fresh peer. This is BitTorrent's real "not delivering" signal (no *data*),
    /// not "still choked".
    public static let snubTimeoutSeconds: TimeInterval = 30
    /// Idle timeout: while choked (or otherwise not actively receiving), we keep the
    /// connection open — like a mainstream client's large peer pool — waiting for the
    /// peer to unchoke us, and only drop it after this long of total silence. Chosen
    /// under the ~2-minute peer keep-alive interval so a still-alive peer that
    /// keep-alives is retained while a truly dead socket is reaped.
    public static let idleTimeoutSeconds: TimeInterval = 90

    /// Which transports a connection may use. `.auto` is the default; the other
    /// two exist so the benchmark can measure each transport on its own.
    public enum TransportPolicy: Sendable {
        /// TCP first, uTP when TCP cannot connect.
        case auto
        case tcpOnly
        case utpOnly
    }

    /// Policy for clients that don't pass one. Set once at startup (by the
    /// benchmark) before any connection is made.
    nonisolated(unsafe) public static var defaultTransportPolicy = TransportPolicy.auto

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
    /// A uTP fallback only adds this much to a dead peer's connect time.
    private static let utpConnectTimeout: TimeInterval = 5
    /// Upper bound on how long the TCP connection may take to become ready.
    private let connectTimeout: TimeInterval
    /// Upper bound on any single send/receive wire operation. A peer that goes
    /// silent mid-message is torn down within this window instead of parking a
    /// download slot forever.
    private let ioTimeout: TimeInterval
    /// Peer-pool retention timeouts used by `downloadPieces`: `snubTimeout` drops an
    /// unchoked peer that stops delivering data; `idleTimeout` drops a choked/idle
    /// peer only after long silence (otherwise the connection is kept, waiting for an
    /// unchoke). Instance-settable so tests can drive them deterministically.
    private let snubTimeout: TimeInterval
    private let idleTimeout: TimeInterval
    private let encryptionPolicy: EncryptionPolicy
    private let transportPolicy: TransportPolicy
    private var transport: (any PeerTransport)?
    /// Set once TCP failed to connect and uTP was used instead (or from the start
    /// under `.utpOnly`).
    private var usesUTP: Bool
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
    /// Piece count of the torrent, once known. Bounds `have`/`bitfield` from the
    /// peer so a hostile one cannot grow `availablePieces` without limit.
    private var knownPieceCount: Int?
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
        snubTimeout: TimeInterval = PeerWireClient.snubTimeoutSeconds,
        idleTimeout: TimeInterval = PeerWireClient.idleTimeoutSeconds,
        encryptionPolicy: EncryptionPolicy = .preferEncrypted,
        transportPolicy: TransportPolicy = PeerWireClient.defaultTransportPolicy
    ) {
        self.endpoint = endpoint
        self.infoHash = infoHash
        self.peerID = peerID
        self.connectTimeout = connectTimeout
        self.ioTimeout = ioTimeout
        self.snubTimeout = snubTimeout
        self.idleTimeout = idleTimeout
        self.encryptionPolicy = encryptionPolicy
        self.transportPolicy = transportPolicy
        usesUTP = transportPolicy == .utpOnly
    }

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

    /// Opens the connection and waits for it to become ready (bounded by
    /// `connectTimeout`). Tries TCP first and falls back to uTP when TCP cannot
    /// connect; once uTP was needed, reconnects go straight to it. Resets any
    /// buffered input from a prior attempt.
    private func openConnection() async throws {
        try Task.checkCancellation()
        inputBuffer.removeAll(keepingCapacity: true)
        if !usesUTP {
            let tcp = try TCPPeerTransport(endpoint: endpoint)
            transport = tcp
            do {
                try await withTimeout(connectTimeout) { try await tcp.open() }
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                tcp.close()
                guard transportPolicy == .auto else { throw error }
                usesUTP = true
            }
        }
        let utp = try UTPPeerTransport(endpoint: endpoint)
        transport = utp
        try await withTimeout(min(connectTimeout, Self.utpConnectTimeout)) { try await utp.open() }
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

    /// Returns peers learned from inbound PEX since the last call and clears the
    /// buffer, so the swarm can fold them into its replacement reserve.
    public func takeDiscoveredPeers() -> [PeerEndpoint] {
        defer { discoveredPeers.removeAll(keepingCapacity: true) }
        return Array(discoveredPeers)
    }

    public func readInitialAvailability(pieceCount: Int) async throws -> Set<Int> {
        knownPieceCount = pieceCount
        while !availabilityIsKnown && isChoked {
            try Task.checkCancellation()
            let message = try await readMessage()
            handlePeerStateMessage(message, pieceCount: pieceCount)
        }
        return availablePieces
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
            // BEP 9: every piece is exactly `pieceSize` bytes except the last. Anything
            // else is bogus, and without this check a hostile peer could make us
            // buffer up to a megabyte per piece.
            let expected = min(pieceSize, metadataSize - piece * pieceSize)
            guard response.count == expected else { throw PeerWireError.metadataUnavailable }
            metadata.append(response)
        }

        guard metadata.count >= metadataSize else { throw PeerWireError.metadataUnavailable }
        return Data(metadata.prefix(metadataSize))
    }

    /// Downloads a continuous stream of pieces from this peer over a **cross-piece**
    /// request pipeline, the way a mainstream client (libtorrent/qBittorrent) drives a
    /// peer connection. Key behaviours:
    ///
    /// - **Cross-piece pipelining.** A window of block requests is kept outstanding
    ///   at all times, spanning piece boundaries — the moment a piece's last block is
    ///   requested the pipeline claims the next piece and keeps filling, so the peer's
    ///   send queue never drains between pieces (the inter-piece bubble that pins a
    ///   fast seed below its line rate).
    /// - **Adaptive window.** The window is sized to ~`requestQueueTargetSeconds` of
    ///   the peer's *measured* rate, clamped to `[minPipelinedBlocks, maxPipelinedBlocks]`,
    ///   so a slow peer keeps a shallow queue and a fast seed a deep one.
    /// - **Hold through chokes.** A choke is normal, not a reason to disconnect. On a
    ///   choke we requeue the discarded requests and keep the connection open, waiting
    ///   for the peer to unchoke us again — the connection is dropped only on *silence*
    ///   (`idleTimeout`), so a still-alive peer that may unchoke us later is retained
    ///   like an entry in a mainstream client's large peer pool.
    /// - **Snubbing.** Once unchoked with requests outstanding, a peer that stops
    ///   sending data for `snubTimeout` is snubbing us; we drop it (via a read timeout)
    ///   so the worker can draw a fresher peer. That is BitTorrent's true "not
    ///   delivering" signal — no *data* — rather than merely "still choked".
    ///
    /// Pieces are claimed lazily via `claimNextPiece`, assembled out of order,
    /// SHA-1-verified on completion, and handed to `onPieceComplete` (write +
    /// accounting). Every claimed-but-unfinished piece is handed back via
    /// `onReturnPiece` on any early exit so the coordinator can requeue it.
    ///
    /// - `claimNextPiece` receives this peer's live availability (whether it was
    ///   declared, and the pieces this peer is already assembling so endgame never
    ///   re-hands one) and returns the next piece to fetch, or nil when the peer has
    ///   nothing more we need — at which point the session ends cleanly.
    /// - `onBlock` is awaited per block with its byte count (rate-limit pacing +
    ///   live-speed accounting); `onPeersDiscovered` folds inbound PEX gossip.
    /// - `completedElsewhere` (endgame): given the pieces this peer is still
    ///   assembling, returns the subset another peer has already finished. We send a
    ///   BEP-3 `cancel` for each still-outstanding block of those pieces and drop
    ///   them, reclaiming the tail bandwidth endgame duplication would otherwise burn
    ///   finishing an already-verified copy. Polled on a throttle so it stays off the
    ///   hot path, and returns empty outside endgame.
    public func downloadPieces(
        blockSize: Int = 16 * 1024,
        pieceCount: Int? = nil,
        pieceLength: @Sendable (Int) -> Int,
        expectedHash: @Sendable (Int) -> Data,
        claimNextPiece: @Sendable (_ available: Set<Int>, _ isKnown: Bool, _ held: Set<Int>) async -> Int?,
        onPieceComplete: @Sendable (Int, Data) async throws -> Void,
        onReturnPiece: @Sendable (Int) async -> Void,
        onBlock: (@Sendable (Int) async -> Void)? = nil,
        onPeersDiscovered: (@Sendable ([PeerEndpoint]) async -> Void)? = nil,
        completedElsewhere: (@Sendable (_ held: Set<Int>) async -> Set<Int>)? = nil
    ) async throws {
        if let pieceCount { knownPieceCount = pieceCount }
        var active: [Int: PieceAssembly] = [:]           // claimed, still assembling
        var requestQueue: [(piece: Int, begin: Int, length: Int)] = []   // not yet requested
        var outstanding = Set<BlockKey>()                // requested, awaiting data
        var noMorePieces = false

        // Adaptive request window: recomputed ~once a second from the peer's measured
        // rate so the in-flight depth tracks its bandwidth. Starts at the floor and
        // grows as data flows.
        let clock = ContinuousClock()
        var windowCap = Self.minPipelinedBlocks
        var rateWindowStart = clock.now
        var rateWindowBytes = 0
        // Endgame: throttle how often we ask whether a held piece was completed by
        // another peer, so this stays off the per-block hot path.
        var lastCancelCheck = clock.now
        // When the last block of data arrived (or when we first started waiting for
        // one). The snub deadline runs from here and is NOT extended by keep-alives
        // or other chatter, so a peer cannot hold a worker slot without sending data.
        var lastDataAt = clock.now

        func returnAll() async {
            for index in active.keys { await onReturnPiece(index) }
        }

        do {
            while true {
                try Task.checkCancellation()

                // Resize the request window from the rate measured over the last ~1 s.
                let sinceRateSample = rateWindowStart.duration(to: clock.now)
                let rateSeconds = Double(sinceRateSample.components.seconds) + Double(sinceRateSample.components.attoseconds) / 1e18
                if rateSeconds >= 1 {
                    let bytesPerSecond = Double(rateWindowBytes) / rateSeconds
                    let target = Int(bytesPerSecond * Self.requestQueueTargetSeconds / Double(blockSize))
                    windowCap = min(Self.maxPipelinedBlocks, max(Self.minPipelinedBlocks, target))
                    rateWindowStart = clock.now
                    rateWindowBytes = 0
                }

                // Endgame cancel: drop any held piece another peer already finished and
                // send a `cancel` for its still-outstanding blocks, so we don't spend
                // the tail redownloading a verified duplicate. Throttled; a no-op until
                // endgame (when the same piece is handed to several peers at once).
                if let completedElsewhere, !active.isEmpty,
                   lastCancelCheck.duration(to: clock.now) >= .milliseconds(250) {
                    lastCancelCheck = clock.now
                    for piece in await completedElsewhere(Set(active.keys)) {
                        active.removeValue(forKey: piece)
                        requestQueue.removeAll { $0.piece == piece }
                        let toCancel = outstanding.filter { $0.piece == piece }
                        outstanding.subtract(toCancel)
                        for key in toCancel {
                            let length = min(blockSize, pieceLength(piece) - key.begin)
                            var payload = Data()
                            payload.appendUInt32(UInt32(key.piece))
                            payload.appendUInt32(UInt32(key.begin))
                            payload.appendUInt32(UInt32(length))
                            try await sendMessage(id: 8, payload: payload)
                        }
                    }
                }

                // Fill the pipeline while unchoked: claim fresh pieces as the queue
                // drains and send block requests until the (adaptive) window is full
                // or the peer has nothing left we need.
                while !isChoked, outstanding.count < windowCap {
                    if requestQueue.isEmpty {
                        if noMorePieces { break }
                        // Fold peers this connection gossiped before claiming more work.
                        if let onPeersDiscovered {
                            let gossiped = takeDiscoveredPeers()
                            if !gossiped.isEmpty { await onPeersDiscovered(gossiped) }
                        }
                        guard let index = await claimNextPiece(availablePieces, availabilityIsKnown, Set(active.keys)) else {
                            noMorePieces = true
                            break
                        }
                        let length = pieceLength(index)
                        var begins: [Int] = []
                        var offset = 0
                        while offset < length { begins.append(offset); offset += blockSize }
                        active[index] = PieceAssembly(length: length, blockBegins: begins, hash: expectedHash(index))
                        for begin in begins {
                            requestQueue.append((index, begin, min(blockSize, length - begin)))
                        }
                    }
                    guard !requestQueue.isEmpty else { break }
                    let request = requestQueue.removeFirst()
                    if outstanding.isEmpty { lastDataAt = clock.now }
                    var payload = Data()
                    payload.appendUInt32(UInt32(request.piece))
                    payload.appendUInt32(UInt32(request.begin))
                    payload.appendUInt32(UInt32(request.length))
                    try await sendMessage(id: 6, payload: payload)
                    outstanding.insert(BlockKey(piece: request.piece, begin: request.begin))
                }

                // Everything claimed has been assembled and the peer has nothing more
                // we need: a clean end (the worker draws its next peer).
                if active.isEmpty && noMorePieces { return }

                // Read the next message. With requests outstanding we expect data, so a
                // short `snubTimeout` reaps a peer that stalls; otherwise (choked/idle)
                // we wait the longer `idleTimeout`, keeping the connection open for a
                // possible unchoke rather than dropping it. A fired timeout throws
                // `.timedOut`, which the outer catch turns into a peer replacement.
                let readTimeout = outstanding.isEmpty ? idleTimeout : snubTimeout
                let snubDeadline: ContinuousClock.Instant? = outstanding.isEmpty
                    ? nil
                    : lastDataAt + .seconds(snubTimeout)
                let message = try await readMessage(timeout: readTimeout, deadline: snubDeadline)

                switch message.id {
                case 0:
                    // Choke: the peer drops every request in flight. Requeue the
                    // still-missing blocks (front of the queue) to re-send on unchoke.
                    isChoked = true
                    for key in outstanding {
                        guard let asm = active[key.piece] else { continue }
                        requestQueue.insert((key.piece, key.begin, min(blockSize, asm.length - key.begin)), at: 0)
                    }
                    outstanding.removeAll()
                case 1:
                    isChoked = false
                case 4, 5:
                    handlePeerStateMessage(message)
                case 7:
                    guard message.payload.count >= 8 else { throw PeerWireError.unexpectedMessage }
                    let pieceIndex = Int(message.payload.readUInt32(at: 0))
                    let begin = Int(message.payload.readUInt32(at: 4))
                    let data = Data(message.payload.dropFirst(8))
                    outstanding.remove(BlockKey(piece: pieceIndex, begin: begin))
                    guard let asm = active[pieceIndex] else { continue }   // stale/unwanted
                    // We only ever request whole blocks on a fixed grid, so anything else
                    // is a misbehaving peer.
                    guard begin >= 0, begin % blockSize == 0, begin < asm.length,
                          data.count == min(blockSize, asm.length - begin) else {
                        throw PeerWireError.unexpectedMessage
                    }
                    lastDataAt = clock.now
                    if asm.received.insert(begin).inserted {
                        asm.data.replaceSubrange(begin..<(begin + data.count), with: data)
                        rateWindowBytes += data.count
                        await onBlock?(data.count)
                        if asm.received.count == asm.blockBegins.count {
                            active.removeValue(forKey: pieceIndex)
                            guard Data(Insecure.SHA1.hash(data: asm.data)) == asm.hash else {
                                await onReturnPiece(pieceIndex)
                                throw PeerWireError.invalidPieceHash
                            }
                            try await onPieceComplete(pieceIndex, asm.data)
                        }
                    }
                case 20:
                    handleExtendedMessage(message.payload)
                default:
                    continue
                }
            }
        } catch {
            // Any early exit (choke-out, disconnect, cancellation, bad piece): hand
            // every still-unfinished piece back so another peer retries it.
            await returnAll()
            throw error
        }
    }

    public func close() {
        transport?.close()
        transport = nil
    }

    private func handlePeerStateMessage(_ message: (id: UInt8, payload: Data), pieceCount: Int? = nil) {
        switch message.id {
        case 1:
            isChoked = false
        case 4:
            guard message.payload.count == 4 else { return }
            let index = Int(message.payload.readUInt32(at: 0))
            if let limit = pieceCount ?? knownPieceCount, index >= limit { return }
            availablePieces.insert(index)
            availabilityIsKnown = true
        case 5:
            availablePieces = Self.parseBitfield(message.payload, pieceCount: pieceCount ?? knownPieceCount)
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
        let deadline = ContinuousClock.now + .seconds(ioTimeout)
        while !receivedExtendedHandshake {
            try Task.checkCancellation()
            let message = try await readMessage(deadline: deadline)
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
        // Bounds the whole wait for this piece, so a peer streaming unrelated
        // messages cannot keep the loop alive indefinitely.
        let deadline = ContinuousClock.now + .seconds(ioTimeout)
        while true {
            try Task.checkCancellation()
            let message = try await readMessage(deadline: deadline)
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

    /// Reads one wire message. `timeout` bounds each underlying socket read; it
    /// defaults to `ioTimeout` (handshake/setup) but `downloadPieces` passes a longer
    /// idle window so a choked-but-alive peer is kept rather than reaped every 30 s.
    ///
    /// `deadline` bounds the whole call, keep-alives included: each socket read is
    /// capped to the time remaining, and an empty (keep-alive) message cannot
    /// extend it. Without it a peer sending keep-alives forever resets every
    /// per-read timeout.
    private func readMessage(
        timeout: TimeInterval? = nil,
        deadline: ContinuousClock.Instant? = nil
    ) async throws -> (id: UInt8, payload: Data) {
        while true {
            var perRead = timeout
            if let deadline {
                let remaining = ContinuousClock.now.duration(to: deadline)
                let seconds = Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18
                guard seconds > 0 else { throw PeerWireError.timedOut }
                perRead = min(timeout ?? ioTimeout, seconds)
            }
            let lengthData = try await receiveExactly(4, timeout: perRead)
            let length = Int(lengthData.readUInt32(at: 0))
            if length == 0 { continue }
            guard length <= Self.maxMessageLength else { throw PeerWireError.unexpectedMessage }
            let body = try await receiveExactly(length, timeout: perRead)
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
        guard let transport else { throw PeerWireError.disconnected }
        let outgoing: Data
        if var cipher = sendCipher {
            outgoing = cipher.process(data)
            sendCipher = cipher
        } else {
            outgoing = data
        }
        try await withTimeout(ioTimeout) {
            try await transport.send(outgoing)
        }
    }

    /// Reads exactly `count` bytes, decrypting through `recvCipher` when the MSE
    /// handshake selected RC4 (raw bytes otherwise). Drains the input buffer first
    /// so bytes over-read during the MSE resync are consumed in order.
    private func receiveExactly(_ count: Int, timeout: TimeInterval? = nil) async throws -> Data {
        let raw = try await rawReceive(count, timeout: timeout ?? ioTimeout)
        guard var cipher = recvCipher else { return raw }
        let plain = cipher.process(raw)
        recvCipher = cipher
        return plain
    }

    /// Removes and returns exactly `count` raw (undecrypted) bytes from the input
    /// buffer, reading from the socket as needed.
    private func rawReceive(_ count: Int, timeout: TimeInterval) async throws -> Data {
        while inputBuffer.count < count {
            try await fillInputBuffer(timeout: timeout)
        }
        let head = Data(inputBuffer[0..<count])
        inputBuffer.removeFirst(count)
        return head
    }

    /// Appends one socket read to the raw input buffer.
    private func fillInputBuffer(timeout: TimeInterval) async throws {
        try Task.checkCancellation()
        guard let transport else { throw PeerWireError.disconnected }
        let chunk = try await withTimeout(timeout) {
            try await transport.receive()
        }
        inputBuffer.append(contentsOf: chunk)
    }

    /// Fails with `.timedOut` after `seconds`. Cancelling the operation runs the
    /// transport's cancellation handler, which closes it, so a parked receive
    /// resumes and nothing leaks.
    private func withTimeout<T: Sendable>(
        _ seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withDeadline(.seconds(seconds), timeoutError: PeerWireError.timedOut, operation: operation)
    }
}

/// A piece being assembled block-by-block inside a peer session. A reference type
/// so the pipeline mutates its buffer in place — copying a 256 KB `Data` value on
/// every one of the ~16 blocks per piece would swamp the transfer. Lives only in
/// `PeerWireClient`'s actor-isolated state, so it never crosses a concurrency
/// boundary and needs no `Sendable` conformance.
private final class PieceAssembly {
    var data: Data
    var received = Set<Int>()
    let blockBegins: [Int]
    let length: Int
    let hash: Data

    init(length: Int, blockBegins: [Int], hash: Data) {
        self.data = Data(count: length)
        self.blockBegins = blockBegins
        self.length = length
        self.hash = hash
    }
}

/// Identifies one outstanding block request by its piece and offset, so a block
/// can be matched back to its request across piece boundaries in the pipeline.
private struct BlockKey: Hashable {
    let piece: Int
    let begin: Int
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
