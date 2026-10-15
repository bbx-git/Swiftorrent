import Foundation

/// A process-wide cap on concurrently open peer connections, so many torrents
/// (each wanting up to 100 peers) plus freshly added magnets share the socket and
/// descriptor budget instead of racing each other into failures. Waiters are served
/// in arrival order, so a worker that releases and re-acquires goes to the back of
/// the line and busy torrents interleave fairly.
///
/// Swarm downloads and magnet resolve probes draw on separate budgets: a client
/// full of downloading torrents must never keep a newly added magnet from probing.
final class ConnectionBudget: @unchecked Sendable {
    /// Peer connections across all running swarm downloads.
    static let swarm = ConnectionBudget(limit: 300)
    /// Metadata probes across all magnets being resolved.
    static let resolve = ConnectionBudget(limit: 128)

    private let limit: Int
    private let lock = NSLock()
    private var held = 0
    private var queue: [UInt64] = []
    private var nextTicket: UInt64 = 0

    init(limit: Int) {
        self.limit = limit
    }

    var inUse: Int { lock.withLock { held } }
    var waiting: Int { lock.withLock { queue.count } }

    /// Waits for a free slot. Throws `CancellationError` (holding nothing) if the
    /// caller is cancelled while waiting; otherwise the caller must `release()`.
    func acquire() async throws {
        let ticket: UInt64 = lock.withLock {
            defer { nextTicket += 1 }
            queue.append(nextTicket)
            return nextTicket
        }
        while true {
            let granted: Bool = lock.withLock {
                guard queue.first == ticket, held < limit else { return false }
                queue.removeFirst()
                held += 1
                return true
            }
            if granted { return }
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                lock.withLock { queue.removeAll { $0 == ticket } }
                throw error
            }
        }
    }

    func release() {
        lock.withLock { held = max(0, held - 1) }
    }

    /// Runs `body` holding one slot, releasing it however `body` exits.
    func withSlot<T>(_ body: () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        return try await body()
    }
}
