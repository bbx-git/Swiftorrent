import CryptoKit
import Foundation
import Network
@testable import SwiftorrentCore
import Testing

@Suite("Core parsing")
struct CoreParsingTests {
    @Test("Bencode parser keeps dictionary ranges")
    func bencodeRanges() throws {
        let data = Data("d4:infod4:name4:testee".utf8)
        let root = try BencodeParser(data: data).parse()
        guard case let .dictionary(dictionary) = root.value,
              let info = dictionary["info"] else {
            Issue.record("Missing info dictionary")
            return
        }
        #expect(Data(data[info.range]) == Data("d4:name4:teste".utf8))
    }

    @Test("Bencode parser rejects overflowing byte-string length")
    func bencodeRejectsOverflowingLength() {
        // A length field of all 9s far exceeds Int.max and must not trap.
        let data = Data("99999999999999999999999999:payload".utf8)

        #expect(throws: BencodeError.invalidByteStringLength) {
            try BencodeParser(data: data).parse()
        }
    }

    @Test("Tracker compact peers drop port-0 entries")
    func trackerCompactPeersDropPortZero() {
        let peers = TrackerClient.parseCompactPeers(Data([
            127, 0, 0, 1, 0x00, 0x00,
            192, 168, 1, 10, 0x1A, 0xE1
        ]))

        #expect(peers == [PeerEndpoint(host: "192.168.1.10", port: 6881)])
    }

    @Test("Peer wire caps guard against hostile sizes")
    func peerWireSizeCaps() {
        #expect(PeerWireClient.maxMessageLength == 1024 * 1024)
        #expect(PeerWireClient.maxMetadataSize == 10 * 1024 * 1024)
    }

    @Test("Magnet parser accepts hex BTIH")
    func magnetHex() throws {
        let magnet = try MagnetLinkParser().parse("magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=Example")
        #expect(magnet.infoHash.count == 20)
        #expect(magnet.displayName == "Example")
    }

    @Test("Magnet parser keeps HTTP trackers from long links")
    func magnetTrackers() throws {
        let magnet = try MagnetLinkParser().parse(
            "magnet:?xt=urn:btih:6A8F134C989C1ECF961CED4AC0B32CC5B615B287&dn=Example&tr=udp%3A%2F%2Ftracker.example.invalid%3A1337%2Fannounce&tr=http%3A%2F%2Ftracker.example.invalid%3A8080%2Fannounce&tr=https%3A%2F%2Fsecure.example.invalid%2Fannounce&xs=https%3A%2F%2Fexample.invalid%2Fexample.torrent&ws=https%3A%2F%2Fexample.invalid%2Fdownloads%2F"
        )
        #expect(magnet.infoHash.map { String(format: "%02X", $0) }.joined() == "6A8F134C989C1ECF961CED4AC0B32CC5B615B287")
        #expect(magnet.trackers.filter { $0.scheme == "http" || $0.scheme == "https" }.count == 2)
        #expect(magnet.exactSources == [URL(string: "https://example.invalid/example.torrent")!])
        #expect(magnet.webSeeds == [URL(string: "https://example.invalid/downloads/")!])
    }

    @Test("Magnet parser decodes form-encoded display names")
    func magnetFormEncodedDisplayName() throws {
        // Torrent sites conventionally form-encode `dn`: `+` means space, a
        // literal plus arrives as `%2B`.
        let magnet = try MagnetLinkParser().parse(
            "magnet:?xt=urn:btih:6A8F134C989C1ECF961CED4AC0B32CC5B615B287&dn=Example+Movie+%282026%29+C%2B%2B+1080p&tr=udp%3A%2F%2Ftracker.example.invalid%3A1337%2Fannounce"
        )
        #expect(magnet.displayName == "Example Movie (2026) C++ 1080p")
        #expect(magnet.trackers.count == 1)
    }

    @Test("Bencode encoder sorts dictionary keys")
    func bencodeEncoder() {
        let encoded = BencodeEncoder.encode([
            "piece": .integer(3),
            "msg_type": .integer(0)
        ])
        #expect(String(data: encoded, encoding: .utf8) == "d8:msg_typei0e5:piecei3ee")
    }

    @Test("Bencode encoder writes lists")
    func bencodeEncoderLists() {
        let encoded = BencodeEncoder.encode([
            "values": .list([.string("one"), .string("two")])
        ])

        #expect(String(data: encoded, encoding: .utf8) == "d6:valuesl3:one3:twoee")
    }

    @Test("Tracker percent encoding escapes binary bytes")
    func trackerPercentEncoding() {
        let data = Data([0x00, 0x20, 0x2F, 0x41, 0x7A, 0xFF])

        #expect(TrackerClient.percentEncode(data) == "%00%20%2FAz%FF")
    }

    @Test("Tracker announce URL builds query and rejects malformed bases")
    func trackerAnnounceURL() {
        let infoHash = Data([0x00, 0xFF, 0x10])
        let peerID = Data(repeating: 0x41, count: 3)

        let valid = TrackerClient.makeAnnounceURL(
            base: "http://tracker.example.invalid/announce",
            infoHash: infoHash,
            peerID: peerID,
            port: 6881,
            downloaded: 0,
            left: 100,
            event: "started"
        )
        #expect(valid?.absoluteString == "http://tracker.example.invalid/announce?info_hash=%00%FF%10&peer_id=AAA&port=6881&uploaded=0&downloaded=0&left=100&compact=1&numwant=48&no_peer_id=1&event=started")

        // A base whose authority contains a space cannot form a valid URL, so the
        // builder must return nil instead of force-unwrapping and crashing.
        let invalid = TrackerClient.makeAnnounceURL(
            base: "http://bad host.invalid/announce",
            infoHash: infoHash,
            peerID: peerID,
            port: 6881,
            downloaded: 0,
            left: 0,
            event: nil
        )
        #expect(invalid == nil)
    }

    @Test("Tracker requests announce port 0 because we never listen")
    func trackerRequestPort() {
        let request = TrackerRequest(
            announceURL: URL(string: "http://tracker.example.invalid/announce")!,
            infoHash: Data(repeating: 0, count: 20),
            peerID: Data(repeating: 1, count: 20),
            downloaded: 0,
            left: 0,
            event: "started"
        )
        let customPortRequest = TrackerRequest(
            announceURL: request.announceURL,
            infoHash: request.infoHash,
            peerID: request.peerID,
            port: 51413,
            downloaded: 0,
            left: 0,
            event: nil
        )

        #expect(request.port == 0)
        #expect(customPortRequest.port == 51413)
    }

    @Test("Tracker compact peers parse IPv4 endpoints")
    func trackerCompactPeers() {
        let peers = TrackerClient.parseCompactPeers(Data([
            127, 0, 0, 1, 0x1A, 0xE1,
            192, 168, 1, 10, 0xC0, 0x00,
            1, 2, 3
        ]))

        #expect(peers == [
            PeerEndpoint(host: "127.0.0.1", port: 6881),
            PeerEndpoint(host: "192.168.1.10", port: 49152)
        ])
    }

    @Test("DHT compact nodes parse IPv4 endpoints")
    func dhtCompactNodes() {
        var nodes = Data(repeating: 1, count: 20)
        nodes.append(contentsOf: [10, 0, 0, 2, 0x1A, 0xE1])
        nodes.append(Data(repeating: 2, count: 20))
        nodes.append(contentsOf: [192, 168, 1, 20, 0xC0, 0x00])
        nodes.append(contentsOf: [1, 2, 3])

        let parsed = DHTClient.parseCompactIPv4Nodes(nodes)

        #expect(parsed == [
            DHTNodeEndpoint(host: "10.0.0.2", port: 6881, id: Data(repeating: 1, count: 20)),
            DHTNodeEndpoint(host: "192.168.1.20", port: 49152, id: Data(repeating: 2, count: 20))
        ])
    }

    @Test("DHT get_peers response parses values and nodes")
    func dhtGetPeersResponse() throws {
        let transactionID = Data("aa".utf8)
        var compactNodes = Data(repeating: 3, count: 20)
        compactNodes.append(contentsOf: [8, 8, 8, 8, 0x1A, 0xE1])
        let response = BencodeEncoder.encode([
            "r": .dictionary([
                "id": .bytes(Data(repeating: 4, count: 20)),
                "nodes": .bytes(compactNodes),
                "values": .list([
                    .bytes(Data([127, 0, 0, 1, 0x1A, 0xE1]))
                ])
            ]),
            "t": .bytes(transactionID),
            "y": .string("r")
        ])

        let parsed = try DHTClient.parseGetPeersResponse(response, expectedTransactionID: transactionID)

        #expect(parsed.peers == [PeerEndpoint(host: "127.0.0.1", port: 6881)])
        #expect(parsed.nodes == [DHTNodeEndpoint(host: "8.8.8.8", port: 6881, id: Data(repeating: 3, count: 20))])
    }

    @Test("Peer bitfield parser maps high bits to piece indexes")
    func peerBitfieldParser() {
        let pieces = PeerWireClient.parseBitfield(Data([0b1010_0000, 0b0100_0000]), pieceCount: 10)

        #expect(pieces == [0, 2, 9])
    }

    @Test("Torrent parser sanitizes unsafe output paths")
    func torrentPathsAreSanitized() throws {
        var info = Data("d5:filesld6:lengthi1e4:pathl2:..9:file/nameeee4:name4:Root12:piece lengthi1e6:pieces20:".utf8)
        info.append(Data(repeating: 0, count: 20))
        info.append(UInt8(ascii: "e"))

        let metainfo = try TorrentMetainfoParser().parseInfoDictionary(data: info, announceURLs: [])

        #expect(metainfo.files.map(\.path) == ["Root/file_name"])
    }

    @Test("Torrent parser keeps single-file paths relative")
    func singleFilePathIsRelative() throws {
        var info = Data("d6:lengthi1e4:name9:/tmp/evil12:piece lengthi1e6:pieces20:".utf8)
        info.append(Data(repeating: 0, count: 20))
        info.append(UInt8(ascii: "e"))

        let metainfo = try TorrentMetainfoParser().parseInfoDictionary(data: info, announceURLs: [])

        #expect(metainfo.files.map(\.path) == ["_tmp_evil"])
    }

    @Test("Torrent parser keeps piece length and hash count")
    func torrentPieceLengthAndHashes() throws {
        var info = Data("d6:lengthi5e4:name4:file12:piece lengthi3e6:pieces40:".utf8)
        info.append(Data(repeating: 1, count: 20))
        info.append(Data(repeating: 2, count: 20))
        info.append(UInt8(ascii: "e"))

        let metainfo = try TorrentMetainfoParser().parseInfoDictionary(data: info, announceURLs: [])

        #expect(metainfo.pieceLength == 3)
        #expect(metainfo.pieceHashes.count == 2)
        #expect(metainfo.totalSize == 5)
    }

    @Test("Torrent parser keeps HTTP web seeds")
    func torrentWebSeeds() throws {
        var torrent = Data("d8:url-listl30:https://example.invalid/files/28:ftp://example.invalid/files/e4:infod6:lengthi1e4:name4:file12:piece lengthi1e6:pieces20:".utf8)
        torrent.append(Data(repeating: 0, count: 20))
        torrent.append(Data("ee".utf8))

        let metainfo = try TorrentMetainfoParser().parse(data: torrent)

        #expect(metainfo.webSeedURLs == [URL(string: "https://example.invalid/files/")!])
    }

    @Test("Torrent writer writes and verifies pieces across file boundaries")
    func torrentWriterVerifiesMultiFilePieces() throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination) }

        let metainfo = makeMetainfo(pieceLength: 4, pieces: [
            Data("abcd".utf8),
            Data("ef".utf8)
        ])
        let writer = TorrentFileWriter(metainfo: metainfo, destination: destination)

        try writer.write(piece: Data("abcd".utf8), pieceIndex: 0)

        #expect(try writer.read(pieceIndex: 0, length: 4) == Data("abcd".utf8))
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("Root/a.txt").path))
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("Root/b.txt").path))
        #expect(try Data(contentsOf: destination.appendingPathComponent("Root/a.txt.tor")) == Data("ab".utf8))
        #expect(try Data(contentsOf: destination.appendingPathComponent("Root/b.txt.tor")) == Data("cd".utf8))
        #expect(try writer.verifiedPieces() == [0])

        try writer.finalize()

        #expect(try Data(contentsOf: destination.appendingPathComponent("Root/a.txt")) == Data("ab".utf8))
        #expect(try Data(contentsOf: destination.appendingPathComponent("Root/b.txt")) == Data("cd".utf8))
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("Root/a.txt.tor").path))
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("Root/b.txt.tor").path))
    }

    @Test("Torrent writer ignores corrupt resume pieces")
    func torrentWriterRejectsCorruptExistingPieces() throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination) }

        let metainfo = makeMetainfo(pieceLength: 4, pieces: [
            Data("abcd".utf8),
            Data("ef".utf8)
        ])
        let writer = TorrentFileWriter(metainfo: metainfo, destination: destination)

        try writer.write(piece: Data("wxyz".utf8), pieceIndex: 0)
        try writer.write(piece: Data("ef".utf8), pieceIndex: 1)

        #expect(try writer.verifiedPieces() == [1])
    }

    @Test("Torrent writer verifies only the requested piece subset")
    func torrentWriterVerifiesPieceSubset() throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination) }

        let metainfo = makeMetainfo(pieceLength: 4, pieces: [
            Data("abcd".utf8),
            Data("ef".utf8)
        ])
        let writer = TorrentFileWriter(metainfo: metainfo, destination: destination)

        try writer.write(piece: Data("abcd".utf8), pieceIndex: 0)
        try writer.write(piece: Data("ef".utf8), pieceIndex: 1)

        // Restricting the scan to a subset only reports matches within it, so a
        // cached set can be refreshed without re-hashing already-valid pieces.
        #expect(try writer.verifiedPieces(among: [1]) == [1])
        #expect(try writer.verifiedPieces(among: [0]) == [0])
        #expect(try writer.verifiedPieces(among: []) == [])
        #expect(try writer.verifiedPieces(among: [0, 1]) == writer.verifiedPieces())
    }

    @Test("Web-seed resume offset reflects on-disk partial state")
    func webSeedResumeOffset() throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination) }

        // Single 8-byte file in its own piece keeps the math independent of
        // cross-file piece boundaries.
        let metainfo = TorrentMetainfo(
            name: "Root",
            announceURLs: [],
            files: [TorrentFile(id: 0, path: "Root/a.bin", length: 8)],
            pieceLength: 8,
            pieceHashes: [Data(Insecure.SHA1.hash(data: Data(repeating: 0, count: 8)))],
            totalSize: 8,
            infoHash: Data(repeating: 0, count: 20),
            infoDictionaryData: Data()
        )
        let writer = TorrentFileWriter(metainfo: metainfo, destination: destination)
        let file = metainfo.files[0]
        let partialURL = destination.appendingPathComponent("Root/a.bin.tor")
        let finalURL = destination.appendingPathComponent("Root/a.bin")

        // No file yet → fresh empty partial, offset 0.
        let fresh = try writer.partialFileResumeOffset(for: file)
        #expect(fresh.offset == 0)
        #expect(fresh.url == partialURL)
        #expect(FileManager.default.fileExists(atPath: partialURL.path))

        // Partial with 3 bytes → resume from 3.
        try Data([1, 2, 3]).write(to: partialURL)
        #expect(try writer.partialFileResumeOffset(for: file).offset == 3)

        // Oversized partial → truncated back to 0.
        try Data(repeating: 9, count: 12).write(to: partialURL)
        let oversized = try writer.partialFileResumeOffset(for: file)
        #expect(oversized.offset == 0)
        #expect(try Data(contentsOf: partialURL).isEmpty)

        // Only a completed final file → report full length so the fetch is skipped.
        try FileManager.default.removeItem(at: partialURL)
        try Data(repeating: 7, count: 8).write(to: finalURL)
        let complete = try writer.partialFileResumeOffset(for: file)
        #expect(complete.offset == 8)
        #expect(complete.url == finalURL)
    }

    @Test("Peer id is exactly 20 ASCII bytes with the client prefix")
    func makePeerIDIsTwentyASCIIBytes() throws {
        let peerID = TorrentDownloader.makePeerID()
        #expect(peerID.count == 20)
        #expect(peerID.allSatisfy { $0 < 0x80 })
        #expect(peerID.starts(with: Data("-SW0001-".utf8)))
    }

    @Test("DHT node id is 20 random bytes and not constant")
    func makeNodeIDIsTwentyRandomBytes() throws {
        let first = DHTClient.makeNodeID()
        let second = DHTClient.makeNodeID()
        #expect(first.count == 20)
        #expect(second.count == 20)
        #expect(first != second)
    }

    @Test("Torrent writer refuses paths outside destination")
    func torrentWriterRefusesEscapedPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = root.appendingPathComponent("Downloads", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let metainfo = TorrentMetainfo(
            name: "Escaped",
            announceURLs: [],
            files: [TorrentFile(id: 0, path: "../escaped.txt", length: 4)],
            pieceLength: 4,
            pieceHashes: [Data(Insecure.SHA1.hash(data: Data("abcd".utf8)))],
            totalSize: 4,
            infoHash: Data(repeating: 0, count: 20),
            infoDictionaryData: Data()
        )
        let writer = TorrentFileWriter(metainfo: metainfo, destination: destination)

        #expect(throws: CocoaError.self) {
            try writer.write(piece: Data("abcd".utf8), pieceIndex: 0)
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("escaped.txt").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("escaped.txt.tor").path))
    }

    @Test("Torrent downloader merges tracker and DHT peers")
    func torrentDownloaderMergesTrackerAndDHTPeers() async throws {
        let metainfo = makeMetainfo(pieceLength: 4, pieces: [Data("abcd".utf8)])
        let trackerPeer = PeerEndpoint(host: "192.0.2.10", port: 6881)
        let sharedPeer = PeerEndpoint(host: "192.0.2.11", port: 6882)
        let dhtPeer = PeerEndpoint(host: "192.0.2.12", port: 6883)
        let downloader = TorrentDownloader(
            trackerClient: MockTrackerAnnouncer(peers: [trackerPeer, sharedPeer]),
            dhtClient: MockDHTPeerFinder(peers: [sharedPeer, dhtPeer])
        )

        let peers = try await downloader.collectPeers(
            for: metainfo,
            peerID: Data(repeating: 1, count: 20),
            event: "started"
        )

        #expect(Set(peers) == [trackerPeer, sharedPeer, dhtPeer])
    }

    @Test("Streamed DHT peers start the swarm while the walk is still running")
    func streamedDHTPeersDoNotWaitForTheWalk() async throws {
        let metainfo = makeMetainfo(pieceLength: 4, pieces: [Data("abcd".utf8)])
        let dhtPeer = PeerEndpoint(host: "192.0.2.30", port: 6881)
        let downloader = TorrentDownloader(
            trackerClient: HangingTrackerAnnouncer(),
            dhtClient: StreamingThenHangingDHT(peer: dhtPeer)
        )

        let started = ContinuousClock.now
        let peers = try await downloader.collectPeers(
            for: metainfo,
            peerID: Data(repeating: 1, count: 20),
            event: "started"
        )

        #expect(peers == [dhtPeer])
        #expect(ContinuousClock.now - started < .seconds(6))
    }

    @Test("Torrent downloader skips DHT for stopped announces")
    func torrentDownloaderSkipsDHTForStoppedAnnounce() async throws {
        let metainfo = makeMetainfo(pieceLength: 4, pieces: [Data("abcd".utf8)])
        let trackerPeer = PeerEndpoint(host: "192.0.2.20", port: 6881)
        let dhtPeer = PeerEndpoint(host: "192.0.2.21", port: 6882)
        let downloader = TorrentDownloader(
            trackerClient: MockTrackerAnnouncer(peers: [trackerPeer]),
            dhtClient: MockDHTPeerFinder(peers: [dhtPeer])
        )

        let peers = try await downloader.collectPeers(
            for: metainfo,
            peerID: Data(repeating: 1, count: 20),
            event: "stopped",
            includeDHT: false
        )

        #expect(peers == [trackerPeer])
    }

    @Test("Stopped announce is capped when the tracker never answers")
    func stoppedAnnounceIsCapped() async throws {
        let metainfo = makeMetainfo(pieceLength: 4, pieces: [Data("abcd".utf8)])
        let downloader = TorrentDownloader(
            trackerClient: HangingTrackerAnnouncer(),
            dhtClient: MockDHTPeerFinder(peers: [])
        )

        let started = ContinuousClock.now
        await downloader.announceStopped(
            for: metainfo,
            peerID: Data(repeating: 1, count: 20),
            downloaded: 4,
            cap: .milliseconds(200)
        )

        #expect(ContinuousClock.now - started < .seconds(3))
    }

    @Test("A download that ends without completing announces stopped")
    func failedDownloadAnnouncesStopped() async throws {
        let recorder = RecordingTrackerAnnouncer()
        let downloader = TorrentDownloader(trackerClient: recorder, dhtClient: MockDHTPeerFinder(peers: []))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let metainfo = makeMetainfo(pieceLength: 4, pieces: [Data("abcd".utf8)])

        // No tracker, DHT or web-seed peers: the run fails after the "started" announce.
        _ = try? await downloader.download(metainfo: metainfo, destination: directory) { _ in }

        #expect(await recorder.events == ["started", "stopped"])
    }

    @Test("Peer wire tears down a silent peer within the timeout window")
    func peerWireTimesOutOnSilentPeer() async throws {
        // A loopback listener that accepts the connection but never sends a
        // handshake back, modelling a peer that connects then goes silent.
        let holder = AcceptedConnections()
        let listener = try NWListener(using: .tcp)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global(qos: .utility))
            holder.add(connection)
        }
        let port: NWEndpoint.Port = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port {
                        listener.stateUpdateHandler = nil
                        continuation.resume(returning: port)
                    }
                case let .failed(error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: .global(qos: .utility))
        }
        defer {
            listener.cancel()
            holder.cancelAll()
        }

        let client = PeerWireClient(
            endpoint: PeerEndpoint(host: "127.0.0.1", port: port.rawValue),
            infoHash: Data(repeating: 0, count: 20),
            peerID: Data(repeating: 1, count: 20),
            connectTimeout: 2,
            ioTimeout: 0.5,
            // Exercise the plaintext handshake-read timeout directly. The default
            // .preferEncrypted policy would (correctly) try MSE first and, on that
            // read timing out, fall back to a second plaintext attempt — doubling
            // the wait — which is a separate behavior from the teardown primitive
            // under test here.
            encryptionPolicy: .plaintextOnly
        )

        let start = ContinuousClock.now
        var thrown: Error?
        do {
            // connect() opens the socket and sends the handshake, then blocks
            // on receiveExactly(68); the silent peer never replies.
            try await client.connect()
        } catch {
            thrown = error
        }
        let elapsed = ContinuousClock.now - start
        await client.close()

        if let peerError = thrown as? PeerWireError, case .timedOut = peerError {
            // Expected.
        } else {
            Issue.record("Expected PeerWireError.timedOut, got \(String(describing: thrown))")
        }
        // The handshake read should be abandoned shortly after ioTimeout, well
        // before any default multi-second wait.
        #expect(elapsed < .seconds(2))
    }

    @Test("Peer session streams multiple pieces across the cross-piece pipeline")
    func downloadPiecesStreamsAcrossBoundaries() async throws {
        // A loopback seed that declares all pieces, unchokes, and serves every block
        // it is asked for. Drives the continuous pipeline through three whole pieces
        // (blocks requested with one deep window spanning piece boundaries) and
        // asserts each is assembled and SHA-1-verified.
        let infoHash = Data(repeating: 0x33, count: 20)
        let pieceLen = 10
        let pieces: [Data] = (0..<3).map { p in Data((0..<pieceLen).map { UInt8((p * pieceLen + $0) & 0xff) }) }
        let hashes = pieces.map { Data(Insecure.SHA1.hash(data: $0)) }
        // bitfield with the high 3 bits set (pieces 0–2), then unchoke.
        let postHandshake = wireFrame(5, Data([0xE0])) + wireFrame(1)
        let seed = RespondingSeed(infoHash: infoHash, pieces: pieces, postHandshake: postHandshake, respondToRequests: true)

        let holder = AcceptedConnections()
        let listener = try NWListener(using: .tcp)
        listener.newConnectionHandler = { connection in
            holder.add(connection)
            seed.handle(connection)
        }
        let port = try await startLoopbackListener(listener)
        defer { listener.cancel(); holder.cancelAll() }

        let client = PeerWireClient(
            endpoint: PeerEndpoint(host: "127.0.0.1", port: port.rawValue),
            infoHash: infoHash,
            peerID: Data(repeating: 1, count: 20),
            connectTimeout: 2,
            ioTimeout: 2,
            encryptionPolicy: .plaintextOnly
        )
        try await client.connect()
        _ = try await client.readInitialAvailability(pieceCount: 3)

        let claimer = SequentialClaimer(total: 3)
        let sink = PieceSink()
        try await client.downloadPieces(
            blockSize: 4,
            pieceLength: { _ in pieceLen },
            expectedHash: { hashes[$0] },
            claimNextPiece: { _, _, _ in await claimer.claim() },
            onPieceComplete: { index, data in await sink.add(index, data) },
            onReturnPiece: { _ in }
        )
        await client.close()

        let got = await sink.all
        #expect(got.count == 3)
        for index in 0..<3 { #expect(got[index] == pieces[index]) }
    }

    @Test("Peer session holds through a choke, then drops the peer only on idle silence")
    func downloadPiecesHoldsThroughChokeThenDropsOnIdle() async throws {
        // A loopback seed that declares piece 0, unchokes (so the pipeline claims and
        // requests it), then immediately chokes and goes silent, never serving the
        // block. The session must NOT drop the peer the instant it chokes — it holds
        // the connection and waits — but once the peer stays silent past the (short,
        // for the test) idle timeout it reaps the connection and hands the claimed
        // piece back for another peer to retry.
        let infoHash = Data(repeating: 0x44, count: 20)
        let pieces = [Data(repeating: 0, count: 10)]
        let postHandshake = wireFrame(5, Data([0x80])) + wireFrame(1) + wireFrame(0) // bitfield, unchoke, choke
        let seed = RespondingSeed(infoHash: infoHash, pieces: pieces, postHandshake: postHandshake, respondToRequests: false)

        let holder = AcceptedConnections()
        let listener = try NWListener(using: .tcp)
        listener.newConnectionHandler = { connection in
            holder.add(connection)
            seed.handle(connection)
        }
        let port = try await startLoopbackListener(listener)
        defer { listener.cancel(); holder.cancelAll() }

        let client = PeerWireClient(
            endpoint: PeerEndpoint(host: "127.0.0.1", port: port.rawValue),
            infoHash: infoHash,
            peerID: Data(repeating: 1, count: 20),
            connectTimeout: 2,
            ioTimeout: 5,
            snubTimeout: 5,
            idleTimeout: 0.5,
            encryptionPolicy: .plaintextOnly
        )
        try await client.connect()
        _ = try await client.readInitialAvailability(pieceCount: 1)

        let claimer = SequentialClaimer(total: 1)
        let returned = ReturnedPieces()
        let start = ContinuousClock.now
        var thrown: Error?
        do {
            try await client.downloadPieces(
                blockSize: 4,
                pieceLength: { _ in 10 },
                expectedHash: { _ in Data(repeating: 0, count: 20) },
                claimNextPiece: { _, _, _ in await claimer.claim() },
                onPieceComplete: { _, _ in },
                onReturnPiece: { index in await returned.add(index) }
            )
        } catch {
            thrown = error
        }
        let elapsed = ContinuousClock.now - start
        await client.close()

        if let peerError = thrown as? PeerWireError, case .timedOut = peerError {
            // Expected.
        } else {
            Issue.record("Expected PeerWireError.timedOut, got \(String(describing: thrown))")
        }
        // Reaped near the 0.5s idle timeout, well under the 5s I/O timeout.
        #expect(elapsed < .seconds(3))
        // The claimed piece was handed back so another peer retries it.
        #expect(await returned.all == [0])
    }

    @Test("Peer session rides out a transient choke and completes once re-unchoked")
    func downloadPiecesRidesOutTransientChoke() async throws {
        // A loopback seed that declares piece 0 but starts choked (bitfield only, no
        // unchoke in the greeting), then unchokes after a short delay and serves the
        // blocks. The session must keep the connection open across the initial choke
        // — like a mainstream client holding a peer that hasn't unchoked it yet —
        // rather than bailing, and complete the piece once the unchoke arrives.
        let infoHash = Data(repeating: 0x55, count: 20)
        let pieceLen = 10
        let piece = Data((0..<pieceLen).map { UInt8($0) })
        let hash = Data(Insecure.SHA1.hash(data: piece))
        let postHandshake = wireFrame(5, Data([0x80])) // bitfield only — peer stays choked at first
        let seed = RespondingSeed(infoHash: infoHash, pieces: [piece], postHandshake: postHandshake, respondToRequests: true, unchokeAfter: 0.3)

        let holder = AcceptedConnections()
        let listener = try NWListener(using: .tcp)
        listener.newConnectionHandler = { connection in
            holder.add(connection)
            seed.handle(connection)
        }
        let port = try await startLoopbackListener(listener)
        defer { listener.cancel(); holder.cancelAll() }

        let client = PeerWireClient(
            endpoint: PeerEndpoint(host: "127.0.0.1", port: port.rawValue),
            infoHash: infoHash,
            peerID: Data(repeating: 1, count: 20),
            connectTimeout: 2,
            ioTimeout: 5,
            snubTimeout: 5,
            idleTimeout: 3, // comfortably longer than the seed's 0.3s choke, so we hold
            encryptionPolicy: .plaintextOnly
        )
        try await client.connect()
        _ = try await client.readInitialAvailability(pieceCount: 1)

        let claimer = SequentialClaimer(total: 1)
        let sink = PieceSink()
        try await client.downloadPieces(
            blockSize: 4,
            pieceLength: { _ in pieceLen },
            expectedHash: { _ in hash },
            claimNextPiece: { _, _, _ in await claimer.claim() },
            onPieceComplete: { index, data in await sink.add(index, data) },
            onReturnPiece: { _ in }
        )
        await client.close()

        // The piece completed despite the peer being choked when we first connected.
        #expect(await sink.all[0] == piece)
    }

    @Test("Metadata fetch accepts replies tagged with our advertised ut_metadata id")
    func fetchMetadataMatchesLocalExtensionID() async throws {
        // A scripted loopback peer that completes the BEP-9/BEP-10 metadata
        // exchange, but advertises `ut_metadata` under id 3 for itself while
        // (correctly, per BEP-10) tagging the reply it sends us with the id *we*
        // advertised. Regression guard: the reader must key off our advertised
        // id, not the peer's — the old code compared against the peer's id (3),
        // ignored every reply, and hung until the peer disconnected.
        let infoHash = Data(repeating: 7, count: 20)
        let metadata = Data((0..<50).map { UInt8($0) })
        let localMetaID = PeerWireClient.localMetadataExtensionID // the id we advertise

        func be32(_ value: Int) -> Data {
            let v = UInt32(value)
            return Data([UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)])
        }
        func frame(id: UInt8, payload: Data) -> Data {
            be32(payload.count + 1) + Data([id]) + payload
        }

        var reserved = Data(repeating: 0, count: 8)
        reserved[5] = 0x10 // advertise extension-protocol support
        let peerHandshake = Data([19]) + Data("BitTorrent protocol".utf8) + reserved + infoHash + Data(repeating: 9, count: 20)
        let extHandshake = frame(id: 20, payload: Data([0]) + BencodeEncoder.encode([
            "m": .dictionary(["ut_metadata": .integer(3)]),
            "metadata_size": .integer(Int64(metadata.count))
        ]))
        let metadataReply = frame(id: 20, payload: Data([localMetaID]) + BencodeEncoder.encode([
            "msg_type": .integer(1),
            "piece": .integer(0),
            "total_size": .integer(Int64(metadata.count))
        ]) + metadata)
        let scriptedBlob = peerHandshake + extHandshake + metadataReply

        let holder = AcceptedConnections()
        let listener = try NWListener(using: .tcp)
        listener.newConnectionHandler = { connection in
            holder.add(connection)
            connection.stateUpdateHandler = { state in
                if case .ready = state {
                    connection.stateUpdateHandler = nil
                    connection.send(content: scriptedBlob, completion: .contentProcessed { _ in })
                }
            }
            connection.start(queue: .global(qos: .utility))
        }
        let port: NWEndpoint.Port = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port {
                        listener.stateUpdateHandler = nil
                        continuation.resume(returning: port)
                    }
                case let .failed(error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: .global(qos: .utility))
        }
        defer {
            listener.cancel()
            holder.cancelAll()
        }

        let client = PeerWireClient(
            endpoint: PeerEndpoint(host: "127.0.0.1", port: port.rawValue),
            infoHash: infoHash,
            peerID: Data(repeating: 1, count: 20),
            connectTimeout: 2,
            ioTimeout: 2,
            encryptionPolicy: .plaintextOnly
        )
        try await client.connect()
        let resolved = try await client.fetchMetadata()
        await client.close()
        #expect(resolved == metadata)
    }

    @Test("A peer gossiping PEX during the metadata handshake is captured for the magnet path")
    func metadataFetchHarvestsInboundPex() async throws {
        // Magnet-path PEX: while fetching metadata, the peer sends a `ut_pex`
        // message (tagged with the id *we* advertised for PEX) interleaved with
        // the metadata exchange. The resolver folds these gossiped peers back into
        // its probe pool, so `takeDiscoveredPeers` must surface them even though
        // this connection's only job was the metadata fetch.
        let infoHash = Data(repeating: 4, count: 20)
        let metadata = Data((0..<40).map { UInt8($0) })
        let localMetaID = PeerWireClient.localMetadataExtensionID
        let localPexID = PeerWireClient.localPexExtensionID
        // Compact peer list: 5.6.7.8:6881 and 9.10.11.12:51413.
        let gossiped = Data([5, 6, 7, 8, 0x1A, 0xE1]) + Data([9, 10, 11, 12, 0xC8, 0xD5])

        func be32(_ value: Int) -> Data {
            let v = UInt32(value)
            return Data([UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)])
        }
        func frame(id: UInt8, payload: Data) -> Data {
            be32(payload.count + 1) + Data([id]) + payload
        }

        var reserved = Data(repeating: 0, count: 8)
        reserved[5] = 0x10
        let peerHandshake = Data([19]) + Data("BitTorrent protocol".utf8) + reserved + infoHash + Data(repeating: 9, count: 20)
        let extHandshake = frame(id: 20, payload: Data([0]) + BencodeEncoder.encode([
            "m": .dictionary(["ut_metadata": .integer(2), "ut_pex": .integer(1)]),
            "metadata_size": .integer(Int64(metadata.count))
        ]))
        let pexMessage = frame(id: 20, payload: Data([localPexID]) + BencodeEncoder.encode([
            "added": .bytes(gossiped)
        ]))
        let metadataReply = frame(id: 20, payload: Data([localMetaID]) + BencodeEncoder.encode([
            "msg_type": .integer(1),
            "piece": .integer(0),
            "total_size": .integer(Int64(metadata.count))
        ]) + metadata)
        // PEX arrives between the extension handshake and the metadata reply, so it
        // is read (and routed) mid-fetch rather than up front.
        let scriptedBlob = peerHandshake + extHandshake + pexMessage + metadataReply

        let holder = AcceptedConnections()
        let listener = try NWListener(using: .tcp)
        listener.newConnectionHandler = { connection in
            holder.add(connection)
            connection.stateUpdateHandler = { state in
                if case .ready = state {
                    connection.stateUpdateHandler = nil
                    connection.send(content: scriptedBlob, completion: .contentProcessed { _ in })
                }
            }
            connection.start(queue: .global(qos: .utility))
        }
        let port: NWEndpoint.Port = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port {
                        listener.stateUpdateHandler = nil
                        continuation.resume(returning: port)
                    }
                case let .failed(error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: .global(qos: .utility))
        }
        defer {
            listener.cancel()
            holder.cancelAll()
        }

        let client = PeerWireClient(
            endpoint: PeerEndpoint(host: "127.0.0.1", port: port.rawValue),
            infoHash: infoHash,
            peerID: Data(repeating: 1, count: 20),
            connectTimeout: 2,
            ioTimeout: 2,
            encryptionPolicy: .plaintextOnly
        )
        try await client.connect()
        let resolved = try await client.fetchMetadata()
        let discovered = await client.takeDiscoveredPeers()
        await client.close()

        #expect(resolved == metadata)
        #expect(Set(discovered) == [
            PeerEndpoint(host: "5.6.7.8", port: 6881),
            PeerEndpoint(host: "9.10.11.12", port: 51413)
        ])
    }

    @Test("Layout maps selected files onto overlapping pieces, including shared boundaries")
    func layoutSelectsBoundaryPieces() {
        // a.txt = bytes 0..2 (piece 0), b.txt = bytes 2..6 (pieces 0 and 1).
        let metainfo = makeMetainfo(pieceLength: 4, pieces: [Data("abcd".utf8), Data("ef".utf8)])
        let layout = TorrentLayout(metainfo: metainfo)

        #expect(layout.length(ofPiece: 0) == 4)
        #expect(layout.length(ofPiece: 1) == 2)
        #expect(layout.pieceIndices(forFiles: [0]) == [0])
        #expect(layout.pieceIndices(forFiles: [1]) == [0, 1])
        #expect(layout.pieceIndices(forFiles: [0, 1]) == [0, 1])
    }

    @Test("Layout attributes completed-piece bytes to each file")
    func layoutDistributesBytesPerFile() {
        let metainfo = makeMetainfo(pieceLength: 4, pieces: [Data("abcd".utf8), Data("ef".utf8)])
        let layout = TorrentLayout(metainfo: metainfo)

        #expect(layout.completedBytesPerFile(completedPieces: [0]) == [2, 2])
        #expect(layout.completedBytesPerFile(completedPieces: [1]) == [0, 2])
        #expect(layout.completedBytesPerFile(completedPieces: [0, 1]) == [2, 4])
    }

    @Test("Selective finalize keeps chosen files and removes deselected boundary partials")
    func finalizeSelectedFilesOnly() throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination) }

        let metainfo = makeMetainfo(pieceLength: 4, pieces: [Data("abcd".utf8), Data("ef".utf8)])
        let writer = TorrentFileWriter(metainfo: metainfo, destination: destination)

        // Piece 0 spans both files, leaving a small b.txt boundary partial.
        try writer.write(piece: Data("abcd".utf8), pieceIndex: 0)
        try writer.finalize(selectedFileIDs: [0])

        #expect(try Data(contentsOf: destination.appendingPathComponent("Root/a.txt")) == Data("ab".utf8))
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("Root/b.txt").path))
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("Root/b.txt.tor").path))
    }

    @Test("Stripping the root directory writes files directly into the destination")
    func writerStripsRootDirectory() throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination) }

        let metainfo = makeMetainfo(pieceLength: 4, pieces: [Data("abcd".utf8), Data("ef".utf8)])
        let writer = TorrentFileWriter(metainfo: metainfo, destination: destination, stripRootDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        try writer.write(piece: Data("abcd".utf8), pieceIndex: 0)
        try writer.write(piece: Data("ef".utf8), pieceIndex: 1)
        try writer.finalize(selectedFileIDs: [0, 1])

        // No enclosing "Root/" folder: files land directly in the destination.
        #expect(try Data(contentsOf: destination.appendingPathComponent("a.txt")) == Data("ab".utf8))
        #expect(try Data(contentsOf: destination.appendingPathComponent("b.txt")) == Data("cdef".utf8))
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("Root").path))
    }

    @Test func flatteningRootDirectoryStripsSharedFolder() {
        let metainfo = makeMetainfo(pieceLength: 2, pieces: [Data("ab".utf8), Data("cdef".utf8)])
        #expect(metainfo.createsEnclosingDirectory)

        let flattened = metainfo.flatteningRootDirectory()
        #expect(flattened.files.map(\.path) == ["a.txt", "b.txt"])
        #expect(flattened.files.map(\.id) == metainfo.files.map(\.id))
        #expect(flattened.files.map(\.length) == metainfo.files.map(\.length))
        // Piece geometry must be untouched so the same bytes still verify.
        #expect(flattened.pieceHashes == metainfo.pieceHashes)
        #expect(flattened.infoHash == metainfo.infoHash)
        #expect(!flattened.createsEnclosingDirectory)
    }

    @Test func flatteningSingleFileTorrentIsUnchanged() {
        let metainfo = TorrentMetainfo(
            name: "movie.mp4",
            announceURLs: [],
            files: [TorrentFile(id: 0, path: "movie.mp4", length: 4)],
            pieceLength: 4,
            pieceHashes: [Data(Insecure.SHA1.hash(data: Data("abcd".utf8)))],
            totalSize: 4,
            infoHash: Data(repeating: 0, count: 20),
            infoDictionaryData: Data()
        )
        #expect(!metainfo.createsEnclosingDirectory)
        #expect(metainfo.flatteningRootDirectory().files.map(\.path) == ["movie.mp4"])
    }

    @Test("Rate limiter passes traffic through when unlimited")
    func rateLimiterUnlimitedDoesNotBlock() async {
        let limiter = RateLimiter(bytesPerSecond: nil)
        let start = ContinuousClock().now
        // A large consume must return immediately when no cap is set.
        await limiter.consume(50 * 1024 * 1024)
        let elapsed = ContinuousClock().now - start
        #expect(elapsed < .milliseconds(50))
    }

    @Test("Rate limiter throttles a burst beyond the per-second budget")
    func rateLimiterThrottlesOverBudget() async {
        // 1 KB/s cap, bucket starts empty. A 3 KB consume must wait ~3s.
        let limiter = RateLimiter(bytesPerSecond: 1024)
        let start = ContinuousClock().now
        await limiter.consume(3 * 1024)
        let elapsed = ContinuousClock().now - start
        #expect(elapsed >= .milliseconds(2500))
    }

    @Test("Rate limiter caps the combined rate of concurrent consumers")
    func rateLimiterCapsConcurrentStreams() async {
        // Four parallel streams each charging 1 KB against a 1 KB/s cap must take
        // ~4s in total (serialized debt), not ~1s — this is the property that
        // keeps N peer connections from each running at the full cap.
        let limiter = RateLimiter(bytesPerSecond: 1024)
        let start = ContinuousClock().now
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask { await limiter.consume(1024) }
            }
        }
        let elapsed = ContinuousClock().now - start
        #expect(elapsed >= .milliseconds(3500))
    }

    @Test("Rate limiter stops throttling once the limit is cleared")
    func rateLimiterClearingLimitUnblocks() async {
        let limiter = RateLimiter(bytesPerSecond: 1024)
        await limiter.consume(1024) // drain the initial bucket
        await limiter.setLimit(bytesPerSecond: nil)
        let start = ContinuousClock().now
        await limiter.consume(10 * 1024 * 1024)
        let elapsed = ContinuousClock().now - start
        #expect(elapsed < .milliseconds(50))
    }

    @Test("Coordinator folds added availability into rarest-first ordering")
    func coordinatorAddAvailabilityOrdersRarestFirst() async {
        let metainfo = makeMetainfo(pieceLength: 4, pieces: [Data("abcd".utf8), Data("ef".utf8)])
        let layout = TorrentLayout(metainfo: metainfo)
        let coordinator = PieceDownloadCoordinator(
            layout: layout,
            selectablePieces: [0, 1],
            completedPieces: [],
            initialDownloaded: 0,
            availabilityCounts: [:]
        )
        // Two peers hold piece 0, only one holds piece 1, so piece 1 is rarer and
        // must be handed out first even though it has the higher index.
        await coordinator.addAvailability([0, 1])
        await coordinator.addAvailability([0])
        #expect(await coordinator.nextPiece(availablePieces: [0, 1]) == 1)
        #expect(await coordinator.nextPiece(availablePieces: [0, 1]) == 0)
    }

    @Test("Coordinator enters endgame and duplicates in-flight pieces, counting each once")
    func coordinatorEndgameDuplicatesTail() async {
        let metainfo = makeMetainfo(pieceLength: 4, pieces: [Data("abcd".utf8), Data("ef".utf8)])
        let layout = TorrentLayout(metainfo: metainfo)
        let coordinator = PieceDownloadCoordinator(
            layout: layout,
            selectablePieces: [0, 1],
            completedPieces: [],
            initialDownloaded: 0,
            availabilityCounts: [:]
        )
        // A slow peer A claims both pieces, so nothing is left unassigned.
        let a0 = await coordinator.nextPiece(availablePieces: [0, 1])
        let a1 = await coordinator.nextPiece(availablePieces: [0, 1])
        #expect(Set([a0, a1]) == Set([0, 1]))
        // Peer B, holding nothing, must now get an endgame *duplicate* of an in-flight
        // piece rather than nil — otherwise B would idle while A drips out the tail.
        let b0 = await coordinator.nextPiece(availablePieces: [0, 1], excluding: [])
        #expect(b0 != nil)
        // B is then spread onto the other in-flight piece (least-duplicated first) and
        // never re-handed the one it already holds.
        let b1 = await coordinator.nextPiece(availablePieces: [0, 1], excluding: [b0!])
        #expect(b1 != nil && b1 != b0)
        // The first completion of a duplicated piece counts once (piece 0 = 4 bytes);
        // the redundant copy the other peer finishes is a harmless no-op.
        let (afterFirst, _) = await coordinator.complete(pieceIndex: 0)
        #expect(afterFirst == 4)
        let (afterDuplicate, _) = await coordinator.complete(pieceIndex: 0)
        #expect(afterDuplicate == 4)
        // Finishing the other piece completes the download; nothing is left in flight.
        _ = await coordinator.complete(pieceIndex: 1)
        #expect(await coordinator.isComplete)
    }

    @Test("Coordinator reports which held pieces another peer already completed (endgame cancel)")
    func coordinatorCompletedAmongDrivesEndgameCancel() async {
        let metainfo = makeMetainfo(pieceLength: 4, pieces: [Data("abcd".utf8), Data("ef".utf8)])
        let layout = TorrentLayout(metainfo: metainfo)
        let coordinator = PieceDownloadCoordinator(
            layout: layout,
            selectablePieces: [0, 1],
            completedPieces: [],
            initialDownloaded: 0,
            availabilityCounts: [:]
        )
        // Before anything completes, a peer holding both pieces is told to cancel
        // nothing — completedAmong is a no-op outside endgame.
        #expect(await coordinator.completedAmong([0, 1]).isEmpty)
        // Peer A finishes piece 0. A peer still assembling pieces 0 and 1 must now be
        // told piece 0 is done (so it can cancel those blocks) but not piece 1.
        _ = await coordinator.complete(pieceIndex: 0)
        #expect(await coordinator.completedAmong([0, 1]) == [0])
        #expect(await coordinator.completedAmong([1]).isEmpty)
        // A peer that isn't holding the completed piece is told to cancel nothing.
        #expect(await coordinator.completedAmong([]).isEmpty)
    }

    @Test("Peer supply hands out each peer once then drains to nil")
    func peerSupplyDrainsWithoutDuplicates() async {
        let peers = [
            PeerEndpoint(host: "192.0.2.1", port: 1),
            PeerEndpoint(host: "192.0.2.2", port: 2),
            PeerEndpoint(host: "192.0.2.3", port: 3)
        ]
        let supply = PeerSupply(peers: peers)
        var handed: [PeerEndpoint] = []
        while let peer = await supply.next() { handed.append(peer) }
        #expect(handed == peers)
        #expect(Set(handed).count == peers.count)
        #expect(await supply.next() == nil)
    }

    @Test("Peer supply enqueues only unseen PEX peers and hands them out")
    func peerSupplyAddsUnseenDiscoveredPeers() async {
        let initial = [
            PeerEndpoint(host: "192.0.2.1", port: 1),
            PeerEndpoint(host: "192.0.2.2", port: 2)
        ]
        let supply = PeerSupply(peers: initial)
        _ = await supply.next() // hand out 192.0.2.1
        // One brand-new peer plus a duplicate of an already-queued one.
        let added = await supply.add([
            PeerEndpoint(host: "192.0.2.2", port: 2),
            PeerEndpoint(host: "198.51.100.9", port: 9)
        ])
        #expect(added == 1)
        var handed: [PeerEndpoint] = []
        while let peer = await supply.next() { handed.append(peer) }
        #expect(handed == [
            PeerEndpoint(host: "192.0.2.2", port: 2),
            PeerEndpoint(host: "198.51.100.9", port: 9)
        ])
    }

    @Test("Peer supply stays open for refills until explicitly finished")
    func peerSupplyRefillableUntilFinished() async {
        // Regression guard for the zero-byte swarm failure: the reserve must not be
        // one-shot. After the initial peers drain, `next()` returns nil but the
        // supply is NOT finished, so the supervisor can still `add` re-announced
        // peers and workers keep going. Only `finish()` closes it for good.
        let supply = PeerSupply(peers: [PeerEndpoint(host: "192.0.2.1", port: 1)])
        #expect(await supply.isFinished == false)
        #expect(await supply.next() != nil)     // drain the initial peer
        #expect(await supply.next() == nil)      // empty now...
        #expect(await supply.isFinished == false) // ...but still open for refills

        await supply.add([PeerEndpoint(host: "198.51.100.9", port: 9)]) // re-announce
        #expect(await supply.next() == PeerEndpoint(host: "198.51.100.9", port: 9))

        await supply.finish()
        #expect(await supply.isFinished == true)
    }

    @Test("PEX message parser reads compact IPv4 added peers and ignores added6")
    func pexAddedPeersParse() {
        let body = BencodeEncoder.encode([
            "added": .bytes(Data([192, 0, 2, 5, 0x1A, 0xE1])),   // 192.0.2.5:6881
            "added6": .bytes(Data(repeating: 0, count: 18))
        ])
        let peers = PeerWireClient.parsePexAddedPeers(body)
        #expect(peers == [PeerEndpoint(host: "192.0.2.5", port: 6881)])
    }

    @Test("PEX message parser tolerates a missing added field")
    func pexAddedPeersMissingField() {
        let body = BencodeEncoder.encode(["dropped": .bytes(Data())])
        #expect(PeerWireClient.parsePexAddedPeers(body).isEmpty)
    }

    @Test("Magnet peer cursor parks a worker until a source streams peers in")
    func peerCursorWaitsForStreamedPeers() async throws {
        // The point of overlapping discovery with fetching: workers start before
        // any tracker has answered, so `next()` must wait for peers to arrive
        // rather than reporting the pool empty and letting the worker exit.
        let cursor = PeerCursor(maxPeers: 300)
        let peer = PeerEndpoint(host: "192.0.2.1", port: 1)

        async let handed = cursor.next()
        try await Task.sleep(for: .milliseconds(150)) // worker is parked here
        await cursor.add([peer])

        #expect(try await handed == peer)
    }

    @Test("Magnet peer cursor reports exhaustion only once discovery found nothing")
    func peerCursorEndsOnlyWhenDiscoveryFoundNoPeers() async throws {
        // The resolver counts workers returning nil to detect "no peers at all",
        // so an empty-but-still-running discovery must never look exhausted.
        let cursor = PeerCursor(maxPeers: 300)
        await cursor.finishDiscovery()
        #expect(try await cursor.next() == nil)

        let live = PeerCursor(maxPeers: 300)
        await live.add([PeerEndpoint(host: "192.0.2.2", port: 2)])
        await live.finishDiscovery()
        // Discovery is over but a peer exists, so it recycles instead of ending.
        #expect(try await live.next() != nil)
    }

    @Test("Magnet peer cursor never hands the same peer to two workers at once")
    func peerCursorDoesNotDogpileOnePeer() async throws {
        // 24 workers against a one-peer pool would otherwise all dial it at once.
        let cursor = PeerCursor(maxPeers: 300)
        let peer = PeerEndpoint(host: "192.0.2.3", port: 3)
        await cursor.add([peer])

        #expect(try await cursor.next() == peer)
        // Second worker finds it in flight and parks rather than re-dialing it.
        let second = Task { try await cursor.next() }
        try await Task.sleep(for: .milliseconds(150))
        #expect(!second.isCancelled)

        await cursor.release(peer)
        #expect(try await second.value == peer) // eligible for retry once free
    }

    @Test("Magnet peer cursor tries every new peer before retrying reachable ones")
    func peerCursorPrefersUntriedPeersThenRecyclesReachable() async throws {
        let cursor = PeerCursor(maxPeers: 300)
        let reachable = PeerEndpoint(host: "192.0.2.4", port: 4)
        let dead = PeerEndpoint(host: "192.0.2.5", port: 5)
        await cursor.add([reachable, dead])

        #expect(try await cursor.next() == reachable)
        #expect(try await cursor.next() == dead)
        await cursor.markReachable(reachable)
        await cursor.release(reachable)
        await cursor.release(dead)

        // A peer gossiped mid-phase is untried, so it jumps ahead of any retry.
        let gossiped = PeerEndpoint(host: "192.0.2.6", port: 6)
        await cursor.add([gossiped, reachable]) // duplicate is ignored
        #expect(try await cursor.next() == gossiped)
        await cursor.release(gossiped)

        // Nothing untried left: only the peer that connected gets re-dialed, not
        // the NAT'd majority that would burn the budget on connect timeouts.
        #expect(try await cursor.next() == reachable)
        #expect(await cursor.count == 3)
    }

    @Test("Magnet peer cursor stops accepting peers at its cap")
    func peerCursorCapsPoolSize() async {
        let cursor = PeerCursor(maxPeers: 2)
        await cursor.add((1...5).map { PeerEndpoint(host: "192.0.2.\($0)", port: UInt16($0)) })
        #expect(await cursor.count == 2)
        #expect(await cursor.isFull)
    }

    private func makeMetainfo(pieceLength: Int, pieces: [Data]) -> TorrentMetainfo {
        TorrentMetainfo(
            name: "Root",
            announceURLs: [URL(string: "http://tracker.example.invalid/announce")!],
            files: [
                TorrentFile(id: 0, path: "Root/a.txt", length: 2),
                TorrentFile(id: 1, path: "Root/b.txt", length: 4)
            ],
            pieceLength: pieceLength,
            pieceHashes: pieces.map { Data(Insecure.SHA1.hash(data: $0)) },
            totalSize: Int64(pieces.reduce(0) { $0 + $1.count }),
            infoHash: Data(repeating: 0, count: 20),
            infoDictionaryData: Data()
        )
    }
}

