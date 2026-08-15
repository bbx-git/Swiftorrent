import Foundation
@testable import SwiftorrentDomain
import Testing

@Suite("Cancel-pending safety")
@MainActor
struct SessionCancelPendingTests {
    /// Regression test: the add window's catch-all `.onDisappear` fires
    /// `cancelPending` right after Download moves the item into `items` and
    /// launches its download task. `cancelPending` must ignore non-pending items
    /// — previously it cancelled the just-launched task and nilled the stored
    /// metainfo, leaving every magnet/torrent stuck on "Starting download.".
    @Test("cancelPending after startDownload leaves the download intact")
    func cancelPendingAfterStartIsANoOp() async throws {
        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        // Minimal valid single-file torrent: name, piece length, one piece hash.
        let torrentURL = workDirectory.appendingPathComponent("tiny.torrent")
        var torrentData = Data("d4:infod6:lengthi16384e4:name4:tiny12:piece lengthi16384e6:pieces20:".utf8)
        torrentData.append(Data(repeating: 0xAB, count: 20))
        torrentData.append(Data("ee".utf8))
        try torrentData.write(to: torrentURL)

        let store = TorrentSessionStore(fileURL: workDirectory.appendingPathComponent("session.json"))
        let session = TorrentSession(destination: workDirectory, store: store)
        let id = session.addTorrentFile(torrentURL)

        // Parsing is async; wait for the item to reach the reviewing state.
        for _ in 0..<200 {
            if session.pendingItems.first(where: { $0.id == id })?.state == .reviewing { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(session.pendingItems.first(where: { $0.id == id })?.state == .reviewing)

        session.startDownload(itemID: id, createSubfolder: false)
        // What the window's `.onDisappear` does once Download empties its item
        // out of `pendingItems`.
        session.cancelPending(itemID: id)

        #expect(session.pendingItems.isEmpty)
        #expect(session.items.first(where: { $0.id == id })?.state == .downloading)

        // The metainfo must also survive, or the row could never resume. Pause
        // then resume: resume only succeeds when the metainfo is still stored.
        session.pause(itemID: id)
        #expect(session.items.first(where: { $0.id == id })?.state == .paused)
        session.resume(itemID: id)
        #expect(session.items.first(where: { $0.id == id })?.state == .downloading)

        if let item = session.items.first(where: { $0.id == id }) {
            session.remove(item)
        }
    }
}
