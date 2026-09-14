import Foundation

/// Intermediate type system
/// Principle: no lossy coercion. DECIMAL is kept verbatim; unfamiliar types
/// fall into `.unknown` with the type name instead of crashing or mis-rounding.
public enum BerryValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case decimal(String)
    case text(String)
    case bytes(Data)
    case date(DateComponents)
    case timestamp(Date, hasTimezone: Bool)
    case json(String)
    case uuid(UUID)
    case unknown(raw: Data, typeName: String)
}

extension BerryValue {
    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

 /// Display string for grid/copy. NULL returns nil so the UI can style it separately.
    public var displayString: String? {
        switch self {
        case .null:
            return nil
        case .bool(let b):
            return b ? "true" : "false"
        case .int(let i):
            return String(i)
        case .double(let d):
            return String(d)
        case .decimal(let s), .text(let s), .json(let s):
            return s
        case .bytes(let data):
            return "0x" + data.prefix(64).map { String(format: "%02x", $0) }.joined()
                + (data.count > 64 ? "… (\(data.count) bytes)" : "")
        case .date(let c):
            let y = c.year ?? 0, m = c.month ?? 0, d = c.day ?? 0
            return String(format: "%04d-%02d-%02d", y, m, d)
        case .timestamp(let date, _):
            return date.formatted(Self.timestampFormat)
        case .uuid(let u):
            return u.uuidString.lowercased()
        case .unknown(let raw, let typeName):
            return "<\(typeName): \(raw.count) bytes>"
        }
    }

    private static let timestampFormat = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

 /// Numeric value for charting (Visualize Result)
    /// nil for anything that isn't actually a number. Never coerces text/
    /// dates/etc. (N4-style: no lossy guessing), and DECIMAL parses
    /// best-effort since it's stored verbatim as a string.
    public var numericValue: Double? {
        switch self {
        case .int(let i): Double(i)
        case .double(let d): d
        case .decimal(let s): Double(s)
        default: nil
        }
    }
}
