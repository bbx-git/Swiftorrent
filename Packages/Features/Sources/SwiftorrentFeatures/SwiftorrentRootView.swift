import SwiftUI
import SwiftorrentDomain
import UniformTypeIdentifiers

public struct SwiftorrentRootView: View {
    @Environment(TorrentSession.self) private var session
    @Environment(\.openWindow) private var openWindow
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
                    openAddTorrentWindow(for: session.addTorrentFile(url))
                }
            }
        }
        .onOpenURL { url in
            if url.isFileURL, url.pathExtension.lowercased() == "torrent" {
                openAddTorrentWindow(for: session.addTorrentFile(url))
            } else if url.scheme?.lowercased() == "magnet" {
                openAddTorrentWindow(for: session.addMagnet(url.absoluteString))
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
        .transparentWindow()
        .keepsDialogsAboveWhenActivated()
        .showsSpeedInDockBadge()
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
        // Behind-window glass instead of a solid fill so the detail pane is
        // translucent and tracks the system Liquid Glass opacity slider.
        VisualEffectBackground(material: .underWindowBackground)
            .ignoresSafeArea()
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
                    openAddTorrentWindow(for: session.addMagnet(magnetText))
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
        }
        .padding(20)
        .background(Color.black.opacity(0.045))
        .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 340)
    }

    private var downloadRateLimitBinding: Binding<Int?> {
        Binding(
            get: { session.downloadRateLimit },
            set: { session.downloadRateLimit = $0 }
        )
    }

    private var header: some View {
        HStack {
            SpeedLimitControl(limit: downloadRateLimitBinding)
            Button("Clear Completed", systemImage: "checkmark.circle.badge.xmark") {
                session.removeCompleted()
            }
            .buttonStyle(.glass(.regular.tint(Color.swiftorrentGraphite.opacity(0.16)).interactive()))
            .tint(.primary)
            .disabled(!session.hasCompleted)
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
                                    deleteFile: { fileID in
                                        session.deleteFile(itemID: item.id, fileID: fileID)
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

    // `openWindow` called synchronously from `.onOpenURL` during a cold launch
    // races the main scene's own launch/activation sequence: the add-torrent
    // window gets created, but the main window's launch-time activation can
    // still assert itself afterward and end up in front, leaving the new
    // dialog open but hidden behind an empty "No torrents yet" list — which
    // reads as "nothing happened". Deferring to the next run-loop turn lets
    // the initial launch settle first, so the dialog opens on top as intended.
    private func openAddTorrentWindow(for itemID: TorrentItem.ID) {
        Task { @MainActor in
            openWindow(value: itemID)
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
    let isSelected: Bool
    let deleteFile: (Int) -> Void
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
            ForEach(item.files.filter(\.isSelected)) { file in
                FileRow(file: file) {
                    deleteFile(file.id)
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

private struct FileRow: View {
    let file: TorrentItem.FileEntry
    let delete: () -> Void
    @State private var confirmingDelete = false

    var body: some View {
        HStack(spacing: 10) {
            Button(role: .destructive) {
                confirmingDelete = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .help("Delete this file from the drive")
            .alert("Delete File?", isPresented: $confirmingDelete) {
                Button("Delete", role: .destructive, action: delete)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\"\(file.name)\" will be permanently removed from your drive. This cannot be undone.")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(file.name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)

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
    }
}

/// Header control for the global download-speed cap: a menu of presets plus a
/// "Custom…" popover where the user types an exact value in KB/s or MB/s. The
/// limit is bytes per second; `nil` means unlimited.
private struct SpeedLimitControl: View {
    @Binding var limit: Int?

    @State private var showingCustom = false
    @State private var customValue = ""
    @State private var customUnit: SpeedUnit = .megabytes

    private enum SpeedUnit: String, CaseIterable, Identifiable {
        case kilobytes, megabytes
        var id: String { rawValue }
        var label: String { self == .kilobytes ? "KB/s" : "MB/s" }
        // Decimal (1000-based) to match the `.file` ByteCountFormatter display,
        // so a typed "50 KB/s" reads back as exactly "50 KB/s".
        var multiplier: Int { self == .kilobytes ? 1_000 : 1_000_000 }
    }

    private static let presets: [Int] = [
        128 * 1_000, 256 * 1_000, 512 * 1_000,
        1_000_000, 2_000_000, 5_000_000, 10_000_000
    ]

    static func label(forBytesPerSecond bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) + "/s"
    }

    var body: some View {
        Menu {
            menuButton(title: "Unlimited", isSelected: limit == nil) { limit = nil }
            Divider()
            ForEach(Self.presets, id: \.self) { bytes in
                menuButton(title: Self.label(forBytesPerSecond: bytes), isSelected: limit == bytes) {
                    limit = bytes
                }
            }
            Divider()
            Button("Custom…") {
                prepareCustomFields()
                showingCustom = true
            }
        } label: {
            Label(limit.map(Self.label(forBytesPerSecond:)) ?? "Unlimited", systemImage: "speedometer")
        }
        .menuStyle(.button)
        .buttonStyle(.glass(.regular.tint(Color.swiftorrentGraphite.opacity(0.16)).interactive()))
        // The window-wide graphite tint would otherwise colour the label near
        // black on the dark glass while the window is active.
        .tint(.primary)
        .fixedSize()
        .help("Limit total download speed")
        .popover(isPresented: $showingCustom, arrowEdge: .bottom) { customForm }
    }

    @ViewBuilder private func menuButton(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if isSelected {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private var customForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Custom Speed Limit")
                .font(.headline)
            HStack(spacing: 8) {
                TextField("Max", text: $customValue)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .onSubmit(applyCustom)
                Picker("", selection: $customUnit) {
                    ForEach(SpeedUnit.allCases) { unit in
                        Text(unit.label).tag(unit)
                    }
                }
                .labelsHidden()
                .fixedSize()
                Button("Set", action: applyCustom)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(.swiftorrentGraphite)
                    .disabled(parsedBytesPerSecond == nil)
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    /// Parses the typed value (accepting a comma or dot decimal) into bytes per
    /// second, or `nil` when it isn't a positive number.
    private var parsedBytesPerSecond: Int? {
        let normalized = customValue
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        guard let value = Double(normalized), value > 0 else { return nil }
        return Int(value * Double(customUnit.multiplier))
    }

    private func applyCustom() {
        guard let bytes = parsedBytesPerSecond else { return }
        limit = bytes
        showingCustom = false
    }

    /// Pre-fills the popover from the active limit so editing starts from the
    /// current value rather than blank.
    private func prepareCustomFields() {
        guard let limit else {
            customValue = ""
            return
        }
        if limit % 1_000_000 == 0 {
            customUnit = .megabytes
            customValue = String(limit / 1_000_000)
        } else {
            customUnit = .kilobytes
            customValue = String(format: "%g", Double(limit) / 1_000.0)
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

extension Color {
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
