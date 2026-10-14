import Foundation

/// The BEP 29 (uTP) connection state machine, with no I/O and no clock of its
/// own. The caller feeds it received packets and the current time, sends the
/// packets it returns, and calls `tick` at `nextDeadline`. That keeps it
/// deterministic: tests drive it with a virtual clock and a lossy simulated link.
///
/// We only download, so the sender side is deliberately small: a fixed window,
/// RTO and fast retransmit, no LEDBAT. The receiver side is complete: in-order
/// delivery, a reorder buffer, selective ACK, an honest window and echoed delay.
///
/// Times are microseconds from any monotonic origin. Not thread-safe; one owner.
final class UTPConnectionCore {
    enum State: Equatable {
        case idle, synSent, connected, finSent, closed
    }

    enum Failure: Error, Equatable {
        case reset
        case timedOut
    }

    /// Payload bytes per DATA packet; stays below a typical path MTU.
    static let maxPayload = 1200
    /// Cap on unacknowledged payload bytes we keep in flight.
    static let maxSendWindow = 64 * 1024
    static let receiveBufferLimit = 1 << 20
    /// How far past `ackNr` an out-of-order packet is still buffered. The
    /// selective-ACK bitmask covers exactly this range.
    private static let reorderSpan = 256
    private static let initialRTO: UInt64 = 1_000_000
    private static let minRTO: UInt64 = 500_000
    private static let maxRTO: UInt64 = 30_000_000
    private static let maxConsecutiveTimeouts = 6
    private static let fastRetransmitSkips = 3

    private(set) var state: State = .idle
    private(set) var failure: Failure?
    /// The peer's FIN was received and everything before it delivered.
    private(set) var remoteFinished = false

    private let recvID: UInt16
    private let sendID: UInt16
    private var seqNr: UInt16 = 1
    /// Last in-order sequence number received from the peer.
    private var ackNr: UInt16 = 0
    private var peerWindow = UInt32(UTPConnectionCore.maxSendWindow)
    private var lastTimestampDifference: UInt32 = 0

    // Byte arrays, not `Data`: `Data.removeFirst` only moves `startIndex`, so a
    // `Data` buffer keeps every byte that ever passed through it.
    private var pendingSend: [UInt8] = []
    private var inFlight: [InFlight] = []
    private var rtt: Double?
    private var rttVariance: Double = 0
    private var rto = UTPConnectionCore.initialRTO
    private var consecutiveTimeouts = 0

    private var inbound: [UInt8] = []
    private var reorder: [UInt16: Incoming] = [:]
    private var reorderBytes = 0
    private var lastAdvertisedWindow: UInt32 = 0

    private struct InFlight {
        var packet: UTPPacket
        var sentAt: UInt64
        var retransmitted = false
        var skipped = 0
    }

    private struct Incoming {
        var payload: Data
        var isFin: Bool
    }

    /// An outbound connection: `recvID` is this side's connection id; the
    /// packets we send after the SYN carry `recvID + 1`.
    init(connectionID recvID: UInt16) {
        self.recvID = recvID
        sendID = recvID &+ 1
    }

    /// The responder side, used by tests as the remote peer. Production code
    /// only ever opens outbound connections.
    init(accepting syn: UTPPacket, initialSequence: UInt16) {
        recvID = syn.connectionID &+ 1
        sendID = syn.connectionID
        seqNr = initialSequence
        ackNr = syn.sequenceNumber
        peerWindow = syn.windowSize
        state = .connected
    }

    var isEstablished: Bool { state == .connected }
    var inboundCount: Int { inbound.count }

    /// The time `tick` next needs to run, or `nil` when nothing is in flight.
    var nextDeadline: UInt64? {
        guard state != .closed, let oldest = inFlight.map(\.sentAt).min() else { return nil }
        return oldest + rto
    }

    // MARK: Driving the connection

    /// Sends the SYN that starts an outbound connection.
    func open(now: UInt64) -> [UTPPacket] {
        guard state == .idle else { return [] }
        state = .synSent
        return [track(.syn, payload: Data(), now: now)]
    }

    /// The ST_STATE answer to a SYN, for the responder side.
    func acceptReply(now: UInt64) -> [UTPPacket] {
        [makePacket(.state, sequence: seqNr, now: now)]
    }

    /// Queues `data` for sending and transmits what the window allows.
    func write(_ data: Data, now: UInt64) -> [UTPPacket] {
        guard state == .connected, !data.isEmpty else { return [] }
        pendingSend.append(contentsOf: data)
        return flush(now: now)
    }

