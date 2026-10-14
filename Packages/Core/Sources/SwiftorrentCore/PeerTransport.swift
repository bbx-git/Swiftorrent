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
