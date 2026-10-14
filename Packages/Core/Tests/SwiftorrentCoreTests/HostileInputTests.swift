import CryptoKit
import Foundation
import Network
@testable import SwiftorrentCore
import Testing

@Suite("Hostile input")
struct HostileInputTests {
    // MARK: Bencode depth

    @Test("Deeply nested bencode is rejected instead of overflowing the stack")
    func bencodeRejectsDeepNesting() {
        let depth = 200_000
        let data = Data(repeating: UInt8(ascii: "l"), count: depth) + Data(repeating: UInt8(ascii: "e"), count: depth)

        #expect(throws: BencodeError.nestingTooDeep) {
            try BencodeParser(data: data).parse()
        }
    }

    @Test("Moderately nested bencode still parses")
    func bencodeAcceptsReasonableNesting() throws {
        let depth = 20
        let data = Data(repeating: UInt8(ascii: "l"), count: depth) + Data(repeating: UInt8(ascii: "e"), count: depth)

        _ = try BencodeParser(data: data).parse()
    }

    // MARK: Metainfo validation

    private func info(
        pieceLength: Int64 = 16384,
        pieceCount: Int,
        length: Int64? = nil,
        files: [Int64]? = nil
    ) -> Data {
        var dictionary: [String: BencodeEncodableValue] = [
            "name": .string("t"),
            "piece length": .integer(pieceLength),
            "pieces": .bytes(Data(repeating: 0, count: 20 * pieceCount))
        ]
        if let length {
            dictionary["length"] = .integer(length)
        }
        if let files {
            dictionary["files"] = .list(files.enumerated().map { index, size in
                .dictionary(["length": .integer(size), "path": .list([.string("f\(index)")])])
            })
        }
        return BencodeEncoder.encode(dictionary)
    }

    private func parse(_ data: Data) throws -> TorrentMetainfo {
        try TorrentMetainfoParser().parseInfoDictionary(data: data, announceURLs: [])
    }

    @Test("A well-formed single-file torrent parses")
    func validMetainfoParses() throws {
        let metainfo = try parse(info(pieceCount: 2, length: 20_000))

        #expect(metainfo.totalSize == 20_000)
        #expect(metainfo.pieceHashes.count == 2)
    }

    @Test("Negative file length is rejected")
    func negativeFileLength() {
        #expect(throws: TorrentMetainfoError.invalidFileLength) {
            try parse(info(pieceCount: 1, length: -5))
        }
        #expect(throws: TorrentMetainfoError.invalidFileLength) {
            try parse(info(pieceCount: 1, files: [10, -1]))
        }
    }

    @Test("File lengths that overflow the total are rejected, not trapped")
    func overflowingFileLengths() {
        #expect(throws: TorrentMetainfoError.invalidFileLength) {
            try parse(info(pieceCount: 1, files: [Int64.max, Int64.max]))
        }
    }

    @Test("Absurd piece length is rejected")
    func hugePieceLength() {
        #expect(throws: TorrentMetainfoError.invalidPieceLength) {
            try parse(info(pieceLength: 1 << 40, pieceCount: 1, length: 1000))
        }
    }

    @Test("Piece hash count must match the total size")
    func pieceCountMismatch() {
        // 20_000 bytes at 16 KiB needs 2 pieces.
        #expect(throws: TorrentMetainfoError.invalidPieces) {
            try parse(info(pieceCount: 1, length: 20_000))
        }
        #expect(throws: TorrentMetainfoError.invalidPieces) {
            try parse(info(pieceCount: 5, length: 20_000))
        }
    }
}

// MARK: - Hostile peer scenarios

/// A loopback peer that completes the BitTorrent handshake and then plays a fixed
/// script of (delay, bytes) steps, ignoring whatever the client sends.
private final class ScriptedPeer: @unchecked Sendable {
    typealias Step = (delay: TimeInterval, bytes: Data)

    private let infoHash: Data
    private let supportsExtensions: Bool
    private let script: [Step]
    private let queue = DispatchQueue(label: "scripted-peer")
    private let listener: NWListener
    private let lock = NSLock()
    private var connections: [NWConnection] = []

    init(infoHash: Data, supportsExtensions: Bool = false, script: [Step]) throws {
        self.infoHash = infoHash
        self.supportsExtensions = supportsExtensions
        self.script = script
        listener = try NWListener(using: .tcp)
    }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [self] connection in
            lock.lock(); connections.append(connection); lock.unlock()
            serve(connection)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let resume = ResumeOnce(continuation)
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    if let port = listener.port { resume.resume(returning: port.rawValue) }
                case let .failed(error):
                    resume.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        lock.lock(); let all = connections; lock.unlock()
        all.forEach { $0.cancel() }
    }

    private func serve(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [self] state in
            guard case .ready = state else { return }
            connection.stateUpdateHandler = nil
            var reserved = Data(count: 8)
            if supportsExtensions { reserved[5] = 0x10 }
            let greeting = Data([19]) + Data("BitTorrent protocol".utf8) + reserved + infoHash + Data(repeating: 7, count: 20)
            connection.send(content: greeting, completion: .contentProcessed { _ in })
            // Drain whatever the client sends so its writes never block.
            drain(connection)
            var elapsed: TimeInterval = 0
            for step in script {
                elapsed += step.delay
                queue.asyncAfter(deadline: .now() + elapsed) {
                    connection.send(content: step.bytes, completion: .contentProcessed { _ in })
                }
            }
        }
        connection.start(queue: queue)
    }

    private func drain(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, isComplete, error in
            if error == nil, !isComplete, data != nil { drain(connection) }
        }
    }
}

