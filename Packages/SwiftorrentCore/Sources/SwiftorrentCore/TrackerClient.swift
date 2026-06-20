import Foundation

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
    public let downloaded: Int64
    public let left: Int64
    public let event: String?

    public init(announceURL: URL, infoHash: Data, peerID: Data, downloaded: Int64, left: Int64, event: String?) {
        self.announceURL = announceURL
        self.infoHash = infoHash
        self.peerID = peerID
        self.downloaded = downloaded
        self.left = left
        self.event = event
    }
}

public enum TrackerClientError: Error, LocalizedError {
    case unsupportedScheme(String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case let .unsupportedScheme(scheme): "Only HTTP and HTTPS trackers are supported in this first build, not \(scheme)."
        case .invalidResponse: "Tracker returned an invalid response."
        }
    }
}

public struct TrackerClient: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func announce(_ request: TrackerRequest) async throws -> [PeerEndpoint] {
        guard let scheme = request.announceURL.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw TrackerClientError.unsupportedScheme(request.announceURL.scheme ?? "unknown")
        }

        let url = makeAnnounceURL(request)
        var urlRequest = URLRequest(url: url)
        urlRequest.timeoutInterval = 20
        urlRequest.setValue("Swiftorrent/0.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw TrackerClientError.invalidResponse
        }
        return try parsePeers(from: data)
    }

    private func makeAnnounceURL(_ request: TrackerRequest) -> URL {
        var absolute = request.announceURL.absoluteString
        absolute += absolute.contains("?") ? "&" : "?"
        absolute += [
            "info_hash=\(percentEncode(request.infoHash))",
            "peer_id=\(percentEncode(request.peerID))",
            "port=0",
            "uploaded=0",
            "downloaded=\(request.downloaded)",
            "left=\(request.left)",
            "compact=1",
            "numwant=48",
            "no_peer_id=1"
        ].joined(separator: "&")
        if let event = request.event {
            absolute += "&event=\(event)"
        }
        return URL(string: absolute)!
    }

    private func parsePeers(from data: Data) throws -> [PeerEndpoint] {
        let root = try BencodeParser(data: data).parse()
        guard case let .dictionary(dictionary) = root.value else {
            throw TrackerClientError.invalidResponse
        }

        if case let .bytes(compact)? = dictionary["peers"]?.value {
            return parseCompactPeers(compact)
        }

        if case let .list(peerNodes)? = dictionary["peers"]?.value {
            return peerNodes.compactMap { node in
                guard case let .dictionary(peer) = node.value,
                      let host = peer["ip"]?.value.stringValue,
                      let portValue = peer["port"]?.value.intValue else {
                    return nil
                }
                return PeerEndpoint(host: host, port: UInt16(portValue))
            }
        }

        throw TrackerClientError.invalidResponse
    }

    private func parseCompactPeers(_ data: Data) -> [PeerEndpoint] {
        stride(from: 0, to: data.count - (data.count % 6), by: 6).map { offset in
            let host = "\(data[offset]).\(data[offset + 1]).\(data[offset + 2]).\(data[offset + 3])"
            let port = UInt16(data[offset + 4]) << 8 | UInt16(data[offset + 5])
            return PeerEndpoint(host: host, port: port)
        }
    }

    private func percentEncode(_ data: Data) -> String {
        data.map { byte in
            let scalar = UnicodeScalar(byte)
            if CharacterSet.alphanumerics.contains(scalar) {
                return String(Character(scalar))
            }
            return String(format: "%%%02X", byte)
        }.joined()
    }
}
