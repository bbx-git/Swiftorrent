import Foundation

public enum BencodeValue: Equatable, Sendable {
    case integer(Int64)
    case bytes(Data)
    case list([BencodeNode])
    case dictionary([String: BencodeNode])

    public var stringValue: String? {
        guard case let .bytes(data) = self else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public var intValue: Int64? {
        guard case let .integer(value) = self else { return nil }
        return value
    }
}

public struct BencodeNode: Equatable, Sendable {
    public let value: BencodeValue
    public let range: Range<Data.Index>

    public init(value: BencodeValue, range: Range<Data.Index>) {
        self.value = value
        self.range = range
    }
}

public enum BencodeError: Error, LocalizedError, Equatable {
    case unexpectedEnd
    case invalidToken(UInt8)
    case invalidInteger
    case invalidByteStringLength
    case invalidDictionaryKey
    case trailingData

    public var errorDescription: String? {
        switch self {
        case .unexpectedEnd: "Unexpected end of bencoded data."
        case let .invalidToken(byte): "Invalid bencode token: \(byte)."
        case .invalidInteger: "Invalid bencode integer."
        case .invalidByteStringLength: "Invalid bencode byte string length."
        case .invalidDictionaryKey: "Bencode dictionary keys must be UTF-8 byte strings."
        case .trailingData: "Bencoded payload contains trailing data."
        }
    }
}

public struct BencodeParser: Sendable {
    private let data: Data
    private var index: Data.Index

    public init(data: Data) {
        self.data = data
        self.index = data.startIndex
    }

    public func parse() throws -> BencodeNode {
        var parser = self
        let node = try parser.parseNode()
        guard parser.index == data.endIndex else { throw BencodeError.trailingData }
        return node
    }

    public func parsePrefix() throws -> BencodeNode {
        var parser = self
        return try parser.parseNode()
    }

    private mutating func parseNode() throws -> BencodeNode {
        guard index < data.endIndex else { throw BencodeError.unexpectedEnd }
        let start = index
        let byte = data[index]
        switch byte {
        case UInt8(ascii: "i"):
            data.formIndex(after: &index)
            let value = try parseIntegerUntilTerminator()
            return BencodeNode(value: .integer(value), range: start..<index)
        case UInt8(ascii: "l"):
            data.formIndex(after: &index)
            var values: [BencodeNode] = []
            while try currentByte() != UInt8(ascii: "e") {
                values.append(try parseNode())
            }
            data.formIndex(after: &index)
            return BencodeNode(value: .list(values), range: start..<index)
        case UInt8(ascii: "d"):
            data.formIndex(after: &index)
            var values: [String: BencodeNode] = [:]
            while try currentByte() != UInt8(ascii: "e") {
                let keyNode = try parseByteString()
                guard case let .bytes(keyData) = keyNode.value,
                      let key = String(data: keyData, encoding: .utf8) else {
                    throw BencodeError.invalidDictionaryKey
                }
                values[key] = try parseNode()
            }
            data.formIndex(after: &index)
            return BencodeNode(value: .dictionary(values), range: start..<index)
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            return try parseByteString()
        default:
            throw BencodeError.invalidToken(byte)
        }
    }

    private mutating func parseByteString() throws -> BencodeNode {
        let start = index
        var length = 0
        var foundColon = false

        while index < data.endIndex {
            let byte = data[index]
            if byte == UInt8(ascii: ":") {
                foundColon = true
                data.formIndex(after: &index)
                break
            }
            guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else {
                throw BencodeError.invalidByteStringLength
            }
            let digit = Int(byte - UInt8(ascii: "0"))
            let (scaled, scaledOverflow) = length.multipliedReportingOverflow(by: 10)
            guard !scaledOverflow else { throw BencodeError.invalidByteStringLength }
            let (next, addOverflow) = scaled.addingReportingOverflow(digit)
            guard !addOverflow else { throw BencodeError.invalidByteStringLength }
            length = next
            data.formIndex(after: &index)
        }

        guard foundColon else { throw BencodeError.unexpectedEnd }
        guard length >= 0, data.distance(from: index, to: data.endIndex) >= length else {
            throw BencodeError.unexpectedEnd
        }

        let payloadStart = index
        let payloadEnd = data.index(index, offsetBy: length)
        index = payloadEnd
        return BencodeNode(value: .bytes(Data(data[payloadStart..<payloadEnd])), range: start..<index)
    }

    private mutating func parseIntegerUntilTerminator() throws -> Int64 {
        let start = index
        while index < data.endIndex, data[index] != UInt8(ascii: "e") {
            data.formIndex(after: &index)
        }
        guard index < data.endIndex else { throw BencodeError.unexpectedEnd }
        let integerData = data[start..<index]
        data.formIndex(after: &index)
        guard let text = String(data: integerData, encoding: .ascii),
              let value = Int64(text) else {
            throw BencodeError.invalidInteger
        }
        return value
    }

    private func currentByte() throws -> UInt8 {
        guard index < data.endIndex else { throw BencodeError.unexpectedEnd }
        return data[index]
    }
}

public indirect enum BencodeEncodableValue: Sendable {
    case integer(Int64)
    case bytes(Data)
    case string(String)
    case list([BencodeEncodableValue])
    case dictionary([String: BencodeEncodableValue])
}

public enum BencodeEncoder {
    public static func encode(_ dictionary: [String: BencodeEncodableValue]) -> Data {
        encode(.dictionary(dictionary))
    }

    public static func encode(_ value: BencodeEncodableValue) -> Data {
        switch value {
        case let .integer(integer):
            return Data("i\(integer)e".utf8)
        case let .bytes(data):
            var result = Data("\(data.count):".utf8)
            result.append(data)
            return result
        case let .string(string):
            let data = Data(string.utf8)
            var result = Data("\(data.count):".utf8)
            result.append(data)
            return result
        case let .list(values):
            var result = Data("l".utf8)
            for value in values {
                result.append(encode(value))
            }
            result.append(UInt8(ascii: "e"))
            return result
        case let .dictionary(dictionary):
            var result = Data("d".utf8)
            for key in dictionary.keys.sorted() {
                result.append(encode(.string(key)))
                if let value = dictionary[key] {
                    result.append(encode(value))
                }
            }
            result.append(UInt8(ascii: "e"))
            return result
        }
    }
}
