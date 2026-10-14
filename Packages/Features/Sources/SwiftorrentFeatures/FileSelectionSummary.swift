import Foundation
import SwiftorrentDomain

/// Count and size of the files ticked in the add dialog.
struct FileSelectionSummary: Equatable {
    let selectedCount: Int
    let totalCount: Int
    let selectedBytes: Int64

    init(files: [TorrentItem.FileEntry]) {
        let selected = files.filter(\.isSelected)
        selectedCount = selected.count
        totalCount = files.count
        selectedBytes = selected.reduce(Int64(0)) { $0 + $1.totalBytes }
    }

    var description: String {
        let size = ByteCountFormatter.string(fromByteCount: selectedBytes, countStyle: .file)
        return "\(selectedCount) of \(totalCount) files · \(size)"
    }
}
