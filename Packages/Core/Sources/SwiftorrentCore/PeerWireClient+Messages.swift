import Foundation

extension PeerWireClient {
    /// Returns peers learned from inbound PEX since the last call and clears the
    /// buffer, so the swarm can fold them into its replacement reserve.
    public func takeDiscoveredPeers() -> [PeerEndpoint] {
        defer { discoveredPeers.removeAll(keepingCapacity: true) }
        return Array(discoveredPeers)
    }

    public func readInitialAvailability(pieceCount: Int) async throws -> Set<Int> {
        knownPieceCount = pieceCount
        while !availabilityIsKnown && isChoked {
            try Task.checkCancellation()
            let message = try await readMessage()
            handlePeerStateMessage(message, pieceCount: pieceCount)
        }
        return availablePieces
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
            let response = try await readMetadataPiece(expectedPiece: piece)
            // BEP 9: every piece is exactly `pieceSize` bytes except the last. Anything
            // else is bogus, and without this check a hostile peer could make us
            // buffer up to a megabyte per piece.
            let expected = min(pieceSize, metadataSize - piece * pieceSize)
            guard response.count == expected else { throw PeerWireError.metadataUnavailable }
            metadata.append(response)
        }

        guard metadata.count >= metadataSize else { throw PeerWireError.metadataUnavailable }
        return Data(metadata.prefix(metadataSize))
    }

    func handlePeerStateMessage(_ message: (id: UInt8, payload: Data), pieceCount: Int? = nil) {
        switch message.id {
        case 1:
            isChoked = false
        case 4:
            guard message.payload.count == 4 else { return }
            let index = Int(message.payload.readUInt32(at: 0))
            if let limit = pieceCount ?? knownPieceCount, index >= limit { return }
            availablePieces.insert(index)
            availabilityIsKnown = true
        case 5:
            availablePieces = Self.parseBitfield(message.payload, pieceCount: pieceCount ?? knownPieceCount)
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

    func sendExtendedHandshake() async throws {
        guard !sentExtendedHandshake else { return }
        sentExtendedHandshake = true
        let payload = Data([0]) + BencodeEncoder.encode([
            "m": .dictionary([
                "ut_metadata": .integer(Int64(Self.localMetadataExtensionID)),
                "ut_pex": .integer(Int64(Self.localPexExtensionID))
            ]),
            "p": .integer(0)
        ])
        try await sendMessage(id: 20, payload: payload)
    }

    private func readUntilMetadataHandshake() async throws {
        // The peer's extension handshake (extended id 0) carries its `ut_metadata`
        // id and `metadata_size`, and is sent once, up front. Loop only until we
        // receive it — not until metadata appears — so a reachable peer that
        // simply doesn't have the metadata (a leecher) is abandoned in ~1 RTT
        // instead of pinning the slot for the full I/O timeout. The caller then
        // sees `peerMetadataExtensionID`/`metadataSize` still nil and fails fast.
        let deadline = ContinuousClock.now + .seconds(ioTimeout)
        while !receivedExtendedHandshake {
            try Task.checkCancellation()
            let message = try await readMessage(deadline: deadline)
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

    private func readMetadataPiece(expectedPiece: Int) async throws -> Data {
        // Bounds the whole wait for this piece, so a peer streaming unrelated
        // messages cannot keep the loop alive indefinitely.
        let deadline = ContinuousClock.now + .seconds(ioTimeout)
        while true {
            try Task.checkCancellation()
            let message = try await readMessage(deadline: deadline)
            guard message.id == 20 else { continue }
            guard let extendedID = message.payload.first else { throw PeerWireError.unexpectedMessage }
            if extendedID == 0 {
                handleExtendedMessage(message.payload)
                continue
            }
            // Per BEP 10 the peer tags its metadata reply with the id *we*
            // advertised for `ut_metadata` (not the id it advertised for itself).
            // Route any other extended id (e.g. `ut_pex`) through the normal
            // handler so PEX peers gossiped mid-fetch aren't lost.
            guard extendedID == Self.localMetadataExtensionID else {
                handleExtendedMessage(message.payload)
                continue
            }

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

    func handleExtendedMessage(_ payload: Data) {
        guard let extendedID = payload.first else { return }
        let body = Data(payload.dropFirst())
        switch extendedID {
        case 0:
            handleExtendedHandshake(body)
        case Self.localPexExtensionID:
            // A `ut_pex` message addressed to the id we advertised: fold its gossiped
            // peers in (download-only — we consume `added`, never send our own).
            for peer in Self.parsePexAddedPeers(body) where discoveredPeers.count < Self.maxDiscoveredPeers {
                discoveredPeers.insert(peer)
            }
        default:
            break
        }
    }

    private func handleExtendedHandshake(_ body: Data) {
        receivedExtendedHandshake = true
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

    /// Parses the compact IPv4 `added` list from a bencoded BEP 11 PEX message
    /// body. IPv6 (`added6`) is ignored, matching the IPv4-only tracker/DHT paths.
    static func parsePexAddedPeers(_ body: Data) -> [PeerEndpoint] {
        guard let node = try? BencodeParser(data: body).parse(),
              case let .dictionary(dictionary) = node.value,
              case let .bytes(added)? = dictionary["added"]?.value else {
            return []
        }
        return TrackerClient.parseCompactPeers(added)
    }
}
