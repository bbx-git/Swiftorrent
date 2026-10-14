import Foundation

/// A shared token-bucket limiter for download byte throughput. A `nil` limit
/// means unlimited and `consume` returns immediately.
///
/// Limiting is applied *after* bytes are read: a caller reports the bytes it
/// just received, charging them against the budget, and the limiter sleeps long
/// enough to keep the running average at or below the configured rate.
///
/// The budget is allowed to go into *debt* (negative) and the charge happens in
/// the actor's synchronous region before any sleep. That is what makes a shared
/// limiter cap the *combined* rate of N concurrent streams rather than letting
/// each run at the full cap: every later `consume` sees the deeper deficit left
/// by the others and waits proportionally longer, so the charges serialize even
/// though the sleeps overlap.
public actor RateLimiter {
    /// The cap in bytes per second, or `nil` for unlimited.
    private var bytesPerSecond: Int?
    /// Current budget, in bytes. Positive means spare capacity (capped at one
    /// second's worth so an idle period can't bank a large burst); negative means
    /// outstanding debt that pending consumers are sleeping off.
    private var tokens: Double
    private let clock = ContinuousClock()
    private var lastRefill: ContinuousClock.Instant

    public init(bytesPerSecond: Int? = nil) {
        self.bytesPerSecond = bytesPerSecond.map { max(0, $0) }
        // Start empty so the first reads are paced immediately rather than
        // delivering a free first-second burst at twice the cap.
        self.tokens = 0
        self.lastRefill = ContinuousClock().now
    }

    /// Updates the cap at runtime. A `nil` (or non-positive) limit disables
    /// throttling. Switching to a tighter limit drops any banked surplus so the
    /// new rate takes effect immediately.
    public func setLimit(bytesPerSecond: Int?) {
        let normalized = bytesPerSecond.map { max(0, $0) }
        self.bytesPerSecond = normalized
        if let rate = normalized {
            tokens = min(tokens, Double(rate))
        }
        lastRefill = clock.now
    }

    /// Charges `bytes` against the budget, awaiting if necessary to stay under
    /// the cap. Returns immediately when unlimited. The charge drives the budget
    /// negative when over capacity; the caller then sleeps off the resulting
    /// deficit. Because the charge happens before the sleep, concurrent callers
    /// stack their debt and wait in series, so a large piece or several parallel
    /// streams are paced to the shared cap rather than each to the full cap.
    public func consume(_ bytes: Int) async {
        guard bytes > 0, let rate = bytesPerSecond, rate > 0 else { return }
        refill(rate: rate)
        tokens -= Double(bytes)
        if tokens < 0 {
            let waitSeconds = -tokens / Double(rate)
            try? await Task.sleep(for: .seconds(waitSeconds))
        }
    }

    private func refill(rate: Int) {
        let now = clock.now
        let elapsed = lastRefill.duration(to: now)
        lastRefill = now
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        tokens = min(Double(rate), tokens + seconds * Double(rate))
    }
}
