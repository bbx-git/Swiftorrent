import Foundation

/// Downloads torrent data over HTTP(S) web seeds (BEP 19, GetRight style).
/// A full selection streams every file whole; a partial selection streams only
/// the selected files and then range-fetches the deselected-neighbor slices of
/// any shared boundary piece so those pieces still SHA-1 verify. `finalize`
/// later drops the neighbor partials, leaving exactly the selected files.
struct WebSeedDownloader: Sendable {
    let session: URLSession
    var rateLimiter: RateLimiter? = nil
    /// Size of one range request when a file is fetched over several connections.
    var segmentSize: Int64 = 1 << 20
    /// Concurrent range requests per file; 1 disables segmenting.
    var maxConnections = 8

    /// Raised by the segmented path when the file should go through the single
    /// stream instead (server ignores `Range`, or the file is too small to split).
    private struct UseSequentialStream: Error {}

    /// Streams every file in `metainfo` whole from the first working web seed.
    func downloadAll(
        metainfo: TorrentMetainfo,
        writer: TorrentFileWriter,
        mapper: FileProgressMapper,
        initialDownloaded: Int64,
        totalBytes: Int64,
        progress: @Sendable @escaping (TorrentDownloadProgress) async -> Void
    ) async throws {
        try await stream(
            files: metainfo.files,
            writer: writer,
            mapper: mapper,
            webSeedURLs: metainfo.webSeedURLs,
            initialDownloaded: initialDownloaded,
            totalBytes: totalBytes,
            progress: progress,
            afterFiles: { _ in }
        )
    }

    /// Streams the selected files whole, then fills the deselected-neighbor
    /// slices of any shared boundary piece so the piece can be verified.
    func downloadSelected(
        metainfo: TorrentMetainfo,
        writer: TorrentFileWriter,
        layout: TorrentLayout,
        selection: Set<Int>,
        selectablePieces: Set<Int>,
        mapper: FileProgressMapper,
        initialDownloaded: Int64,
        totalBytes: Int64,
        progress: @Sendable @escaping (TorrentDownloadProgress) async -> Void
    ) async throws {
        let selectedFiles = metainfo.files.filter { selection.contains($0.id) }
        let neighborSlices = boundaryNeighborSlices(metainfo: metainfo, layout: layout, selectablePieces: selectablePieces, selection: selection)

        try await stream(
            files: selectedFiles,
            writer: writer,
            mapper: mapper,
            webSeedURLs: metainfo.webSeedURLs,
            initialDownloaded: initialDownloaded,
            totalBytes: totalBytes,
            progress: progress,
            afterFiles: { webSeedURL in
                // Fill the deselected-neighbor slices of any shared boundary pieces.
                for slice in neighborSlices {
                    try Task.checkCancellation()
                    let sourceURL = webSeedURL.appendingTorrentRelativePath(slice.file.path)
                    let data = try await self.fetchRange(from: sourceURL, offset: slice.fileOffset, length: slice.length)
                    try writer.writeFileChunk(data, to: slice.file, atFileOffset: slice.fileOffset)
                    await self.rateLimiter?.consume(data.count)
                }
            }
        )
    }