private struct MockTrackerAnnouncer: TrackerAnnouncing {
    let peers: [PeerEndpoint]

    func announce(_ request: TrackerRequest) async throws -> [PeerEndpoint] {
        peers
    }
}

private actor RecordingTrackerAnnouncer: TrackerAnnouncing {
    private(set) var events: [String] = []

    func announce(_ request: TrackerRequest) async throws -> [PeerEndpoint] {
        events.append(request.event ?? "")
        return []
    }
}

private struct HangingTrackerAnnouncer: TrackerAnnouncing {
    func announce(_ request: TrackerRequest) async throws -> [PeerEndpoint] {
        try await Task.sleep(for: .seconds(60))
        return []
    }
}

private struct MockDHTPeerFinder: DHTPeerFinding {
    let peers: [PeerEndpoint]

    func peers(for infoHash: Data) async throws -> [PeerEndpoint] {
        peers
    }

    func peers(for infoHash: Data, onPeers: @Sendable ([PeerEndpoint]) async -> Void) async throws -> [PeerEndpoint] {
        await onPeers(peers)
        return peers
    }
}

/// Reports one peer right away, then keeps "walking" for a minute.
private struct StreamingThenHangingDHT: DHTPeerFinding {
    let peer: PeerEndpoint

    func peers(for infoHash: Data) async throws -> [PeerEndpoint] {
        try await peers(for: infoHash, onPeers: { _ in })
    }

