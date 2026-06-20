import CryptoKit
import Foundation
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
