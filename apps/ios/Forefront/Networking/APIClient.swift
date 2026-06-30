import Foundation

/// Thin URLSession wrapper. Knows how to call `/stack/last-updated` and `/stack`
/// with a Bearer token, decode the response, and surface typed errors.
///
/// One instance is created per session and held by `StackService`.
public final class APIClient: Sendable {
    private let rotator: EndpointRotator
    private let tokenProvider: @Sendable () async -> String?
    private let session: URLSession
    private let decoder: JSONDecoder

    public init(
        rotator: EndpointRotator,
        tokenProvider: @escaping @Sendable () async -> String?,
        session: URLSession = .shared
    ) {
        self.rotator = rotator
        self.tokenProvider = tokenProvider
        self.session = session
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        self.decoder = d
    }

    public func lastUpdated() async throws -> StackVersion {
        try await rotator.withFallback { base in
            let url = base.appendingPathComponent("stack/last-updated")
            let data = try await self.get(url)
            let envelope = try self.decoder.decode(LastUpdatedEnvelope.self, from: data)
            return envelope.version
        }
    }

    public func fetchStack() async throws -> CardStack {
        try await rotator.withFallback { base in
            let url = base.appendingPathComponent("stack")
            let data = try await self.get(url)
            do {
                return try self.decoder.decode(CardStack.self, from: data)
            } catch {
                throw ForefrontNetworkError.decodingFailed(String(describing: error))
            }
        }
    }

    /// Posts the APNs device token to the backend. Endpoint name TBD (see
    /// BACKEND_CONTRACT.md §5). ISC-90: backend confirms acceptance.
    public func registerDeviceToken(_ token: Data) async throws {
        try await rotator.withFallback { base in
            let url = base.appendingPathComponent("push/register")
            var req = try await self.authedRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "deviceToken": token.map { String(format: "%02x", $0) }.joined()
            ])
            let (_, response) = try await self.session.data(for: req)
            try Self.validate(response)
        }
    }

    // MARK: - 5xx retry-once (ISC-31)

    private func get(_ url: URL) async throws -> Data {
        let req = try await authedRequest(url: url)
        do {
            return try await perform(req)
        } catch ForefrontNetworkError.serverError {
            // One retry on 5xx per endpoint.
            return try await perform(req)
        }
    }

    private func perform(_ req: URLRequest) async throws -> Data {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw ForefrontNetworkError.transport(String(describing: error))
        }
        try Self.validate(response)
        return data
    }

    private func authedRequest(url: URL) async throws -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = await tokenProvider(), !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ForefrontNetworkError.transport("Non-HTTP response")
        }
        switch http.statusCode {
        case 200...299: return
        case 401:       throw ForefrontNetworkError.unauthorized
        case 404:       throw ForefrontNetworkError.notFound
        case 500...599: throw ForefrontNetworkError.serverError(status: http.statusCode)
        default:        throw ForefrontNetworkError.serverError(status: http.statusCode)
        }
    }
}

private struct LastUpdatedEnvelope: Decodable {
    let version: StackVersion
}
