import Darwin

/// A GUI app launched from Finder starts with a soft limit of 256 open files, which
/// a swarm of 100 peers (TCP and uTP sockets raced) plus a magnet resolve exceeds.
/// Every further socket then fails with "Too many open files" and the app looks
/// like it has no network.
public enum FileDescriptorLimit {
    /// Raises the soft `RLIMIT_NOFILE` to `target`, capped by the hard limit.
    /// Never lowers it. Returns the soft limit in effect afterwards.
    @discardableResult
    public static func raise(to target: Int = 10_240) -> Int {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return 256 }
        let cap = min(rlim_t(target), limit.rlim_max)
        if cap > limit.rlim_cur {
            var raised = limit
            raised.rlim_cur = cap
            if setrlimit(RLIMIT_NOFILE, &raised) == 0 { return Int(cap) }
        }
        return Int(limit.rlim_cur)
    }
}
