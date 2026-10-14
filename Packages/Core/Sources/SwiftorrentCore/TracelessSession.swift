import Foundation

extension URLSession {
    /// The session for all tracker, magnet and web-seed HTTP. `.shared` writes
    /// every response, announce URLs with their info-hash included, to the app's
    /// `Cache.db`, and keeps cookies and HSTS/alt-svc state on disk. This one is
    /// ephemeral with no cache, cookies or credentials, so nothing about what was
    /// downloaded outlives the process.
    public static let traceless: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }()
}
