import Foundation
@testable import SwiftorrentCore
import Testing

private actor QueryLog {
    private(set) var order: [String] = []
    private(set) var events: [String] = []
    private(set) var inFlight = 0
    private(set) var peak = 0

    func begin(_ host: String) {
        order.append(host)
        events.append("start:\(host)")
        inFlight += 1
        peak = max(peak, inFlight)
    }

    func end(_ host: String) {
        events.append("end:\(host)")
        inFlight -= 1
    }
}

private func node(_ host: String, firstIDByte: UInt8) -> DHTNodeEndpoint {
    DHTNodeEndpoint(host: host, port: 6881, id: Data([firstIDByte]) + Data(repeating: 0, count: 19))
}

@Suite struct DHTLookupTests {
    @Test func queriesNodesClosestToInfoHashFirst() async throws {
        let infoHash = Data([0xF0]) + Data(repeating: 0, count: 19)
        let log = QueryLog()
        let bootstrap = DHTNodeEndpoint(host: "boot", port: 6881)
        let client = DHTClient(bootstrapNodes: [bootstrap], queryLimit: 10, parallelQueries: 1) { endpoint, _, _ in
            await log.begin(endpoint.host)
            defer { Task { await log.end(endpoint.host) } }
            if endpoint.host == "boot" {
                // Far node listed first, near node last: order must follow distance.
                return DHTGetPeersResponse(peers: [], nodes: [
                    node("far", firstIDByte: 0x0F),
                    node("mid", firstIDByte: 0x80),
                    node("near", firstIDByte: 0xF1)
                ])
            }
            return DHTGetPeersResponse(peers: [], nodes: [])
        }

        _ = try? await client.peers(for: infoHash)

        #expect(await Array(log.order.prefix(4)) == ["boot", "near", "mid", "far"])
    }

    @Test func slowQueryDoesNotBlockNextOnes() async throws {
        let infoHash = Data(repeating: 1, count: 20)
        let bootstrap = (0..<3).map { DHTNodeEndpoint(host: "b\($0)", port: 6881) }
        let log = QueryLog()
        let client = DHTClient(bootstrapNodes: bootstrap, queryLimit: 10, parallelQueries: 2) { endpoint, _, _ in
            await log.begin(endpoint.host)
            defer { Task { await log.end(endpoint.host) } }
            if endpoint.host == "b0" {
                try await Task.sleep(for: .seconds(2))
                return DHTGetPeersResponse(peers: [], nodes: [])
            }
            return DHTGetPeersResponse(peers: [PeerEndpoint(host: "1.1.1.\(endpoint.host.last!)", port: 1)], nodes: [])
        }

        let peers = try await client.peers(for: infoHash)
        #expect(peers.count == 2)

        #expect(await log.order.count == 3)
        #expect(await log.peak <= 2)
        // b2 starts as soon as b1 finishes, not after the 2 s query of b0.
        let events = await log.events
        let b2Start = try #require(events.firstIndex(of: "start:b2"))
        let b0End = try #require(events.firstIndex(of: "end:b0"))
        #expect(b2Start < b0End)
    }

    @Test func retriesBootstrapWhenNoNodeAnswered() async throws {
        struct Silent: Error {}
        let calls = QueryLog()
        let client = DHTClient(
            bootstrapNodes: [DHTNodeEndpoint(host: "boot", port: 6881)],
            queryLimit: 10,
            parallelQueries: 1
        ) { _, _, _ in
            await calls.begin("boot")
            await calls.end("boot")
            if await calls.order.count == 1 { throw Silent() }
            return DHTGetPeersResponse(peers: [PeerEndpoint(host: "2.2.2.2", port: 2)], nodes: [])
        }

        let peers = try await client.peers(for: Data(repeating: 3, count: 20))

        #expect(peers == [PeerEndpoint(host: "2.2.2.2", port: 2)])
    }
}
