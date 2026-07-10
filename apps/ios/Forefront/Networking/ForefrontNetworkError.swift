import Foundation

public enum ForefrontNetworkError: Error, Equatable, Sendable {
    case unauthorized
    case notFound
    case serverError(status: Int)
    case decodingFailed(String)
    case transport(String)
    case allEndpointsExhausted

    public var isAuthFailure: Bool {
        if case .unauthorized = self { return true }
        return false
    }

    public var isRetryable: Bool {
        switch self {
        case .serverError, .transport: return true
        case .unauthorized, .notFound, .decodingFailed, .allEndpointsExhausted: return false
        }
    }
}