    func peers(for infoHash: Data, onPeers: @Sendable ([PeerEndpoint]) async -> Void) async throws -> [PeerEndpoint] {
        await onPeers([peer])
        try await Task.sleep(for: .seconds(60))
        return [peer]
    }
}

/// Big-endian 4-byte encoding of a small non-negative integer, for scripting wire
/// messages in tests.
func be32Data(_ value: Int) -> Data {
    let v = UInt32(value)
    return Data([UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)])
}

/// A length-prefixed BitTorrent wire message: `<len><id><payload>`.
func wireFrame(_ id: UInt8, _ payload: Data = Data()) -> Data {
    be32Data(payload.count + 1) + Data([id]) + payload
}

/// Starts an `NWListener` and resolves once it is ready, returning its bound port.
func startLoopbackListener(_ listener: NWListener) async throws -> NWEndpoint.Port {
    try await withCheckedThrowingContinuation { continuation in
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if let port = listener.port {
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: port)
                }
            case let .failed(error):
                listener.stateUpdateHandler = nil
                continuation.resume(throwing: error)
            default:
                break
            }
        }
        listener.start(queue: .global(qos: .utility))
    }
}

/// Hands out piece indices 0..<total once each, then nil — a scripted piece picker
/// for driving `downloadPieces` in tests.
actor SequentialClaimer {
    private var next = 0
    private let total: Int
    init(total: Int) { self.total = total }
    func claim() -> Int? {
        guard next < total else { return nil }
        defer { next += 1 }
        return next
    }
}

