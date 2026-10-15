import Foundation
import Testing
@testable import SwiftorrentCore

@Suite struct PatientResolveTests {
    /// No tracker answers and the DHT has no nodes: the resolver used to give up
    /// within a second with "no peers". Like other clients it must keep looking
    /// until the user cancels.
    @Test func keepsLookingForPeersUntilCancelled() async throws {
        let magnet = MagnetLink(
            infoHash: Data(repeating: 0xAB, count: 20),
            displayName: "nothing",
            trackers: []
        )
        let resolver = MagnetMetadataResolver(dhtClient: DHTClient(bootstrapNodes: []))
        let statuses = StatusLog()
        let task = Task {
            defer { Task { await statuses.markDone() } }
            return try await resolver.resolve(magnet: magnet) { await statuses.add($0.status) }
        }

        try await Task.sleep(for: .seconds(4))
        #expect(!(await statuses.done))
        let sawRetry = await statuses.all.contains { $0.localizedCaseInsensitiveContains("retrying") }
        #expect(sawRetry)

        task.cancel()
        let outcome = await Task { await task.result }.value
        guard case let .failure(error) = outcome else {
            Issue.record("resolve returned metadata for a magnet nobody serves")
            return
        }
        #expect(error is CancellationError)
    }
}

private actor StatusLog {
    var all: [String] = []
    var done = false
    func markDone() { done = true }
    func add(_ status: String) { all.append(status) }
}
