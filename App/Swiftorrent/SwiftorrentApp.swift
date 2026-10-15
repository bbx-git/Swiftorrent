import SwiftUI
import SwiftorrentCore
import SwiftorrentDomain
import SwiftorrentFeatures

/// Delays quit until running downloads have sent their final tracker announce
/// (each is capped at 3 s; the whole wait is capped at 5 s).
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var session: TorrentSession?

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let session else { return .terminateNow }
        // Unstructured on purpose: a task group would wait for a stuck stopAll.
        var replied = false
        let finish = { @MainActor in
            guard !replied else { return }
            replied = true
            sender.reply(toApplicationShouldTerminate: true)
        }
        Task { @MainActor in
            await session.stopAll()
            finish()
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            finish()
        }
        return .terminateLater
    }
}

@main
struct SwiftorrentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // Owned here (not in SwiftorrentRootView) and shared via `.environment` into
    // both scenes below, so the main window and every add-torrent window operate
    // on the same live session instead of each getting its own.
    @State private var session = TorrentSession()

    init() {
        FileDescriptorLimit.raise()
    }

    var body: some Scene {
        // A singleton window, not `WindowGroup`: this is a single-window utility
        // app (no per-torrent or per-document windows), and `WindowGroup` was
        // spawning a brand-new window with its own disconnected `TorrentSession`
        // every time the OS delivered an external open (e.g. clicking a magnet
        // link in a browser) while the app was already running — the fresh,
        // empty session made the new window look like a whole separate app
        // instance instead of receiving the link into the existing one. `Window`
        // has at most one instance, so the OS activates the existing window and
        // its existing `onOpenURL` handles the new link instead.
        Window("Swiftorrent", id: "main") {
            SwiftorrentRootView()
                .environment(session)
                .onAppear { appDelegate.session = session }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        // One real window per torrent still being added (resolving metadata or
        // awaiting file selection), value-parameterized by pending-item id so any
        // number can be open and stacked at once — unlike a single `.sheet`,
        // which can show only one at a time per window. Opened via
        // `openWindow(value:)` from `SwiftorrentRootView` whenever a new torrent
        // is added (magnet link, `.torrent` open, or the sidebar's Add Magnet).
        WindowGroup(id: "add-torrent", for: TorrentItem.ID.self) { $itemID in
            if let itemID {
                AddTorrentWindow(itemID: itemID)
                    .environment(session)
            } else {
                // SwiftUI opens one blank, itemID-less instance of this scene
                // automatically on every app launch (its default "auto-launch"
                // behavior for a WindowGroup, independent of `openWindow` and
                // not fully suppressed by `.defaultLaunchBehavior` below in
                // practice) — an empty floating window with nothing in it.
                // Since it has no item to show by definition, close it the
                // moment it appears rather than leaving a mystery blank window
                // on screen.
                SelfDismissingEmptyWindow()
            }
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}
