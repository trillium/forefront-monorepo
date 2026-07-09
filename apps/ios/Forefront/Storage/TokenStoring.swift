import Foundation

/// The token-persistence seam. Consumers (e.g. `StackService`) depend on this,
/// not on `KeychainStore` directly, so the storage mechanism can swap — an
/// app-group container, a server-session model, or a test double — without any
/// consumer change. `KeychainStore` is the production conformer.
public protocol TokenStoring: Sendable {
    func storeToken(_ token: String) throws
    func loadToken() throws -> String?
    func deleteToken() throws
}

extension KeychainStore: TokenStoring {}
