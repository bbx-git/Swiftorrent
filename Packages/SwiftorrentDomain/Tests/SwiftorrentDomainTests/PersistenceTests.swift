import Foundation
@testable import SwiftorrentDomain
import Testing

@Suite("Session persistence")
struct PersistenceTests {
    @Test("Store round-trips a saved session through disk")
    func storeRoundTrip() async {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("session.json", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let snapshot = PersistedSession(
            destinationPath: "/tmp/Downloads",
            downloadRateLimit: 1024 * 1024,
            items: [
                PersistedItem(
                    id: UUID(),
                    name: "Example",
                    destinationPath: "/tmp/Downloads",
                    source: .magnet(text: "magnet:?xt=urn:btih:abc"),
                    stripRootDirectory: true,
                    createsEnclosingDirectory: false,
                    outputRelativePaths: ["a.txt", "b.txt"],
                    files: [
                        PersistedItem.File(id: 0, path: "a.txt", totalBytes: 10, downloadedBytes: 10, isSelected: true),
                        PersistedItem.File(id: 1, path: "b.txt", totalBytes: 20, downloadedBytes: 5, isSelected: false)
                    ],
                    totalBytes: 30,
                    downloadedBytes: 15,
                    progress: 0.5,
                    state: "downloading",
                    status: "Downloading",
                    infoDictionaryData: Data("d4:name7:examplee".utf8),
                    announceURLs: ["http://tracker.example.invalid/announce"],
                    webSeedURLs: []
                )
            ]
        )

        let writer = TorrentSessionStore(fileURL: fileURL)
        await writer.save(snapshot)

        let reader = TorrentSessionStore(fileURL: fileURL)
        let restored = reader.load()
        #expect(restored == snapshot)
    }

    @Test("Loading a missing session file returns nil rather than failing")
    func loadMissingReturnsNil() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
        let store = TorrentSessionStore(fileURL: fileURL)
        #expect(store.load() == nil)
    }
}
