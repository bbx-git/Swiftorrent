import Foundation
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
