import Foundation
import Network

public struct PeerEndpoint: Hashable, Sendable {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
}

public struct TrackerRequest: Sendable {
    public let announceURL: URL
    public let infoHash: Data
    public let peerID: Data
    public let port: UInt16
    public let downloaded: Int64
    public let left: Int64
    public let event: String?

    public init(announceURL: URL, infoHash: Data, peerID: Data, port: UInt16 = 6881, downloaded: Int64, left: Int64, event: String?) {
        self.announceURL = announceURL
        self.infoHash = infoHash
        self.peerID = peerID
        self.port = port
        self.downloaded = downloaded
        self.left = left
        self.event = event
    }
}

public enum TrackerClientError: Error, LocalizedError {
    case unsupportedScheme(String)
    case invalidResponse
    case invalidTrackerURL
    case transactionMismatch

    public var errorDescription: String? {
        switch self {
        case let .unsupportedScheme(scheme): "Unsupported tracker scheme: \(scheme)."
        case .invalidResponse: "Tracker returned an invalid response."
        case .invalidTrackerURL: "Tracker URL is invalid."
        case .transactionMismatch: "Tracker returned a response for a different transaction."
        }
    }
}

public struct TrackerClient: Sendable {
    /// Largest HTTP announce reply accepted. A compact reply for 48 peers is a few
    /// hundred bytes; this leaves room for verbose dictionary-form replies.
    private static let maxReplyBytes = 1 << 20

    private let http: BoundedHTTPClient

    public init(session: URLSession = .shared) {
        http = BoundedHTTPClient(session: session)
    }

    public func announce(_ request: TrackerRequest) async throws -> [PeerEndpoint] {
        try Task.checkCancellation()
        guard let scheme = request.announceURL.scheme?.lowercased() else {
            throw TrackerClientError.unsupportedScheme(request.announceURL.scheme ?? "unknown")
        }

        if scheme == "udp" {
            return try await announceUDP(request)
        }

        guard scheme == "http" || scheme == "https" else {
            throw TrackerClientError.unsupportedScheme(scheme)
        }

        guard let url = makeAnnounceURL(request) else {
            throw TrackerClientError.invalidTrackerURL
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.timeoutInterval = 20
        urlRequest.setValue("Swiftorrent/0.1", forHTTPHeaderField: "User-Agent")
        let (data, httpResponse) = try await http.data(for: urlRequest, limit: Self.maxReplyBytes)
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw TrackerClientError.invalidResponse
        }
        return try parsePeers(from: data)
    }

    private func makeAnnounceURL(_ request: TrackerRequest) -> URL? {
        Self.makeAnnounceURL(
            base: request.announceURL.absoluteString,
            infoHash: request.infoHash,
            peerID: request.peerID,
            port: request.port,
            downloaded: request.downloaded,
            left: request.left,
            event: request.event
        )
    }

    /// Builds the HTTP(S) announce URL from a base string. Returns `nil` when the
    /// resulting string is not a valid URL so the caller can skip the tracker
    /// instead of force-unwrapping.
    static func makeAnnounceURL(
        base: String,
        infoHash: Data,
        peerID: Data,
        port: UInt16,
        downloaded: Int64,
        left: Int64,
        event: String?
    ) -> URL? {
        var absolute = base
        absolute += absolute.contains("?") ? "&" : "?"
        absolute += [
            "info_hash=\(percentEncode(infoHash))",
            "peer_id=\(percentEncode(peerID))",
            "port=\(port)",
            "uploaded=0",
            "downloaded=\(downloaded)",
            "left=\(left)",
            "compact=1",
            "numwant=48",
            "no_peer_id=1"
        ].joined(separator: "&")
        if let event {
            absolute += "&event=\(event)"
        }
        return URL(string: absolute)
    }

    private func announceUDP(_ request: TrackerRequest) async throws -> [PeerEndpoint] {
        guard let host = request.announceURL.host,
              let portValue = request.announceURL.port,
              portValue > 0,
              portValue <= Int(UInt16.max),
              let port = NWEndpoint.Port(rawValue: UInt16(portValue)) else {
            throw TrackerClientError.invalidTrackerURL
        }

        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .udp)
        defer { connection.cancel() }
        try await waitUntilReady(connection)

