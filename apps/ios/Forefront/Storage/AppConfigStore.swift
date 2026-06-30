import Foundation

/// Persists non-secret onboarding config: endpoint list, QR payload version,
/// push topic. The secret bearer token lives in `KeychainStore`, NOT here.
public final class AppConfigStore: Sendable {
    private let defaults: UserDefaults
    private let endpointsKey = "forefront.endpoints"
    private let versionKey = "forefront.qrPayloadVersion"
    private let pushTopicKey = "forefront.pushTopic"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func loadEndpoints() -> [URL] {
        guard let strings = defaults.stringArray(forKey: endpointsKey) else { return [] }
        return strings.compactMap(URL.init(string:))
    }

    public func storeEndpoints(_ endpoints: [URL]) {
        defaults.set(endpoints.map(\.absoluteString), forKey: endpointsKey)
    }

    public var qrPayloadVersion: Int? {
        get { defaults.object(forKey: versionKey) as? Int }
        set {
            if let newValue { defaults.set(newValue, forKey: versionKey) }
            else { defaults.removeObject(forKey: versionKey) }
        }
    }

    public var pushTopic: String? {
        get { defaults.string(forKey: pushTopicKey) }
        set { defaults.set(newValue, forKey: pushTopicKey) }
    }

    /// Single-transaction adoption of a freshly-scanned QR payload's
    /// non-secret bits. Token write is the caller's responsibility (Keychain).
    public func adopt(_ payload: QRPayload) {
        storeEndpoints(payload.endpoints)
        qrPayloadVersion = payload.version
        pushTopic = payload.push?.topic
    }

    public func clear() {
        defaults.removeObject(forKey: endpointsKey)
        defaults.removeObject(forKey: versionKey)
        defaults.removeObject(forKey: pushTopicKey)
    }
}