/// Collects the pieces `downloadPieces` completes, keyed by index.
private actor PieceSink {
    private(set) var all: [Int: Data] = [:]
    func add(_ index: Int, _ data: Data) { all[index] = data }
}

/// Collects the pieces `downloadPieces` hands back via `onReturnPiece`.
actor ReturnedPieces {
    private(set) var all: [Int] = []
    func add(_ index: Int) { all.append(index) }
}

/// A scripted loopback seed. On connect it sends the plaintext BitTorrent handshake
/// (advertising no extensions, so the client's outbound stream is just interested +
/// requests) followed by `postHandshake` (a bitfield and whatever choke/unchoke
/// script the test needs). When `respondToRequests` is set it parses inbound
/// `request` messages and serves the matching block from `pieces`.
final class RespondingSeed: @unchecked Sendable {
    private let infoHash: Data
    private let pieces: [Data]
    private let postHandshake: Data
    private let respondToRequests: Bool
    private let unchokeAfter: TimeInterval?
    /// When set, sends a `have 0` this often for as long as the connection lives:
    /// a chatty peer that never unchokes.
    private let haveEvery: TimeInterval?
    private let queue = DispatchQueue(label: "responding-seed")

    init(infoHash: Data, pieces: [Data], postHandshake: Data, respondToRequests: Bool, unchokeAfter: TimeInterval? = nil, haveEvery: TimeInterval? = nil) {
        self.infoHash = infoHash
        self.pieces = pieces
        self.postHandshake = postHandshake
        self.respondToRequests = respondToRequests
        self.unchokeAfter = unchokeAfter
        self.haveEvery = haveEvery
    }

