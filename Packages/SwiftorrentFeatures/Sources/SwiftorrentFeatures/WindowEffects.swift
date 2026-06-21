import AppKit
import SwiftUI

/// A behind-window vibrant material used as the app's translucent background.
/// Because `behindWindow` blending blurs whatever sits behind the window, the
/// material picks up the desktop and automatically tracks the system Liquid
/// Glass opacity slider (and the Reduce Transparency accessibility setting).
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .active
    }
}

/// Makes the hosting window non-opaque with a clear background so the
/// behind-window materials can show the (blurred) desktop through the app, and
/// strips the title bar chrome/title text so no "Swiftorrent" bar is drawn.
private struct TransparentWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension View {
    /// Installs the transparent-window configuration via a zero-size background
    /// view that reaches up to the hosting `NSWindow`.
    func transparentWindow() -> some View {
        background(TransparentWindowConfigurator())
    }
}
