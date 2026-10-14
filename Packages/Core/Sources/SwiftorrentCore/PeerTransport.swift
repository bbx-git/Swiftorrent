import Foundation
import Network

/// A byte stream to one peer. `PeerWireClient` layers MSE and the BitTorrent
/// protocol on top, so it only needs to open, send, receive and close.
///
/// Implementations must make a cancelled task abort a parked call (cancel the
/// underlying socket) so nothing leaks; timeouts are applied by the caller.
protocol PeerTransport: Sendable {
    func open() async throws
    func send(_ data: Data) async throws
    /// Returns the next chunk of received bytes; throws `.disconnected` at end of stream.
    func receive() async throws -> Data
    func close()
}

/// TCP through `NWConnection`.
struct TCPPeerTransport: PeerTransport {
    private let connection: NWConnection
    /// A dedicated **serial** queue for this connection's `NWConnection` callbacks.
    /// Network.framework schedules state/send/receive handlers onto the queue passed
    /// to `start`; a *concurrent* queue (e.g. `.global()`) lets the multi-shot
    /// `stateUpdateHandler` fire `.ready`/`.cancelled` on two threads at once, which
    /// can resume the connect continuation twice (a fatal "continuation misuse").
    /// A serial queue keeps callbacks ordered so the `ResumeOnce` guard in `open`
    /// is enough to make the transition strictly single-resume.
    private let queue = DispatchQueue(label: "com.swiftorrent.peerwire.connection")

    init(endpoint: PeerEndpoint) throws {
        guard let port = NWEndpoint.Port(rawValue: endpoint.port) else {
            throw PeerWireError.connectionFailed
        }
        connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: port, using: .tcp)
    }

    func open() async throws {
        let connection = connection
        let queue = queue
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // `stateUpdateHandler` is multi-shot and can race the `onCancel`
                // below (which cancels the connection, delivering `.cancelled`),
                // so funnel every resume through a once-only guard to make the
                // "resume more than once" fatal error impossible.
                let resume = ResumeOnce(continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        connection.stateUpdateHandler = nil
                        resume.resume(returning: ())
                    case let .failed(error):
                        connection.stateUpdateHandler = nil
                        resume.resume(throwing: error)
                    case let .waiting(error):
                        // Without waitForConnectivity, NWConnection parks unreachable or
                        // refused peers in `.waiting` indefinitely. Fail fast instead.
                        connection.stateUpdateHandler = nil
                        connection.cancel()
                        resume.resume(throwing: error)
                    case .cancelled:
                        // Reached when `onCancel` (or `.waiting` above) cancels the
                        // connection; resume so the continuation never leaks.
                        connection.stateUpdateHandler = nil
                        resume.resume(throwing: CancellationError())
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            connection.cancel()
        }
    }

    func send(_ data: Data) async throws {
        let connection = connection
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                })
            }
        } onCancel: {
            connection.cancel()
        }
    }

    func receive() async throws -> Data {
        let connection = connection
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else {
                        continuation.resume(throwing: PeerWireError.disconnected)
                    }
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    func close() {
        connection.cancel()
    }
}

