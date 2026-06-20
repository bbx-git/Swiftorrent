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
            .background(Color(nsColor: .windowBackgroundColor))
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
        .frame(minWidth: 940, minHeight: 620)
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
                .buttonStyle(.glass)
            }
            .padding(14)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 8))

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
                .buttonStyle(.glass)
            }
            .padding(14)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 8))

            Spacer()

            Label("Download-only mode. No seeding.", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 340)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Downloads")
                    .font(.largeTitle.bold())
                Text("A pure Swift BitTorrent client with upload disabled.")
                    .foregroundStyle(.secondary)
            }
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
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(session.items) { item in
                        TorrentRow(item: item) {
                            session.remove(item)
                        }
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
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 12)
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
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 8))
    }
}

extension UTType {
    static let torrent = UTType(filenameExtension: "torrent") ?? .data
}
