import Darwin
import Testing
@testable import SwiftorrentCore

@Suite struct FileDescriptorLimitTests {
    @Test func raisesSoftLimitFromGUIDefaultToTarget() {
        // A Finder-launched app starts with a soft limit of 256.
        var original = rlimit()
        getrlimit(RLIMIT_NOFILE, &original)
        defer { setrlimit(RLIMIT_NOFILE, &original) }

        var low = original
        low.rlim_cur = 256
        #expect(setrlimit(RLIMIT_NOFILE, &low) == 0)

        let applied = FileDescriptorLimit.raise(to: 4096)

        var now = rlimit()
        getrlimit(RLIMIT_NOFILE, &now)
        #expect(applied >= 4096)
        #expect(now.rlim_cur >= 4096)
    }

    @Test func neverLowersAnAlreadyHigherLimit() {
        var original = rlimit()
        getrlimit(RLIMIT_NOFILE, &original)
        defer { setrlimit(RLIMIT_NOFILE, &original) }

        let before = original.rlim_cur
        _ = FileDescriptorLimit.raise(to: 512)
        var now = rlimit()
        getrlimit(RLIMIT_NOFILE, &now)
        #expect(now.rlim_cur >= min(before, original.rlim_max))
    }
}