    /// Shared driver: tries each web seed in turn, streaming `files` whole and
    /// then running `afterFiles` (used to backfill boundary slices). Fails over
    /// to the next seed on any error; rethrows the last error if all seeds fail.
    private func stream(
        files: [TorrentFile],
        writer: TorrentFileWriter,
        mapper: FileProgressMapper,
        webSeedURLs: [URL],
        initialDownloaded: Int64,
        totalBytes: Int64,
        progress: @Sendable @escaping (TorrentDownloadProgress) async -> Void,
        afterFiles: @Sendable (URL) async throws -> Void
    ) async throws {
        var lastError: Error?
        for webSeedURL in webSeedURLs {
            try Task.checkCancellation()
            do {
                var downloadedBytes = initialDownloaded
                var perFileBytes = [Int64](repeating: 0, count: mapper.metainfo.files.count)
                for file in files {
                    try Task.checkCancellation()
                    let sourceURL = webSeedURL.appendingTorrentRelativePath(file.path)
                    let fileBase = downloadedBytes
                    let baseFileBytes = perFileBytes
                    let snapshot: @Sendable (Int64) -> [TorrentFileProgress] = { currentFileBytes in
                        var bytes = baseFileBytes
                        if file.id < bytes.count { bytes[file.id] = min(currentFileBytes, file.length) }
                        return mapper.snapshot(perFileBytes: bytes)
                    }
                    await progress(TorrentDownloadProgress(status: "Downloading from web seed: \(file.path)", downloadedBytes: downloadedBytes, totalBytes: totalBytes, files: snapshot(0)))
                    downloadedBytes += try await downloadFile(from: sourceURL, file: file, writer: writer, progressDownloadedBytes: downloadedBytes) { currentDownloadedBytes in
                        await progress(TorrentDownloadProgress(status: "Downloading from web seed: \(file.path)", downloadedBytes: currentDownloadedBytes, totalBytes: totalBytes, files: snapshot(currentDownloadedBytes - fileBase)))
                    }
                    if file.id < perFileBytes.count { perFileBytes[file.id] = file.length }
                }
                try await afterFiles(webSeedURL)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError ?? TrackerClientError.invalidResponse
    }

    private struct NeighborSlice {
        let file: TorrentFile
        let fileOffset: Int64
        let length: Int64
    }

    /// For each selectable piece, the byte ranges that fall inside a deselected
    /// file. These are exactly the boundary slices that whole-file selected
    /// downloads leave missing but a shared piece needs to verify.
    private func boundaryNeighborSlices(metainfo: TorrentMetainfo, layout: TorrentLayout, selectablePieces: Set<Int>, selection: Set<Int>) -> [NeighborSlice] {
        var slices: [NeighborSlice] = []
        for piece in selectablePieces {
            let pieceRange = layout.range(ofPiece: piece)
            for file in metainfo.files where !selection.contains(file.id) {
                let fileRange = layout.range(ofFile: file.id)
                let low = max(pieceRange.lowerBound, fileRange.lowerBound)
                let high = min(pieceRange.upperBound, fileRange.upperBound)
                guard high > low else { continue }
                slices.append(NeighborSlice(file: file, fileOffset: low - fileRange.lowerBound, length: high - low))
            }
        }
        return slices
    }

    /// Fetches `length` bytes of a file starting at `offset` over HTTP. Honors a
    /// `206` range response; if the server ignores the range and returns the
    /// whole body (`200`), the requested window is sliced out locally.
    private func fetchRange(from sourceURL: URL, offset: Int64, length: Int64) async throws -> Data {
        var request = URLRequest(url: sourceURL)
        request.timeoutInterval = 30
        request.setValue("bytes=\(offset)-\(offset + length - 1)", forHTTPHeaderField: "Range")
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TrackerClientError.invalidResponse
        }
        switch httpResponse.statusCode {
        case 206:
            guard data.count >= Int(length) else { throw TrackerClientError.invalidResponse }
            return data.prefix(Int(length))
        case 200:
            let start = Int(offset)
            let end = start + Int(length)
            guard end <= data.count else { throw TrackerClientError.invalidResponse }
            return data.subdata(in: start..<end)
        default:
            throw TrackerClientError.invalidResponse
        }
    }

    private func downloadFile(
        from sourceURL: URL,
        file: TorrentFile,
        writer: TorrentFileWriter,
        progressDownloadedBytes: Int64,
        progress: @Sendable @escaping (Int64) async -> Void
    ) async throws -> Int64 {
        do {
            return try await downloadFileSegmented(from: sourceURL, file: file, writer: writer, progressDownloadedBytes: progressDownloadedBytes, progress: progress)
        } catch is UseSequentialStream {
            // Resume state is size-based and the segmented path only ever writes a
            // contiguous prefix, so the sequential path picks up where it stopped.
            return try await downloadFileSequential(from: sourceURL, file: file, writer: writer, progressDownloadedBytes: progressDownloadedBytes, progress: progress)
        }
    }

    /// Fetches the missing tail of `file` as `segmentSize` range requests, up to
    /// `maxConnections` in flight, and writes them strictly in order so the partial
    /// file is always a contiguous prefix (what `partialFileResumeOffset` assumes).
    private func downloadFileSegmented(
        from sourceURL: URL,
        file: TorrentFile,
        writer: TorrentFileWriter,
        progressDownloadedBytes: Int64,
        progress: @Sendable @escaping (Int64) async -> Void
    ) async throws -> Int64 {
        let (partialURL, resumeOffset) = try writer.partialFileResumeOffset(for: file)
        if resumeOffset >= file.length { return file.length }
        guard maxConnections > 1, file.length - resumeOffset > segmentSize else { throw UseSequentialStream() }

        let segmentCount = Int((file.length - resumeOffset + segmentSize - 1) / segmentSize)
        let handle = try FileHandle(forWritingTo: partialURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(resumeOffset))

        var written = resumeOffset
        try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            var nextToStart = 0
            var nextToWrite = 0
            var ready: [Int: Data] = [:]
            while nextToWrite < segmentCount {
                while nextToStart < segmentCount, nextToStart - nextToWrite - ready.count < maxConnections,
                      nextToStart - nextToWrite < maxConnections * 2 {
                    let index = nextToStart
                    let offset = resumeOffset + Int64(index) * segmentSize
                    let length = min(segmentSize, file.length - offset)
                    group.addTask { (index, try await self.fetchSegment(from: sourceURL, offset: offset, length: length)) }
                    nextToStart += 1
                }
                guard let (index, data) = try await group.next() else { break }
                ready[index] = data
                while let next = ready.removeValue(forKey: nextToWrite) {
                    try handle.write(contentsOf: next)
                    written += Int64(next.count)
                    nextToWrite += 1
                    await rateLimiter?.consume(next.count)
                    await progress(progressDownloadedBytes + written)
                }
            }
        }
        guard written == file.length else { throw TrackerClientError.invalidResponse }
        return file.length
    }

