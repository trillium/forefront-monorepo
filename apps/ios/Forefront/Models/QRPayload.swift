import Foundation

/// QR-encoded onboarding payload. Scanned once at first launch (or re-scanned).
public struct QRPayload: Codable, Sendable {
    public let version: Int
    public let endpoints: [URL]
    public let authToken: String
    public let push: PushHint?

    public init(version: Int, endpoints: [URL], authToken: String, push: PushHint? = nil) throws {
        guard !endpoints.isEmpty else { throw QRPayloadError.endpointsIsEmpty }
        guard !authToken.isEmpty else { throw QRPayloadError.authTokenIsEmpty }
        self.version = version
        self.endpoints = endpoints
        self.authToken = authToken
        self.push = push
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let v = try c.decode(Int.self, forKey: .version)
        let eps = try c.decode([URL].self, forKey: .endpoints)
        let tok = try c.decode(String.self, forKey: .authToken)
        let p = try c.decodeIfPresent(PushHint.self, forKey: .push)
        try self.init(version: v, endpoints: eps, authToken: tok, push: p)
    }

    enum CodingKeys: String, CodingKey {
        case version, endpoints, authToken, push
    }
}

/// Intentionally redacts `authToken`; never log this struct directly.
extension QRPayload: CustomStringConvertible {
    public var description: String {
        "QRPayload(version: \(version), endpoints: \(endpoints.count), authToken: <redacted>, push: \(push?.topic ?? "nil"))"
    }
}

public struct PushHint: Codable, Sendable {
    public let topic: String?
    public init(topic: String?) { self.topic = topic }
}

public enum QRPayloadError: Error, Equatable, Sendable {
    case endpointsIsEmpty
    case authTokenIsEmpty
}
