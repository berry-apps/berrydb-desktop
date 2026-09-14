import Foundation

/// Tree-shaped value for schema-less data (Mongo documents, Qdrant point
/// payloads) — deliberately separate from `BerryValue` (BerryDriverKit),
/// which is shaped for tabular cells, not nested documents
/// No information-losing coercion: unrecognized
/// shapes stay representable rather than being flattened or dropped.
public indirect enum BerryDocument: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case binary(Data)
    /// Mongo ObjectId (hex string) — kept distinct from a plain string so the
    /// grid/cell viewer can render it recognizably.
    case objectID(String)
    case date(Date)
    /// Qdrant point vector, or a Mongo field that happens to hold one.
    case vector([Float])
    case array([BerryDocument])
    /// Ordered key/value pairs — preserves field order for display, unlike
 /// `[String: BerryDocument]`.
    case object([(String, BerryDocument)])

    public static func == (lhs: BerryDocument, rhs: BerryDocument) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case let (.bool(a), .bool(b)): return a == b
        case let (.int(a), .int(b)): return a == b
        case let (.double(a), .double(b)): return a == b
        case let (.string(a), .string(b)): return a == b
        case let (.binary(a), .binary(b)): return a == b
        case let (.objectID(a), .objectID(b)): return a == b
        case let (.date(a), .date(b)): return a == b
        case let (.vector(a), .vector(b)): return a == b
        case let (.array(a), .array(b)): return a == b
        case let (.object(a), .object(b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .null: hasher.combine(0)
        case .bool(let v): hasher.combine(1); hasher.combine(v)
        case .int(let v): hasher.combine(2); hasher.combine(v)
        case .double(let v): hasher.combine(3); hasher.combine(v)
        case .string(let v): hasher.combine(4); hasher.combine(v)
        case .binary(let v): hasher.combine(5); hasher.combine(v)
        case .objectID(let v): hasher.combine(6); hasher.combine(v)
        case .date(let v): hasher.combine(7); hasher.combine(v)
        case .vector(let v): hasher.combine(8); hasher.combine(v)
        case .array(let v): hasher.combine(9); hasher.combine(v)
        case .object(let v):
            hasher.combine(10)
            for (k, val) in v { hasher.combine(k); hasher.combine(val) }
        }
    }

    /// Field lookup for `.object` — nil for every other case (including
    /// missing keys), so callers can chain without pattern-matching each time.
    public subscript(field: String) -> BerryDocument? {
        guard case .object(let fields) = self else { return nil }
        return fields.first { $0.0 == field }?.1
    }
}

extension BerryDocument {
    /// Plain-JSON round-trip (no Mongo/Qdrant extensions) — the common case
    /// for Qdrant payloads and REST bodies. Extended types (`.objectID`,
    /// `.vector`, `.binary`, `.date`) degrade to their JSON-safe representation;
    /// drivers needing exact BSON fidelity build `BerryDocument` directly from
    /// the wire format instead of going through this initializer.
    public init(jsonObject: Any) {
        switch jsonObject {
        case is NSNull:
            self = .null
        case let v as NSNumber:
            // `JSONSerialization` bridges BOTH JSON booleans and JSON numbers
            // to `NSNumber` — for a literal `0`/`1`, Swift's `as? Bool` and
            // `as? Int` both succeed (a well-known NSNumber/Bool bridging
            // ambiguity), so checking `as? Bool` first — the naive order —
            // silently mistypes an integer `0`/`1` field (e.g. Mongo's
            // `$sort` direction) as a boolean. `objCType` is the reliable
            // signal: real JSON `true`/`false` decode as an ObjC `BOOL`
            // (`"c"`); real JSON numbers never do.
            if String(cString: v.objCType) == "c" {
                self = .bool(v.boolValue)
            } else if let i = v as? Int64 {
                self = .int(i)
            } else {
                self = .double(v.doubleValue)
            }
        case let v as String:
            self = .string(v)
        case let v as [Any]:
            self = .array(v.map { BerryDocument(jsonObject: $0) })
        case let v as [String: Any]:
            self = .object(v.map { ($0.key, BerryDocument(jsonObject: $0.value)) })
        default:
            self = .null
        }
    }

    /// Inverse of `init(jsonObject:)` — `Foundation.JSONSerialization`-compatible.
    public var jsonObject: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .string(let v): return v
        case .binary(let v): return v.base64EncodedString()
        case .objectID(let v): return v
        case .date(let v): return ISO8601DateFormatter().string(from: v)
        case .vector(let v): return v.map { Double($0) }
        case .array(let v): return v.map(\.jsonObject)
        // Not uniqueKeysWithValues: `.object` deliberately tolerates
        // duplicate keys (ordered pairs, not a Dictionary) since BSON
        // permits them on the wire — collapsing here must not trap. Last
        // value wins, matching how a real Dictionary literal with repeated
        // keys would resolve.
        case .object(let v): return Dictionary(v.map { ($0.0, $0.1.jsonObject) }, uniquingKeysWith: { _, last in last })
        }
    }
}
