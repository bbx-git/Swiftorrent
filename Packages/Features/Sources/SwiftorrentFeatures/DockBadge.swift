import AppKit
import SwiftUI
import SwiftorrentDomain

/// The Dock icon's badge text: the combined download speed, formatted exactly
/// like the window's Speed metric, or no badge at all when nothing is moving.
enum DockBadge {
    static func label(forSpeed bytesPerSecond: Int64) -> String? {
        guard bytesPerSecond > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytesPerSecond, countStyle: .file) + "/s"
    }
}

private struct DockBadgeModifier: ViewModifier {
    @Environment(TorrentSession.self) private var session

    func body(content: Content) -> some View {
        content
            .onChange(of: DockBadge.label(forSpeed: session.downloadSpeed), initial: true) { _, label in
                NSApp.dockTile.badgeLabel = label
            }
    }
}

extension View {
    /// Mirrors the session's download speed onto the Dock icon badge.
    func showsSpeedInDockBadge() -> some View {
        modifier(DockBadgeModifier())
    }
}
