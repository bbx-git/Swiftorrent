@testable import SwiftorrentFeatures
import Testing

@Suite("Speed limit input")
@MainActor
struct SpeedLimitInputTests {
    @Test("parses KB/s and MB/s with decimal 1000-based units")
    func parsesValues() {
        #expect(SpeedLimitInput.bytesPerSecond(from: "50", kilobytes: true) == 50_000)
        #expect(SpeedLimitInput.bytesPerSecond(from: "2.5", kilobytes: false) == 2_500_000)
    }

    @Test("accepts a comma decimal and surrounding spaces")
    func commaDecimal() {
        #expect(SpeedLimitInput.bytesPerSecond(from: " 1,5 ", kilobytes: false) == 1_500_000)
    }

    @Test("rejects non-finite, non-positive and non-numeric text")
    func rejectsInvalid() {
        for text in ["inf", "-inf", "nan", "0", "-3", "", "abc"] {
            #expect(SpeedLimitInput.bytesPerSecond(from: text, kilobytes: false) == nil, "\(text)")
        }
    }

    @Test("rejects values that round below one byte per second")
    func rejectsSubByte() {
        #expect(SpeedLimitInput.bytesPerSecond(from: "0.0001", kilobytes: true) == nil)
    }

    @Test("rejects values too large to be a real limit instead of trapping")
    func rejectsHuge() {
        #expect(SpeedLimitInput.bytesPerSecond(from: "1e30", kilobytes: false) == nil)
        #expect(SpeedLimitInput.bytesPerSecond(from: "9999999999", kilobytes: false) == nil)
    }
}
