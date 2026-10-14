import Foundation
@testable import SwiftorrentCore
import Testing

@Suite struct UTPPacketTests {
    @Test func synEncodesToTheDocumentedLayout() {
        let packet = UTPPacket(
            kind: .syn, connectionID: 0x1234, timestamp: 0x0102_0304,
            timestampDifference: 0, windowSize: 0x0001_0000, sequenceNumber: 1, ackNumber: 0
        )
        let bytes = [UInt8](packet.encoded())
        #expect(bytes == [
            0x41, 0x00, 0x12, 0x34,
            0x01, 0x02, 0x03, 0x04,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x01, 0x00, 0x00,
            0x00, 0x01, 0x00, 0x00,
        ])
    }

    @Test func roundTripsWithPayloadAndSelectiveAck() {
        let packet = UTPPacket(
            kind: .data, connectionID: 7, timestamp: 99, timestampDifference: 5,
            windowSize: 1 << 20, sequenceNumber: 65535, ackNumber: 3,
            selectiveAck: [0b0000_0101, 0, 0, 0x80],
            payload: Data("hello".utf8)
        )
        #expect(UTPPacket(packet.encoded()) == packet)
    }

    @Test func parsesEveryKind() {
        for kind in [UTPPacket.Kind.data, .fin, .state, .reset, .syn] {
            let packet = UTPPacket(kind: kind, connectionID: 1)
            #expect(UTPPacket(packet.encoded())?.kind == kind)
        }
    }

    @Test func skipsUnknownExtensionsAndKeepsSelectiveAck() {
        // ext 9 (4 bytes) -> ext 1 selective ack (4 bytes) -> payload "x"
        var bytes = [UInt8](UTPPacket(kind: .state, connectionID: 1).encoded())
        bytes[1] = 9
        bytes += [1, 4, 1, 2, 3, 4]
        bytes += [0, 4, 0xAA, 0xBB, 0xCC, 0xDD]
        bytes += [0x78]
        let parsed = UTPPacket(Data(bytes))
        #expect(parsed?.selectiveAck == [0xAA, 0xBB, 0xCC, 0xDD])
        #expect(parsed?.payload == Data([0x78]))
    }

    @Test func rejectsMalformedDatagrams() {
        #expect(UTPPacket(Data()) == nil)
        #expect(UTPPacket(Data(repeating: 0, count: 19)) == nil)

        var wrongVersion = [UInt8](UTPPacket(kind: .data, connectionID: 1).encoded())
        wrongVersion[0] = 0x02
        #expect(UTPPacket(Data(wrongVersion)) == nil)

        var unknownType = [UInt8](UTPPacket(kind: .data, connectionID: 1).encoded())
        unknownType[0] = 0x51
        #expect(UTPPacket(Data(unknownType)) == nil)

        // Extension announced but truncated, or with a length that overruns.
        var truncated = [UInt8](UTPPacket(kind: .data, connectionID: 1).encoded())
        truncated[1] = 1
        #expect(UTPPacket(Data(truncated)) == nil)
        #expect(UTPPacket(Data(truncated + [0, 8, 1, 2])) == nil)

        // Selective ack length must be a non-zero multiple of 4.
        #expect(UTPPacket(Data(truncated + [0, 3, 1, 2, 3])) == nil)
    }
}
