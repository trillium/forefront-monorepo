import Foundation

/// A cursor used only for equality comparison. The backend may emit an integer,
/// an ISO-8601 string, or an opaque etag — the client tolerates all three and
/// only asks "is this equal to the cached one?".
public struct StackVersion: Codable, Hashable, Sendable, CustomStringConvertible {
    public enum Representation: Hashable, Sendable {
        case integer(Int)
        case string(String)
    }

    public let value: Representation

    public init(integer: Int) { self.value = .integer(integer) }
    public init(string: String) { self.value = .string(string) }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int.self) {
            self.value = .integer(int)
        } else {
            self.value = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case .integer(let i): try container.encode(i)
        case .string(let s): try container.encode(s)
        }
    }

    public var description: String {
        switch value {
        case .integer(let i): return String(i)
        case .string(let s): return s
        }
    }
}