private func frame(_ id: UInt8, _ payload: Data = Data()) -> Data {
    var length = Data()
    length.appendUInt32(UInt32(payload.count + 1))
    return length + Data([id]) + payload
}

private func u32(_ value: Int) -> Data {
    var data = Data()
    data.appendUInt32(UInt32(value))
    return data
}

private actor Claims {
    private(set) var seenSizes: [Int] = []
    private var handed: Bool

    /// - Parameter handOut: when `false`, never hands out a piece (only records
    ///   the availability it was shown).
    init(handOut: Bool = true) {
        handed = !handOut
    }

    func claim(available: Set<Int>) -> Int? {
        seenSizes.append(available.count)
        if handed { return nil }
        handed = true
        return 0
    }
}

@Suite("Hostile peers")
struct HostilePeerTests {
    private let infoHash = Data(repeating: 0x5A, count: 20)

    private func makeClient(port: UInt16, snub: TimeInterval = 1.5, idle: TimeInterval = 5) -> PeerWireClient {
        PeerWireClient(
            endpoint: PeerEndpoint(host: "127.0.0.1", port: port),
            infoHash: infoHash,
            peerID: Data(repeating: 1, count: 20),
            connectTimeout: 2,
            ioTimeout: 2,
            snubTimeout: snub,
            idleTimeout: idle,
            encryptionPolicy: .plaintextOnly
        )
    }

    private func runDownload(
        _ client: PeerWireClient,
        claims: Claims,
        pieceCount: Int = 1,
        pieceLength: Int = 10
    ) async -> Error? {
        do {
            try await client.connect()
            _ = try await client.readInitialAvailability(pieceCount: pieceCount)
            try await client.downloadPieces(
                blockSize: 4,
                pieceLength: { _ in pieceLength },
                expectedHash: { _ in Data(repeating: 0, count: 20) },
                claimNextPiece: { available, _, _ in await claims.claim(available: available) },
                onPieceComplete: { _, _ in },
                onReturnPiece: { _ in }
            )
            return nil
        } catch {
            return error
        }
    }

    @Test("A bitfield or have beyond the piece count cannot grow availability")
    func availabilityIsBounded() async throws {
        let hugeBitfield = frame(5, Data(repeating: 0xFF, count: 200_000))
        let farHave = frame(4, u32(5_000_000))
        let peer = try ScriptedPeer(infoHash: infoHash, script: [
            (0, frame(5, Data([0x80]))),                 // bitfield: piece 0 only, still choked
            (0.2, hugeBitfield),
            (0.1, farHave),
            (0.2, frame(1))                              // unchoke: the client now claims work
        ])
        let port = try await peer.start()
        defer { peer.stop() }

        let client = makeClient(port: port)
        let claims = Claims(handOut: false)
        _ = await runDownload(client, claims: claims)
        await client.close()

        let sizes = await claims.seenSizes
        #expect(!sizes.isEmpty, "the client never claimed work")
        #expect(sizes.allSatisfy { $0 <= 1 }, "availability grew to \(sizes)")
    }

    @Test("A block that is off the request grid drops the peer")
    func misalignedBlockIsRejected() async throws {
        // Piece 0 is 10 bytes in blocks of 4; begin = 1 is not a block we asked for.
        let bogus = frame(7, u32(0) + u32(1) + Data([1, 2, 3, 4]))
        let peer = try ScriptedPeer(infoHash: infoHash, script: [
            (0, frame(5, Data([0x80])) + frame(1)),
            (0.3, bogus)
        ])
        let port = try await peer.start()
        defer { peer.stop() }

        let client = makeClient(port: port)
        let error = await runDownload(client, claims: Claims())
        await client.close()

        guard let wire = error as? PeerWireError, case .unexpectedMessage = wire else {
            Issue.record("Expected unexpectedMessage, got \(String(describing: error))")
            return
        }
    }

    @Test("Keep-alives do not extend the snub timeout")
    func keepAlivesDoNotDefeatSnubTimeout() async throws {
        // After unchoking, the peer sends only keep-alives (four zero bytes) every
        // 100 ms for 4 s and never any data. The snub timeout is 1 s.
        var script: [ScriptedPeer.Step] = [(0, frame(5, Data([0x80])) + frame(1))]
        for _ in 0..<40 { script.append((0.1, Data(count: 4))) }
        let peer = try ScriptedPeer(infoHash: infoHash, script: script)
        let port = try await peer.start()
        defer { peer.stop() }

        let client = makeClient(port: port, snub: 1, idle: 5)
        let start = ContinuousClock.now
        let error = await runDownload(client, claims: Claims())
        let elapsed = ContinuousClock.now - start
        await client.close()

        guard let wire = error as? PeerWireError, case .timedOut = wire else {
            Issue.record("Expected timedOut, got \(String(describing: error))")
            return
        }
        #expect(elapsed < .seconds(2.5), "snubbed peer was kept for \(elapsed)")
    }

