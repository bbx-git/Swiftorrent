import CryptoKit
import Foundation
@testable import SwiftorrentCore
import Testing

/// Serves one in-memory file, optionally honoring `Range`, and records the peak
/// number of requests in flight.
private final class WebSeedStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var honorsRange = true
    nonisolated(unsafe) static var inFlight = 0
    nonisolated(unsafe) static var peak = 0
    nonisolated(unsafe) static var ranges: [String] = []
    nonisolated(unsafe) static var answers = true
    nonisolated(unsafe) static var hosts: Set<String> = []
    static let lock = NSLock()

    static func reset(body: Data, honorsRange: Bool, answers: Bool = true) {
        lock.lock(); defer { lock.unlock() }
        self.body = body
        self.honorsRange = honorsRange
        self.answers = answers
        inFlight = 0
        peak = 0
        ranges = []
        hosts = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let range = request.value(forHTTPHeaderField: "Range")
        Self.lock.lock()
        Self.inFlight += 1
        Self.peak = max(Self.peak, Self.inFlight)
        if let range { Self.ranges.append(range) }
        Self.hosts.insert(request.url?.host ?? "")
        let answers = Self.answers
        Self.lock.unlock()
        // A dead seed: never respond, until URLSession gives up or is cancelled.
        guard answers else { return }

        let client = self.client
        let url = request.url!
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            Self.lock.lock()
            Self.inFlight -= 1
            let body = Self.body
            let honors = Self.honorsRange
            Self.lock.unlock()

            var status = 200
            var payload = body
            var headers: [String: String] = [:]
            if honors, let range, range.hasPrefix("bytes=") {
                let parts = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
                let start = Int(parts[0])!
                let end = parts[1].isEmpty ? body.count - 1 : Int(parts[1])!
                payload = body.subdata(in: start..<(end + 1))
                status = 206
                headers["Content-Range"] = "bytes \(start)-\(end)/\(body.count)"
            }
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: payload)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

@Suite("Web-seed segmented download", .serialized)
struct WebSeedSegmentTests {
    private func makeFixture(length: Int, webSeeds: [URL] = [URL(string: "http://seed.test/")!]) throws -> (WebSeedDownloader, TorrentMetainfo, TorrentFileWriter, FileProgressMapper, URL) {
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
            webSeedURLs: webSeeds
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebSeedStub.self]
        var downloader = WebSeedDownloader(session: URLSession(configuration: configuration))
        downloader.segmentSize = 1_000
        downloader.maxConnections = 4
        let writer = TorrentFileWriter(metainfo: metainfo, destination: destination)
        let mapper = FileProgressMapper(metainfo: metainfo, selection: [0])
        return (downloader, metainfo, writer, mapper, destination.appendingPathComponent("Root/a.bin.tor"))
    }

    private func payload(_ length: Int) -> Data {
        Data((0..<length).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
    }

    @Test("fetches segments concurrently and writes them in order")
    func concurrentSegments() async throws {
        let body = payload(10_500)
        WebSeedStub.reset(body: body, honorsRange: true)
        let (downloader, metainfo, writer, mapper, partial) = try makeFixture(length: body.count)
        defer { try? FileManager.default.removeItem(at: partial.deletingLastPathComponent().deletingLastPathComponent()) }

        try await downloader.downloadAll(metainfo: metainfo, writer: writer, mapper: mapper, initialDownloaded: 0, totalBytes: Int64(body.count)) { _ in }

        #expect(try Data(contentsOf: partial) == body)
        #expect(WebSeedStub.peak > 1)
        #expect(WebSeedStub.peak <= 4)
    }

    @Test("a server that ignores Range falls back to one stream")
    func rangeIgnored() async throws {
        let body = payload(5_000)
        WebSeedStub.reset(body: body, honorsRange: false)
        let (downloader, metainfo, writer, mapper, partial) = try makeFixture(length: body.count)
        defer { try? FileManager.default.removeItem(at: partial.deletingLastPathComponent().deletingLastPathComponent()) }

        try await downloader.downloadAll(metainfo: metainfo, writer: writer, mapper: mapper, initialDownloaded: 0, totalBytes: Int64(body.count)) { _ in }

        #expect(try Data(contentsOf: partial) == body)
    }

    @Test("resumes after the existing prefix")
    func resumesPrefix() async throws {
        let body = payload(6_000)
        WebSeedStub.reset(body: body, honorsRange: true)
        let (downloader, metainfo, writer, mapper, partial) = try makeFixture(length: body.count)
        defer { try? FileManager.default.removeItem(at: partial.deletingLastPathComponent().deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.prefix(2_500).write(to: partial)

        try await downloader.downloadAll(metainfo: metainfo, writer: writer, mapper: mapper, initialDownloaded: 2_500, totalBytes: Int64(body.count)) { _ in }

        #expect(try Data(contentsOf: partial) == body)
        #expect(WebSeedStub.ranges.contains("bytes=2500-3499"))
        #expect(!WebSeedStub.ranges.contains { $0.hasPrefix("bytes=0-") })
    }

    @Test("a seed that never answers is given up on after the first-byte deadline")
    func deadSeedFailsFast() async throws {
        WebSeedStub.reset(body: Data(), honorsRange: true, answers: false)
        var (downloader, metainfo, writer, mapper, partial) = try makeFixture(length: 5_000)
        defer { try? FileManager.default.removeItem(at: partial.deletingLastPathComponent().deletingLastPathComponent()) }
        downloader.firstByteDeadline = .milliseconds(200)

        let start = ContinuousClock.now
        await #expect(throws: (any Error).self) {
            try await downloader.downloadAll(metainfo: metainfo, writer: writer, mapper: mapper, initialDownloaded: 0, totalBytes: 5_000) { _ in }
        }
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test("dead seeds stop being tried once the start budget is spent")
    func deadSeedsShareOneBudget() async throws {
        WebSeedStub.reset(body: Data(), honorsRange: true, answers: false)
        let seeds = (1...5).map { URL(string: "http://seed\($0).test/")! }
        var (downloader, metainfo, writer, mapper, partial) = try makeFixture(length: 5_000, webSeeds: seeds)
        defer { try? FileManager.default.removeItem(at: partial.deletingLastPathComponent().deletingLastPathComponent()) }
        downloader.firstByteDeadline = .milliseconds(300)
        downloader.startBudget = .milliseconds(500)

        await #expect(throws: (any Error).self) {
            try await downloader.downloadAll(metainfo: metainfo, writer: writer, mapper: mapper, initialDownloaded: 0, totalBytes: 5_000) { _ in }
        }
        #expect(WebSeedStub.hosts.count == 2)
    }
}
