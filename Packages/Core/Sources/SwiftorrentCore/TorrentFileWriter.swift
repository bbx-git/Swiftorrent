import CryptoKit
import Foundation

/// Writes torrent pieces and file ranges to disk, verifies pieces against their
/// SHA-1 hashes, and promotes completed `.tor` partials to their final names.
/// All on-disk paths are confined to `destination`; with `stripRootDirectory`
/// the shared top-level torrent folder is dropped from the output location only.
struct TorrentFileWriter: Sendable {
    let metainfo: TorrentMetainfo
    let destination: URL
    /// When true, the shared top-level torrent folder is removed from every
    /// output path so files land directly in `destination` rather than an
    /// enclosing `<name>/` directory. This affects only the on-disk location;
    /// `metainfo.files[].path` stays torrent-relative so web-seed source URLs
    /// and the protocol piece map remain correct.
    let stripRootDirectory: Bool
    private let partialExtension = "tor"

    init(metainfo: TorrentMetainfo, destination: URL, stripRootDirectory: Bool = false) {
        self.metainfo = metainfo
        self.destination = destination
        self.stripRootDirectory = stripRootDirectory
    }

    /// Writes a raw byte range of a single file into its `.tor` partial. Used by
    /// the web-seed path to fill the slice of a boundary piece that belongs to a
    /// deselected neighbor file, so the shared piece can still be SHA-1 verified.
    func writeFileChunk(_ chunk: Data, to file: TorrentFile, atFileOffset offset: Int64) throws {
        try write(chunk: chunk, to: file, at: offset)
    }

    func verifiedPieces() throws -> Set<Int> {
        try verifiedPieces(among: metainfo.pieceHashes.indices)
    }

    /// Verifies only `indices` against their expected hashes, returning the
    /// subset that is present on disk and matches. Reading + SHA-1 hashing a
    /// piece is expensive, so callers that already hold a cached verified set
    /// pass just the still-unverified indices here to refresh it after new
    /// pieces are written, instead of re-hashing the entire dataset.
    func verifiedPieces<S: Sequence>(among indices: S) throws -> Set<Int> where S.Element == Int {
        var verified = Set<Int>()
        for pieceIndex in indices {
            let length = pieceLength(for: pieceIndex)
            guard let piece = try read(pieceIndex: pieceIndex, length: length),
                  Data(Insecure.SHA1.hash(data: piece)) == metainfo.pieceHashes[pieceIndex] else {
                continue
            }
            verified.insert(pieceIndex)
        }
        return verified
    }

    func write(piece: Data, pieceIndex: Int) throws {
        let pieceStart = Int64(pieceIndex * metainfo.pieceLength)
        var remaining = piece
        var offsetInTorrent = pieceStart

        for file in metainfo.files {
            let fileStart = metainfo.files.prefix(file.id).reduce(Int64(0)) { $0 + $1.length }
            let fileEnd = fileStart + file.length
            guard offsetInTorrent < fileEnd, offsetInTorrent + Int64(remaining.count) > fileStart else {
                continue
            }

            let localStart = max(offsetInTorrent, fileStart)
            let localEnd = min(offsetInTorrent + Int64(remaining.count), fileEnd)
            let count = Int(localEnd - localStart)
            let sourceOffset = Int(localStart - offsetInTorrent)
            let chunkStart = remaining.index(remaining.startIndex, offsetBy: sourceOffset)
            let chunkEnd = remaining.index(chunkStart, offsetBy: count)
            let chunk = Data(remaining[chunkStart..<chunkEnd])
            try write(chunk: chunk, to: file, at: localStart - fileStart)
            remaining.removeFirst(sourceOffset + count)
            offsetInTorrent = localEnd
            if remaining.isEmpty { break }
        }
    }

    func finalize() throws {
        try finalize(selectedFileIDs: Set(metainfo.files.map(\.id)))
    }

    /// Promotes the selected files' `.tor` partials to their final names. A
    /// deselected file may still hold a small `.tor` partial of bytes from a
    /// boundary piece it shares with a selected neighbor; those are removed so
    /// the destination ends up with exactly the selected files.
    func finalize(selectedFileIDs: Set<Int>) throws {
        for file in metainfo.files {
            let partialURL = try outputURL(for: file, partial: true)
            guard FileManager.default.fileExists(atPath: partialURL.path) else {
                continue
            }

            guard selectedFileIDs.contains(file.id) else {
                try? FileManager.default.removeItem(at: partialURL)
                continue
            }

            let finalURL = try outputURL(for: file, partial: false)
            try FileManager.default.createDirectory(at: finalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: finalURL.path) {
                try FileManager.default.removeItem(at: finalURL)
            }
            try FileManager.default.moveItem(at: partialURL, to: finalURL)
        }
    }

