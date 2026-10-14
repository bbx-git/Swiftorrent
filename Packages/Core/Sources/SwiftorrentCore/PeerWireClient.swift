import Foundation

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
        /// TCP with a 1 s head start, then uTP alongside it; the first ready wins.
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

    private let endpoint: PeerEndpoint
    let infoHash: Data
    private let peerID: Data
    /// Cap on a uTP connect once a peer is known to need uTP.
    private static let utpConnectTimeout: TimeInterval = 5
    /// How long TCP gets on its own before uTP is tried alongside it. Reachable
    /// peers answer TCP in ~0.2 s (median); in public swarms about 40% of the
    /// reachable peers answer only uTP, and waiting out the TCP timeout first
    /// delayed each of those by the full `connectTimeout`.
    private static let utpHeadStart: Duration = .seconds(1)
    /// Upper bound on how long the TCP connection may take to become ready.
    private let connectTimeout: TimeInterval
    /// Upper bound on any single send/receive wire operation. A peer that goes
    /// silent mid-message is torn down within this window instead of parking a
    /// download slot forever.
    let ioTimeout: TimeInterval
    /// Peer-pool retention timeouts used by `downloadPieces`: `snubTimeout` drops an
    /// unchoked peer that stops delivering data; `idleTimeout` drops a choked/idle
    /// peer only after long silence (otherwise the connection is kept, waiting for an
    /// unchoke). Instance-settable so tests can drive them deterministically.
    let snubTimeout: TimeInterval
    let idleTimeout: TimeInterval
    private let encryptionPolicy: EncryptionPolicy
    private let transportPolicy: TransportPolicy
    var transport: (any PeerTransport)?
    /// Set once uTP won the connect race (or from the start under `.utpOnly`).
    private var usesUTP: Bool
    /// Once the MSE handshake selects RC4, `sendCipher` encrypts our outgoing
    /// bytes and `recvCipher` decrypts the peer's — both `nil` on a plaintext
    /// connection. RC4 is a stream cipher, so running bytes through in order works
    /// regardless of how sends/receives are chunked.
    var sendCipher: RC4?
    var recvCipher: RC4?
    /// Raw (still-encrypted) bytes received from the socket but not yet consumed.
    /// Every receive drains this first, so the MSE VC resync can over-read while
    /// scanning without losing the payload bytes that follow.
    var inputBuffer = [UInt8]()
    var isChoked = true
    var peerSupportsExtensions = false
    var peerMetadataExtensionID: UInt8?
    var metadataSize: Int?
    var availablePieces = Set<Int>()
    var availabilityIsKnown = false
    /// Piece count of the torrent, once known. Bounds `have`/`bitfield` from the
    /// peer so a hostile one cannot grow `availablePieces` without limit.
    var knownPieceCount: Int?
    /// Guards against re-sending our extension handshake when both `connect()` and
    /// `fetchMetadata()` would otherwise send one.
    var sentExtendedHandshake = false
    /// Set once the peer's BEP 10 extension handshake (extended id 0) arrives.
    /// Lets the metadata path stop waiting as soon as we know whether the peer
    /// offers `ut_metadata`, rather than blocking until the I/O timeout.
    var receivedExtendedHandshake = false
    /// Peers learned from inbound BEP 11 PEX `added` lists during this session,
    /// drained by the swarm so dead connections are replaced from gossiped peers.
    var discoveredPeers = Set<PeerEndpoint>()

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
    /// `connectTimeout`). Under `.auto`, TCP gets `utpHeadStart`, then uTP is tried
    /// alongside it and the first one ready is kept; once uTP was used, reconnects
    /// go straight to it. Resets any buffered input from a prior attempt.
    private func openConnection() async throws {
        try Task.checkCancellation()
        inputBuffer.removeAll(keepingCapacity: true)
        if usesUTP {
            let utp = try UTPPeerTransport(endpoint: endpoint)
            transport = utp
            try await withTimeout(min(connectTimeout, Self.utpConnectTimeout)) { try await utp.open() }
            return
        }
        let tcp = try TCPPeerTransport(endpoint: endpoint)
        guard transportPolicy == .auto else {
            transport = tcp
            try await withTimeout(connectTimeout) { try await tcp.open() }
            return
        }
        let endpoint = endpoint
        let opened = try await withTimeout(connectTimeout) {
            try await openFirst(primary: tcp, fallback: { try UTPPeerTransport(endpoint: endpoint) }, fallbackDelay: Self.utpHeadStart)
        }
        transport = opened.transport
        usesUTP = opened.isFallback
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

    public func close() {
        transport?.close()
        transport = nil
    }

    /// Reads one wire message. `timeout` bounds each underlying socket read; it
    /// defaults to `ioTimeout` (handshake/setup) but `downloadPieces` passes a longer
    /// idle window so a choked-but-alive peer is kept rather than reaped every 30 s.
    ///
    /// `deadline` bounds the whole call, keep-alives included: each socket read is
    /// capped to the time remaining, and an empty (keep-alive) message cannot
    /// extend it. Without it a peer sending keep-alives forever resets every
    /// per-read timeout.
    func readMessage(
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

    func sendMessage(id: UInt8, payload: Data) async throws {
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

    func send(_ data: Data) async throws {
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
    func rawReceive(_ count: Int, timeout: TimeInterval) async throws -> Data {
        while inputBuffer.count < count {
            try await fillInputBuffer(timeout: timeout)
        }
        let head = Data(inputBuffer[0..<count])
        inputBuffer.removeFirst(count)
        return head
    }

    /// Appends one socket read to the raw input buffer.
    func fillInputBuffer(timeout: TimeInterval) async throws {
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
