import Foundation

/// Iterates the configured `endpoints` array in order on each call.
/// Persists the last-successful index for the session so we don't re-try the
/// known-bad primary on every fetch within one session.
public actor EndpointRotator {
    private let endpoints: [URL]
    private(set) public var lastSuccessIndex: Int = 0

    public init(endpoints: [URL]) {
        precondition(!endpoints.isEmpty, "EndpointRotator requires at least one endpoint")
        self.endpoints = endpoints
    }

    public var primary: URL { endpoints[0] }
    public var count: Int { endpoints.count }

    /// Runs `attempt` against each endpoint starting at `lastSuccessIndex`,
    /// wrapping around. First success wins; the success index is persisted.
    /// Throws `.allEndpointsExhausted` if every endpoint fails.
    public func withFallback<T: Sendable>(
        attempt: @Sendable (URL) async throws -> T
    ) async throws -> T {
        var lastError: Error?
        for offset in 0..<endpoints.count {
            let idx = (lastSuccessIndex + offset) % endpoints.count
            let url = endpoints[idx]
            do {
                let value = try await attempt(url)
                lastSuccessIndex = idx
                return value
            } catch let error as ForefrontNetworkError where !error.isRetryable {
                // Don't fall through on non-retryable errors (e.g. 401).
                throw error
            } catch {
                lastError = error
                continue
            }
        }
        if let lastError = lastError as? ForefrontNetworkError { throw lastError }
        throw ForefrontNetworkError.allEndpointsExhausted
    }
}