    private func sendHaves(_ connection: NWConnection, every interval: TimeInterval) {
        queue.asyncAfter(deadline: .now() + interval) { [self] in
            guard connection.state != .cancelled else { return }
            connection.send(content: wireFrame(4, be32Data(0)), completion: .contentProcessed { _ in })
            sendHaves(connection, every: interval)
        }
    }

    /// Per-connection parse state. The first 68 bytes (the client's handshake) are
    /// skipped; the remainder is length-prefixed messages. Only ever touched on the
    /// seed's serial `queue`, so unchecked-Sendable is safe.
    private final class ConnState: @unchecked Sendable {
        var buffer = [UInt8]()
        var skip = 68
    }

    func handle(_ connection: NWConnection) {
        let state = ConnState()
        connection.stateUpdateHandler = { [self] update in
            if case .ready = update {
                connection.stateUpdateHandler = nil
                var greeting = Data([19]) + Data("BitTorrent protocol".utf8) + Data(repeating: 0, count: 8) + infoHash + Data(repeating: 9, count: 20)
                greeting.append(postHandshake)
                connection.send(content: greeting, completion: .contentProcessed { _ in })
                if let unchokeAfter {
                    queue.asyncAfter(deadline: .now() + unchokeAfter) {
                        connection.send(content: wireFrame(1), completion: .contentProcessed { _ in })
                    }
                }
                if let haveEvery { sendHaves(connection, every: haveEvery) }
                receive(connection, state)
            }
        }
        connection.start(queue: queue)
    }

