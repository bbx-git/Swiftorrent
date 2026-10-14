import AppKit
import Observation
import SwiftUI
import SwiftorrentDomain

/// The Dock icon's badge text: the combined download speed, formatted exactly
/// like the window's Speed metric, or no badge at all when nothing is moving.
enum DockBadge {
    static func label(forSpeed bytesPerSecond: Int64) -> String? {
        guard bytesPerSecond > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytesPerSecond, countStyle: .file) + "/s"
    }

    /// Calls `show` with the current label now and again after every change of
    /// whatever `speed` reads. It re-arms itself, so it needs no view and keeps
    /// running when the main window is closed.
    @MainActor
    static func follow(speed: @escaping @MainActor () -> Int64, show: @escaping @MainActor (String?) -> Void) {
        let label = withObservationTracking {
            label(forSpeed: speed())
        } onChange: {
            Task { @MainActor in follow(speed: speed, show: show) }
        }
        show(label)
    }

    private static var isFollowingSession = false

    /// Starts mirroring the session's speed onto the Dock tile; later calls do nothing.
    @MainActor
    static func followSession(_ session: TorrentSession) {
        guard !isFollowingSession else { return }
        isFollowingSession = true
        follow(speed: { session.downloadSpeed }, show: DockTile.show)
    }
}

/// Draws the Dock icon with a badge of constant size. The system badge
/// (`badgeLabel`) resizes with its text, which jumps around as the speed
/// changes, so while a speed is shown the tile is drawn by hand instead.
@MainActor
private enum DockTile {
    @Observable
    final class Model {
        var label = ""
    }

    private static let model = Model()
    private static var hostingView: NSHostingView<DockTileView>?

    static func show(_ label: String?) {
        let tile = NSApp.dockTile
        guard let label else {
            guard tile.contentView != nil else { return }
            tile.contentView = nil
            tile.display()
            return
        }
        model.label = label
        if tile.contentView == nil {
            let view = hostingView ?? NSHostingView(rootView: DockTileView(model: model))
            hostingView = view
            view.frame = NSRect(origin: .zero, size: tile.size)
            tile.contentView = view
        }
        tile.display()
    }
}

private struct DockTileView: View {
    let model: DockTile.Model

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack(alignment: .top) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                // Fixed font size and box for every value, so nothing jumps.
                Text(model.label)
                    .font(.system(size: side * 0.15, weight: .semibold, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .foregroundStyle(.white)
                    .frame(width: side * 0.92, height: side * 0.26)
                    .background(Capsule().fill(.red))
                    .padding(.top, side * 0.04)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}