    /// Removes and returns up to `maxBytes` of in-order received bytes. A read
    /// that reopens a nearly closed window sends an update so the peer resumes.
    func read(maxBytes: Int, now: UInt64) -> (data: Data, packets: [UTPPacket]) {
        let count = min(maxBytes, inbound.count)
        let data = Data(inbound.prefix(count))
        inbound.removeFirst(count)
        var packets: [UTPPacket] = []
        if state != .closed, lastAdvertisedWindow < UInt32(Self.maxPayload * 2),
           advertisedWindow >= UInt32(Self.maxPayload * 2) {
            packets.append(makeAck(now: now))
        }
        return (data, packets)
    }

    /// Sends our FIN after any queued data has been transmitted.
    func close(now: UInt64) -> [UTPPacket] {
        guard state == .connected else {
            if state == .idle || state == .synSent { state = .closed }
            return []
        }
        var packets = flush(now: now, drainAll: true)
        packets.append(track(.fin, payload: Data(), now: now))
        state = .finSent
        return packets
    }

    func receive(_ packet: UTPPacket, now: UInt64) -> [UTPPacket] {
        guard state != .idle, state != .closed, packet.connectionID == recvID else { return [] }
        if packet.kind == .reset {
            fail(.reset)
            return []
        }
        if state == .synSent {
            guard packet.kind == .state else { return [] }
            state = .connected
            ackNr = packet.sequenceNumber &- 1
        }
        lastTimestampDifference = UInt32(truncatingIfNeeded: now) &- packet.timestamp
        peerWindow = packet.windowSize

        var packets: [UTPPacket] = []
        packets += processAcks(in: packet, now: now)
        if packet.kind == .data || packet.kind == .fin {
            packets += accept(packet, now: now)
        }
        if state == .finSent, inFlight.isEmpty, remoteFinished { state = .closed }
        packets += flush(now: now)
        return packets
    }

    /// Handles timeouts: resends everything in flight and backs the RTO off.
    func tick(now: UInt64) -> [UTPPacket] {
        guard let deadline = nextDeadline, now >= deadline else { return [] }
        consecutiveTimeouts += 1
        if consecutiveTimeouts > Self.maxConsecutiveTimeouts {
            fail(.timedOut)
            return []
        }
        rto = min(rto * 2, Self.maxRTO)
        return inFlight.indices.map { retransmit($0, now: now) }
    }

    // MARK: Sending

    private func flush(now: UInt64, drainAll: Bool = false) -> [UTPPacket] {
        guard state == .connected else { return [] }
        var packets: [UTPPacket] = []
        while !pendingSend.isEmpty {
            let chunk = min(Self.maxPayload, pendingSend.count)
            if !drainAll, !inFlight.isEmpty,
               inFlightBytes + chunk > min(Int(peerWindow), Self.maxSendWindow) { break }
            let payload = Data(pendingSend.prefix(chunk))
            pendingSend.removeFirst(chunk)
            packets.append(track(.data, payload: payload, now: now))
        }
        return packets
    }

    private var inFlightBytes: Int {
        inFlight.reduce(0) { $0 + $1.packet.payload.count }
    }

    private func track(_ kind: UTPPacket.Kind, payload: Data, now: UInt64) -> UTPPacket {
        let packet = makePacket(kind, sequence: seqNr, payload: payload, now: now)
        seqNr &+= 1
        inFlight.append(InFlight(packet: packet, sentAt: now))
        return packet
    }

    private func retransmit(_ index: Int, now: UInt64) -> UTPPacket {
        var entry = inFlight[index]
        entry.packet.timestamp = UInt32(truncatingIfNeeded: now)
        entry.packet.timestampDifference = lastTimestampDifference
        entry.packet.ackNumber = ackNr
        entry.packet.windowSize = advertisedWindow
        entry.packet.selectiveAck = selectiveAck()
        entry.sentAt = now
        entry.retransmitted = true
        entry.skipped = 0
        inFlight[index] = entry
        return entry.packet
    }

    private func makePacket(
        _ kind: UTPPacket.Kind, sequence: UInt16, payload: Data = Data(), now: UInt64
    ) -> UTPPacket {
        let window = advertisedWindow
        lastAdvertisedWindow = window
        return UTPPacket(
            kind: kind,
            connectionID: kind == .syn ? recvID : sendID,
            timestamp: UInt32(truncatingIfNeeded: now),
            timestampDifference: lastTimestampDifference,
            windowSize: window,
            sequenceNumber: sequence,
            ackNumber: ackNr,
            selectiveAck: selectiveAck(),
            payload: payload
        )
    }

    private func makeAck(now: UInt64) -> UTPPacket {
        makePacket(.state, sequence: seqNr, now: now)
    }

