import SwiftUI
import SwiftorrentDomain

struct TorrentRow: View {
    let item: TorrentItem
    let isSelected: Bool
    let deleteFile: (Int) -> Void
    let restoreFile: (Int) -> Void
    let pause: () -> Void
    let resume: () -> Void
    let remove: () -> Void
    @State private var showFiles = false

    private var hasFileList: Bool { item.files.count > 1 }
    private var canPauseOrResume: Bool {
        item.state == .downloading || item.state == .paused || item.state == .failed
    }

    private var pauseResumeIcon: String {
        switch item.state {
        case .downloading: "pause.fill"
        case .failed: "arrow.clockwise"
        default: "play.fill"
        }
    }

    private var pauseResumeHelp: String {
        switch item.state {
        case .downloading: "Pause"
        case .failed: "Retry"
        default: "Resume"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(color)
                    .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(item.name)
                            .font(.headline)
                        Spacer()
                        Text(item.state.rawValue.capitalized)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .foregroundStyle(badgeForeground)
                            .glassEffect(.regular.tint(badgeColor.opacity(0.55)), in: Capsule())
                    }

                    ProgressView(value: item.progress)
                        .progressViewStyle(.linear)
                        .tint(.swiftorrentProgress)

                    HStack(spacing: 6) {
                        Text(item.status)
                        if item.state == .downloading, item.downloadSpeed > 0 {
                            Label(item.speedDescription, systemImage: "arrow.down")
                                .labelStyle(.titleAndIcon)
                                .foregroundStyle(Color.swiftorrentGreen)
                        }
                        Spacer()
                        Text("\(item.downloadedDescription) / \(item.totalDescription)")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if hasFileList {
                        Button {
                            withAnimation(.snappy(duration: 0.18)) { showFiles.toggle() }
                        } label: {
                            Label("\(selectedCount) of \(item.files.count) files", systemImage: showFiles ? "chevron.down" : "chevron.right")
                                .font(.caption.weight(.medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if canPauseOrResume {
                    Button(action: item.state == .downloading ? pause : resume) {
                        Image(systemName: pauseResumeIcon)
                    }
                    .buttonStyle(.glass(.regular.tint(Color.swiftorrentGraphite.opacity(0.12)).interactive()))
                    .help(pauseResumeHelp)
                }

                Button(role: .destructive, action: remove) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.glass(.regular.tint(Color.swiftorrentGraphite.opacity(0.12)).interactive()))
                .help("Remove")
            }

            if hasFileList, showFiles {
                fileList
            }
        }
        .padding(14)
        .glassEffect(.regular.tint(isSelected ? Color.swiftorrentGraphite.opacity(0.18) : Color.swiftorrentPanel), in: RoundedRectangle(cornerRadius: 8))
    }

    private var selectedCount: Int {
        item.files.filter(\.isSelected).count
    }

    private var fileList: some View {
        VStack(spacing: 6) {
            ForEach(item.files) { file in
                FileRow(file: file, delete: { deleteFile(file.id) }, restore: { restoreFile(file.id) })
            }
        }
        .padding(.leading, 50)
        .padding(.trailing, 6)
    }

    var icon: String {
        switch item.state {
        case .queued: "clock"
        case .reviewing: "checklist"
        case .downloading: "arrow.down"
        case .paused: "pause.circle.fill"
        case .complete: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch item.state {
        case .queued: .secondary
        case .reviewing: .swiftorrentSmoke
        case .downloading: .swiftorrentGreen
        case .paused: .swiftorrentSmoke
        case .complete: .swiftorrentBlue
        case .failed: .swiftorrentRed
        }
    }

    private var badgeColor: Color {
        switch item.state {
        case .queued: .swiftorrentSmoke
        case .reviewing: .swiftorrentSmoke
        case .downloading: .swiftorrentGreen
        case .paused: .swiftorrentSmoke
        case .complete: .swiftorrentBlue
        case .failed: .swiftorrentRed
        }
    }

    private var badgeForeground: Color {
        switch item.state {
        case .queued, .reviewing, .paused: .primary
        case .downloading, .complete, .failed: .white
        }
    }
}