/// uTP (BEP 29) over one UDP `NWConnection` per peer. The protocol itself lives
/// in `UTPConnectionCore`; this class only moves datagrams, drives its timer and
/// wakes the callers parked in `open`/`receive`.
///
/// Everything touching `core`, the waiters and the timer runs on `queue`, which
/// is also the queue the `NWConnection` delivers its callbacks on.
final class UTPPeerTransport: PeerTransport, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.swiftorrent.peerwire.utp")
    private let timer: DispatchSourceTimer
    private let core = UTPConnectionCore(connectionID: UInt16.random(in: 1..<UInt16.max))
    private var connectWaiter: ResumeOnce<Void>?
    private var readWaiter: ResumeOnce<Data>?
    private var isShutDown = false

    init(endpoint: PeerEndpoint) throws {
        guard let port = NWEndpoint.Port(rawValue: endpoint.port) else {
            throw PeerWireError.connectionFailed
        }
        connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: port, using: .udp)
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.schedule(deadline: .distantFuture)
        timer.resume()
    }

    func open() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let waiter = ResumeOnce(continuation)
                queue.async { [self] in
                    guard !isShutDown else {
                        waiter.resume(throwing: CancellationError())
                        return
                    }
                    connectWaiter = waiter
                    connection.stateUpdateHandler = { [self] state in
                        switch state {
                        case .ready:
                            connection.stateUpdateHandler = nil
                            transmit(core.open(now: Self.now))
                            receiveDatagram()
                            armTimer()
                        case .failed, .waiting, .cancelled:
                            connection.stateUpdateHandler = nil
                            shutDown()
                        default:
                            break
                        }
                    }
                    connection.start(queue: queue)
                }
            }
        } onCancel: {
            close()
        }
    }

    func send(_ data: Data) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async { [self] in
                    guard !isShutDown, core.isEstablished else {
                        continuation.resume(throwing: PeerWireError.disconnected)
                        return
                    }
                    transmit(core.write(data, now: Self.now))
                    armTimer()
                    continuation.resume()
                }
            }
        } onCancel: {
            close()
        }
    }

    func receive() async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                let waiter = ResumeOnce(continuation)
                queue.async { [self] in
                    readWaiter = waiter
                    serviceWaiters()
                }
            }
        } onCancel: {
            close()
        }
    }

    func close() {
        queue.async { [self] in
            guard !isShutDown else { return }
            transmit(core.close(now: Self.now))
            shutDown()
        }
    }

    // MARK: On `queue`

    private static var now: UInt64 { DispatchTime.now().uptimeNanoseconds / 1000 }

    private func transmit(_ packets: [UTPPacket]) {
        for packet in packets {
            connection.send(content: packet.encoded(), completion: .idempotent)
        }
    }

    private func receiveDatagram() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, _, error in
            guard !isShutDown else { return }
            if error != nil {
                shutDown()
                return
            }
            if let data, let packet = UTPPacket(data) {
                transmit(core.receive(packet, now: Self.now))
                serviceWaiters()
                armTimer()
            }
            receiveDatagram()
        }
    }

    private func tick() {
        guard !isShutDown else { return }
        transmit(core.tick(now: Self.now))
        serviceWaiters()
        armTimer()
    }

    private func armTimer() {
        guard !isShutDown, let deadline = core.nextDeadline else {
            timer.schedule(deadline: .distantFuture)
            return
        }
        let now = Self.now
        timer.schedule(deadline: .now() + .microseconds(Int(deadline > now ? deadline - now : 0)))
    }

    /// Wakes the connect and read waiters if their condition now holds, and
    /// tears everything down once the connection has failed or ended.
    private func serviceWaiters() {
        if let waiter = connectWaiter {
            if core.isEstablished {
                connectWaiter = nil
                waiter.resume(returning: ())
            } else if core.state == .closed {
                connectWaiter = nil
                waiter.resume(throwing: PeerWireError.connectionFailed)
            }
        }
        if let waiter = readWaiter {
            if core.inboundCount > 0 {
                let result = core.read(maxBytes: 65536, now: Self.now)
                readWaiter = nil
                transmit(result.packets)
                waiter.resume(returning: result.data)
            } else if core.state == .closed || core.remoteFinished {
                readWaiter = nil
                waiter.resume(throwing: PeerWireError.disconnected)
            }
        }
        if core.state == .closed { shutDown() }
    }

    private func shutDown() {
        guard !isShutDown else { return }
        isShutDown = true
        timer.cancel()
        connection.cancel()
        if let waiter = connectWaiter {
            connectWaiter = nil
            waiter.resume(throwing: PeerWireError.connectionFailed)
        }
        if let waiter = readWaiter {
            readWaiter = nil
            waiter.resume(throwing: PeerWireError.disconnected)
        }
    }
}