    private func receive(_ connection: NWConnection, _ state: ConnState) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                state.buffer.append(contentsOf: data)
                drain(connection, state)
            }
            if error == nil, !isComplete {
                receive(connection, state)
            }
        }
    }

    private func drain(_ connection: NWConnection, _ state: ConnState) {
        if state.skip > 0 {
            let n = min(state.skip, state.buffer.count)
            state.buffer.removeFirst(n)
            state.skip -= n
        }
        while state.buffer.count >= 4 {
            let length = Int(state.buffer[0]) << 24 | Int(state.buffer[1]) << 16 | Int(state.buffer[2]) << 8 | Int(state.buffer[3])
            guard state.buffer.count >= 4 + length else { break }
            let body = Array(state.buffer[4..<(4 + length)])
            state.buffer.removeFirst(4 + length)
            guard respondToRequests, length >= 13, body.first == 6 else { continue }
            let index = Int(body[1]) << 24 | Int(body[2]) << 16 | Int(body[3]) << 8 | Int(body[4])
            let begin = Int(body[5]) << 24 | Int(body[6]) << 16 | Int(body[7]) << 8 | Int(body[8])
            let blockLength = Int(body[9]) << 24 | Int(body[10]) << 16 | Int(body[11]) << 8 | Int(body[12])
            guard index < pieces.count, begin >= 0, begin + blockLength <= pieces[index].count else { continue }
            var payload = be32Data(index) + be32Data(begin)
            payload.append(pieces[index].subdata(in: begin..<(begin + blockLength)))
            connection.send(content: wireFrame(7, payload), completion: .contentProcessed { _ in })
        }
    }
}

/// Retains accepted loopback connections so they stay open for the duration of
/// a timeout test, then tears them down on cleanup.
final class AcceptedConnections: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [NWConnection] = []

    func add(_ connection: NWConnection) {
        lock.lock()
        connections.append(connection)
        lock.unlock()
    }

    func cancelAll() {
        lock.lock()
        let current = connections
        connections.removeAll()
        lock.unlock()
        current.forEach { $0.cancel() }
    }
}
