import Foundation
import ForefrontModels

/// Read/write seam for the on-disk deck cache. `StackService` depends on this
/// protocol (not the concrete `CacheStore`) so tests can inject a spy that
/// counts writes (ISC-145) or asserts write-before-adopt ordering (ISC-146).
public protocol StackCaching: Sendable {
    func loadStack(now: Date) throws -> CardStack?
    func saveStack(_ stack: CardStack) throws
    /// ISC-154: the wall-clock time the cached deck was last written, or nil if
    /// no cache exists yet. Drives the offline "as of HH:mm" staleness line.
    func lastRefreshed() -> Date?
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

    /// ISC-154: last-refreshed timestamp = the cache file's modification date.
    /// Chosen as the least-invasive persistent source — it survives app relaunch
    /// (it's a filesystem attribute), needs no new stored field, and is updated
    /// for free by `saveStack` on every `.updated` fetch. Semantics: "the deck you
    /// are looking at is as-of this time" (last successful content refresh). A
    /// `.unchanged` outcome does not rewrite the file, which is correct — the
    /// content is unchanged, so its as-of time is unchanged too.
    public func lastRefreshed() -> Date? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        return attrs?[.modificationDate] as? Date
    }

    public func clear() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }
}