    @Test("Oversized metadata pieces are rejected")
    func oversizedMetadataPiece() async throws {
        // metadata_size 20_000 => two pieces (16 KiB + rest). The peer answers piece 0
        // with 100 KB instead of 16 KiB.
        let handshake = frame(20, Data([0]) + BencodeEncoder.encode([
            "m": .dictionary(["ut_metadata": .integer(3)]),
            "metadata_size": .integer(20_000)
        ]))
        let header = BencodeEncoder.encode(["msg_type": .integer(1), "piece": .integer(0), "total_size": .integer(20_000)])
        let oversized = frame(20, Data([1]) + header + Data(repeating: 0xAB, count: 100_000))
        let peer = try ScriptedPeer(infoHash: infoHash, supportsExtensions: true, script: [
            (0, handshake),
            (0.2, oversized)
        ])
        let port = try await peer.start()
        defer { peer.stop() }

        let client = makeClient(port: port)
        try await client.connect()
        var thrown: Error?
        do {
            _ = try await client.fetchMetadata()
        } catch {
            thrown = error
        }
        await client.close()

        guard let wire = thrown as? PeerWireError, case .metadataUnavailable = wire else {
            Issue.record("Expected metadataUnavailable, got \(String(describing: thrown))")
            return
        }
    }
}

@Suite("Peer address hygiene")
struct PeerAddressTests {
    @Test("Compact peers that can never be dialled are dropped")
    func compactPeersDropUnroutable() {
        let peers = TrackerClient.parseCompactPeers(Data([
            0, 0, 0, 0, 0x1A, 0xE1,          // unspecified
            224, 0, 0, 1, 0x1A, 0xE1,        // multicast
            239, 255, 255, 250, 0x1A, 0xE1,  // multicast
            255, 255, 255, 255, 0x1A, 0xE1,  // broadcast
            240, 0, 0, 1, 0x1A, 0xE1,        // reserved
            8, 8, 8, 8, 0x1A, 0xE1,          // public
            192, 168, 1, 10, 0x1A, 0xE1,     // LAN peers are legitimate
            127, 0, 0, 1, 0x1A, 0xE1         // loopback is kept (local swarms, tests)
        ]))

        #expect(peers.map(\.host) == ["8.8.8.8", "192.168.1.10", "127.0.0.1"])
    }

    @Test("DHT nodes that can never be dialled are dropped")
    func dhtNodesDropUnroutable() {
        var data = Data()
        for host in [[0, 0, 0, 0], [224, 0, 0, 1], [255, 255, 255, 255], [1, 2, 3, 4]] as [[UInt8]] {
            data.append(Data(repeating: 9, count: 20))
            data.append(contentsOf: host)
            data.append(contentsOf: [0x1A, 0xE1])
        }

        let nodes = DHTClient.parseCompactIPv4Nodes(data)

        #expect(nodes.map(\.host) == ["1.2.3.4"])
    }

    @Test("The swarm reserve stops growing at its cap")
    func peerSupplyIsCapped() async {
        let supply = PeerSupply(peers: [])
        let flood = (0..<20_000).map { PeerEndpoint(host: "10.\($0 >> 16 & 255).\($0 >> 8 & 255).\($0 & 255)", port: 6881) }

        await supply.add(flood)
        var handed = 0
        while await supply.next() != nil { handed += 1 }

        #expect(handed <= PeerSupply.maxPeers)
        #expect(handed > 0)
    }
}

@Suite("Web-seed URLs")
struct WebSeedURLTests {
    private let single = TorrentFile(id: 0, path: "disc.iso", length: 10)
    private let nested = TorrentFile(id: 1, path: "Album/CD 1/01.flac", length: 10)

    @Test("A single-file url-list entry without a trailing slash is used as is (BEP 19)")
    func singleFileUsedAsIs() {
        let url = URL(string: "https://mirror.test/pub/disc.iso")!

        #expect(url.torrentSourceURL(for: single, singleFile: true).absoluteString == "https://mirror.test/pub/disc.iso")
    }

    @Test("A single-file entry that is a directory gets the file name appended")
    func singleFileDirectory() {
        let url = URL(string: "https://mirror.test/pub/")!

        #expect(url.torrentSourceURL(for: single, singleFile: true).absoluteString == "https://mirror.test/pub/disc.iso")
    }

    @Test("Multi-file torrents append the torrent-relative path")
    func multiFileAppends() {
        let url = URL(string: "https://mirror.test/pub")!

        #expect(url.torrentSourceURL(for: nested, singleFile: false).absoluteString == "https://mirror.test/pub/Album/CD%201/01.flac")
    }
}
