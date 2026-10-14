@testable import SwiftorrentFeatures
import Foundation
import Testing

@Suite("Dock badge")
@MainActor
struct DockBadgeTests {
    @Test("No badge when nothing is downloading")
    func zeroSpeedHasNoBadge() {
        #expect(DockBadge.label(forSpeed: 0) == nil)
    }

    @Test("Badge uses the same text as the window's Speed metric")
    func badgeMatchesWindowSpeedText() {
        let speed: Int64 = 4_200_000
        let expected = ByteCountFormatter.string(fromByteCount: speed, countStyle: .file) + "/s"
        #expect(DockBadge.label(forSpeed: speed) == expected)
    }
}
