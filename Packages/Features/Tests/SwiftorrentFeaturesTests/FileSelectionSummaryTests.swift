@testable import SwiftorrentFeatures
import SwiftorrentDomain
import Testing

@Suite("File selection summary")
@MainActor
struct FileSelectionSummaryTests {
    private let files = [
        TorrentItem.FileEntry(id: 0, path: "a.bin", totalBytes: 1_000, isSelected: true),
        TorrentItem.FileEntry(id: 1, path: "b.bin", totalBytes: 2_000, isSelected: false),
        TorrentItem.FileEntry(id: 2, path: "c.bin", totalBytes: 4_000, isSelected: true)
    ]

    @Test("counts and sums only the selected files")
    func countsSelected() {
        let summary = FileSelectionSummary(files: files)
        #expect(summary.selectedCount == 2)
        #expect(summary.totalCount == 3)
        #expect(summary.selectedBytes == 5_000)
    }

    @Test("nothing selected gives zero")
    func noneSelected() {
        let none = files.map { entry in
            var entry = entry
            entry.isSelected = false
            return entry
        }
        let summary = FileSelectionSummary(files: none)
        #expect(summary.selectedCount == 0)
        #expect(summary.selectedBytes == 0)
    }
}
