import Foundation

public struct MagnetLink: Equatable, Sendable {
    public let infoHash: Data
    public let displayName: String?
    public let trackers: [URL]
    public let exactSources: [URL]
    public let webSeeds: [URL]

    public init(infoHash: Data, displayName: String?, trackers: [URL], exactSources: [URL] = [], webSeeds: [URL] = []) {
        self.infoHash = infoHash
        self.displayName = displayName
        self.trackers = trackers
        self.exactSources = exactSources
        self.webSeeds = webSeeds
    }
}

public enum MagnetLinkError: Error, LocalizedError, Equatable {
    case invalidScheme
    case missingInfoHash
    case unsupportedInfoHash

    public var errorDescription: String? {
        switch self {
        case .invalidScheme: "Magnet links must start with magnet:."
        case .missingInfoHash: "The magnet link is missing an xt=urn:btih info hash."
        case .unsupportedInfoHash: "Only SHA-1 BTIH magnet hashes are supported."
        }
    }
}

public struct MagnetLinkParser: Sendable {
    public init() {}

    public func parse(_ text: String) throws -> MagnetLink {
        guard let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme == "magnet" else {
            throw MagnetLinkError.invalidScheme
        }

        var displayName: String?
        var trackers: [URL] = []
        var exactSources: [URL] = []
        var webSeeds: [URL] = []
        var infoHash: Data?

        for item in components.queryItems ?? [] {
            switch item.name {
            case "dn":
                displayName = item.value
            case "tr":
                if let value = item.value, let url = URL(string: value) {
                    trackers.append(url)
                }
            case "xs":
                if let value = item.value, let url = URL(string: value), url.isHTTPOrHTTPS {
                    exactSources.append(url)
                }
            case "ws":
                if let value = item.value, let url = URL(string: value), url.isHTTPOrHTTPS {
                    webSeeds.append(url)
                }
            case "xt":
                guard let value = item.value else { continue }
                if value.lowercased().hasPrefix("urn:btih:") {
                    let raw = String(value.dropFirst("urn:btih:".count))
                    infoHash = try decodeInfoHash(raw)
                }
            default:
                continue
            }
        }

        guard let infoHash else { throw MagnetLinkError.missingInfoHash }
        return MagnetLink(infoHash: infoHash, displayName: displayName, trackers: trackers, exactSources: exactSources, webSeeds: webSeeds)
    }

    private func decodeInfoHash(_ text: String) throws -> Data {
        if text.count == 40, let data = Data(hexEncoded: text) {
            return data
        }
        if text.count == 32, let data = Data(base32BTIHEncoded: text) {
            return data
        }
        throw MagnetLinkError.unsupportedInfoHash
    }
}

private extension URL {
    var isHTTPOrHTTPS: Bool {
        scheme?.lowercased() == "http" || scheme?.lowercased() == "https"
    }
}

extension Data {
    init?(hexEncoded text: String) {
        guard text.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = Data(bytes)
    }

    init?(base32BTIHEncoded text: String) {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        let lookup = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { ($1, UInt8($0)) })
        var buffer = 0
        var bitsLeft = 0
        var bytes: [UInt8] = []

        for char in text.uppercased() {
            guard let value = lookup[char] else { return nil }
            buffer = (buffer << 5) | Int(value)
            bitsLeft += 5
            if bitsLeft >= 8 {
                bytes.append(UInt8((buffer >> (bitsLeft - 8)) & 0xFF))
                bitsLeft -= 8
            }
        }

        guard bytes.count == 20 else { return nil }
        self = Data(bytes)
    }
}
