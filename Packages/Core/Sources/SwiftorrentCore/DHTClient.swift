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
    typealias NodeQuery = @Sendable (DHTNodeEndpoint, Data, Data) async throws -> DHTGetPeersResponse

    private let bootstrapNodes: [DHTNodeEndpoint]
    private let queryLimit: Int
    private let parallelQueries: Int
    private let nodeQuery: NodeQuery?

    public init(
        bootstrapNodes: [DHTNodeEndpoint] = Self.defaultBootstrapNodes,
        queryLimit: Int = 80,
        parallelQueries: Int = 8
    ) {
        self.init(bootstrapNodes: bootstrapNodes, queryLimit: queryLimit, parallelQueries: parallelQueries, nodeQuery: nil)
    }

    /// Test seam: `nodeQuery` replaces the UDP `get_peers` exchange.
    init(
        bootstrapNodes: [DHTNodeEndpoint],
        queryLimit: Int,
        parallelQueries: Int,
        nodeQuery: NodeQuery?
    ) {
        self.bootstrapNodes = bootstrapNodes
        self.queryLimit = queryLimit
        self.parallelQueries = parallelQueries
        self.nodeQuery = nodeQuery
    }

    /// Queries the DHT for peers on `infoHash`, returning them all at once.
    ///
    /// Kept as its own overload rather than a defaulted parameter on the
    /// streaming variant below, because a default argument does not satisfy the
    /// `DHTPeerFinding` requirement the download path is written against.
    public func peers(for infoHash: Data) async throws -> [PeerEndpoint] {
        try await peers(for: infoHash, onPeers: { _ in })
    }

    /// Queries the DHT for peers on `infoHash`.
    ///
    /// - Parameter onPeers: Called with the newly found peers after each query
    ///   batch, so a caller can start using them while the search continues.
    ///   Walking the routing table takes tens of seconds, and the first batch
    ///   usually lands long before the last — a caller that only needs *some*
    ///   peers shouldn't have to wait for the whole query budget to be spent.
    ///   The full deduplicated set is still returned at the end.
    public func peers(
        for infoHash: Data,
        onPeers: @Sendable ([PeerEndpoint]) async -> Void
    ) async throws -> [PeerEndpoint] {
        try Task.checkCancellation()
        let nodeID = Self.makeNodeID()
        var peers = Set<PeerEndpoint>()
        var queued = bootstrapNodes
        var visited = Set<String>()
        var queried = 0
        var lastError: Error?
        var reseeds = 0

        // Sliding window: a finished query is replaced immediately, so one dead
        // node never holds up the rest. The nearest known node is always asked
        // next, so the walk converges on the info-hash instead of wandering.
        await withTaskGroup(of: Result<DHTGetPeersResponse, Error>.self) { group in
            var inFlight = 0
            while true {
                while inFlight < parallelQueries, queried < queryLimit, peers.count < 96,
                      let node = Self.popClosest(from: &queued, to: infoHash) {
                    guard visited.insert(Self.key(for: node)).inserted else { continue }
                    queried += 1
                    inFlight += 1
                    group.addTask {
                        do {
                            if let nodeQuery {
                                return .success(try await nodeQuery(node, infoHash, nodeID))
                            }
                            return .success(try await queryGetPeers(node: node, infoHash: infoHash, nodeID: nodeID))
                        } catch {
                            return .failure(error)
                        }
                    }
                }
                guard inFlight > 0, let result = await group.next() else {
                    // The walk died without a peer (silent routers, or nodes that
                    // never answered): ask the bootstrap nodes again before giving up.
                    if peers.isEmpty, reseeds < 2, queried < queryLimit, !Task.isCancelled {
                        reseeds += 1
                        visited.removeAll()
                        queued = bootstrapNodes
                        continue
                    }
                    break
                }
                inFlight -= 1

                switch result {
                case let .success(response):
                    let fresh = response.peers.filter { peers.insert($0).inserted }
                    for node in response.nodes where !visited.contains(Self.key(for: node)) {
                        queued.append(node)
                    }
                    if !fresh.isEmpty {
                        await onPeers(fresh)
                    }
                case let .failure(error):
                    lastError = error
                }
                if Task.isCancelled || peers.count >= 96 {
                    group.cancelAll()
                }
            }
        }
        try Task.checkCancellation()

        if peers.isEmpty, let lastError {
            throw lastError
        }
        return Array(peers).shuffled()
    }

    /// Removes and returns the queued node nearest to `infoHash` by XOR distance.
    /// Nodes without a known id (bootstrap routers) count as nearest, so they are
    /// asked first.
    static func popClosest(from queue: inout [DHTNodeEndpoint], to infoHash: Data) -> DHTNodeEndpoint? {
        func distance(_ node: DHTNodeEndpoint) -> [UInt8] {
            guard let id = node.id, id.count == infoHash.count else { return [UInt8](repeating: 0, count: infoHash.count) }
            return zip(id, infoHash).map { $0 ^ $1 }
        }
        guard let index = queue.indices.min(by: { distance(queue[$0]).lexicographicallyPrecedes(distance(queue[$1])) }) else {
            return nil
        }
        return queue.remove(at: index)
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
        // A dedicated serial queue per connection: NWConnection's multi-shot
        // `stateUpdateHandler` on a concurrent queue can resume this continuation
        // twice (a `.ready`/`.failed` racing the `.cancelled` from `onCancel`),
        // a fatal continuation misuse. Serial delivery + the `ResumeOnce` guard
        // makes the transition strictly single-resume.
        let queue = DispatchQueue(label: "com.swiftorrent.dht.connection")
        try await withTimeout(seconds: .seconds(5)) {
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
        return try await withTimeout(seconds: .seconds(3)) {
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
            guard port > 0,
                  TrackerClient.isDialable(ipv4: data[hostOffset], data[hostOffset + 1], data[hostOffset + 2], data[hostOffset + 3]) else {
                return nil
            }
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
        DHTNodeEndpoint(host: "router.utorrent.com", port: 6881),
        DHTNodeEndpoint(host: "dht.libtorrent.org", port: 25401),
        DHTNodeEndpoint(host: "dht.aelitis.com", port: 6881)
    ]
}

public struct DHTGetPeersResponse: Sendable {
    public let peers: [PeerEndpoint]
    public let nodes: [DHTNodeEndpoint]
}
