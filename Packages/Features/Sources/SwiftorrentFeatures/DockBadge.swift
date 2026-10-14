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
            ZStack(alignment: .bottom) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                // Fixed box for every value; long labels shrink to fit it.
                Text(model.label)
                    .font(.system(size: side * 0.2, weight: .semibold, design: .rounded).monospacedDigit())
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .foregroundStyle(.white)
                    .frame(width: side * 0.8, height: side * 0.3)
                    .background(Capsule().fill(.red))
                    .padding(.bottom, side * 0.04)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

private struct DockBadgeModifier: ViewModifier {
    @Environment(TorrentSession.self) private var session

    func body(content: Content) -> some View {
        content
            .onChange(of: DockBadge.label(forSpeed: session.downloadSpeed), initial: true) { _, label in
                DockTile.show(label)
            }
    }
}

extension View {
    /// Mirrors the session's download speed onto the Dock icon badge.
    func showsSpeedInDockBadge() -> some View {
        modifier(DockBadgeModifier())
    }
}
