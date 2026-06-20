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
            "magnet:?xt=urn:btih:6A8F134C989C1ECF961CED4AC0B32CC5B615B287&dn=Example&tr=udp%3A%2F%2Ftracker.example.invalid%3A1337%2Fannounce&tr=http%3A%2F%2Ftracker.example.invalid%3A8080%2Fannounce&tr=https%3A%2F%2Fsecure.example.invalid%2Fannounce"
        )
        #expect(magnet.infoHash.map { String(format: "%02X", $0) }.joined() == "6A8F134C989C1ECF961CED4AC0B32CC5B615B287")
        #expect(magnet.trackers.filter { $0.scheme == "http" || $0.scheme == "https" }.count == 2)
    }

    @Test("Bencode encoder sorts dictionary keys")
    func bencodeEncoder() {
        let encoded = BencodeEncoder.encode([
            "piece": .integer(3),
            "msg_type": .integer(0)
        ])
        #expect(String(data: encoded, encoding: .utf8) == "d8:msg_typei0e5:piecei3ee")
    }

    @Test("Tracker percent encoding escapes binary bytes")
    func trackerPercentEncoding() {
        let data = Data([0x00, 0x20, 0x2F, 0x41, 0x7A, 0xFF])

        #expect(TrackerClient.percentEncode(data) == "%00%20%2FAz%FF")
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
        #expect(try Data(contentsOf: destination.appendingPathComponent("Root/a.txt")) == Data("ab".utf8))
        #expect(try Data(contentsOf: destination.appendingPathComponent("Root/b.txt")) == Data("cd".utf8))
        #expect(try writer.verifiedPieces() == [0])
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

    private func makeMetainfo(pieceLength: Int, pieces: [Data]) -> TorrentMetainfo {
        TorrentMetainfo(
            name: "Root",
            announceURLs: [],
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
