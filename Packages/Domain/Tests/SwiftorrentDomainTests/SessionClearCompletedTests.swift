import Foundation
@testable import SwiftorrentDomain
import Testing

@Suite("Clear completed")
@MainActor
struct SessionClearCompletedTests {
    private func persistedItem(name: String, state: String) -> PersistedItem {
        var info = Data("d6:lengthi16384e4:name\(name.utf8.count):\(name)12:piece lengthi16384e6:pieces20:".utf8)
        info.append(Data(repeating: 0xAB, count: 20))
        info.append(Data("e".utf8))
        return PersistedItem(
            id: UUID(),
            name: name,
            destinationPath: "/tmp/Downloads",
            source: .magnet(text: "magnet:?xt=urn:btih:abc"),
            stripRootDirectory: true,
            createsEnclosingDirectory: false,
            outputRelativePaths: [name],
            files: [PersistedItem.File(id: 0, path: name, totalBytes: 16384, downloadedBytes: 16384, isSelected: true)],
            totalBytes: 16384,
            downloadedBytes: 16384,
            progress: 1,
            state: state,
            status: state,
            infoDictionaryData: info,
            announceURLs: [],
            webSeedURLs: []
        )
    }

    private func makeSession(states: [String]) async -> TorrentSession {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("session.json", isDirectory: false)
        let names = ["aaaa", "bbbb", "cccc"]
        let snapshot = PersistedSession(
            destinationPath: "/tmp/Downloads",
            downloadRateLimit: nil,
            items: states.enumerated().map { persistedItem(name: names[$0.offset], state: $0.element) }
        )
        let store = TorrentSessionStore(fileURL: fileURL)
        await store.save(snapshot)
        return TorrentSession(destination: URL(fileURLWithPath: "/tmp/Downloads"), store: store)
    }

    @Test("Removes completed rows and leaves paused and failed ones")
    func removesOnlyCompleted() async {
        let session = await makeSession(states: ["complete", "paused", "complete"])
        #expect(session.hasCompleted)

        session.removeCompleted()

        #expect(session.items.map(\.state) == [.paused])
        #expect(!session.hasCompleted)
    }

    @Test("Nothing to clear when no row is complete")
    func nothingToClear() async {
        let session = await makeSession(states: ["paused"])
        #expect(!session.hasCompleted)
        session.removeCompleted()
        #expect(session.items.count == 1)
    }
}
