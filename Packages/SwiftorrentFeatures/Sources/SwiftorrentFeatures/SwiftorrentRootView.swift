import SwiftUI
import SwiftorrentDomain
import UniformTypeIdentifiers

public struct SwiftorrentRootView: View {
    @State private var session = TorrentSession()
    @State private var magnetText = ""
    @State private var importerPresented = false

    public init() {}

    public var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                header
                content
            }
            .background(appBackground)
        }
        .fileImporter(isPresented: $importerPresented, allowedContentTypes: [.torrent], allowsMultipleSelection: true) { result in
            if case let .success(urls) = result {
                for url in urls {
                    session.addTorrentFile(url)
                }
            }
        }
        .onOpenURL { url in
            if url.isFileURL, url.pathExtension.lowercased() == "torrent" {
                session.addTorrentFile(url)
            } else if url.scheme?.lowercased() == "magnet" {
                session.addMagnet(url.absoluteString)
            }
        }
        .tint(.swiftorrentBlue)
        .frame(minWidth: 940, minHeight: 620)
    }

    private var appBackground: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: [
                    Color.swiftorrentBlue.opacity(0.16),
                    Color.cyan.opacity(0.06),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [
                    Color.swiftorrentBlue.opacity(0.16),
                    Color.clear
                ],
                center: .topTrailing,
                startRadius: 40,
                endRadius: 520
            )
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Swiftorrent", systemImage: "arrow.down.circle.fill")
                .font(.title2.bold())
                .foregroundStyle(.primary)

            Button {
                importerPresented = true
            } label: {
                Label("Open .torrent", systemImage: "doc.badge.plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.glassProminent)
            .tint(.swiftorrentBlue)

            VStack(alignment: .leading, spacing: 8) {
                Text("Magnet")
                    .font(.headline)
                TextField("magnet:?xt=urn:btih:...", text: $magnetText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...5)
                Button("Add Magnet") {
                    session.addMagnet(magnetText)
                    magnetText = ""
                }
                .disabled(magnetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .buttonStyle(.glass(.regular.tint(.swiftorrentBlue.opacity(0.16)).interactive()))
            }
            .padding(14)
            .glassEffect(.regular.tint(.swiftorrentBlue.opacity(0.14)), in: RoundedRectangle(cornerRadius: 8))

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Download To")
                    .font(.headline)
                Text(session.destination.path(percentEncoded: false))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                Button {
                    chooseFolder()
                } label: {
                    Label("Choose Folder", systemImage: "folder")
                }
                .buttonStyle(.glass(.regular.tint(.swiftorrentBlue.opacity(0.16)).interactive()))
            }
            .padding(14)
            .glassEffect(.regular.tint(.swiftorrentBlue.opacity(0.14)), in: RoundedRectangle(cornerRadius: 8))

            Spacer()

            Label("Download-only mode. No seeding.", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .background(Color.swiftorrentBlue.opacity(0.05))
        .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 340)
    }

    private var header: some View {
        HStack {
            Spacer()
            Metric(title: "Active", value: "\(session.items.filter { $0.state == .downloading }.count)")
            Metric(title: "Done", value: "\(session.items.filter { $0.state == .complete }.count)")
        }
        .padding(28)
    }

    private var content: some View {
        Group {
            if session.items.isEmpty {
                ContentUnavailableView("No torrents yet", systemImage: "tray", description: Text("Open a .torrent file or paste a magnet link to begin."))
                    .padding(32)
                    .glassEffect(.regular.tint(.swiftorrentBlue.opacity(0.10)), in: RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(session.items) { item in
                        TorrentRow(item: item) {
                            session.remove(item)
                        }
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 7, leading: 20, bottom: 7, trailing: 20))
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = session.destination
        if panel.runModal() == .OK, let url = panel.url {
            session.chooseDestination(url)
        }
    }
}

private struct TorrentRow: View {
    let item: TorrentItem
    let remove: () -> Void

    var body: some View {
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
                        .foregroundStyle(color)
                        .glassEffect(.regular.tint(color.opacity(0.18)), in: Capsule())
                }

                ProgressView(value: item.progress)
                    .progressViewStyle(.linear)

                HStack {
                    Text(item.status)
                    Spacer()
                    Text("\(item.downloadedDescription) / \(item.totalDescription)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Button(role: .destructive, action: remove) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.glass(.regular.tint(.red.opacity(0.10)).interactive()))
        }
        .padding(14)
        .glassEffect(.regular.tint(.swiftorrentBlue.opacity(0.10)), in: RoundedRectangle(cornerRadius: 8))
    }

    private var icon: String {
        switch item.state {
        case .queued: "clock"
        case .downloading: "arrow.down"
        case .complete: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch item.state {
        case .queued: .secondary
        case .downloading: .accentColor
        case .complete: .green
        case .failed: .red
        }
    }
}

private struct Metric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(value)
                .font(.title2.bold())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular.tint(.swiftorrentBlue.opacity(0.14)), in: RoundedRectangle(cornerRadius: 8))
    }
}

private extension Color {
    static let swiftorrentBlue = Color(red: 0.18, green: 0.43, blue: 0.82)
}

extension UTType {
    static let torrent = UTType(filenameExtension: "torrent") ?? .data
}
