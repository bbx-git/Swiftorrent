import Foundation
@testable import SwiftorrentCore
import Synchronization
import Testing

/// Opens after `opensAfter`, never when nil, or fails when `fails` is set.
private final class FakeTransport: PeerTransport {
    let opensAfter: Duration?
    let fails: Bool
    let closed = Mutex(false)

    init(opensAfter: Duration?, fails: Bool = false) {
        self.opensAfter = opensAfter
        self.fails = fails
    }

    func open() async throws {
        if fails { throw PeerWireError.connectionFailed }
        try await Task.sleep(for: opensAfter ?? .seconds(3_600))
    }

    func send(_ data: Data) async throws {}
    func receive() async throws -> Data { Data() }
    func close() { closed.withLock { $0 = true } }
}

@Suite("TCP/uTP connect race")
struct TransportRaceTests {
    @Test("a peer that answers only uTP connects soon after the head start, not after the TCP timeout")
    func fallbackWinsWhenPrimaryHangs() async throws {
        let tcp = FakeTransport(opensAfter: nil)
        let utp = FakeTransport(opensAfter: .zero)
        let start = ContinuousClock.now
        let opened = try await openFirst(primary: tcp, fallback: { utp }, fallbackDelay: .milliseconds(100))
        #expect(opened.isFallback)
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(tcp.closed.withLock { $0 })
    }

    @Test("a fast TCP peer never opens uTP")
    func primaryWinsWhenFast() async throws {
        let tcp = FakeTransport(opensAfter: .milliseconds(10))
        let made = Mutex(false)
        let opened = try await openFirst(primary: tcp, fallback: {
            made.withLock { $0 = true }
            return FakeTransport(opensAfter: .zero)
        }, fallbackDelay: .seconds(1))
        #expect(!opened.isFallback)
        #expect(!made.withLock { $0 })
    }

    @Test("a refused TCP connect starts uTP at once")
    func primaryFailureStartsFallbackEarly() async throws {
        let start = ContinuousClock.now
        let opened = try await openFirst(primary: FakeTransport(opensAfter: nil, fails: true), fallback: { FakeTransport(opensAfter: .zero) }, fallbackDelay: .seconds(30))
        #expect(opened.isFallback)
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test("fails when neither transport connects")
    func bothFail() async {
        await #expect(throws: PeerWireError.self) {
            _ = try await openFirst(primary: FakeTransport(opensAfter: nil, fails: true), fallback: { FakeTransport(opensAfter: nil, fails: true) }, fallbackDelay: .zero)
        }
    }
}
