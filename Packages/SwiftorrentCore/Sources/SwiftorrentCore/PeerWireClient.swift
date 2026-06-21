import CryptoKit
import Foundation
import Network

public struct PieceBlock: Sendable {
    public let begin: Int
    public let data: Data
}

public enum PeerWireError: Error, LocalizedError {
    case connectionFailed
    case invalidHandshake
    case disconnected
    case choked
    case unexpectedMessage
    case invalidPieceHash
    case extensionProtocolUnavailable
    case metadataUnavailable
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .connectionFailed: "Could not connect to peer."
        case .invalidHandshake: "Peer returned an invalid BitTorrent handshake."
        case .disconnected: "Peer disconnected."
        case .choked: "Peer choked this client."
        case .unexpectedMessage: "Peer returned an unexpected message."
        case .invalidPieceHash: "Downloaded piece failed SHA-1 verification."
        case .extensionProtocolUnavailable: "Peer does not support the BitTorrent extension protocol."
        case .metadataUnavailable: "Peer does not provide magnet metadata."
        case .timedOut: "Peer stopped responding."
        }
    }
}

public actor PeerWireClient {
    /// Upper bound on a peer-advertised wire-message length, guarding against OOM from hostile peers.
    static let maxMessageLength = 1024 * 1024
    /// Upper bound on peer-advertised `metadata_size`, guarding against OOM from hostile peers.
    static let maxMetadataSize = 10 * 1024 * 1024

    private let endpoint: PeerEndpoint
    private let infoHash: Data
    private let peerID: Data
    /// Upper bound on how long the TCP connection may take to become ready.
    private let connectTimeout: TimeInterval
    /// Upper bound on any single send/receive wire operation. A peer that goes
    /// silent mid-message is torn down within this window instead of parking a
    /// download slot forever.
    private let ioTimeout: TimeInterval
    private var connection: NWConnection?
    private var isChoked = true
    private var peerSupportsExtensions = false
    private var peerMetadataExtensionID: UInt8?
    private var metadataSize: Int?
    private var availablePieces = Set<Int>()
    private var availabilityIsKnown = false

    public init(
        endpoint: PeerEndpoint,
        infoHash: Data,
        peerID: Data,
        connectTimeout: TimeInterval = 10,
        ioTimeout: TimeInterval = 30
    ) {
        self.endpoint = endpoint
        self.infoHash = infoHash
        self.peerID = peerID
        self.connectTimeout = connectTimeout
        self.ioTimeout = ioTimeout
    }

    public func connect() async throws {
        try Task.checkCancellation()
        guard let port = NWEndpoint.Port(rawValue: endpoint.port) else {
            throw PeerWireError.connectionFailed
        }
        let connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: port, using: .tcp)
        self.connection = connection
        try await withTimeout(connectTimeout) {
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
                            // Without waitForConnectivity, NWConnection parks unreachable or
                            // refused peers in `.waiting` indefinitely. Fail fast instead.
                            connection.stateUpdateHandler = nil
                            connection.cancel()
                            continuation.resume(throwing: error)
                        case .cancelled:
                            // Reached when `onCancel` (or `.waiting` above) cancels the
                            // connection; resume so the continuation never leaks.
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
        try await send(handshake())
        let response = try await receiveExactly(68)
        guard response.count == 68,
              response[0] == 19,
              String(data: response[1..<20], encoding: .ascii) == "BitTorrent protocol",
              Data(response[28..<48]) == infoHash else {
            throw PeerWireError.invalidHandshake
        }
        peerSupportsExtensions = (response[25] & 0x10) != 0
        try await sendMessage(id: 2, payload: Data())
    }

    public func readInitialAvailability(pieceCount: Int) async throws -> Set<Int> {
        while !availabilityIsKnown && isChoked {
            try Task.checkCancellation()
            let message = try await readMessage()
            handlePeerStateMessage(message, pieceCount: pieceCount)
        }
        return availablePieces
    }

    /// Current piece availability for this peer, plus whether the peer has
    /// actually declared it. `isKnown` is `false` only when the peer unchoked
    /// before sending any `bitfield`/`have`, so the caller can decide how to
    /// treat the ambiguous case instead of assuming an empty set means "no
    /// pieces". Availability stays current because `bitfield`/`have` messages
    /// received while downloading also update `availablePieces`.
    public func currentAvailability() -> (pieces: Set<Int>, isKnown: Bool) {
        (availablePieces, availabilityIsKnown)
    }

    public func fetchMetadata(pieceSize: Int = 16 * 1024) async throws -> Data {
        try Task.checkCancellation()
        guard peerSupportsExtensions else { throw PeerWireError.extensionProtocolUnavailable }
        try await sendExtendedHandshake()
        try await readUntilMetadataHandshake()
        guard let extensionID = peerMetadataExtensionID, let metadataSize else {
            throw PeerWireError.metadataUnavailable
        }
        guard metadataSize <= Self.maxMetadataSize else {
            throw PeerWireError.metadataUnavailable
        }

        let pieceCount = Int(ceil(Double(metadataSize) / Double(pieceSize)))
        var metadata = Data()
        metadata.reserveCapacity(metadataSize)

        for piece in 0..<pieceCount {
            try Task.checkCancellation()
            try await requestMetadataPiece(piece, extensionID: extensionID)
            let response = try await readMetadataPiece(expectedPiece: piece, extensionID: extensionID)
            metadata.append(response)
        }

        guard metadata.count >= metadataSize else { throw PeerWireError.metadataUnavailable }
        return Data(metadata.prefix(metadataSize))
    }

    /// Downloads a piece block by block. `onBlock` is awaited after each 16 KB
    /// block arrives, carrying that block's byte count — the caller uses it to
    /// charge the shared rate limiter at block granularity, so the throttle holds
    /// the combined cap smoothly rather than letting a whole piece burst through
    /// before any pacing is applied.
    public func downloadPiece(index: Int, length: Int, expectedHash: Data, blockSize: Int = 16 * 1024, onBlock: (@Sendable (Int) async -> Void)? = nil) async throws -> Data {
        try Task.checkCancellation()
        var piece = Data(count: length)
        var downloaded = 0

        while downloaded < length {
            try Task.checkCancellation()
            if isChoked {
                try await drainUntilUnchoked()
            }

            let requestLength = min(blockSize, length - downloaded)
            var payload = Data()
            payload.appendUInt32(UInt32(index))
            payload.appendUInt32(UInt32(downloaded))
            payload.appendUInt32(UInt32(requestLength))
            try await sendMessage(id: 6, payload: payload)

            let block = try await readPieceBlock(expectedIndex: index)
            guard block.begin >= 0, block.begin + block.data.count <= piece.count else {
                throw PeerWireError.unexpectedMessage
            }
            piece.replaceSubrange(block.begin..<(block.begin + block.data.count), with: block.data)
            downloaded += block.data.count
            await onBlock?(block.data.count)
        }

        guard Data(Insecure.SHA1.hash(data: piece)) == expectedHash else {
            throw PeerWireError.invalidPieceHash
        }
        return piece
    }

    public func close() {
        connection?.cancel()
        connection = nil
    }

    private func drainUntilUnchoked() async throws {
        while isChoked {
            try Task.checkCancellation()
            let message = try await readMessage()
            handlePeerStateMessage(message)
        }
    }

    private func readPieceBlock(expectedIndex: Int) async throws -> PieceBlock {
        while true {
            try Task.checkCancellation()
            let message = try await readMessage()
            switch message.id {
            case 0:
                isChoked = true
                throw PeerWireError.choked
            case 1:
                isChoked = false
            case 4, 5:
                handlePeerStateMessage(message)
            case 7:
                guard message.payload.count >= 8 else { throw PeerWireError.unexpectedMessage }
                let pieceIndex = Int(message.payload.readUInt32(at: 0))
                guard pieceIndex == expectedIndex else { continue }
                let begin = Int(message.payload.readUInt32(at: 4))
                return PieceBlock(begin: begin, data: Data(message.payload.dropFirst(8)))
            case 20:
                handleExtendedMessage(message.payload)
            default:
                continue
            }
        }
    }

    private func handlePeerStateMessage(_ message: (id: UInt8, payload: Data), pieceCount: Int? = nil) {
        switch message.id {
        case 1:
            isChoked = false
        case 4:
            guard message.payload.count == 4 else { return }
            availablePieces.insert(Int(message.payload.readUInt32(at: 0)))
            availabilityIsKnown = true
        case 5:
            availablePieces = Self.parseBitfield(message.payload, pieceCount: pieceCount)
            availabilityIsKnown = true
        case 20:
            handleExtendedMessage(message.payload)
        default:
            break
        }
    }

    static func parseBitfield(_ payload: Data, pieceCount: Int? = nil) -> Set<Int> {
        var pieces = Set<Int>()
        for (byteOffset, byte) in payload.enumerated() {
            for bit in 0..<8 {
                let pieceIndex = byteOffset * 8 + bit
                if let pieceCount, pieceIndex >= pieceCount { return pieces }
                if byte & (0x80 >> UInt8(bit)) != 0 {
                    pieces.insert(pieceIndex)
                }
            }
        }
        return pieces
    }

    private func sendExtendedHandshake() async throws {
        let payload = Data([0]) + BencodeEncoder.encode([
            "m": .dictionary(["ut_metadata": .integer(1)]),
            "p": .integer(0)
        ])
        try await sendMessage(id: 20, payload: payload)
    }

    private func readUntilMetadataHandshake() async throws {
        while peerMetadataExtensionID == nil || metadataSize == nil {
            try Task.checkCancellation()
            let message = try await readMessage()
            if message.id == 20 {
                handleExtendedMessage(message.payload)
            }
        }
    }

    private func requestMetadataPiece(_ piece: Int, extensionID: UInt8) async throws {
        let payload = Data([extensionID]) + BencodeEncoder.encode([
            "msg_type": .integer(0),
            "piece": .integer(Int64(piece))
        ])
        try await sendMessage(id: 20, payload: payload)
    }

    private func readMetadataPiece(expectedPiece: Int, extensionID: UInt8) async throws -> Data {
        while true {
            try Task.checkCancellation()
            let message = try await readMessage()
            guard message.id == 20 else { continue }
            guard let extendedID = message.payload.first else { throw PeerWireError.unexpectedMessage }
            if extendedID == 0 {
                handleExtendedMessage(message.payload)
                continue
            }
            guard extendedID == extensionID else { continue }

            let payload = Data(message.payload.dropFirst())
            let header = try BencodeParser(data: payload).parsePrefix()
            guard case let .dictionary(dictionary) = header.value,
                  dictionary["msg_type"]?.value.intValue == 1,
                  dictionary["piece"]?.value.intValue == Int64(expectedPiece) else {
                continue
            }
            return Data(payload[header.range.upperBound..<payload.endIndex])
        }
    }

    private func handleExtendedMessage(_ payload: Data) {
        guard payload.first == 0 else { return }
        let body = Data(payload.dropFirst())
        guard let node = try? BencodeParser(data: body).parse(),
              case let .dictionary(dictionary) = node.value else {
            return
        }
        if case let .dictionary(messages)? = dictionary["m"]?.value,
           let id = messages["ut_metadata"]?.value.intValue,
           id > 0,
           id < 256 {
            peerMetadataExtensionID = UInt8(id)
        }
        if let size = dictionary["metadata_size"]?.value.intValue, size > 0 {
            metadataSize = Int(size)
        }
    }

    private func readMessage() async throws -> (id: UInt8, payload: Data) {
        while true {
            let lengthData = try await receiveExactly(4)
            let length = Int(lengthData.readUInt32(at: 0))
            if length == 0 { continue }
            guard length <= Self.maxMessageLength else { throw PeerWireError.unexpectedMessage }
            let body = try await receiveExactly(length)
            guard let id = body.first else { throw PeerWireError.unexpectedMessage }
            return (id, Data(body.dropFirst()))
        }
    }

    private func sendMessage(id: UInt8, payload: Data) async throws {
        var data = Data()
        data.appendUInt32(UInt32(payload.count + 1))
        data.append(id)
        data.append(payload)
        try await send(data)
    }

    private func handshake() -> Data {
        var data = Data()
        data.append(19)
        data.append("BitTorrent protocol".data(using: .ascii)!)
        data.append(Data([0, 0, 0, 0, 0, 0x10, 0, 0]))
        data.append(infoHash)
        data.append(peerID)
        return data
    }

    private func send(_ data: Data) async throws {
        try Task.checkCancellation()
        guard let connection else { throw PeerWireError.disconnected }
        try await withTimeout(ioTimeout) {
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

    private func receiveExactly(_ count: Int) async throws -> Data {
        var result = Data()
        while result.count < count {
            try Task.checkCancellation()
            guard let connection else { throw PeerWireError.disconnected }
            let remaining = count - result.count
            let chunk = try await withTimeout(ioTimeout) {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                        connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, isComplete, error in
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
            result.append(chunk)
        }
        return result
    }

    /// Races `operation` against a sleeping timer. If the timer wins, the
    /// structured task group cancels the operation task on scope exit, whose
    /// `onCancel` cancels the underlying `NWConnection`, so the parked
    /// continuation resumes and nothing leaks. Surfaced error is `.timedOut`.
    private func withTimeout<T: Sendable>(
        _ seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw PeerWireError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw PeerWireError.timedOut
            }
            return result
        }
    }
}

extension Data {
    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    func readUInt32(at offset: Int) -> UInt32 {
        UInt32(self[offset]) << 24 | UInt32(self[offset + 1]) << 16 | UInt32(self[offset + 2]) << 8 | UInt32(self[offset + 3])
    }
}
