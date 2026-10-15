import Foundation

/// A trailing window of (time, cumulative bytes) samples. The rate is the byte
/// delta across the window divided by its *actual* elapsed time, which smooths
/// the lumpiness of one-second ticks without assuming an exact tick length.
struct SpeedWindow {
    private var samples: [(time: ContinuousClock.Instant, bytes: Int64)] = []
    /// Roughly four seconds of one-second ticks.
    private let capacity = 4

    /// Records a sample and returns the rate in bytes per second (never negative).
    mutating func add(bytes: Int64, at time: ContinuousClock.Instant) -> Int64 {
        samples.append((time, bytes))
        if samples.count > capacity + 1 { samples.removeFirst() }
        guard let oldest = samples.first else { return 0 }
        let span = oldest.time.duration(to: time)
        let seconds = Double(span.components.seconds) + Double(span.components.attoseconds) / 1e18
        let delta = max(0, bytes - oldest.bytes)
        return seconds > 0 ? Int64(Double(delta) / seconds) : 0
    }
}
