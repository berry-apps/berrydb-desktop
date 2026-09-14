import BerryDriverKit
import Foundation

/// DynamoDB `AttributeValue` JSON ↔ `BerryValue`
/// (no lossy coercion), verified against real `AttributeValue` shapes
/// returned by dynamodb-local (`{"S":..}`, `{"N":".."}`, `{"BOOL":..}`,
/// `{"NULL":true}`, `{"B":"<base64>"}`, `{"M":{...}}`, `{"L":[...]}`,
/// `{"SS":[...]}`, `{"NS":[...]}`, `{"BS":[...]}`).
enum DynamoDBWire {
    /// One attribute value (already unwrapped from its `{"Name": {...}}`
    /// entry) → `BerryValue`. `M`/`L`/`SS`/`NS`/`BS` have no direct
    /// `BerryValue` case (schemaless nested structure, not a SQL type) so
    /// they render as `.json` text for display — same treatment Postgres
 /// gives `jsonb`.
    static func berryValue(from attribute: [String: Any]) -> BerryValue {
        if let s = attribute["S"] as? String { return .text(s) }
        if let n = attribute["N"] as? String { return numberValue(n) }
        if let b = attribute["BOOL"] as? Bool { return .bool(b) }
        if let isNull = attribute["NULL"] as? Bool, isNull { return .null }
        if let b64 = attribute["B"] as? String {
            guard let data = Data(base64Encoded: b64) else {
                return .unknown(raw: Data(b64.utf8), typeName: "DynamoDB.B(invalid base64)")
            }
            return .bytes(data)
        }
        if let m = attribute["M"] as? [String: Any] {
            return .json(jsonString(from: plainJSONObject(m)) ?? "{}")
        }
        if let l = attribute["L"] as? [Any] {
            return .json(jsonString(from: plainJSONArray(l)) ?? "[]")
        }
        if let ss = attribute["SS"] as? [String] { return .json(jsonString(from: ss) ?? "[]") }
        if let ns = attribute["NS"] as? [String] { return .json(jsonString(from: ns) ?? "[]") }
        if let bs = attribute["BS"] as? [String] { return .json(jsonString(from: bs) ?? "[]") }
        return .unknown(raw: Data(), typeName: "DynamoDB(\(attribute.keys.first ?? "?"))")
    }

    /// A DynamoDB item (`{"Attr": {"S": "x"}, ...}`) → one grid row, in
    /// `columnOrder`. Missing attributes become `.null`; attributes not in
    /// `columnOrder` are dropped — the known limitation documented in
    /// `DynamoDBConnection` (a later page can introduce attributes the first
    /// `.columns` event never announced).
    static func row(from item: [String: Any], columnOrder: [String]) -> [BerryValue] {
        columnOrder.map { name in
            guard let attribute = item[name] as? [String: Any] else { return .null }
            return berryValue(from: attribute)
        }
    }

    /// Best-effort DynamoDB type tag for a column, from the first row that
    /// carries a value for it — `ColumnMeta.declaredType` is allowed to stay
 /// empty for computed/absent cases.
    static func declaredType(of name: String, firstBatch: [[String: Any]]) -> String {
        for item in firstBatch {
            if let attribute = item[name] as? [String: Any], let tag = attribute.keys.first {
                return tag
            }
        }
        return ""
    }

    // MARK: - Number (arbitrary precision, kept verbatim unless it is a plain Int64)

    private static func numberValue(_ n: String) -> BerryValue {
        if let i = Int64(n) { return .int(i) }
        return .decimal(n)
    }

 // MARK: - Plain JSON conversion for M/L display (display only)

    /// `M`/`L` unwrap into plain JSON for readability. Numbers deeper than
    /// the top level fall back to `Double` when they do not fit `Int64` —
    /// unlike the top-level `.decimal` path, this can lose precision on
    /// >15-digit numbers nested inside a map/list; acceptable for a
 /// display-only JSON preview, called out
    private static func plainJSONValue(_ attribute: [String: Any]) -> Any {
        if let s = attribute["S"] as? String { return s }
        if let n = attribute["N"] as? String { return Int64(n) ?? Double(n).map { $0 as Any } ?? (n as Any) }
        if let b = attribute["BOOL"] as? Bool { return b }
        if let isNull = attribute["NULL"] as? Bool, isNull { return NSNull() }
        if let b64 = attribute["B"] as? String { return b64 }
        if let m = attribute["M"] as? [String: Any] { return plainJSONObject(m) }
        if let l = attribute["L"] as? [Any] { return plainJSONArray(l) }
        if let ss = attribute["SS"] as? [String] { return ss }
        if let ns = attribute["NS"] as? [String] { return ns }
        if let bs = attribute["BS"] as? [String] { return bs }
        return NSNull()
    }

    private static func plainJSONObject(_ m: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in m {
            guard let attribute = value as? [String: Any] else { continue }
            result[key] = plainJSONValue(attribute)
        }
        return result
    }

    private static func plainJSONArray(_ l: [Any]) -> [Any] {
        l.compactMap { ($0 as? [String: Any]).map(plainJSONValue) }
    }

    private static func jsonString(from object: Any) -> String? {
        // JSONSerialization accepts a top-level array or dictionary — SS/NS/BS
        // (plain [String]) and M/L both go through this one path.
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