    // MARK: Acknowledgements

    private func processAcks(in packet: UTPPacket, now: UInt64) -> [UTPPacket] {
        guard !inFlight.isEmpty else { return [] }
        // Ignore acks for sequence numbers we have not sent yet.
        guard Self.distance(from: packet.ackNumber, to: seqNr &- 1) < 0x8000 else { return [] }

        var acked: [Int] = []
        for (index, entry) in inFlight.enumerated() {
            let seq = entry.packet.sequenceNumber
            var isAcked = Self.distance(from: seq, to: packet.ackNumber) < 0x8000
            if !isAcked, let mask = packet.selectiveAck {
                let offset = Int(Self.distance(from: packet.ackNumber &+ 2, to: seq))
                if offset < mask.count * 8, mask[offset / 8] & (1 << UInt8(offset % 8)) != 0 {
                    isAcked = true
                }
            }
            if isAcked { acked.append(index) }
        }
        guard let highestAcked = acked.last.map({ inFlight[$0].packet.sequenceNumber }) else { return [] }

        for index in acked {
            let entry = inFlight[index]
            if !entry.retransmitted { sampleRTT(Double(now &- entry.sentAt)) }
        }
        for index in acked.reversed() { inFlight.remove(at: index) }
        consecutiveTimeouts = 0

        // Packets older than one the peer has acked were probably lost: after a
        // few such acks resend them without waiting for the RTO.
        var packets: [UTPPacket] = []
        for index in inFlight.indices
            where Self.distance(from: inFlight[index].packet.sequenceNumber, to: highestAcked) < 0x8000 {
            inFlight[index].skipped += 1
            if inFlight[index].skipped >= Self.fastRetransmitSkips {
                packets.append(retransmit(index, now: now))
            }
        }
        return packets
    }

    private func sampleRTT(_ sample: Double) {
        if let current = rtt {
            rttVariance += (abs(current - sample) - rttVariance) / 4
            rtt = current + (sample - current) / 8
        } else {
            rtt = sample
            rttVariance = sample / 2
        }
        let estimate = (rtt ?? sample) + rttVariance * 4
        rto = min(max(UInt64(estimate), Self.minRTO), Self.maxRTO)
    }

    // MARK: Receiving

    private var advertisedWindow: UInt32 {
        UInt32(max(0, Self.receiveBufferLimit - inbound.count - reorderBytes))
    }

    private func accept(_ packet: UTPPacket, now: UInt64) -> [UTPPacket] {
        let offset = Int(Self.distance(from: ackNr, to: packet.sequenceNumber))
        let isFin = packet.kind == .fin
        let fits = inbound.count + reorderBytes + packet.payload.count <= Self.receiveBufferLimit
        if offset == 1, fits {
            deliver(Incoming(payload: packet.payload, isFin: isFin))
            ackNr = packet.sequenceNumber
            while let next = reorder.removeValue(forKey: ackNr &+ 1) {
                reorderBytes -= next.payload.count
                deliver(next)
                ackNr &+= 1
            }
        } else if offset >= 2, offset <= Self.reorderSpan + 1,
                  reorder[packet.sequenceNumber] == nil, fits {
            reorder[packet.sequenceNumber] = Incoming(payload: packet.payload, isFin: isFin)
            reorderBytes += packet.payload.count
        }
        // Always acknowledge, duplicates included, so the sender stops resending.
        return [makeAck(now: now)]
    }

    private func deliver(_ incoming: Incoming) {
        inbound.append(contentsOf: incoming.payload)
        if incoming.isFin { remoteFinished = true }
    }

    private func selectiveAck() -> [UInt8]? {
        guard !reorder.isEmpty else { return nil }
        var mask = [UInt8](repeating: 0, count: Self.reorderSpan / 8)
        var highest = 0
        for seq in reorder.keys {
            let offset = Int(Self.distance(from: ackNr &+ 2, to: seq))
            guard offset < Self.reorderSpan else { continue }
            mask[offset / 8] |= 1 << UInt8(offset % 8)
            highest = max(highest, offset)
        }
        let length = (highest / 32 + 1) * 4
        return Array(mask.prefix(length))
    }

    // MARK: Helpers

    private func fail(_ reason: Failure) {
        failure = reason
        state = .closed
        inFlight.removeAll()
        pendingSend.removeAll()
    }

    /// Forward distance from `a` to `b` in 16-bit sequence space; values below
    /// 0x8000 mean `b` is at or after `a`.
    private static func distance(from a: UInt16, to b: UInt16) -> UInt16 {
        b &- a
    }
}
