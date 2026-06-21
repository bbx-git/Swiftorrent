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
        .sheet(item: reviewingBinding) { item in
            FileSelectionSheet(
                item: item,
                setFileSelected: { fileID, isSelected in
                    session.setFileSelected(itemID: item.id, fileID: fileID, isSelected: isSelected)
                },
                setAllSelected: { isSelected in
                    session.setAllFilesSelected(itemID: item.id, isSelected: isSelected)
                },
                start: { createSubfolder in
                    session.startDownload(itemID: item.id, createSubfolder: createSubfolder)
                },
                cancel: {
                    session.cancelPending(itemID: item.id)
                }
            )
        }
        .tint(.swiftorrentGraphite)
        .frame(minWidth: 940, minHeight: 620)
    }

    /// Surfaces the torrent currently in the add dialog (resolving metadata or
    /// awaiting file selection). It is not yet in the list. Dismissing the dialog
    /// (Esc / close) cancels adding that torrent.
    private var reviewingBinding: Binding<TorrentItem?> {
        Binding {
            session.pendingItems.first
        } set: { newValue in
            if newValue == nil, let pending = session.pendingItems.first {
                session.cancelPending(itemID: pending.id)
            }
        }
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
        Color(nsColor: .windowBackgroundColor)
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
            Metric(title: "Speed", value: session.downloadSpeedDescription, systemImage: "arrow.down.circle")
            Metric(title: "Active", value: "\(session.items.filter { $0.state == .downloading }.count)", systemImage: "arrow.down.to.line")
            Metric(title: "Done", value: "\(session.items.filter { $0.state == .complete }.count)", systemImage: "checkmark.circle")
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
                                    pause: {
                                        session.pause(itemID: item.id)
                                    },
                                    resume: {
                                        session.resume(itemID: item.id)
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
    let pause: () -> Void
    let resume: () -> Void
    let remove: () -> Void
    @State private var showFiles = false

    private var hasFileList: Bool { item.files.count > 1 }
    private var canPauseOrResume: Bool { item.state == .downloading || item.state == .paused }

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

                if canPauseOrResume {
                    Button(action: item.state == .downloading ? pause : resume) {
                        Image(systemName: item.state == .downloading ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(.glass(.regular.tint(Color.swiftorrentGraphite.opacity(0.12)).interactive()))
                    .help(item.state == .downloading ? "Pause" : "Resume")
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
                        .tint(.swiftorrentProgress)
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

private struct FileSelectionSheet: View {
    let item: TorrentItem
    let setFileSelected: (Int, Bool) -> Void
    let setAllSelected: (Bool) -> Void
    let start: (Bool) -> Void
    let cancel: () -> Void

    @State private var createSubfolder = true

    private var selectedCount: Int { item.files.filter(\.isSelected).count }
    private var selectedBytes: Int64 {
        item.files.filter(\.isSelected).reduce(Int64(0)) { $0 + $1.totalBytes }
    }
    private var selectedBytesDescription: String {
        ByteCountFormatter.string(fromByteCount: selectedBytes, countStyle: .file)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.state == .reviewing ? "Select Files to Download" : "Add Torrent")
                    .font(.title3.bold())
                Text(item.name)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            switch item.state {
            case .reviewing:
                reviewBody
            case .failed:
                failureBody
            default:
                resolvingBody
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    @ViewBuilder private var reviewBody: some View {
        HStack {
            Text("\(selectedCount) of \(item.files.count) files · \(selectedBytesDescription)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Select All") { setAllSelected(true) }
                .buttonStyle(.link)
            Button("Deselect All") { setAllSelected(false) }
                .buttonStyle(.link)
        }

        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(item.files) { file in
                    HStack(spacing: 10) {
                        Toggle(isOn: Binding(get: { file.isSelected }, set: { setFileSelected(file.id, $0) })) {
                            EmptyView()
                        }
                        .toggleStyle(.checkbox)
                        .labelsHidden()

                        Text(file.path)
                            .font(.caption)
                            .foregroundStyle(file.isSelected ? .primary : .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text(file.totalDescription)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(minHeight: 180, maxHeight: 320)
        .glassEffect(.regular.tint(.swiftorrentPanel), in: RoundedRectangle(cornerRadius: 8))

        if item.createsEnclosingDirectory {
            Toggle("Create a subfolder named \"\(item.name)\"", isOn: $createSubfolder)
                .toggleStyle(.checkbox)
                .font(.callout)
        }

        HStack {
            Button("Cancel", role: .cancel) { cancel() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button("Download") { start(createSubfolder) }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(.swiftorrentGraphite)
                .disabled(selectedCount == 0)
        }
    }

    @ViewBuilder private var resolvingBody: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text(item.status)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 24)

        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { cancel() }
                .keyboardShortcut(.cancelAction)
        }
    }

    @ViewBuilder private var failureBody: some View {
        Label(item.status, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 24)

        HStack {
            Spacer()
            Button("Close") { cancel() }
                .keyboardShortcut(.defaultAction)
        }
    }
}

private struct Metric: View {
    let title: String
    let value: String
    var systemImage: String? = nil

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(value)
                .font(.title2.bold())
                .monospacedDigit()
            Label {
                Text(title)
            } icon: {
                if let systemImage {
                    Image(systemName: systemImage)
                }
            }
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
    /// Vivid progress-bar fill so download progress stands out against the panel.
    static let swiftorrentProgress = Color(red: 0.18, green: 0.80, blue: 0.44)
    static let swiftorrentBlue = Color(red: 0.08, green: 0.38, blue: 0.82)
    static let swiftorrentRed = Color(red: 0.82, green: 0.12, blue: 0.12)
}

extension UTType {
    static let torrent = UTType(filenameExtension: "torrent") ?? .data
}
