import Foundation
@testable import SwiftorrentDomain
import Testing

@Suite("Speed window")
struct SpeedWindowTests {
    @Test("Rate is the byte delta over the window's actual elapsed time")
    func rateOverWindow() {
        var window = SpeedWindow()
        let start = ContinuousClock.now
        #expect(window.add(bytes: 0, at: start) == 0)
        #expect(window.add(bytes: 1_000, at: start + .seconds(1)) == 1_000)
        #expect(window.add(bytes: 3_000, at: start + .seconds(2)) == 1_500)
    }

    @Test("Only the last four samples count, so a stall decays")
    func stallDecays() {
        var window = SpeedWindow()
        let start = ContinuousClock.now
        _ = window.add(bytes: 0, at: start)
        _ = window.add(bytes: 4_000, at: start + .seconds(1))
        for second in 2...5 { _ = window.add(bytes: 4_000, at: start + .seconds(second)) }
        #expect(window.add(bytes: 4_000, at: start + .seconds(6)) == 0)
    }

    @Test("A drop in bytes never reports a negative rate")
    func neverNegative() {
        var window = SpeedWindow()
        let start = ContinuousClock.now
        _ = window.add(bytes: 5_000, at: start)
        #expect(window.add(bytes: 1_000, at: start + .seconds(1)) == 0)
    }
}
