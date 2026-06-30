import Foundation

/// On-disk Codable cache of the most recent `CardStack`. Lives in
/// `Application Support/forefront/stack.json`. Not backed up to iCloud.
public final class CacheStore: Sendable {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileManager: FileManager = .default) throws {
        let supportDir = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("forefront", isDirectory: true)
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
        // ISC-46: atomic write.
        try data.write(to: fileURL, options: [.atomic])
    }

    public func clear() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }
}
