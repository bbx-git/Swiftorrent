import Foundation
@testable import SwiftorrentCore
import Testing

/// A seeded generator so every simulated network run is reproducible.
private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Two connection cores joined by a simulated datagram link with a virtual
/// clock: fixed latency plus jitter (which reorders), random loss and duplication.
/// Packets go through `encoded()`/`init(_:)` so the codec is exercised too.
private final class Link {
    let a: UTPConnectionCore
    var b: UTPConnectionCore?
    var now: UInt64 = 1_000
    var loss = 0.0
    var duplication = 0.0
    var jitter: UInt64 = 0
    var dropAll = false
    private let latency: UInt64 = 20_000
    private var rng = SplitMix(state: 42)
    private var queue: [(at: UInt64, toB: Bool, bytes: Data)] = []
    private let responderSequence: UInt16

    init(connectionID: UInt16 = 0x4242, responderSequence: UInt16 = 500) {
        a = UTPConnectionCore(connectionID: connectionID)
        self.responderSequence = responderSequence
    }

    func send(_ packets: [UTPPacket], toB: Bool) {
        for packet in packets {
            if dropAll || Double.random(in: 0..<1, using: &rng) < loss { continue }
            let extra = jitter == 0 ? 0 : UInt64.random(in: 0...jitter, using: &rng)
            queue.append((now + latency + extra, toB, packet.encoded()))
            if Double.random(in: 0..<1, using: &rng) < duplication {
                queue.append((now + latency + extra + 5_000, toB, packet.encoded()))
            }
        }
    }

    /// Advances to the next event (delivery or timer) and processes it.
    /// Returns `false` when nothing is left to happen.
    @discardableResult
    func step() -> Bool {
        let deadlines = [a.nextDeadline, b?.nextDeadline].compactMap { $0 }
        guard let next = (queue.map(\.at) + deadlines).min() else { return false }
        now = max(now, next)
        send(a.tick(now: now), toB: true)
        if let b { send(b.tick(now: now), toB: false) }

        while let index = queue.firstIndex(where: { $0.at <= now }) {
            let item = queue.remove(at: index)
            guard let packet = UTPPacket(item.bytes) else { continue }
            if item.toB {
                if b == nil, packet.kind == .syn {
                    let responder = UTPConnectionCore(accepting: packet, initialSequence: responderSequence)
                    b = responder
                    send(responder.acceptReply(now: now), toB: false)
                } else if let b {
                    send(b.receive(packet, now: now), toB: false)
                }
            } else {
                send(a.receive(packet, now: now), toB: true)
            }
        }
        return true
    }

    /// Runs until `done` or the virtual clock passes `limit` microseconds.
    @discardableResult
    func run(limit: UInt64 = 600_000_000, until done: () -> Bool) -> Bool {
        while !done() {
            if now > limit || !step() { return done() }
        }
        return true
    }

    func connect() {
        send(a.open(now: now), toB: true)
        run { a.isEstablished }
    }

    /// Has `b` write `payload` while `a` reads it all; returns what `a` received.
    func transferToA(_ payload: Data, readChunk: Int = 64 * 1024) -> Data {
        guard let b else { return Data() }
        send(b.write(payload, now: now), toB: false)
        var received = Data()
        run {
            let result = a.read(maxBytes: readChunk, now: now)
            received.append(result.data)
            send(result.packets, toB: true)
            return received.count >= payload.count
        }
        return received
    }
}

private func pattern(_ count: Int) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 8) })
}

@Suite struct UTPConnectionTests {
    @Test func handshakeEstablishesBothSides() {
        let link = Link()
        link.connect()
        #expect(link.a.state == .connected)
        #expect(link.b?.state == .connected)
    }

    @Test func transfersMegabyteIntact() {
        let link = Link()
        link.connect()
        let payload = pattern(1 << 20)
        #expect(link.transferToA(payload) == payload)
    }

    /// `Data.removeFirst` only moves `startIndex`, so a `Data` receive buffer kept
    /// every byte the peer ever sent (hundreds of MB on a long download).
    @Test func receiveBufferDoesNotKeepConsumedBytes() throws {
        let link = Link()
        link.connect()
        let payload = pattern(4 << 20)
        #expect(link.transferToA(payload) == payload)

        let inbound = Mirror(reflecting: link.a).descendant("inbound")
        let retained = try #require((inbound as? [UInt8])?.capacity ?? (inbound as? Data)?.endIndex)
        #expect(retained <= 2 * UTPConnectionCore.receiveBufferLimit, "array growth may round capacity up")
    }

    @Test func survivesLossReorderingAndDuplication() {
        let link = Link()
        link.loss = 0.10
        link.duplication = 0.05
        link.jitter = 60_000
        link.connect()
        let payload = pattern(2 << 20)
        #expect(link.transferToA(payload) == payload)
    }

    @Test func handlesSequenceNumberWraparound() {
        let link = Link(responderSequence: 0xFFF0)
        link.loss = 0.05
        link.jitter = 40_000
        link.connect()
        let payload = pattern(300_000)
        #expect(link.transferToA(payload) == payload)
    }

    @Test func requestsFlowTowardTheResponderToo() {
        let link = Link()
        link.connect()
        let request = Data("hello over utp".utf8)
        link.send(link.a.write(request, now: link.now), toB: true)
        var received = Data()
        link.run {
            guard let b = link.b else { return false }
            let result = b.read(maxBytes: 100, now: link.now)
            received.append(result.data)
            return received.count >= request.count
        }
        #expect(received == request)
    }

    @Test func finIsDeliveredAfterTheData() {
        let link = Link()
        link.loss = 0.05
        link.connect()
        let payload = pattern(50_000)
        #expect(link.transferToA(payload) == payload)
        if let b = link.b { link.send(b.close(now: link.now), toB: false) }
        link.run { link.a.remoteFinished }
        #expect(link.a.remoteFinished)
    }

    @Test func resetFailsTheConnection() {
        let link = Link()
        link.connect()
        let reset = UTPPacket(kind: .reset, connectionID: 0x4242)
        _ = link.a.receive(reset, now: link.now)
        #expect(link.a.state == .closed)
        #expect(link.a.failure == .reset)
    }

    @Test func unansweredSynTimesOut() {
        let link = Link()
        link.dropAll = true
        link.send(link.a.open(now: link.now), toB: true)
        link.run { link.a.state == .closed }
        #expect(link.a.failure == .timedOut)
    }

    @Test func advertisedWindowStallsASlowReader() {
        let link = Link()
        link.connect()
        let payload = pattern(3 << 20)
        guard let b = link.b else { return }
        link.send(b.write(payload, now: link.now), toB: false)
        // A never reads: the sender must stop at the receive buffer limit.
        link.run(limit: 30_000_000) { false }
        #expect(link.a.inboundCount <= UTPConnectionCore.receiveBufferLimit)
        #expect(link.a.inboundCount >= UTPConnectionCore.receiveBufferLimit - 2 * UTPConnectionCore.maxPayload)

        // Reading reopens the window and the rest arrives.
        var received = Data()
        link.run {
            let result = link.a.read(maxBytes: 256 * 1024, now: link.now)
            received.append(result.data)
            link.send(result.packets, toB: true)
            return received.count >= payload.count
        }
        #expect(received == payload)
    }
}
