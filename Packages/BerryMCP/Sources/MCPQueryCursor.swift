import BerryDriverKit
import CryptoKit
import Foundation

enum MCPQueryCursorError: Error, Equatable {
    case invalid
    case otherQuery
}

/// A continuation token for a DynamoDB query the agent pages through.
///
/// The token is the last evaluated key plus the scope it was issued for,
/// sealed with AES-GCM under a key drawn once per helper process and never
/// stored or logged. A token from another helper process therefore fails
/// authentication and is refused: a cursor has no meaning across sessions, and
/// the agent is told to start the query again.
///
/// The scope travels inside the sealed payload instead of being compared
/// against a plain side channel, so a token cannot be edited or replayed onto a
/// different profile, table, index or query: opening it under another scope
/// finds the sealed one differs and refuses.
enum MCPQueryCursor {
    struct Scope: Hashable, Sendable, Encodable {
        let profileID: UUID
        let table: String
        let indexName: String?
        let queryDigest: Data
    }

    static let processKey = SymmetricKey(size: .bits256)

    static func seal(lastKey: [String: DynamoDBAttributeValue], scope: Scope, key: SymmetricKey = processKey) throws -> String {
        let payload: [String: Any] = [
            "scope": try scopeObject(scope),
            "lastKey": lastKey.mapValues(\.json),
        ]
        let plaintext = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
        guard let combined = try AES.GCM.seal(plaintext, using: key).combined else {
            throw MCPQueryCursorError.invalid
        }
        return combined.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func open(_ token: String, scope: Scope, key: SymmetricKey = processKey) throws -> [String: DynamoDBAttributeValue] {
        var base64 = token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let combined = Data(base64Encoded: base64),
            let box = try? AES.GCM.SealedBox(combined: combined),
            let plaintext = try? AES.GCM.open(box, using: key),
            let root = (try? JSONSerialization.jsonObject(with: plaintext)) as? [String: Any],
            let sealedScope = root["scope"] as? [String: Any],
            let rawKey = root["lastKey"] as? [String: Any]
        else { throw MCPQueryCursorError.invalid }

        guard NSDictionary(dictionary: sealedScope).isEqual(to: try scopeObject(scope)) else {
            throw MCPQueryCursorError.otherQuery
        }
        do {
            return try rawKey.mapValues { try DynamoDBAttributeValue(json: $0) }
        } catch {
            throw MCPQueryCursorError.invalid
        }
    }

    /// Covers what selects rows and shapes them, so a cursor cannot be reused
    /// with a different key condition or projection. `limit` and the start key
    /// are left out: the page size may change between pages, and the start key
    /// is what the cursor itself supplies.
    static func digest(of query: DynamoDBPartitionQuery) -> Data {
        let canonical = CanonicalQuery(
            partitionKey: query.partitionKey.attributeValue,
            sortKey: query.sortKey.map(CanonicalSortKey.init),
            projection: query.projection)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Encoding plain strings and tagged values cannot fail.
        let bytes = (try? encoder.encode(canonical)) ?? Data()
        return Data(SHA256.hash(data: bytes))
    }

    private static func scopeObject(_ scope: Scope) throws -> [String: Any] {
        let data = try JSONEncoder().encode(scope)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPQueryCursorError.invalid
        }
        return object
    }

    private struct CanonicalQuery: Encodable {
        let partitionKey: DynamoDBAttributeValue
        let sortKey: CanonicalSortKey?
        let projection: [String]?
    }

    private struct CanonicalSortKey: Encodable {
        let op: String
        let values: [DynamoDBAttributeValue]

        init(_ condition: DynamoDBSortKeyCondition) {
            switch condition {
            case .equal(let value): (op, values) = ("equal", [value.attributeValue])
            case .lessThan(let value): (op, values) = ("lessThan", [value.attributeValue])
            case .lessThanOrEqual(let value): (op, values) = ("lessThanOrEqual", [value.attributeValue])
            case .greaterThan(let value): (op, values) = ("greaterThan", [value.attributeValue])
            case .greaterThanOrEqual(let value): (op, values) = ("greaterThanOrEqual", [value.attributeValue])
            case .between(let low, let high): (op, values) = ("between", [low.attributeValue, high.attributeValue])
            case .beginsWith(let value): (op, values) = ("beginsWith", [value.attributeValue])
            }
        }
    }
}
