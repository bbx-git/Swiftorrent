import Darwin
import Foundation
import Testing
@testable import SwiftorrentCore

private let sanitizerLoaded = ["__tsan_init", "__asan_init"].contains { (symbol: String) in
    dlsym(UnsafeMutableRawPointer(bitPattern: -2), symbol) != nil
}

@Suite struct DeadlineTests {
    private struct Expired: Error {}

    @Test func returnsTheOperationsResult() async throws {
        let value = try await withDeadline(.seconds(5), timeoutError: Expired()) { 42 }
        #expect(value == 42)
    }

    @Test func throwsTheTimeoutErrorAndCancelsTheOperation() async throws {
        let start = ContinuousClock.now
        await #expect(throws: Expired.self) {
            try await withDeadline(.milliseconds(50), timeoutError: Expired()) {
                try await Task.sleep(for: .seconds(10))
            }
        }
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func propagatesTheOperationsOwnError() async throws {
        await #expect(throws: CancellationError.self) {
            try await withDeadline(.seconds(5), timeoutError: Expired()) { throw CancellationError() }
        }
    }

    /// Every peer socket read runs under a deadline. Racing a `Task.sleep` kept each
    /// cancelled timer and its task alive until the original deadline (~700 B per
    /// read for 30 s), which grew a fast download by hundreds of MB. The footprint
    /// is process-wide and other suites run in parallel (tens of MB of noise), so
    /// the loop is sized for the old behaviour to leave ~200 MB behind.
    @Test(.disabled(if: sanitizerLoaded, "sanitizers keep shadow memory per allocation"))
    func finishedDeadlinesReleaseTheirTimers() async throws {
        let before = physicalFootprint()
        for _ in 0..<300_000 {
            _ = try await withDeadline(.seconds(60), timeoutError: Expired()) { 1 }
        }
        let grown = physicalFootprint() - before
        #expect(grown < 128 << 20, "grew \(grown >> 20) MB")
    }

    private func physicalFootprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }
}
