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
        }
    }
}

public actor PeerWireClient {
    private let endpoint: PeerEndpoint
    private let infoHash: Data
    private let peerID: Data
    private var connection: NWConnection?
    private var isChoked = true
    private var peerSupportsExtensions = false
    private var peerMetadataExtensionID: UInt8?
    private var metadataSize: Int?

    public init(endpoint: PeerEndpoint, infoHash: Data, peerID: Data) {
        self.endpoint = endpoint
        self.infoHash = infoHash
        self.peerID = peerID
    }

    public func connect() async throws {
        let connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: NWEndpoint.Port(rawValue: endpoint.port)!, using: .tcp)
        self.connection = connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    continuation.resume()
                    connection.stateUpdateHandler = nil
                case let .failed(error):
                    continuation.resume(throwing: error)
                    connection.stateUpdateHandler = nil
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
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

    public func fetchMetadata(pieceSize: Int = 16 * 1024) async throws -> Data {
        guard peerSupportsExtensions else { throw PeerWireError.extensionProtocolUnavailable }
        try await sendExtendedHandshake()
        try await readUntilMetadataHandshake()
        guard let extensionID = peerMetadataExtensionID, let metadataSize else {
            throw PeerWireError.metadataUnavailable
        }

        let pieceCount = Int(ceil(Double(metadataSize) / Double(pieceSize)))
        var metadata = Data()
        metadata.reserveCapacity(metadataSize)

        for piece in 0..<pieceCount {
            try await requestMetadataPiece(piece, extensionID: extensionID)
            let response = try await readMetadataPiece(expectedPiece: piece, extensionID: extensionID)
            metadata.append(response)
        }

        guard metadata.count >= metadataSize else { throw PeerWireError.metadataUnavailable }
        return Data(metadata.prefix(metadataSize))
    }

    public func downloadPiece(index: Int, length: Int, expectedHash: Data, blockSize: Int = 16 * 1024) async throws -> Data {
        var piece = Data(count: length)
        var downloaded = 0

        while downloaded < length {
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
            let message = try await readMessage()
            if message.id == 1 {
                isChoked = false
            }
        }
    }

    private func readPieceBlock(expectedIndex: Int) async throws -> PieceBlock {
        while true {
            let message = try await readMessage()
            switch message.id {
            case 0:
                isChoked = true
                throw PeerWireError.choked
            case 1:
                isChoked = false
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

    private func sendExtendedHandshake() async throws {
        let payload = Data([0]) + BencodeEncoder.encode([
            "m": .dictionary(["ut_metadata": .integer(1)]),
            "p": .integer(0)
        ])
        try await sendMessage(id: 20, payload: payload)
    }

    private func readUntilMetadataHandshake() async throws {
        while peerMetadataExtensionID == nil || metadataSize == nil {
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
        guard let connection else { throw PeerWireError.disconnected }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func receiveExactly(_ count: Int) async throws -> Data {
        var result = Data()
        while result.count < count {
            guard let connection else { throw PeerWireError.disconnected }
            let chunk = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: count - result.count) { data, _, isComplete, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else if isComplete {
                        continuation.resume(throwing: PeerWireError.disconnected)
                    } else {
                        continuation.resume(throwing: PeerWireError.disconnected)
                    }
                }
            }
            result.append(chunk)
        }
        return result
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
