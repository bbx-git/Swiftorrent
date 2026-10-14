import SwiftUI

/// Header control for the global download-speed cap: a menu of presets plus a
/// "Custom…" popover where the user types an exact value in KB/s or MB/s. The
/// limit is bytes per second; `nil` means unlimited.
struct SpeedLimitControl: View {
    @Binding var limit: Int?

    @State private var showingCustom = false
    @State private var customValue = ""
    @State private var customUnit: SpeedUnit = .megabytes

    private enum SpeedUnit: String, CaseIterable, Identifiable {
        case kilobytes, megabytes
        var id: String { rawValue }
        var label: String { self == .kilobytes ? "KB/s" : "MB/s" }
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
        SpeedLimitInput.bytesPerSecond(from: customValue, kilobytes: customUnit == .kilobytes)
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
