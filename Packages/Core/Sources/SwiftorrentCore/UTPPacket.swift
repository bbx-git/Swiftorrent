import Foundation

/// A BEP 29 (uTP) packet: the 20-byte header, an optional selective-ACK
/// extension, then the payload. All integers are big-endian.
struct UTPPacket: Equatable, Sendable {
    enum Kind: UInt8, Sendable {
        case data = 0
        case fin = 1
        case state = 2
        case reset = 3
        case syn = 4
    }

    static let headerSize = 20
    static let version: UInt8 = 1
    private static let selectiveAckExtension: UInt8 = 1

    var kind: Kind
    var connectionID: UInt16
    var timestamp: UInt32
    var timestampDifference: UInt32
    var windowSize: UInt32
    var sequenceNumber: UInt16
    var ackNumber: UInt16
    /// Selective-ACK bitmask bytes (length a non-zero multiple of 4), or `nil`.
    var selectiveAck: [UInt8]?
    var payload: Data

    init(
        kind: Kind,
        connectionID: UInt16,
        timestamp: UInt32 = 0,
        timestampDifference: UInt32 = 0,
        windowSize: UInt32 = 0,
        sequenceNumber: UInt16 = 0,
        ackNumber: UInt16 = 0,
        selectiveAck: [UInt8]? = nil,
        payload: Data = Data()
    ) {
        self.kind = kind
        self.connectionID = connectionID
        self.timestamp = timestamp
        self.timestampDifference = timestampDifference
        self.windowSize = windowSize
        self.sequenceNumber = sequenceNumber
        self.ackNumber = ackNumber
        self.selectiveAck = selectiveAck
        self.payload = payload
    }

    func encoded() -> Data {
        var out = Data()
        out.append(kind.rawValue << 4 | Self.version)
        out.append(selectiveAck == nil ? 0 : Self.selectiveAckExtension)
        out.append(contentsOf: connectionID.bigEndianBytes)
        out.append(contentsOf: timestamp.bigEndianBytes)
        out.append(contentsOf: timestampDifference.bigEndianBytes)
        out.append(contentsOf: windowSize.bigEndianBytes)
        out.append(contentsOf: sequenceNumber.bigEndianBytes)
        out.append(contentsOf: ackNumber.bigEndianBytes)
        if let selectiveAck {
            out.append(0) // no further extension
            out.append(UInt8(selectiveAck.count))
            out.append(contentsOf: selectiveAck)
        }
        out.append(payload)
        return out
    }

    /// Returns `nil` for anything that is not a well-formed version-1 packet.
    init?(_ datagram: Data) {
        let bytes = [UInt8](datagram)
        guard bytes.count >= Self.headerSize,
              bytes[0] & 0x0F == Self.version,
              let kind = Kind(rawValue: bytes[0] >> 4) else { return nil }

        var selectiveAck: [UInt8]?
        var next = bytes[1]
        var offset = Self.headerSize
        while next != 0 {
            guard offset + 2 <= bytes.count else { return nil }
            let current = next
            next = bytes[offset]
            let length = Int(bytes[offset + 1])
            offset += 2
            guard offset + length <= bytes.count else { return nil }
            if current == Self.selectiveAckExtension {
                guard length >= 4, length % 4 == 0 else { return nil }
                selectiveAck = Array(bytes[offset..<offset + length])
            }
            offset += length
        }

        self.kind = kind
        connectionID = UInt16(bigEndian: bytes, at: 2)
        timestamp = UInt32(bigEndian: bytes, at: 4)
        timestampDifference = UInt32(bigEndian: bytes, at: 8)
        windowSize = UInt32(bigEndian: bytes, at: 12)
        sequenceNumber = UInt16(bigEndian: bytes, at: 16)
        ackNumber = UInt16(bigEndian: bytes, at: 18)
        self.selectiveAck = selectiveAck
        payload = Data(bytes[offset...])
    }
}

private extension UInt16 {
    var bigEndianBytes: [UInt8] { [UInt8(self >> 8), UInt8(self & 0xFF)] }

    init(bigEndian bytes: [UInt8], at offset: Int) {
        self = UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }
}

private extension UInt32 {
    var bigEndianBytes: [UInt8] {
        [UInt8(self >> 24), UInt8((self >> 16) & 0xFF), UInt8((self >> 8) & 0xFF), UInt8(self & 0xFF)]
    }

    init(bigEndian bytes: [UInt8], at offset: Int) {
        self = UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }
}
