import Foundation

public enum BoundedHTTPError: Error, LocalizedError, Equatable {
    case tooLarge
    case notHTTP

    public var errorDescription: String? {
        switch self {
        case .tooLarge: "The server sent more data than expected."
        case .notHTTP: "The server did not return an HTTP response."
        }
    }
}

/// Loads small HTTP bodies (tracker replies, `.torrent` files, web-seed ranges)
/// while enforcing a byte ceiling. `URLSession.data(for:)` buffers the entire
/// body, so a hostile server could make it hold gigabytes; this client cancels
/// the transfer as soon as the body (or its declared `Content-Length`) exceeds
/// `limit`.
///
/// It runs on a private session built from the caller's configuration, so a
/// session injected with custom `protocolClasses` (tests) still applies. One
/// instance is shared by many concurrent requests; connection reuse is kept.
final class BoundedHTTPClient: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// What a transfer produced. `truncated` is set only when the caller asked for
    /// truncation and the body ran past the limit; `data` is then a prefix.
    struct Reply {
        let data: Data
        let response: HTTPURLResponse
        let truncated: Bool
    }

    private struct Transfer {
        var data = Data()
        var response: HTTPURLResponse?
        var overLimit = false
        let limit: Int
        let truncating: Bool
        let continuation: CheckedContinuation<Reply, Error>
    }

    private let lock = NSLock()
    private var transfers: [Int: Transfer] = [:]
    private var session: URLSession!

    init(configuration: URLSessionConfiguration) {
        super.init()
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    convenience init(session: URLSession) {
        self.init(configuration: session.configuration)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    /// Returns the full body and response, or throws `BoundedHTTPError.tooLarge`
    /// once more than `limit` bytes are (or are declared to be) coming.
    func data(for request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        let reply = try await load(request, limit: limit, truncating: false)
        return (reply.data, reply.response)
    }

    /// Like `data(for:limit:)`, but with `truncating` a body that runs past
    /// `limit` yields a `truncated` reply (status and headers intact) instead of
    /// an error, so the caller can tell *why* it was too large.
    func load(_ request: URLRequest, limit: Int, truncating: Bool) async throws -> Reply {
        try Task.checkCancellation()
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                lock.lock()
                transfers[task.taskIdentifier] = Transfer(limit: limit, truncating: truncating, continuation: continuation)
                lock.unlock()
                box.set(task)
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        var allow = true
        if var transfer = transfers[dataTask.taskIdentifier] {
            transfer.response = response as? HTTPURLResponse
            if response.expectedContentLength > Int64(transfer.limit) {
                transfer.overLimit = true
                allow = false
            }
            transfers[dataTask.taskIdentifier] = transfer
        }
        lock.unlock()
        completionHandler(allow ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        var cancel = false
        if var transfer = transfers[dataTask.taskIdentifier] {
            transfer.data.append(data)
            if transfer.data.count > transfer.limit {
                transfer.overLimit = true
                cancel = true
            }
            transfers[dataTask.taskIdentifier] = transfer
        }
        lock.unlock()
        if cancel { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let transfer = transfers.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let transfer else { return }
        if transfer.overLimit {
            if transfer.truncating, let response = transfer.response {
                transfer.continuation.resume(returning: Reply(data: transfer.data, response: response, truncated: true))
            } else {
                transfer.continuation.resume(throwing: BoundedHTTPError.tooLarge)
            }
        } else if let error {
            let cancelled = (error as? URLError)?.code == .cancelled
            transfer.continuation.resume(throwing: cancelled ? CancellationError() : error)
        } else if let response = transfer.response {
            transfer.continuation.resume(returning: Reply(data: transfer.data, response: response, truncated: false))
        } else {
            transfer.continuation.resume(throwing: BoundedHTTPError.notHTTP)
        }
    }
}

/// Lets the cancellation handler reach a task created inside the continuation body.
private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false

    func set(_ task: URLSessionTask) {
        lock.lock()
        self.task = task
        let alreadyCancelled = cancelled
        lock.unlock()
        if alreadyCancelled { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }
}
