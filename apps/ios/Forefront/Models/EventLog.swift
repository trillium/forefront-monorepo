import Foundation

/// A single breadcrumb in the in-app diagnostic trail.
public struct LogEvent: Sendable, Identifiable, Equatable {
    public enum Level: String, Sendable {
        case info, success, warn, error
    }

    public let id: UUID
    public let time: Date
    /// Coarse source: "scan", "network", "refresh", "cache", "ui".
    public let category: String
    public let level: Level
    public let message: String
    /// Optional extra context (an error reason, an endpoint, a count).
    public let detail: String?

    public init(
        id: UUID = UUID(),
        time: Date = Date(),
        category: String,
        level: Level = .info,
        message: String,
        detail: String? = nil
    ) {
        self.id = id
        self.time = time
        self.category = category
        self.level = level
        self.message = message
        self.detail = detail
    }
}

/// Thread-safe, in-memory ring buffer of diagnostic breadcrumbs — the app's own
/// record of what the user and the app did, especially the failures that never
/// reach the server (a scan that didn't connect, an ATS-blocked request).
///
/// One shared instance for the whole app. Writable from any isolation: the
/// networking actor logs the real connection error here; the UI logs user
/// actions. Reads return an immutable snapshot. Caps at `maxEvents` and is cheap
/// enough to leave on in release.
public final class EventLog: @unchecked Sendable {
    public static let shared = EventLog()

    private let lock = NSLock()
    private var events: [LogEvent] = []
    private let maxEvents: Int

    public init(maxEvents: Int = 250) {
        self.maxEvents = maxEvents
    }

    public func log(
        _ category: String,
        _ message: String,
        level: LogEvent.Level = .info,
        detail: String? = nil
    ) {
        let event = LogEvent(category: category, level: level, message: message, detail: detail)
        lock.lock()
        defer { lock.unlock() }
        events.append(event)
        if events.count > maxEvents {
            events.removeFirst(events.count - maxEvents)
        }
    }

    /// Newest-first snapshot for display.
    public func snapshot() -> [LogEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events.reversed()
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        events.removeAll()
    }

    /// Chronological (oldest-first) plaintext dump for "Copy debug state".
    public func formatted() -> String {
        lock.lock()
        let snap = events
        lock.unlock()
        if snap.isEmpty { return "(no events recorded yet)" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return snap.map { e in
            let tag = e.level == .info ? "" : " [\(e.level.rawValue.uppercased())]"
            let d = e.detail.map { " — \($0)" } ?? ""
            return "\(f.string(from: e.time)) \(e.category)\(tag): \(e.message)\(d)"
        }.joined(separator: "\n")
    }

    // Convenience wrappers.
    public func info(_ category: String, _ message: String, detail: String? = nil) {
        log(category, message, level: .info, detail: detail)
    }
    public func success(_ category: String, _ message: String, detail: String? = nil) {
        log(category, message, level: .success, detail: detail)
    }
    public func warn(_ category: String, _ message: String, detail: String? = nil) {
        log(category, message, level: .warn, detail: detail)
    }
    public func error(_ category: String, _ message: String, detail: String? = nil) {
        log(category, message, level: .error, detail: detail)
    }
}
