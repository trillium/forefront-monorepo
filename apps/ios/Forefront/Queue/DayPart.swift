import Foundation

/// ISC-153: the day-part half of the masthead greeting ("Tuesday morning").
///
/// Pure logic, no SwiftUI import, so it lives in the Queue target and is
/// unit-testable and locale-deterministic. The view layer combines
/// `greeting(...)` with the live remaining card count.
public enum DayPart: String, Sendable, CaseIterable {
    case morning
    case afternoon
    case evening

    /// Local-hour → day-part. Boundaries:
    ///   - morning:   [5, 12)   05:00–11:59
    ///   - afternoon: [12, 17)  12:00–16:59
    ///   - evening:   [17, 5)   17:00–04:59  (wraps midnight)
    ///
    /// The pre-dawn small hours (00:00–04:59) read as "evening" deliberately —
    /// there is no "night" bucket, and a 2am reader is closer in mood to evening
    /// than to a bright "good morning".
    public static func from(hour: Int) -> DayPart {
        switch hour {
        case 5..<12: return .morning
        case 12..<17: return .afternoon
        default: return .evening
        }
    }

    /// Day-part for a given instant in a given calendar (defaults to `.current`).
    public static func from(date: Date, calendar: Calendar = .current) -> DayPart {
        from(hour: calendar.component(.hour, from: date))
    }
}

/// ISC-153: assembles the full masthead greeting text, e.g. "Tuesday morning".
/// Kept as pure logic (no view) so the weekday-name + day-part composition is
/// unit-testable without a rendering pass.
public struct Masthead: Sendable {
    /// e.g. "Tuesday morning".
    public let greeting: String
    /// Remaining cards in the current deck generation.
    public let cardCount: Int

    public init(date: Date, cardCount: Int, calendar: Calendar = .current, locale: Locale = .current) {
        var cal = calendar
        cal.locale = locale
        let weekdayIndex = cal.component(.weekday, from: date)  // 1 = Sunday … 7 = Saturday
        // `weekdaySymbols` is Sunday-first and 0-indexed; the component is 1-based.
        let symbols = cal.weekdaySymbols
        let weekday: String
        if weekdayIndex >= 1 && weekdayIndex <= symbols.count {
            weekday = symbols[weekdayIndex - 1]
        } else {
            weekday = ""
        }
        let part = DayPart.from(date: date, calendar: cal).rawValue
        self.greeting = weekday.isEmpty ? part.capitalized : "\(weekday) \(part)"
        self.cardCount = cardCount
    }

    /// "6 cards" / "1 card" / "No cards" — grammatically correct pluralization.
    public var cardCountText: String {
        switch cardCount {
        case 0: return "No cards"
        case 1: return "1 card"
        default: return "\(cardCount) cards"
        }
    }

    /// The full one-line masthead string: "Tuesday morning — 6 cards".
    public var line: String {
        "\(greeting) — \(cardCountText)"
    }
}
