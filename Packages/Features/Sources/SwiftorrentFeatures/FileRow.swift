import SwiftUI
import SwiftorrentDomain

struct FileRow: View {
    let file: TorrentItem.FileEntry
    let delete: () -> Void
    let restore: () -> Void
    @State private var confirmingDelete = false

    var body: some View {
        HStack(spacing: 10) {
            if file.isSelected {
                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .help("Delete this file from the drive")
            } else {
                Button(action: restore) {
                    Image(systemName: "arrow.down.circle")
                }
                .buttonStyle(.borderless)
                .help("Download this file again")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(file.name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(file.isSelected ? .primary : .secondary)

                ProgressView(value: file.fraction)
                    .progressViewStyle(.linear)
                    .controlSize(.mini)
                    .tint(.swiftorrentProgress)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(Int(file.fraction * 100))% · \(file.totalDescription)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .alert("Delete File?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive, action: delete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\"\(file.name)\" will be permanently removed from your drive. This cannot be undone.")
        }
    }
}
