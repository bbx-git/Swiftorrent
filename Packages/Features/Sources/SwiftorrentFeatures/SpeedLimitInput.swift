import Foundation

/// Turns the text typed in the custom speed-limit popover into bytes per second.
enum SpeedLimitInput {
    /// Largest accepted limit: 1 TB/s, far above any real link.
    static let maximumBytesPerSecond = 1_000_000_000_000.0

    /// Decimal (1000-based) to match the `.file` ByteCountFormatter display.
    /// Accepts a comma or dot decimal. Returns `nil` unless the result is a
    /// finite whole number of at least 1 byte/s and at most 1 TB/s.
    static func bytesPerSecond(from text: String, kilobytes: Bool) -> Int? {
        let normalized = text
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        guard let value = Double(normalized) else { return nil }
        let bytes = value * (kilobytes ? 1_000 : 1_000_000)
        guard bytes.isFinite, bytes >= 1, bytes <= maximumBytesPerSecond else { return nil }
        return Int(bytes)
    }
}
