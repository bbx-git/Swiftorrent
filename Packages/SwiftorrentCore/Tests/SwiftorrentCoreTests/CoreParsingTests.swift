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

    @Test("Tracker requests announce a real peer port")
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

        #expect(request.port == 6881)
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
            ioTimeout: 0.5
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

private struct MockDHTPeerFinder: DHTPeerFinding {
    let peers: [PeerEndpoint]

    func peers(for infoHash: Data) async throws -> [PeerEndpoint] {
        peers
    }
}

/// Retains accepted loopback connections so they stay open for the duration of
/// a timeout test, then tears them down on cleanup.
private final class AcceptedConnections: @unchecked Sendable {
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
