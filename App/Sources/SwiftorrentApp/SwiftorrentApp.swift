import SwiftUI
import SwiftorrentFeatures

@main
struct SwiftorrentApp: App {
    var body: some Scene {
        WindowGroup {
            SwiftorrentRootView()
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