    /// One range request that must be answered with exactly `length` bytes of `206`.
    /// A `200` means the server ignores `Range`; the caller falls back to one stream.
    private func fetchSegment(from sourceURL: URL, offset: Int64, length: Int64) async throws -> Data {
        var request = URLRequest(url: sourceURL)
        request.timeoutInterval = 30
        request.setValue("bytes=\(offset)-\(offset + length - 1)", forHTTPHeaderField: "Range")
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TrackerClientError.invalidResponse
        }
        switch httpResponse.statusCode {
        case 206:
            guard Int64(data.count) == length else { throw TrackerClientError.invalidResponse }
            return data
        case 200:
            throw UseSequentialStream()
        default:
            throw TrackerClientError.invalidResponse
        }
    }

    private func downloadFileSequential(
        from sourceURL: URL,
        file: TorrentFile,
        writer: TorrentFileWriter,
        progressDownloadedBytes: Int64,
        progress: @Sendable @escaping (Int64) async -> Void
    ) async throws -> Int64 {
        let (partialURL, resumeOffset) = try writer.partialFileResumeOffset(for: file)
        // Already fully present from a prior run; nothing to fetch.
        if resumeOffset >= file.length {
            return file.length
        }

        var request = URLRequest(url: sourceURL)
        request.timeoutInterval = 30
        if resumeOffset > 0 {
            request.setValue("bytes=\(resumeOffset)-", forHTTPHeaderField: "Range")
        }
        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TrackerClientError.invalidResponse
        }

        // Honor the server's decision: 206 means our range was accepted, so we
        // append; 200 means the range was ignored and the whole body follows, so
        // we rewrite from the start. Anything else is treated as a failure and
        // the caller falls through to the next web seed / peers.
        let writeOffset: Int64
        switch httpResponse.statusCode {
        case 206:
            writeOffset = resumeOffset
        case 200:
            writeOffset = 0
        default:
            throw TrackerClientError.invalidResponse
        }

        let handle = try FileHandle(forWritingTo: partialURL)
        var fileDownloadedBytes: Int64 = writeOffset
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)
        do {
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(writeOffset))
            for try await byte in bytes {
                try Task.checkCancellation()
                buffer.append(byte)
                if buffer.count >= 64 * 1024 {
                    try handle.write(contentsOf: buffer)
                    fileDownloadedBytes += Int64(buffer.count)
                    let chunkSize = buffer.count
                    buffer.removeAll(keepingCapacity: true)
                    await rateLimiter?.consume(chunkSize)
                    await progress(progressDownloadedBytes + fileDownloadedBytes)
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
                fileDownloadedBytes += Int64(buffer.count)
                await progress(progressDownloadedBytes + fileDownloadedBytes)
            }
        }

        // `fileDownloadedBytes` started at `writeOffset`, so it now reflects the
        // whole file present on disk, including any resumed prefix.
        guard fileDownloadedBytes == file.length else {
            throw TrackerClientError.invalidResponse
        }
        return file.length
    }
}

extension URL {
    func appendingTorrentRelativePath(_ path: String) -> URL {
        path.split(separator: "/").reduce(self) { url, component in
            url.appendingPathComponent(String(component))
        }
    }
}
