import Foundation
import SwiftorrentCore
import Testing

@Suite("Core parsing")
struct CoreParsingTests {
    @Test("Bencode parser keeps dictionary ranges")
    func bencodeRanges() throws {
        let data = Data("d4:infod4:name4:testee".utf8)
        let root = try BencodeParser(data: data).parse()
        guard case let .dictionary(dictionary) = root.value,
              let info = dictionary["info"] else {
            Issue.record("Missing info dictionary")
            return
        }
        #expect(Data(data[info.range]) == Data("d4:name4:teste".utf8))
    }

    @Test("Magnet parser accepts hex BTIH")
    func magnetHex() throws {
        let magnet = try MagnetLinkParser().parse("magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=Example")
        #expect(magnet.infoHash.count == 20)
        #expect(magnet.displayName == "Example")
    }

    @Test("Magnet parser keeps HTTP trackers from long links")
    func magnetTrackers() throws {
        let magnet = try MagnetLinkParser().parse(
            "magnet:?xt=urn:btih:6A8F134C989C1ECF961CED4AC0B32CC5B615B287&dn=Example&tr=udp%3A%2F%2Ftracker.example.invalid%3A1337%2Fannounce&tr=http%3A%2F%2Ftracker.example.invalid%3A8080%2Fannounce&tr=https%3A%2F%2Fsecure.example.invalid%2Fannounce"
        )
        #expect(magnet.infoHash.map { String(format: "%02X", $0) }.joined() == "6A8F134C989C1ECF961CED4AC0B32CC5B615B287")
        #expect(magnet.trackers.filter { $0.scheme == "http" || $0.scheme == "https" }.count == 2)
    }

    @Test("Bencode encoder sorts dictionary keys")
    func bencodeEncoder() {
        let encoded = BencodeEncoder.encode([
            "piece": .integer(3),
            "msg_type": .integer(0)
        ])
        #expect(String(data: encoded, encoding: .utf8) == "d8:msg_typei0e5:piecei3ee")
    }
}
