import SwiftUI
import SwiftorrentDomain

/// One independent, real window per torrent still being added: resolving
/// metadata, awaiting file selection, or reporting a resolve failure. Backed by
/// `TorrentSession.pendingItems`, which already supports any number of
/// concurrent in-flight adds — this view is what lets several of them be open
/// and reviewable at once instead of serialized behind a single sheet.
public struct AddTorrentWindow: View {
    let itemID: TorrentItem.ID

    @Environment(TorrentSession.self) private var session
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var createSubfolder = true

    public init(itemID: TorrentItem.ID) {
        self.itemID = itemID
    }

    private var item: TorrentItem? {
        session.pendingItems.first(where: { $0.id == itemID })
    }

    public var body: some View {
        if let item {
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
                    reviewBody(item)
                case .failed:
                    failureBody(item)
                default:
                    resolvingBody(item)
                }
            }
            .padding(24)
            .frame(width: 520)
            .navigationTitle(item.name)
            .registersAsDialogWindow()
            // Catches every dismissal path that isn't the explicit Cancel/Download
            // buttons below (titlebar close, ⌘W). This also fires when Download
            // moves the item out of `pendingItems`; `cancelPending` ignores
            // non-pending items, so the just-launched download is untouched.
            .onDisappear {
                session.cancelPending(itemID: itemID)
            }
        } else {
            // `itemID` no longer matches anything in `pendingItems` (already
            // cancelled/downloaded elsewhere). Rather than leave a blank window
            // sitting on screen, close it immediately.
            SelfDismissingEmptyWindow()
        }
    }

    @ViewBuilder private func reviewBody(_ item: TorrentItem) -> some View {
        let selectedCount = item.files.filter(\.isSelected).count
        let selectedBytes = item.files.filter(\.isSelected).reduce(Int64(0)) { $0 + $1.totalBytes }
        let selectedBytesDescription = ByteCountFormatter.string(fromByteCount: selectedBytes, countStyle: .file)

        HStack {
            Text("\(selectedCount) of \(item.files.count) files · \(selectedBytesDescription)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Select All") { session.setAllFilesSelected(itemID: itemID, isSelected: true) }
                .buttonStyle(.link)
            Button("Deselect All") { session.setAllFilesSelected(itemID: itemID, isSelected: false) }
                .buttonStyle(.link)
        }

        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(item.files) { file in
                    HStack(spacing: 10) {
                        Toggle(isOn: Binding(
                            get: { file.isSelected },
                            set: { session.setFileSelected(itemID: itemID, fileID: file.id, isSelected: $0) }
                        )) {
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
            Button("Cancel", role: .cancel) {
                session.cancelPending(itemID: itemID)
                dismissWindow()
            }
            .keyboardShortcut(.cancelAction)
            .buttonStyle(.bordered)
            .tint(.primary)
            Spacer()
            Button("Download") {
                session.startDownload(itemID: itemID, createSubfolder: createSubfolder)
                dismissWindow()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .tint(.swiftorrentGraphite)
            .disabled(selectedCount == 0)
        }
    }

    @ViewBuilder private func resolvingBody(_ item: TorrentItem) -> some View {
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
            Button("Cancel", role: .cancel) {
                session.cancelPending(itemID: itemID)
                dismissWindow()
            }
            .keyboardShortcut(.cancelAction)
            .buttonStyle(.bordered)
            .tint(.primary)
        }
    }

    @ViewBuilder private func failureBody(_ item: TorrentItem) -> some View {
        Label(item.status, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 24)

        HStack {
            Spacer()
            Button("Close") {
                session.cancelPending(itemID: itemID)
                dismissWindow()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.bordered)
            .tint(.primary)
        }
    }
}

/// Closes its own window the instant it appears. Used for the add-torrent
/// `WindowGroup`'s no-value case: SwiftUI can open a blank instance of that
/// scene on its own (e.g. its default per-scene launch behavior at app start),
/// independent of any explicit `openWindow(value:)` call. Since that instance
/// has nothing to show by construction, self-closing beats leaving a mystery
/// empty window on screen.
public struct SelfDismissingEmptyWindow: View {
    @Environment(\.dismissWindow) private var dismissWindow

    public init() {}

    public var body: some View {
        Color.clear
            .onAppear { dismissWindow() }
    }
}
