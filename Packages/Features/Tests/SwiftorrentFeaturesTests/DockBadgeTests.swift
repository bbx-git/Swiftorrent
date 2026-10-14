@testable import SwiftorrentFeatures
import Foundation
import Observation
import Testing

@Observable
final class SpeedSource {
    var speed: Int64 = 0
}

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

    @Test("Badge keeps following the speed with no view alive")
    func followUpdatesWithoutAnyView() async {
        let source = SpeedSource()
        var shown: [String?] = []
        DockBadge.follow(speed: { source.speed }, show: { shown.append($0) })
        #expect(shown == [nil])

        source.speed = 1_000_000
        await Task.yield()
        #expect(shown.last == DockBadge.label(forSpeed: 1_000_000))

        source.speed = 0
        await Task.yield()
        #expect(shown.last! == nil)
    }
}
