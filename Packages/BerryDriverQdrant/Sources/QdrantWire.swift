import BerryDataSourceKit
import Foundation

/// Pure JSON <-> `BerryDocument` conversions for the Qdrant REST wire format
/// (docs/architecture/12 §5) — no networking, so these are unit-testable
/// without a stubbed `URLSession`.
enum QdrantWire {
    /// A Qdrant point ID is either an unsigned integer or a UUID string.
    /// `.objectID`/`.string` both map to the string form; anything else falls
    /// back to its plain-JSON representation.
    static func pointID(from doc: BerryDocument) -> Any {
        switch doc {
        case .string(let s): return s
        case .objectID(let s): return s
        case .int(let i): return i
        default: return doc.jsonObject
        }
    }

    static func berryDocument(fromPointID id: Any) -> BerryDocument {
        switch id {
        case let s as String: return .string(s)
        case let n as Int64: return .int(n)
        case let n as Int: return .int(Int64(n))
        case let n as NSNumber: return .int(n.int64Value)
        default: return .null
        }
    }

    /// Accepts `.vector([Float])` directly, or a plain `.array` of numeric
    /// documents (e.g. built by hand rather than through `.vector`) — no
    /// information-losing coercion silently drops non-numeric elements instead
    /// of throwing, matching `BerryDocument`'s own no-loss philosophy is not
    /// possible here (a vector IS numbers), so a mismatch just yields nil.
    static func vectorArray(from doc: BerryDocument) -> [Double]? {
        switch doc {
        case .vector(let v): return v.map(Double.init)
        case .array(let items):
            var result: [Double] = []
            result.reserveCapacity(items.count)
            for item in items {
                switch item {
                case .double(let d): result.append(d)
                case .int(let i): result.append(Double(i))
                default: return nil
                }
            }
            return result
        default: return nil
        }
    }

    /// One Qdrant point (id + optional score + payload + vector) as seen in a
    /// `search`/`scroll` response, folded into the flat `BerryDocument.object`
    /// shape the driver streams to callers.
    static func document(fromPointJSON json: [String: Any]) -> BerryDocument {
        var fields: [(String, BerryDocument)] = []
        if let id = json["id"] {
            fields.append(("id", berryDocument(fromPointID: id)))
        }
        if let score = json["score"] as? NSNumber {
            fields.append(("score", .double(score.doubleValue)))
        }
        if let payload = json["payload"] as? [String: Any] {
            fields.append(("payload", BerryDocument(jsonObject: payload)))
        }
        if let vector = json["vector"] as? [Any] {
            let floats = vector.compactMap { ($0 as? NSNumber)?.floatValue }
            fields.append(("vector", .vector(floats)))
        }
        return .object(fields)
    }

    /// Short label for the union-of-payload-fields schema inference (NS-06/07)
    /// — describes shape, not a real type system (docs/architecture/12 §3).
    static func typeLabel(_ doc: BerryDocument) -> String {
        switch doc {
        case .null: return "null"
        case .bool: return "bool"
        case .int: return "int"
        case .double: return "double"
        case .string: return "string"
        case .binary: return "binary"
        case .objectID: return "objectID"
        case .date: return "date"
        case .vector: return "vector"
        case .array: return "array"
        case .object: return "object"
        }
    }
}