        let connectionID = try await udpConnect(connection)
        return try await udpAnnounce(connection, connectionID: connectionID, request: request)
    }

    private func waitUntilReady(_ connection: NWConnection) async throws {
        try Task.checkCancellation()
        // Per-connection serial queue + `ResumeOnce`: NWConnection's multi-shot
        // `stateUpdateHandler` on a concurrent queue can resume this continuation
        // twice (a `.ready`/`.failed` racing the `.cancelled` from `onCancel`),
        // which is a fatal continuation misuse.
        let queue = DispatchQueue(label: "com.swiftorrent.tracker.connection")
        try await withTimeout(seconds: .seconds(10)) {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
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
                            connection.stateUpdateHandler = nil
                            connection.cancel()
                            resume.resume(throwing: error)
                        case .cancelled:
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
    }

    private func udpConnect(_ connection: NWConnection) async throws -> Int64 {
        try Task.checkCancellation()
        let transactionID = UInt32.random(in: UInt32.min...UInt32.max)
        var payload = Data()
        payload.appendUInt64(0x0000_0417_2710_1980)
        payload.appendUInt32(0)
        payload.appendUInt32(transactionID)

        try await sendUDP(payload, on: connection)
        let response = try await receiveUDP(on: connection)
        guard response.count >= 16, response.readUInt32(at: 0) == 0 else {
            throw TrackerClientError.invalidResponse
        }
        guard response.readUInt32(at: 4) == transactionID else {
            throw TrackerClientError.transactionMismatch
        }
        return Int64(bitPattern: response.readUInt64(at: 8))
    }

    private func udpAnnounce(_ connection: NWConnection, connectionID: Int64, request: TrackerRequest) async throws -> [PeerEndpoint] {
        try Task.checkCancellation()
        let transactionID = UInt32.random(in: UInt32.min...UInt32.max)
        var payload = Data()
        payload.appendInt64(connectionID)
        payload.appendUInt32(1)
        payload.appendUInt32(transactionID)
        payload.append(request.infoHash)
        payload.append(request.peerID)
        payload.appendInt64(request.downloaded)
        payload.appendInt64(max(0, request.left))
        payload.appendInt64(0)
        payload.appendUInt32(udpEventCode(request.event))
        payload.appendUInt32(0)
        payload.appendUInt32(UInt32.random(in: UInt32.min...UInt32.max))
        payload.appendInt32(48)
        payload.appendUInt16(request.port)

        try await sendUDP(payload, on: connection)
        let response = try await receiveUDP(on: connection)
        guard response.count >= 20, response.readUInt32(at: 0) == 1 else {
            throw TrackerClientError.invalidResponse
        }
        guard response.readUInt32(at: 4) == transactionID else {
            throw TrackerClientError.transactionMismatch
        }
        return Self.parseCompactPeers(Data(response.dropFirst(20)))
    }

    private func udpEventCode(_ event: String?) -> UInt32 {
        switch event {
        case "completed": 1
        case "started": 2
        case "stopped": 3
        default: 0
        }
    }

    private func sendUDP(_ data: Data, on connection: NWConnection) async throws {
        try Task.checkCancellation()
        try await withTimeout(seconds: .seconds(10)) {
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
    }

    private func receiveUDP(on connection: NWConnection) async throws -> Data {
        try Task.checkCancellation()
        return try await withTimeout(seconds: .seconds(15)) {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                    connection.receiveMessage { data, _, _, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else if let data, !data.isEmpty {
                            continuation.resume(returning: data)
                        } else {
                            continuation.resume(throwing: TrackerClientError.invalidResponse)
                        }
                    }
                }
            } onCancel: {
                connection.cancel()
            }
        }
    }

    private func parsePeers(from data: Data) throws -> [PeerEndpoint] {
        let root = try BencodeParser(data: data).parse()
        guard case let .dictionary(dictionary) = root.value else {
            throw TrackerClientError.invalidResponse
        }

        if case let .bytes(compact)? = dictionary["peers"]?.value {
            return Self.parseCompactPeers(compact)
        }

        if case let .list(peerNodes)? = dictionary["peers"]?.value {
            return peerNodes.compactMap { node in
                guard case let .dictionary(peer) = node.value,
                      let host = peer["ip"]?.value.stringValue,
                      let portValue = peer["port"]?.value.intValue else {
                    return nil
                }
                guard portValue > 0, portValue <= Int64(UInt16.max) else { return nil }
                return PeerEndpoint(host: host, port: UInt16(portValue))
            }
        }

        throw TrackerClientError.invalidResponse
    }

    static func parseCompactPeers(_ data: Data) -> [PeerEndpoint] {
        stride(from: 0, to: data.count - (data.count % 6), by: 6).compactMap { offset in
            let host = "\(data[offset]).\(data[offset + 1]).\(data[offset + 2]).\(data[offset + 3])"
            let port = UInt16(data[offset + 4]) << 8 | UInt16(data[offset + 5])
            guard port > 0 else { return nil }
            return PeerEndpoint(host: host, port: port)
        }
    }

    static func percentEncode(_ data: Data) -> String {
        data.map { byte in
            if (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) ||
                (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) ||
                (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) {
                return String(UnicodeScalar(byte))
            }
            return String(format: "%%%02X", byte)
        }.joined()
    }
}

extension Data {
    mutating func appendUInt64(_ value: UInt64) {
        append(UInt8((value >> 56) & 0xFF))
        append(UInt8((value >> 48) & 0xFF))
        append(UInt8((value >> 40) & 0xFF))
        append(UInt8((value >> 32) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    mutating func appendInt64(_ value: Int64) {
        appendUInt64(UInt64(bitPattern: value))
    }

    mutating func appendInt32(_ value: Int32) {
        appendUInt32(UInt32(bitPattern: value))
    }

    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    func readUInt64(at offset: Int) -> UInt64 {
        UInt64(self[offset]) << 56 |
            UInt64(self[offset + 1]) << 48 |
            UInt64(self[offset + 2]) << 40 |
            UInt64(self[offset + 3]) << 32 |
            UInt64(self[offset + 4]) << 24 |
            UInt64(self[offset + 5]) << 16 |
            UInt64(self[offset + 6]) << 8 |
            UInt64(self[offset + 7])
    }
}
