import CryptoKit
import Foundation

public struct TorrentFile: Identifiable, Equatable, Sendable {
    public let id: Int
    public let path: String
    public let length: Int64

    public init(id: Int, path: String, length: Int64) {
        self.id = id
        self.path = path
        self.length = length
    }
}

public struct TorrentMetainfo: Equatable, Sendable {
    public let name: String
    public let announceURLs: [URL]
    public let files: [TorrentFile]
    public let pieceLength: Int
    public let pieceHashes: [Data]
    public let totalSize: Int64
    public let infoHash: Data
    public let infoDictionaryData: Data

    public var displaySize: String {
        ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }

    public init(
        name: String,
        announceURLs: [URL],
        files: [TorrentFile],
        pieceLength: Int,
        pieceHashes: [Data],
        totalSize: Int64,
        infoHash: Data,
        infoDictionaryData: Data
    ) {
        self.name = name
        self.announceURLs = announceURLs
        self.files = files
        self.pieceLength = pieceLength
        self.pieceHashes = pieceHashes
        self.totalSize = totalSize
        self.infoHash = infoHash
        self.infoDictionaryData = infoDictionaryData
    }
}

public enum TorrentMetainfoError: Error, LocalizedError, Equatable {
    case rootIsNotDictionary
    case missingInfoDictionary
    case missingName
    case missingPieceLength
    case invalidPieces
    case missingLength

    public var errorDescription: String? {
        switch self {
        case .rootIsNotDictionary: "The torrent root is not a bencoded dictionary."
        case .missingInfoDictionary: "The torrent is missing its info dictionary."
        case .missingName: "The torrent info dictionary is missing a name."
        case .missingPieceLength: "The torrent info dictionary is missing a piece length."
        case .invalidPieces: "The torrent contains invalid piece hashes."
        case .missingLength: "The torrent is missing file length data."
        }
    }
}

public struct TorrentMetainfoParser: Sendable {
    public init() {}

    public func parse(data: Data) throws -> TorrentMetainfo {
        let rootNode = try BencodeParser(data: data).parse()
        guard case let .dictionary(root) = rootNode.value else {
            throw TorrentMetainfoError.rootIsNotDictionary
        }
        guard let infoNode = root["info"],
              case let .dictionary(info) = infoNode.value else {
            throw TorrentMetainfoError.missingInfoDictionary
        }

        return try parseInfoDictionary(infoNode: infoNode, info: info, announceURLs: parseAnnounces(root: root), preferredName: nil, sourceData: data)
    }

    public func parseInfoDictionary(data: Data, announceURLs: [URL], preferredName: String? = nil) throws -> TorrentMetainfo {
        let infoNode = try BencodeParser(data: data).parse()
        guard case let .dictionary(info) = infoNode.value else {
            throw TorrentMetainfoError.missingInfoDictionary
        }
        return try parseInfoDictionary(infoNode: infoNode, info: info, announceURLs: announceURLs, preferredName: preferredName, sourceData: data)
    }

    private func parseInfoDictionary(
        infoNode: BencodeNode,
        info: [String: BencodeNode],
        announceURLs: [URL],
        preferredName: String?,
        sourceData: Data
    ) throws -> TorrentMetainfo {
        guard let name = info["name"]?.value.stringValue ?? info["name.utf-8"]?.value.stringValue ?? preferredName else {
            throw TorrentMetainfoError.missingName
        }
        guard let pieceLengthValue = info["piece length"]?.value.intValue,
              pieceLengthValue > 0 else {
            throw TorrentMetainfoError.missingPieceLength
        }
        guard case let .bytes(pieceBlob)? = info["pieces"]?.value,
              pieceBlob.count.isMultiple(of: 20) else {
            throw TorrentMetainfoError.invalidPieces
        }

        let files = try parseFiles(info: info, name: name)
        let totalSize = files.reduce(Int64(0)) { $0 + $1.length }
        let infoData = Data(sourceData[infoNode.range])
        let digest = Insecure.SHA1.hash(data: infoData)
        var pieces: [Data] = []
        pieces.reserveCapacity(pieceBlob.count / 20)
        var pieceOffset = pieceBlob.startIndex
        while pieceOffset < pieceBlob.endIndex {
            let nextOffset = pieceBlob.index(pieceOffset, offsetBy: 20)
            pieces.append(Data(pieceBlob[pieceOffset..<nextOffset]))
            pieceOffset = nextOffset
        }

        return TorrentMetainfo(
            name: name,
            announceURLs: announceURLs,
            files: files,
            pieceLength: Int(pieceLengthValue),
            pieceHashes: pieces,
            totalSize: totalSize,
            infoHash: Data(digest),
            infoDictionaryData: infoData
        )
    }

    private func parseAnnounces(root: [String: BencodeNode]) -> [URL] {
        var urls: [URL] = []
        if let announce = root["announce"]?.value.stringValue, let url = URL(string: announce) {
            urls.append(url)
        }
        if case let .list(tiers)? = root["announce-list"]?.value {
            for tier in tiers {
                guard case let .list(entries) = tier.value else { continue }
                for entry in entries {
                    if let text = entry.value.stringValue, let url = URL(string: text) {
                        urls.append(url)
                    }
                }
            }
        }
        return Array(Set(urls)).sorted { $0.absoluteString < $1.absoluteString }
    }

    private func parseFiles(info: [String: BencodeNode], name: String) throws -> [TorrentFile] {
        if let length = info["length"]?.value.intValue {
            return [TorrentFile(id: 0, path: sanitizePath(components: [name], fallback: "download"), length: length)]
        }

        guard case let .list(fileNodes)? = info["files"]?.value else {
            throw TorrentMetainfoError.missingLength
        }

        let rootName = sanitizePathComponent(name) ?? "download"
        return try fileNodes.enumerated().map { index, node in
            guard case let .dictionary(fileDictionary) = node.value,
                  let length = fileDictionary["length"]?.value.intValue,
                  case let .list(pathNodes)? = fileDictionary["path.utf-8"]?.value ?? fileDictionary["path"]?.value else {
                throw TorrentMetainfoError.missingLength
            }
            let components = pathNodes.compactMap(\.value.stringValue)
            let filePath = sanitizePath(components: components, fallback: "file-\(index)")
            return TorrentFile(id: index, path: ([rootName, filePath]).joined(separator: "/"), length: length)
        }
    }

    private func sanitizePath(components: [String], fallback: String) -> String {
        let sanitized = components.compactMap(sanitizePathComponent)
        guard !sanitized.isEmpty else { return fallback }
        return sanitized.joined(separator: "/")
    }

    private func sanitizePathComponent(_ component: String) -> String? {
        let cleaned = component
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty,
              cleaned != ".",
              cleaned != ".." else {
            return nil
        }
        return cleaned
    }
}
