import Foundation

/// Wraps a checked continuation so it resumes **at most once**, thread-safely.
///
/// `NWConnection.stateUpdateHandler` is multi-shot: it fires on every transition,
/// and those callbacks can race a task-cancellation handler that cancels the
/// connection (delivering a `.cancelled` state) while a `.ready`/`.failed` is
/// already in flight. Resuming the underlying continuation twice is a fatal
/// "SWIFT TASK CONTINUATION MISUSE". This guard makes the first resume win and
/// every later one a no-op, so any `NWConnection` state-handler continuation is
/// safe regardless of queue-delivery ordering.
final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: sending T) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(throwing: error)
    }
}
