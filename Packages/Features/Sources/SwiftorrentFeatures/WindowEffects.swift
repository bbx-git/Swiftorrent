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

/// Tracks currently-open add-torrent dialog windows and re-orders them above
/// the main window whenever the main window becomes key. Works around an
/// AppKit multi-window quirk: opening (or closing) one of our windows can
/// bring the app's main window forward as part of a group-activation step,
/// silently dropping any *other* already-open dialog window behind it even
/// though nothing asked for that — the dialog isn't gone, it's just stuck
/// behind the main window (confirmed via `CGWindowList` front-to-back order:
/// [newest dialog, main window, older dialog] instead of both dialogs above
/// the main window). `orderFront` only changes on-screen stacking, not
/// keyboard focus, so this doesn't steal focus from whatever the user is
/// actually interacting with.
@MainActor
final class DialogWindowCoordinator {
    static let shared = DialogWindowCoordinator()
    private var dialogWindows: [ObjectIdentifier: NSWindow] = [:]

    private init() {}

    func register(_ window: NSWindow) {
        dialogWindows[ObjectIdentifier(window)] = window
    }

    func unregister(_ window: NSWindow) {
        dialogWindows[ObjectIdentifier(window)] = nil
    }

    func bringDialogsAboveMainWindow() {
        for window in dialogWindows.values {
            window.orderFront(nil)
        }
    }
}

/// Registers the hosting window with `DialogWindowCoordinator` so it gets
/// kept above the main window, unregistering when the view goes away.
private struct DialogWindowRegistrar: NSViewRepresentable {
    final class Coordinator {
        weak var window: NSWindow?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            context.coordinator.window = window
            DialogWindowCoordinator.shared.register(window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let window = coordinator.window {
            DialogWindowCoordinator.shared.unregister(window)
        }
    }
}

/// Observes the hosting window becoming key and re-asserts every registered
/// dialog window above it when that happens.
private struct DialogsStayAboveConfigurator: NSViewRepresentable {
    final class Coordinator {
        var observer: NSObjectProtocol?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            context.coordinator.observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    DialogWindowCoordinator.shared.bringDialogsAboveMainWindow()
                }
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let observer = coordinator.observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

extension View {
    /// Marks this view's hosting window as a dialog that should stay above
    /// the main window. Apply to every add-torrent window's content.
    func registersAsDialogWindow() -> some View {
        background(DialogWindowRegistrar())
    }

    /// Marks this view's hosting window as the main window: whenever it
    /// becomes key, every registered dialog window is brought back above it.
    /// Apply once, to the main window's content.
    func keepsDialogsAboveWhenActivated() -> some View {
        background(DialogsStayAboveConfigurator())
    }
}
