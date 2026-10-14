import Foundation
@testable import SwiftorrentCore
import Testing

@Suite("Piece progress throttle")
struct ProgressThrottleTests {
    private func makeCoordinator() -> PieceDownloadCoordinator {
        let files = [TorrentFile(id: 0, path: "a", length: 100)]
        let metainfo = TorrentMetainfo(
            name: "a", announceURLs: [], files: files, pieceLength: 10,
            pieceHashes: Array(repeating: Data(count: 20), count: 10),
            totalSize: 100, infoHash: Data(count: 20), infoDictionaryData: Data()
        )
        return PieceDownloadCoordinator(
            layout: TorrentLayout(metainfo: metainfo),
            selectablePieces: Set(0..<10),
            completedPieces: [],
            initialDownloaded: 0,
            availabilityCounts: [:]
        )
    }

    @Test("Piece-completion progress is reported at most every 200 ms")
    func pieceProgressIsThrottled() async throws {
        let coordinator = makeCoordinator()

        let first = await coordinator.complete(pieceIndex: 0).perFileBytes
        let burst = await (1..<9).asyncMap { await coordinator.complete(pieceIndex: $0).perFileBytes }
        try await Task.sleep(for: .milliseconds(250))
        let later = await coordinator.complete(pieceIndex: 9).perFileBytes

        #expect(first == [10])
        #expect(burst.allSatisfy { $0 == nil })
        #expect(later == [100])
    }
}

private extension Sequence {
    func asyncMap<T>(_ transform: (Element) async -> T) async -> [T] {
        var result: [T] = []
        for element in self { result.append(await transform(element)) }
        return result
    }
}