    /// Determines where an interrupted web-seed download of `file` should resume.
    /// Returns the URL to append to and the byte offset already on disk, so the
    /// caller can issue an HTTP `Range: bytes=offset-` request instead of
    /// refetching the whole file. Behavior by existing state:
    /// - Partial `.tor` present and not oversized → resume from its length.
    /// - Partial present but larger than `file.length` (corrupt) → truncate, start at 0.
    /// - No partial but a completed final file → report `file.length` so the
    ///   caller can skip the fetch entirely (no wasteful copy).
    /// - Nothing present → fresh empty partial, start at 0.
    func partialFileResumeOffset(for file: TorrentFile) throws -> (url: URL, offset: Int64) {
        let partialURL = try outputURL(for: file, partial: true)
        let finalURL = try outputURL(for: file, partial: false)
        try FileManager.default.createDirectory(at: partialURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: partialURL.path) {
            let size = try fileSize(at: partialURL)
            if size > file.length {
                try FileManager.default.removeItem(at: partialURL)
                FileManager.default.createFile(atPath: partialURL.path, contents: nil)
                return (partialURL, 0)
            }
            return (partialURL, size)
        }

        if FileManager.default.fileExists(atPath: finalURL.path),
           try fileSize(at: finalURL) >= file.length {
            return (finalURL, file.length)
        }

        FileManager.default.createFile(atPath: partialURL.path, contents: nil)
        return (partialURL, 0)
    }

    private func fileSize(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }

    func read(pieceIndex: Int, length: Int) throws -> Data? {
        let pieceStart = Int64(pieceIndex * metainfo.pieceLength)
        var result = Data()
        result.reserveCapacity(length)
        let pieceEnd = pieceStart + Int64(length)

        for file in metainfo.files {
            let fileStart = metainfo.files.prefix(file.id).reduce(Int64(0)) { $0 + $1.length }
            let fileEnd = fileStart + file.length
            guard pieceStart < fileEnd, pieceEnd > fileStart else {
                continue
            }

            let localStart = max(pieceStart, fileStart)
            let localEnd = min(pieceEnd, fileEnd)
            let count = Int(localEnd - localStart)
            let chunk = try readChunk(from: file, at: localStart - fileStart, count: count)
            guard let chunk, chunk.count == count else {
                return nil
            }
            result.append(chunk)
        }

        return result.count == length ? result : nil
    }

    private func write(chunk: Data, to file: TorrentFile, at offset: Int64) throws {
        let url = try outputURL(for: file, partial: true)
        let finalURL = try outputURL(for: file, partial: false)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            if FileManager.default.fileExists(atPath: finalURL.path) {
                try FileManager.default.copyItem(at: finalURL, to: url)
            } else {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: chunk)
    }

    private func readChunk(from file: TorrentFile, at offset: Int64, count: Int) throws -> Data? {
        let partialURL = try outputURL(for: file, partial: true)
        let finalURL = try outputURL(for: file, partial: false)
        let url = FileManager.default.fileExists(atPath: partialURL.path) ? partialURL : finalURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: count)
    }

    private func pieceLength(for index: Int) -> Int {
        if index == metainfo.pieceHashes.count - 1 {
            let consumed = Int64(index * metainfo.pieceLength)
            return Int(metainfo.totalSize - consumed)
        }
        return metainfo.pieceLength
    }

    private func outputURL(for file: TorrentFile, partial: Bool) throws -> URL {
        let destinationURL = destination.standardizedFileURL
        let relativePath = stripRootDirectory ? Self.strippingRootDirectory(file.path) : file.path
        let finalURL = destinationURL.appendingPathComponent(relativePath)
        let outputURL = (partial ? finalURL.appendingPathExtension(partialExtension) : finalURL).standardizedFileURL
        let destinationPath = destinationURL.path
        let outputPath = outputURL.path
        guard outputPath == destinationPath || outputPath.hasPrefix(destinationPath + "/") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        return outputURL
    }

    /// Drops the leading path component (the shared torrent folder) from a
    /// multi-file torrent-relative path. Single-component paths are unchanged.
    static func strippingRootDirectory(_ path: String) -> String {
        var components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count > 1 else { return path }
        components.removeFirst()
        return components.joined(separator: "/")
    }
}
