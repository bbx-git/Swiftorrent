import SwiftUI
import SwiftorrentDomain
import UniformTypeIdentifiers

public struct SwiftorrentRootView: View {
    @State private var session = TorrentSession()
    @State private var magnetText = ""
    @State private var importerPresented = false
    @State private var selectedItemID: TorrentItem.ID?
    @State private var pendingRemovalItem: TorrentItem?

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
        .alert("Remove Torrent?", isPresented: removalAlertPresented, presenting: pendingRemovalItem) { item in
            Button("Remove from Program", role: .destructive) {
                remove(item, deleteFiles: false)
            }
            Button("Remove and Delete Files", role: .destructive) {
                remove(item, deleteFiles: true)
            }
            Button("Cancel", role: .cancel) {
                pendingRemovalItem = nil
            }
        } message: { item in
            Text("Remove \"\(item.name)\" only from Swiftorrent, or also delete its downloaded and partial files from the drive?")
        }
        .tint(.swiftorrentGraphite)
        .frame(minWidth: 940, minHeight: 620)
    }

    private var removalAlertPresented: Binding<Bool> {
        Binding {
            pendingRemovalItem != nil
        } set: { isPresented in
            if !isPresented {
                pendingRemovalItem = nil
            }
        }
    }

    private var appBackground: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: [
                    Color.black.opacity(0.14),
                    Color.swiftorrentSmoke.opacity(0.10),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [
                    Color.swiftorrentGraphite.opacity(0.14),
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
            .tint(.swiftorrentGraphite)

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
                .buttonStyle(.glass(.regular.tint(.swiftorrentGraphite.opacity(0.16)).interactive()))
            }
            .padding(14)
            .glassEffect(.regular.tint(.swiftorrentPanel), in: RoundedRectangle(cornerRadius: 8))

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
                .buttonStyle(.glass(.regular.tint(.swiftorrentGraphite.opacity(0.16)).interactive()))
            }
            .padding(14)
            .glassEffect(.regular.tint(.swiftorrentPanel), in: RoundedRectangle(cornerRadius: 8))

            Spacer()

            Label("Download-only mode. No seeding.", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .background(Color.black.opacity(0.045))
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
                    .glassEffect(.regular.tint(.swiftorrentPanel), in: RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            ForEach(session.items) { item in
                                TorrentRow(
                                    item: item,
                                    isSelected: selectedItemID == item.id,
                                    setFileSelected: { fileID, isSelected in
                                        session.setFileSelected(itemID: item.id, fileID: fileID, isSelected: isSelected)
                                    },
                                    remove: {
                                        requestRemoval(for: item)
                                    }
                                )
                                .id(item.id)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedItemID = item.id
                                }
                                .contextMenu {
                                    Button("Remove Torrent...", role: .destructive) {
                                        selectedItemID = item.id
                                        requestRemoval(for: item)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 28)
                        .padding(.vertical, 18)
                    }
                    .scrollContentBackground(.hidden)
                    .onChange(of: session.items.first?.id) { _, firstID in
                        guard let firstID else { return }
                        withAnimation(.snappy(duration: 0.18)) {
                            proxy.scrollTo(firstID, anchor: .top)
                        }
                    }
                }
                .onDeleteCommand {
                    requestRemovalForSelection()
                }
            }
        }
    }

    private func requestRemovalForSelection() {
        guard let selectedItemID,
              let item = session.items.first(where: { $0.id == selectedItemID }) else {
            return
        }
        requestRemoval(for: item)
    }

    private func requestRemoval(for item: TorrentItem) {
        selectedItemID = item.id
        pendingRemovalItem = item
    }

    private func remove(_ item: TorrentItem, deleteFiles: Bool) {
        session.remove(item, deleteFiles: deleteFiles)
        if selectedItemID == item.id {
            selectedItemID = nil
        }
        pendingRemovalItem = nil
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
    let isSelected: Bool
    let setFileSelected: (Int, Bool) -> Void
    let remove: () -> Void
    @State private var showFiles = false

    private var hasFileList: Bool { item.files.count > 1 }

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

                    HStack {
                        Text(item.status)
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

                Button(role: .destructive, action: remove) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.glass(.regular.tint(Color.swiftorrentGraphite.opacity(0.12)).interactive()))
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
                FileSelectionRow(file: file) { isSelected in
                    setFileSelected(file.id, isSelected)
                }
            }
        }
        .padding(.leading, 50)
        .padding(.trailing, 6)
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
        case .downloading: .swiftorrentGreen
        case .complete: .swiftorrentBlue
        case .failed: .swiftorrentRed
        }
    }

    private var badgeColor: Color {
        switch item.state {
        case .queued: .swiftorrentSmoke
        case .downloading: .swiftorrentGreen
        case .complete: .swiftorrentBlue
        case .failed: .swiftorrentRed
        }
    }

    private var badgeForeground: Color {
        switch item.state {
        case .queued: .primary
        case .downloading, .complete, .failed: .white
        }
    }
}

private struct FileSelectionRow: View {
    let file: TorrentItem.FileEntry
    let setSelected: (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { file.isSelected }, set: { setSelected($0) })) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 4) {
                Text(file.name)
                    .font(.caption)
                    .foregroundStyle(file.isSelected ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if file.isSelected {
                    ProgressView(value: file.fraction)
                        .progressViewStyle(.linear)
                        .controlSize(.mini)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(file.isSelected ? "\(Int(file.fraction * 100))% · \(file.totalDescription)" : "Skipped")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
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
        .glassEffect(.regular.tint(.swiftorrentPanel), in: RoundedRectangle(cornerRadius: 8))
    }
}

private extension Color {
    static let swiftorrentGraphite = Color(red: 0.18, green: 0.18, blue: 0.19)
    static let swiftorrentSmoke = Color(red: 0.46, green: 0.46, blue: 0.48)
    static let swiftorrentPanel = Color.black.opacity(0.08)
    static let swiftorrentGreen = Color(red: 0.05, green: 0.58, blue: 0.28)
    static let swiftorrentBlue = Color(red: 0.08, green: 0.38, blue: 0.82)
    static let swiftorrentRed = Color(red: 0.82, green: 0.12, blue: 0.12)
}

extension UTType {
    static let torrent = UTType(filenameExtension: "torrent") ?? .data
}
