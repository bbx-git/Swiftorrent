import CryptoKit
import Foundation
@testable import SwiftorrentCore
import Testing

@Suite("Many-file torrents")
struct ManyFilesTests {
    /// A torrent of `fileCount` small files, with pieces spanning many files.
    private func makeTorrent(fileCount: Int, fileSize: Int, pieceLength: Int) -> (TorrentMetainfo, Data) {
        var stream = Data()
        var files: [TorrentFile] = []
        for index in 0..<fileCount {
            files.append(TorrentFile(id: index, path: "Root/d\(index / 100)/f\(index).bin", length: Int64(fileSize)))
            stream.append(Data((0..<fileSize).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ index) }))
        }
        var hashes: [Data] = []
        var offset = 0
        while offset < stream.count {
            let end = min(offset + pieceLength, stream.count)
            hashes.append(Data(Insecure.SHA1.hash(data: stream[offset..<end])))
            offset = end
        }
        let metainfo = TorrentMetainfo(
            name: "Root",
            announceURLs: [],
            files: files,
            pieceLength: pieceLength,
            pieceHashes: hashes,
            totalSize: Int64(stream.count),
            infoHash: Data(repeating: 0, count: 20),
            infoDictionaryData: Data()
        )
        return (metainfo, stream)
    }

    @Test("Writing and verifying thousands of small files stays fast")
    func writeAndVerifyManyFiles() throws {
        let (metainfo, stream) = makeTorrent(fileCount: 16_000, fileSize: 1_000, pieceLength: 16_384)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        let writer = TorrentFileWriter(metainfo: metainfo, destination: destination)
        let clock = ContinuousClock()

        let writeTime = try clock.measure {
            for index in metainfo.pieceHashes.indices {
                let start = index * metainfo.pieceLength
                let end = min(start + metainfo.pieceLength, stream.count)
                try writer.write(piece: Data(stream[start..<end]), pieceIndex: index)
            }
        }
        var verified = Set<Int>()
        let verifyTime = try clock.measure { verified = try writer.verifiedPieces() }

        #expect(verified.count == metainfo.pieceHashes.count)
        // Quadratic offset math took 14 s to write and 35 s to verify this torrent.
        #expect(writeTime < .seconds(8))
        #expect(verifyTime < .seconds(8))
    }

    @Test("Concurrent verification agrees with the sequential scan and spots a bad piece")
    func concurrentVerifyMatchesSequential() async throws {
        let (metainfo, stream) = makeTorrent(fileCount: 300, fileSize: 1_000, pieceLength: 4_096)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        let writer = TorrentFileWriter(metainfo: metainfo, destination: destination)
        for index in metainfo.pieceHashes.indices {
            let start = index * metainfo.pieceLength
            let end = min(start + metainfo.pieceLength, stream.count)
            var piece = Data(stream[start..<end])
            if index == 7 { piece[0] ^= 0xFF }   // corrupt one piece on disk
            try writer.write(piece: piece, pieceIndex: index)
        }

        let sequential = try writer.verifiedPieces()
        let concurrent = try await writer.verifiedPiecesConcurrently(among: metainfo.pieceHashes.indices)

        #expect(concurrent == sequential)
        #expect(!concurrent.contains(7))
        #expect(concurrent.count == metainfo.pieceHashes.count - 1)
    }

    @Test("A verification scan stops when its task is cancelled")
    func verificationIsCancellable() async throws {
        let (metainfo, stream) = makeTorrent(fileCount: 2_000, fileSize: 1_000, pieceLength: 4_096)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        let writer = TorrentFileWriter(metainfo: metainfo, destination: destination)
        for index in metainfo.pieceHashes.indices {
            let start = index * metainfo.pieceLength
            let end = min(start + metainfo.pieceLength, stream.count)
            try writer.write(piece: Data(stream[start..<end]), pieceIndex: index)
        }

        let scan = Task { try await writer.verifiedPiecesConcurrently(among: metainfo.pieceHashes.indices) }
        scan.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await scan.value
        }
    }

    @Test("Boundary slices for a partial web-seed selection match the brute-force definition")
    func boundarySlicesMatchBruteForce() {
        let lengths: [Int64] = [100, 50, 3_000, 20, 700, 0, 256, 1]
        let files = lengths.enumerated().map { TorrentFile(id: $0.offset, path: "R/f\($0.offset)", length: $0.element) }
        let total = lengths.reduce(0, +)
        let pieceLength = 256
        let pieceCount = Int((total + Int64(pieceLength) - 1) / Int64(pieceLength))
        let metainfo = TorrentMetainfo(
            name: "R", announceURLs: [], files: files, pieceLength: pieceLength,
            pieceHashes: Array(repeating: Data(count: 20), count: pieceCount),
            totalSize: total, infoHash: Data(count: 20), infoDictionaryData: Data()
        )
        let layout = TorrentLayout(metainfo: metainfo)
        let downloader = WebSeedDownloader(session: .shared)

        for selection in [Set([2]), Set([0, 4]), Set([1, 3, 6]), Set([7])] {
            let selectable = layout.pieceIndices(forFiles: selection)
            var expected: [WebSeedDownloader.NeighborSlice] = []
            for piece in selectable.sorted() {
                let pieceRange = layout.range(ofPiece: piece)
                for file in files where !selection.contains(file.id) {
                    let fileRange = layout.range(ofFile: file.id)
                    let low = max(pieceRange.lowerBound, fileRange.lowerBound)
                    let high = min(pieceRange.upperBound, fileRange.upperBound)
                    if high > low {
                        expected.append(.init(file: file, fileOffset: low - fileRange.lowerBound, length: high - low))
                    }
                }
            }

            let actual = downloader.boundaryNeighborSlices(metainfo: metainfo, layout: layout, selectablePieces: selectable, selection: selection)

            func key(_ slice: WebSeedDownloader.NeighborSlice) -> String { "\(slice.file.id):\(slice.fileOffset):\(slice.length)" }
            #expect(Set(actual.map(key)) == Set(expected.map(key)), "selection \(selection)")
            #expect(actual.count == expected.count, "selection \(selection)")
        }
    }
}
