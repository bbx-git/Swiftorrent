import Foundation
import Network

public struct DHTNodeEndpoint: Hashable, Sendable {
    public let host: String
    public let port: UInt16
    public let id: Data?

    public init(host: String, port: UInt16, id: Data? = nil) {
        self.host = host
        self.port = port
        self.id = id
    }
}

public enum DHTClientError: Error, LocalizedError {
    case invalidResponse
    case transactionMismatch

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "DHT node returned an invalid response."
        case .transactionMismatch: "DHT node returned a response for a different transaction."
        }
    }
}

public struct DHTClient: Sendable {
    private let bootstrapNodes: [DHTNodeEndpoint]
    private let queryLimit: Int
    private let parallelQueries: Int

    public init(
        bootstrapNodes: [DHTNodeEndpoint] = Self.defaultBootstrapNodes,
        queryLimit: Int = 80,
        parallelQueries: Int = 8
    ) {
        self.bootstrapNodes = bootstrapNodes
        self.queryLimit = queryLimit
        self.parallelQueries = parallelQueries
    }

    public func peers(for infoHash: Data) async throws -> [PeerEndpoint] {
        try Task.checkCancellation()
        let nodeID = Self.makeNodeID()
        var peers = Set<PeerEndpoint>()
        var queued = bootstrapNodes
        var visited = Set<String>()
        var queried = 0
        var lastError: Error?

        while !queued.isEmpty, queried < queryLimit, peers.count < 96 {
            try Task.checkCancellation()
            let batch = queued.prefix(parallelQueries).filter { visited.insert(Self.key(for: $0)).inserted }
            queued.removeFirst(min(parallelQueries, queued.count))
            if batch.isEmpty { continue }
            queried += batch.count

            await withTaskGroup(of: Result<DHTGetPeersResponse, Error>.self) { group in
                for node in batch {
                    group.addTask {
                        do {
                            return .success(try await queryGetPeers(node: node, infoHash: infoHash, nodeID: nodeID))
                        } catch {
                            return .failure(error)
                        }
                    }
                }

                for await result in group {
                    switch result {
                    case let .success(response):
                        peers.formUnion(response.peers)
                        for node in response.nodes where !visited.contains(Self.key(for: node)) {
                            queued.append(node)
                        }
                    case let .failure(error):
                        lastError = error
                    }
                }
            }
        }

        if peers.isEmpty, let lastError {
            throw lastError
        }
        return Array(peers).shuffled()
    }

    private func queryGetPeers(node: DHTNodeEndpoint, infoHash: Data, nodeID: Data) async throws -> DHTGetPeersResponse {
        guard let port = NWEndpoint.Port(rawValue: node.port) else {
            throw DHTClientError.invalidResponse
        }

        let transactionID = Self.transactionID()
        let payload = BencodeEncoder.encode([
            "a": .dictionary([
                "id": .bytes(nodeID),
                "info_hash": .bytes(infoHash)
            ]),
            "q": .string("get_peers"),
            "t": .bytes(transactionID),
            "y": .string("q")
        ])

        let connection = NWConnection(host: NWEndpoint.Host(node.host), port: port, using: .udp)
        defer { connection.cancel() }
        try await waitUntilReady(connection)
        try await send(payload, on: connection)
        let response = try await receive(on: connection)
        return try Self.parseGetPeersResponse(response, expectedTransactionID: transactionID)
    }

    private func waitUntilReady(_ connection: NWConnection) async throws {
        try Task.checkCancellation()
        try await withTimeout(seconds: .seconds(5)) {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            connection.stateUpdateHandler = nil
                            continuation.resume()
                        case let .failed(error):
                            connection.stateUpdateHandler = nil
                            continuation.resume(throwing: error)
                        case let .waiting(error):
                            connection.stateUpdateHandler = nil
                            connection.cancel()
                            continuation.resume(throwing: error)
                        case .cancelled:
                            connection.stateUpdateHandler = nil
                            continuation.resume(throwing: CancellationError())
                        default:
                            break
                        }
                    }
                    connection.start(queue: .global(qos: .utility))
                }
            } onCancel: {
                connection.cancel()
            }
        }
    }

    private func send(_ data: Data, on connection: NWConnection) async throws {
        try Task.checkCancellation()
        try await withTimeout(seconds: .seconds(5)) {
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

    private func receive(on connection: NWConnection) async throws -> Data {
        try Task.checkCancellation()
        return try await withTimeout(seconds: .seconds(7)) {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                    connection.receiveMessage { data, _, _, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else if let data, !data.isEmpty {
                            continuation.resume(returning: data)
                        } else {
                            continuation.resume(throwing: DHTClientError.invalidResponse)
                        }
                    }
                }
            } onCancel: {
                connection.cancel()
            }
        }
    }

    static func parseGetPeersResponse(_ data: Data, expectedTransactionID: Data) throws -> DHTGetPeersResponse {
        let root = try BencodeParser(data: data).parse()
        guard case let .dictionary(dictionary) = root.value,
              case let .bytes(transactionID)? = dictionary["t"]?.value,
              case let .bytes(y)? = dictionary["y"]?.value,
              y == Data("r".utf8),
              case let .dictionary(response)? = dictionary["r"]?.value else {
            throw DHTClientError.invalidResponse
        }
        guard transactionID == expectedTransactionID else {
            throw DHTClientError.transactionMismatch
        }

        var peers = Set<PeerEndpoint>()
        if case let .list(values)? = response["values"]?.value {
            for value in values {
                guard case let .bytes(compactPeer) = value.value else { continue }
                peers.formUnion(TrackerClient.parseCompactPeers(compactPeer))
            }
        }

        var nodes: [DHTNodeEndpoint] = []
        if case let .bytes(compactNodes)? = response["nodes"]?.value {
            nodes.append(contentsOf: parseCompactIPv4Nodes(compactNodes))
        }

        return DHTGetPeersResponse(peers: Array(peers), nodes: nodes)
    }

    static func parseCompactIPv4Nodes(_ data: Data) -> [DHTNodeEndpoint] {
        stride(from: 0, to: data.count - (data.count % 26), by: 26).compactMap { offset in
            let id = Data(data[offset..<(offset + 20)])
            let hostOffset = offset + 20
            let host = "\(data[hostOffset]).\(data[hostOffset + 1]).\(data[hostOffset + 2]).\(data[hostOffset + 3])"
            let portOffset = offset + 24
            let port = UInt16(data[portOffset]) << 8 | UInt16(data[portOffset + 1])
            guard port > 0 else { return nil }
            return DHTNodeEndpoint(host: host, port: port, id: id)
        }
    }

    static func makeNodeID() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<20).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    private static func transactionID() -> Data {
        Data([UInt8.random(in: .min ... .max), UInt8.random(in: .min ... .max)])
    }

    private static func key(for node: DHTNodeEndpoint) -> String {
        "\(node.host):\(node.port)"
    }

    public static let defaultBootstrapNodes: [DHTNodeEndpoint] = [
        DHTNodeEndpoint(host: "router.bittorrent.com", port: 6881),
        DHTNodeEndpoint(host: "dht.transmissionbt.com", port: 6881),
        DHTNodeEndpoint(host: "router.utorrent.com", port: 6881)
    ]
}

public struct DHTGetPeersResponse: Sendable {
    public let peers: [PeerEndpoint]
    public let nodes: [DHTNodeEndpoint]
}
