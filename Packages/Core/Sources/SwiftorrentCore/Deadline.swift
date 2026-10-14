import Foundation
import Synchronization

/// Runs `operation`, cancelling it and throwing `timeoutError` once `duration`
/// passes; an error the operation throws itself is passed through.
///
/// The deadline is a dispatch timer, not a racing `Task.sleep`: a cancelled sleep
/// keeps its timer and task allocation alive until the original deadline, and
/// with a deadline on every peer socket read that piled up hundreds of MB during
/// a fast download. A cancelled dispatch timer is freed at once.
func withDeadline<T: Sendable>(
    _ duration: Duration,
    timeoutError: any Error & Sendable,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let task = Task { try await operation() }
    let expired = Mutex(false)
    let timer = DispatchSource.makeTimerSource(queue: .global())
    timer.schedule(deadline: .now() + .nanoseconds(Int(min(duration, .seconds(86_400)).nanoseconds)))
    timer.setEventHandler {
        expired.withLock { $0 = true }
        task.cancel()
    }
    timer.activate()
    defer { timer.cancel() }
    do {
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    } catch where expired.withLock({ $0 }) {
        throw timeoutError
    }
}

private extension Duration {
    var nanoseconds: Int64 {
        components.seconds * 1_000_000_000 + components.attoseconds / 1_000_000_000
    }
}
