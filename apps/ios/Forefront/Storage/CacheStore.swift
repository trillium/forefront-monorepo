import Foundation
import ForefrontModels

/// Read/write seam for the on-disk deck cache. `StackService` depends on this
/// protocol (not the concrete `CacheStore`) so tests can inject a spy that
/// counts writes (ISC-145) or asserts write-before-adopt ordering (ISC-146).
public protocol StackCaching: Sendable {
    func loadStack(now: Date) throws -> CardStack?
    func saveStack(_ stack: CardStack) throws
}

public extension StackCaching {
    /// Convenience overload so callers can omit `now`.
    func loadStack() throws -> CardStack? { try loadStack(now: Date()) }
}

/// On-disk Codable cache of the most recent `CardStack`. Lives in
/// `Application Support/forefront/stack.json` by default. Not backed up to iCloud.
public final class CacheStore: StackCaching, Sendable {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// - Parameter directory: the directory to store `stack.json` in. Defaults to
    ///   `Application Support/forefront/`. Tests pass a temp dir so they never
    ///   touch the real cache (and can observe file mtime in isolation).
    public init(fileManager: FileManager = .default, directory: URL? = nil) throws {
        let supportDir: URL
        if let directory {
            supportDir = directory
        } else {
            supportDir = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("forefront", isDirectory: true)
        }
        if !fileManager.fileExists(atPath: supportDir.path) {
            try fileManager.createDirectory(at: supportDir, withIntermediateDirectories: true)
        }
        self.fileURL = supportDir.appendingPathComponent("stack.json")
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        self.encoder = e
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        self.decoder = d
    }

    public func loadStack(now: Date = Date()) throws -> CardStack? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        let stack = try decoder.decode(CardStack.self, from: data)
        // ISC-47: evict expired cards on load.
        let live = stack.cards.filter { !$0.isExpired(now: now) }
        if live.count == stack.cards.count { return stack }
        return CardStack(version: stack.version, cards: live)
    }

    public func saveStack(_ stack: CardStack) throws {
        let data = try encoder.encode(stack)
        // ISC-46: atomic write. Spell out the option type — `[.atomic]` alone
        // cannot infer its element type in this context.
        try data.write(to: fileURL, options: Data.WritingOptions.atomic)
    }

    public func clear() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }
}
