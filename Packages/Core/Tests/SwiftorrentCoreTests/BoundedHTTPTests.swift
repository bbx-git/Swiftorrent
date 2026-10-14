import Foundation
@testable import SwiftorrentCore
import Testing

/// Answers every request with `size` bytes sent in 64 KiB chunks, with or without
/// a declared `Content-Length`, honoring `Range` only when `honorsRange` is set.
private final class OversizedStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var size = 0
    nonisolated(unsafe) static var declaresLength = true
    nonisolated(unsafe) static var honorsRange = false
    static let lock = NSLock()

    static func configure(size: Int, declaresLength: Bool, honorsRange: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        self.size = size
        self.declaresLength = declaresLength
        self.honorsRange = honorsRange
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lock.lock()
        let size = Self.size
        let declares = Self.declaresLength
        let honors = Self.honorsRange
        Self.lock.unlock()

        let range = request.value(forHTTPHeaderField: "Range")
        var status = 200
        var length = size
        var headers: [String: String] = [:]
        if honors, let range, range.hasPrefix("bytes=") {
            let parts = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            if let start = Int(parts[0]), let end = Int(parts[1]) {
                status = 206
                length = size   // a misbehaving server: ignores the requested end
                headers["Content-Range"] = "bytes \(start)-\(end)/\(size)"
            }
        }
        if declares { headers["Content-Length"] = String(length) }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        var sent = 0
        while sent < length, !isStopped {
            let chunk = min(65_536, length - sent)
            client?.urlProtocol(self, didLoad: Data(repeating: 0x41, count: chunk))
            sent += chunk
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    private var isStopped: Bool { false }
}

private func session() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [OversizedStub.self]
    return URLSession(configuration: configuration)
}

@Suite("Bounded HTTP", .serialized)
struct BoundedHTTPTests {
    private let url = URL(string: "http://host.test/x")!

    @Test("A body under the limit is returned whole")
    func smallBody() async throws {
        OversizedStub.configure(size: 1_000, declaresLength: true)
        let client = BoundedHTTPClient(session: session())

        let (data, response) = try await client.data(for: URLRequest(url: url), limit: 4_096)

        #expect(data.count == 1_000)
        #expect(response.statusCode == 200)
    }

    @Test("A body that streams past the limit is cut off")
    func undeclaredOversizedBody() async {
        OversizedStub.configure(size: 3 << 20, declaresLength: false)
        let client = BoundedHTTPClient(session: session())

        await #expect(throws: BoundedHTTPError.tooLarge) {
            _ = try await client.data(for: URLRequest(url: url), limit: 1 << 20)
        }
    }

    @Test("A declared Content-Length over the limit is refused")
    func declaredOversizedBody() async {
        OversizedStub.configure(size: 3 << 20, declaresLength: true)
        let client = BoundedHTTPClient(session: session())

        await #expect(throws: BoundedHTTPError.tooLarge) {
            _ = try await client.data(for: URLRequest(url: url), limit: 1 << 20)
        }
    }

    @Test("An HTTP tracker reply over the limit is rejected")
    func trackerReplyIsBounded() async {
        OversizedStub.configure(size: 3 << 20, declaresLength: false)
        let tracker = TrackerClient(session: session())
        let request = TrackerRequest(
            announceURL: URL(string: "http://tracker.test/announce")!,
            infoHash: Data(repeating: 1, count: 20),
            peerID: Data(repeating: 2, count: 20),
            downloaded: 0,
            left: 1,
            event: nil
        )

        await #expect(throws: BoundedHTTPError.tooLarge) {
            _ = try await tracker.announce(request)
        }
    }

    @Test("A web seed that over-delivers on a range is rejected")
    func webSeedRangeIsBounded() async throws {
        // The server answers every range with 3 MiB of a 3 MiB "file", far past the
        // 1,000-byte segment we asked for.
        OversizedStub.configure(size: 3 << 20, declaresLength: false, honorsRange: true)
        let (downloader, metainfo, writer, mapper, root) = try makeFixture(length: 5_000)
        defer { try? FileManager.default.removeItem(at: root) }

        await #expect(throws: BoundedHTTPError.tooLarge) {
            try await downloader.downloadAll(metainfo: metainfo, writer: writer, mapper: mapper, initialDownloaded: 0, totalBytes: 5_000) { _ in }
        }
    }

    @Test("A sequential web-seed stream stops writing at the file length")
    func sequentialStreamStopsAtLength() async throws {
        // The server ignores Range and keeps sending well past the 5,000-byte file.
        OversizedStub.configure(size: 2 << 20, declaresLength: true, honorsRange: false)
        let (downloader, metainfo, writer, mapper, root) = try makeFixture(length: 5_000)
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try? await downloader.downloadAll(metainfo: metainfo, writer: writer, mapper: mapper, initialDownloaded: 0, totalBytes: 5_000) { _ in }

        let partial = root.appendingPathComponent("Root/a.bin.tor")
        let size = (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? Int) ?? 0
        #expect(size <= 5_000, "wrote \(size) bytes for a 5,000-byte file")
    }

    private func makeFixture(length: Int) throws -> (WebSeedDownloader, TorrentMetainfo, TorrentFileWriter, FileProgressMapper, URL) {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = TorrentFile(id: 0, path: "Root/a.bin", length: Int64(length))
        let metainfo = TorrentMetainfo(
            name: "Root",
            announceURLs: [],
            files: [file],
            pieceLength: 16_384,
            pieceHashes: [],
            totalSize: Int64(length),
            infoHash: Data(repeating: 0, count: 20),
            infoDictionaryData: Data(),
            webSeedURLs: [URL(string: "http://seed.test/")!]
        )
        var downloader = WebSeedDownloader(session: session())
        downloader.segmentSize = 1_000
        downloader.maxConnections = 4
        let writer = TorrentFileWriter(metainfo: metainfo, destination: destination)
        let mapper = FileProgressMapper(metainfo: metainfo, selection: [0])
        return (downloader, metainfo, writer, mapper, destination)
    }
}
