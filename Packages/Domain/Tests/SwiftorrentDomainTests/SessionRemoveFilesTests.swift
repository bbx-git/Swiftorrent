import Foundation
@testable import SwiftorrentDomain
import Testing

@Suite("Remove and delete files")
@MainActor
struct SessionRemoveFilesTests {
    @Test("Deletion waits for the stopping download task, so its last write cannot recreate the file")
    func deletesAfterTaskFinishes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let partial = directory.appendingPathComponent("movie.bin.tor")

        // Stands in for a download task that is cancelled but still finishing a write.
        let lateWriter = Task<Void, Never> {
            try? await Task.sleep(for: .milliseconds(150))
            FileManager.default.createFile(atPath: partial.path, contents: Data([1]))
        }

        var item = TorrentItem(name: "movie.bin", source: .magnet("magnet:?xt=urn:btih:abc"), destination: directory, totalBytes: 1)
        item.outputRelativePaths = ["movie.bin"]
        let session = TorrentSession(destination: directory, store: TorrentSessionStore(fileURL: directory.appendingPathComponent("session.json")))

        await session.removeFiles(for: item, after: lateWriter)

        #expect(!FileManager.default.fileExists(atPath: partial.path))
    }
}
