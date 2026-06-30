import Foundation

/// A base URL with its rotator position. The rotator (Networking layer) owns
/// the order; this type just pairs the URL with its index for diagnostics.
public struct Endpoint: Codable, Hashable, Sendable {
    public let url: URL
    public let position: Int

    public init(url: URL, position: Int) {
        self.url = url
        self.position = position
    }
}
