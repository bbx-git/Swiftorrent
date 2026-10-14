import Foundation
@testable import SwiftorrentCore
import Testing

/// Deterministic mutation fuzzing: every parser that reads bytes from the network
/// or a file must reject garbage with an error, never trap, and finish quickly.
/// A trap would abort the whole test process, so a pass means none occurred.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func mutate(_ seed: Data, using rng: inout SplitMix64) -> Data {
    var bytes = [UInt8](seed)
    let rounds = Int.random(in: 1...6, using: &rng)
    for _ in 0..<rounds {
        switch Int.random(in: 0..<5, using: &rng) {
        case 0 where !bytes.isEmpty:
            bytes[Int.random(in: 0..<bytes.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng)
        case 1 where !bytes.isEmpty:
            bytes.removeSubrange(Int.random(in: 0..<bytes.count, using: &rng)...)
        case 2:
            let at = Int.random(in: 0...bytes.count, using: &rng)
            bytes.insert(contentsOf: (0..<Int.random(in: 1...8, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }, at: at)
        case 3 where bytes.count > 1:
            let from = Int.random(in: 0..<bytes.count, using: &rng)
            let to = Int.random(in: from..<bytes.count, using: &rng)
            bytes.insert(contentsOf: bytes[from...to], at: Int.random(in: 0...bytes.count, using: &rng))
        default:
            // Splice in a bencode-shaped token to reach deeper parser states.
            let token = ["i", "l", "d", "e", ":", "9999999999:", "i-1e", "0:"].randomElement(using: &rng)!
            bytes.insert(contentsOf: Array(token.utf8), at: Int.random(in: 0...bytes.count, using: &rng))
        }
    }
    return Data(bytes)
}

@Suite("Fuzz")
struct FuzzTests {
    private let iterations = 20_000

    private func fixtureTorrent() throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/big-buck-bunny.torrent")
        return try Data(contentsOf: url)
    }

    @Test("Bencode and torrent metainfo parsers survive mutated torrents")
    func torrentParsers() throws {
        let seed = try fixtureTorrent()
        var rng = SplitMix64(state: 1)
        var parsed = 0
        for _ in 0..<iterations {
            let input = mutate(seed, using: &rng)
            _ = try? BencodeParser(data: input).parse()
            if (try? TorrentMetainfoParser().parse(data: input)) != nil { parsed += 1 }
        }
        // Sanity: the harness really exercises both outcomes.
        #expect(parsed < iterations)
    }

    @Test("Info dictionaries from peers survive mutation")
    func infoDictionaryParser() {
        let info = BencodeEncoder.encode([
            "name": .string("x"),
            "piece length": .integer(16_384),
            "pieces": .bytes(Data(repeating: 1, count: 40)),
            "files": .list([
                .dictionary(["length": .integer(20_000), "path": .list([.string("a"), .string("b")])]),
                .dictionary(["length": .integer(5_000), "path": .list([.string("c")])])
            ])
        ])
        var rng = SplitMix64(state: 2)
        for _ in 0..<iterations {
            _ = try? TorrentMetainfoParser().parseInfoDictionary(data: mutate(info, using: &rng), announceURLs: [])
        }
    }

    @Test("uTP packets and the connection state machine survive mutated datagrams")
    func utp() {
        var rng = SplitMix64(state: 3)
        let valid = UTPPacket(
            kind: .data, connectionID: 100, timestamp: 5, timestampDifference: 1, windowSize: 65_536,
            sequenceNumber: 2, ackNumber: 1, selectiveAck: [0xFF, 0, 0, 0], payload: Data(repeating: 9, count: 40)
        ).encoded()

        let core = UTPConnectionCore(connectionID: 100)
        _ = core.open(now: 0)
        _ = core.receive(UTPPacket(kind: .state, connectionID: 100, windowSize: 65_536, sequenceNumber: 1, ackNumber: 1), now: 10)
        var now: UInt64 = 20
        for _ in 0..<iterations {
            let datagram = mutate(valid, using: &rng)
            if let packet = UTPPacket(datagram) {
                now += 1_000
                _ = core.receive(packet, now: now)
                _ = core.tick(now: now + 2_000_000)
                _ = core.read(maxBytes: 4_096, now: now)
            }
        }
    }

    @Test("DHT, PEX, compact-peer and bitfield parsers survive mutation")
    func peerListParsers() {
        let dhtReply = BencodeEncoder.encode([
            "t": .bytes(Data([1, 2])),
            "y": .string("r"),
            "r": .dictionary([
                "id": .bytes(Data(repeating: 3, count: 20)),
                "values": .list([.bytes(Data([1, 2, 3, 4, 0x1A, 0xE1]))]),
                "nodes": .bytes(Data(repeating: 7, count: 52))
            ])
        ])
        let pex = BencodeEncoder.encode(["added": .bytes(Data(repeating: 5, count: 24))])
        var rng = SplitMix64(state: 4)
        for _ in 0..<iterations {
            _ = try? DHTClient.parseGetPeersResponse(mutate(dhtReply, using: &rng), expectedTransactionID: Data([1, 2]))
            _ = PeerWireClient.parsePexAddedPeers(mutate(pex, using: &rng))
            let random = Data((0..<Int.random(in: 0...200, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) })
            _ = TrackerClient.parseCompactPeers(random)
            _ = DHTClient.parseCompactIPv4Nodes(random)
            _ = PeerWireClient.parseBitfield(random, pieceCount: Int.random(in: 0...400, using: &rng))
        }
    }

    @Test("Magnet links survive mutation")
    func magnetLinks() {
        let seed = "magnet:?xt=urn:btih:c12fe1c06bba254a9dc9f519b335aa7c1367a88a&dn=Name+%26+More&tr=udp%3A%2F%2Ft.example%3A80&xs=http%3A%2F%2Fh.example%2Fa.torrent&ws=https%3A%2F%2Fh.example%2F"
        var rng = SplitMix64(state: 5)
        for _ in 0..<iterations {
            let mutated = mutate(Data(seed.utf8), using: &rng)
            _ = try? MagnetLinkParser().parse(String(decoding: mutated, as: UTF8.self))
        }
    }
}
