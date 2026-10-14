import Foundation
import Network
@testable import SwiftorrentCore
import Synchronization
import Testing

@Suite("Choked peer timeout")
struct ChokedPeerTimeoutTests {
    /// A seed that declares piece 0, never unchokes, and sends a `have` every 50 ms,
    /// so no read ever sits idle. Returns a connected, availability-read client.
    private func connectedClientToChattyChokedSeed(
        listener: NWListener,
        holder: AcceptedConnections
    ) async throws -> PeerWireClient {
        let infoHash = Data(repeating: 0x55, count: 20)
        let seed = RespondingSeed(
            infoHash: infoHash,
            pieces: [Data(repeating: 0, count: 10)],
            postHandshake: wireFrame(5, Data([0x80])),
            respondToRequests: false,
            haveEvery: 0.05
        )
        listener.newConnectionHandler = { connection in
            holder.add(connection)
            seed.handle(connection)
        }
        let port = try await startLoopbackListener(listener)
        let client = PeerWireClient(
            endpoint: PeerEndpoint(host: "127.0.0.1", port: port.rawValue),
            infoHash: infoHash,
            peerID: Data(repeating: 1, count: 20),
            connectTimeout: 2,
            ioTimeout: 5,
            snubTimeout: 5,
            idleTimeout: 5,
            encryptionPolicy: .plaintextOnly
        )
        try await client.connect()
        _ = try await client.readInitialAvailability(pieceCount: 1)
        return client
    }

    private func drain(_ client: PeerWireClient, chokeTimeout: TimeInterval, hasUntriedPeers: @escaping @Sendable () async -> Bool) async throws {
        let claimer = SequentialClaimer(total: 1)
        try await client.downloadPieces(
            blockSize: 4,
            pieceLength: { _ in 10 },
            expectedHash: { _ in Data(repeating: 0, count: 20) },
            claimNextPiece: { _, _, _ in await claimer.claim() },
            onPieceComplete: { _, _ in },
            onReturnPiece: { _ in },
            chokeTimeout: chokeTimeout,
            hasUntriedPeers: hasUntriedPeers
        )
    }

    @Test("a peer that stays choked while sending HAVEs is dropped when untried peers wait")
    func dropsChattyChokedPeerWhenReserveHasPeers() async throws {
        let holder = AcceptedConnections()
        let listener = try NWListener(using: .tcp)
        let client = try await connectedClientToChattyChokedSeed(listener: listener, holder: holder)
        defer { listener.cancel(); holder.cancelAll() }

        let start = ContinuousClock.now
        var thrown: Error?
        do {
            try await drain(client, chokeTimeout: 0.5) { true }
        } catch {
            thrown = error
        }
        await client.close()

        if let peerError = thrown as? PeerWireError, case .timedOut = peerError {} else {
            Issue.record("Expected PeerWireError.timedOut, got \(String(describing: thrown))")
        }
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test("the same peer is kept while the reserve is empty, and dropped once it is not")
    func keepsChokedPeerUntilReserveHasPeers() async throws {
        let holder = AcceptedConnections()
        let listener = try NWListener(using: .tcp)
        let client = try await connectedClientToChattyChokedSeed(listener: listener, holder: holder)
        defer { listener.cancel(); holder.cancelAll() }

        let reserveHasPeers = Mutex(false)
        let ended = Mutex<Error?>(nil)
        let finished = Mutex(false)
        let task = Task {
            do {
                try await drain(client, chokeTimeout: 0.3) { reserveHasPeers.withLock { $0 } }
            } catch {
                ended.withLock { $0 = error }
            }
            finished.withLock { $0 = true }
        }

        // Well past the choke timeout, with an empty reserve: still connected.
        try await Task.sleep(for: .seconds(1.2))
        #expect(!finished.withLock { $0 })

        reserveHasPeers.withLock { $0 = true }
        let start = ContinuousClock.now
        while !finished.withLock({ $0 }), ContinuousClock.now - start < .seconds(3) {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(finished.withLock { $0 })
        if let peerError = ended.withLock({ $0 }) as? PeerWireError, case .timedOut = peerError {} else {
            Issue.record("Expected PeerWireError.timedOut, got \(String(describing: ended.withLock { $0 }))")
        }
        task.cancel()
        await client.close()
    }
}
