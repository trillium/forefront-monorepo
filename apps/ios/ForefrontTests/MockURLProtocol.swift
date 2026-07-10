import Foundation

/// A `URLProtocol` stub for deterministic network tests (ISC-142). Register a
/// queue of scripted responses per URL *path* (e.g. `/stack/last-updated`); each
/// intercepted request pops the next scripted response for its path. When a
/// path's queue is exhausted, its LAST scripted response repeats (so a test can
/// script "always 200" with a single entry).
///
/// Also records, per path, how many requests were intercepted — this is how the
/// rotation/retry tests assert "retried once then fell through" (ISC-143) and
/// "did not try the remaining endpoints" (ISC-144).
///
/// Usage:
/// ```
/// let config = URLSessionConfiguration.ephemeral
/// config.protocolClasses = [MockURLProtocol.self]
/// let session = URLSession(configuration: config)
/// MockURLProtocol.reset()
/// MockURLProtocol.script(path: "/stack/last-updated", responses: [.status(200, body: ...)])
/// ```
final class MockURLProtocol: URLProtocol {

    // MARK: - Scripted response

    struct ScriptedResponse {
        let statusCode: Int
        let body: Data
        let headers: [String: String]
        /// If set, the loader fails with this error instead of returning a response.
        let error: (any Error)?

        static func status(_ code: Int, body: Data = Data(), headers: [String: String] = [:]) -> ScriptedResponse {
            ScriptedResponse(statusCode: code, body: body, headers: headers, error: nil)
        }

        static func failure(_ error: any Error) -> ScriptedResponse {
            ScriptedResponse(statusCode: 0, body: Data(), headers: [:], error: error)
        }
    }

    // MARK: - Thread-safe registry (URLProtocol is instantiated by URLSession)

    private static let lock = NSLock()
    private static var queues: [String: [ScriptedResponse]] = [:]
    private static var hitCounts: [String: Int] = [:]

    /// Clear all scripted responses and counters. Call in `setUp` / before each test.
    static func reset() {
        lock.lock(); defer { lock.unlock() }
        queues.removeAll()
        hitCounts.removeAll()
    }

    /// Script a sequence of responses for a URL path. Consumed FIFO; the last one
    /// repeats once exhausted.
    static func script(path: String, responses: [ScriptedResponse]) {
        precondition(!responses.isEmpty, "script(path:responses:) requires at least one response")
        lock.lock(); defer { lock.unlock() }
        queues[path] = responses
    }

    /// How many requests were intercepted for a given path.
    static func hitCount(path: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return hitCounts[path] ?? 0
    }

    private static func nextResponse(for path: String) -> ScriptedResponse? {
        lock.lock(); defer { lock.unlock() }
        hitCounts[path, default: 0] += 1
        guard var queue = queues[path], !queue.isEmpty else { return nil }
        if queue.count == 1 {
            // Last entry repeats.
            return queue[0]
        }
        let head = queue.removeFirst()
        queues[path] = queue
        return head
    }

    // MARK: - URLProtocol overrides

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        // Match on the path so tests do not depend on which endpoint host the
        // rotator picked. Normalize a trailing slash away.
        let path = normalizedPath(url)

        guard let scripted = Self.nextResponse(for: path) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        if let error = scripted.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        guard let response = HTTPURLResponse(
            url: url,
            statusCode: scripted.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: scripted.headers
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotParseResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: scripted.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        // No async work to cancel; responses are delivered synchronously.
    }

    private func normalizedPath(_ url: URL) -> String {
        var path = url.path
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

/// A `URLSession` wired to `MockURLProtocol`, for test injection into `APIClient`.
enum MockSession {
    static func make() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }
}
