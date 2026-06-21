import SwiftUI
import SwiftorrentFeatures

@main
struct SwiftorrentApp: App {
    var body: some Scene {
        WindowGroup {
            SwiftorrentRootView()
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
