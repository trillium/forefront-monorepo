import Foundation
import os

/// Centralized logger. Use `Log.net`, `Log.storage`, `Log.ui`, `Log.push`.
/// No `print(` in production code (ISC-120).
public enum Log {
    public static let subsystem = "com.trilliumsmith.forefront"
    public static let net     = Logger(subsystem: subsystem, category: "net")
    public static let storage = Logger(subsystem: subsystem, category: "storage")
    public static let ui      = Logger(subsystem: subsystem, category: "ui")
    public static let push    = Logger(subsystem: subsystem, category: "push")
}
