import Foundation
import Testing
@testable import SwiftorrentCore

/// Tracker announces carry the info-hash in the URL; a disk cache or cookie
/// store would keep a record of every torrent ever fetched.
@Suite struct TracelessHTTPTests {
    @Test func defaultClientsKeepNothingOnDisk() throws {
        let sessions: [(String, URLSession)] = [
            ("TrackerClient", try boundedSession(of: TrackerClient())),
            ("MagnetMetadataResolver", try boundedSession(of: MagnetMetadataResolver())),
            ("TorrentDownloader", try #require(Mirror(reflecting: TorrentDownloader()).descendant("session") as? URLSession)),
        ]
        for (owner, session) in sessions {
            let configuration = session.configuration
            #expect(configuration.urlCache == nil, "\(owner) caches responses")
            #expect(configuration.httpCookieStorage == nil, "\(owner) stores cookies")
            #expect(configuration.urlCredentialStorage == nil, "\(owner) stores credentials")
            #expect(configuration.httpShouldSetCookies == false, "\(owner) sends cookies")
        }
    }

    private func boundedSession(of owner: Any) throws -> URLSession {
        let http = try #require(Mirror(reflecting: owner).descendant("http") as? BoundedHTTPClient)
        return try #require(Mirror(reflecting: http).descendant("session") as? URLSession)
    }
}
