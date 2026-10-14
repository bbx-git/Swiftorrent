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
        .onAppear { DockBadge.followSession(session) }
        .onChange(of: session.items.map(\.id)) { _, ids in
            if let selectedItemID, !ids.contains(selectedItemID) {
                self.selectedItemID = nil
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
                                    restoreFile: { fileID in
                                        session.setFileSelected(itemID: item.id, fileID: fileID, isSelected: true)
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
