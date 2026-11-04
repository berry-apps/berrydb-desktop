import Foundation

/// One DynamoDB attribute value, kept lossless: numbers stay the decimal text
/// DynamoDB sent (up to 38 digits, beyond what `Double` holds) and binary stays
/// bytes. Shapes: https://docs.aws.amazon.com/amazondynamodb/latest/APIReference/API_AttributeValue.html
public indirect enum DynamoDBAttributeValue: Sendable, Equatable, Encodable {
    case string(String)
    case number(String)
    case binary(Data)
    case bool(Bool)
    case null
    case list([DynamoDBAttributeValue])
    case map([String: DynamoDBAttributeValue])
    case stringSet([String])
    case numberSet([String])
    case binarySet([Data])

    /// Reads one `{"S": …}` entry. Throws on an unknown tag, a value of the
    /// wrong shape, or base64 that does not decode, so a response the codec
    /// cannot represent faithfully is refused instead of altered.
    public init(json: Any) throws {
        guard let entry = json as? [String: Any], entry.count == 1, let (tag, raw) = entry.first else {
            throw Self.malformed("expected one tagged entry")
        }
        switch tag {
        case "S": self = .string(try Self.text(raw, tag))
        case "N": self = .number(try Self.text(raw, tag))
        case "B": self = .binary(try Self.bytes(raw, tag))
        case "BOOL":
            guard let flag = raw as? Bool else { throw Self.malformed("BOOL is not a boolean") }
            self = .bool(flag)
        case "NULL": self = .null
        case "L":
            guard let items = raw as? [Any] else { throw Self.malformed("L is not a list") }
            self = .list(try items.map { try DynamoDBAttributeValue(json: $0) })
        case "M":
            guard let members = raw as? [String: Any] else { throw Self.malformed("M is not a map") }
            self = .map(try members.mapValues { try DynamoDBAttributeValue(json: $0) })
        case "SS": self = .stringSet(try Self.texts(raw, tag))
        case "NS": self = .numberSet(try Self.texts(raw, tag))
        case "BS":
            guard let items = raw as? [Any] else { throw Self.malformed("BS is not a list") }
            self = .binarySet(try items.map { try Self.bytes($0, tag) })
        default:
            throw DriverError.queryFailed(message: "Unsupported attribute value tag: \(tag)", code: nil)
        }
    }

    /// The same single-entry shape, for a request body.
    public var json: [String: Any] {
        switch self {
        case .string(let value): return ["S": value]
        case .number(let value): return ["N": value]
        case .binary(let value): return ["B": value.base64EncodedString()]
        case .bool(let value): return ["BOOL": value]
        case .null: return ["NULL": true]
        case .list(let items): return ["L": items.map(\.json)]
        case .map(let members): return ["M": members.mapValues(\.json)]
        case .stringSet(let values): return ["SS": values]
        case .numberSet(let values): return ["NS": values]
        case .binarySet(let values): return ["BS": values.map { $0.base64EncodedString() }]
        }
    }

    private enum Tag: String, CodingKey {
        case S, N, B, BOOL, NULL, L, M, SS, NS, BS
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Tag.self)
        switch self {
        case .string(let value): try container.encode(value, forKey: .S)
        case .number(let value): try container.encode(value, forKey: .N)
        case .binary(let value): try container.encode(value.base64EncodedString(), forKey: .B)
        case .bool(let value): try container.encode(value, forKey: .BOOL)
        case .null: try container.encode(true, forKey: .NULL)
        case .list(let items): try container.encode(items, forKey: .L)
        case .map(let members): try container.encode(members, forKey: .M)
        case .stringSet(let values): try container.encode(values, forKey: .SS)
        case .numberSet(let values): try container.encode(values, forKey: .NS)
        case .binarySet(let values): try container.encode(values.map { $0.base64EncodedString() }, forKey: .BS)
        }
    }

    private static func malformed(_ detail: String) -> DriverError {
        .queryFailed(message: "Malformed attribute value: \(detail)", code: nil)
    }

    private static func text(_ raw: Any, _ tag: String) throws -> String {
        guard let text = raw as? String else { throw malformed("\(tag) is not a string") }
        return text
    }

    private static func texts(_ raw: Any, _ tag: String) throws -> [String] {
        guard let items = raw as? [Any] else { throw malformed("\(tag) is not a list") }
        return try items.map { try text($0, tag) }
    }

    private static func bytes(_ raw: Any, _ tag: String) throws -> Data {
        guard let data = Data(base64Encoded: try text(raw, tag)) else {
            throw malformed("\(tag) is not valid base64")
        }
        return data
    }
}

public enum DynamoDBKeyType: String, Sendable {
    case string = "S", number = "N", binary = "B"
}

public struct DynamoDBKeyAttribute: Sendable, Equatable {
    public let name: String
    public let type: DynamoDBKeyType

    public init(name: String, type: DynamoDBKeyType) {
        self.name = name
        self.type = type
    }
}

public struct DynamoDBIndexKeySchema: Sendable, Equatable {
    public let name: String
    public let partitionKey: DynamoDBKeyAttribute
    public let sortKey: DynamoDBKeyAttribute?

    public init(name: String, partitionKey: DynamoDBKeyAttribute, sortKey: DynamoDBKeyAttribute?) {
        self.name = name
        self.partitionKey = partitionKey
        self.sortKey = sortKey
    }
}

public struct DynamoDBKeySchema: Sendable, Equatable {
    public let table: String
    public let partitionKey: DynamoDBKeyAttribute
    public let sortKey: DynamoDBKeyAttribute?
    public let indexes: [DynamoDBIndexKeySchema]

    public init(
        table: String, partitionKey: DynamoDBKeyAttribute, sortKey: DynamoDBKeyAttribute?,
        indexes: [DynamoDBIndexKeySchema]
    ) {
        self.table = table
        self.partitionKey = partitionKey
        self.sortKey = sortKey
        self.indexes = indexes
    }

    public func index(named name: String) -> DynamoDBIndexKeySchema? {
        indexes.first { $0.name == name }
    }

    /// The table's key names followed by the index's, each once. A query on an
    /// index returns the table keys with every item, so a caller that checks
    /// which attributes are keys needs both sets.
    public func keyAttributeNames(index: String?) -> [String] {
        var names = [partitionKey.name]
        if let sortKey { names.append(sortKey.name) }
        if let index, let schema = self.index(named: index) {
            for attribute in [schema.partitionKey] + (schema.sortKey.map { [$0] } ?? []) where !names.contains(attribute.name) {
                names.append(attribute.name)
            }
        }
        return names
    }
}

public enum DynamoDBKeyValue: Sendable, Equatable {
    case string(String)
    case number(String)
    case binary(Data)

    public var attributeValue: DynamoDBAttributeValue {
        switch self {
        case .string(let value): return .string(value)
        case .number(let value): return .number(value)
        case .binary(let value): return .binary(value)
        }
    }

    public var type: DynamoDBKeyType {
        switch self {
        case .string: return .string
        case .number: return .number
        case .binary: return .binary
        }
    }
}

public enum DynamoDBSortKeyCondition: Sendable, Equatable {
    case equal(DynamoDBKeyValue)
    case lessThan(DynamoDBKeyValue)
    case lessThanOrEqual(DynamoDBKeyValue)
    case greaterThan(DynamoDBKeyValue)
    case greaterThanOrEqual(DynamoDBKeyValue)
    case between(DynamoDBKeyValue, DynamoDBKeyValue)
    case beginsWith(DynamoDBKeyValue)
}

public struct DynamoDBPartitionQuery: Sendable, Equatable {
    public let table: String
    public let indexName: String?
    public let partitionKey: DynamoDBKeyValue
    public let sortKey: DynamoDBSortKeyCondition?
    public let projection: [String]?
    public let limit: Int
    public let exclusiveStartKey: [String: DynamoDBAttributeValue]?

    public init(
        table: String, indexName: String?, partitionKey: DynamoDBKeyValue,
        sortKey: DynamoDBSortKeyCondition?, projection: [String]?, limit: Int,
        exclusiveStartKey: [String: DynamoDBAttributeValue]?
    ) {
        self.table = table
        self.indexName = indexName
        self.partitionKey = partitionKey
        self.sortKey = sortKey
        self.projection = projection
        self.limit = limit
        self.exclusiveStartKey = exclusiveStartKey
    }
}

public struct DynamoDBQueryPage: Sendable, Equatable {
    public let items: [[String: DynamoDBAttributeValue]]
    public let lastEvaluatedKey: [String: DynamoDBAttributeValue]?
    public let consumedCapacityUnits: Double?
    public let scannedCount: Int

    public init(
        items: [[String: DynamoDBAttributeValue]], lastEvaluatedKey: [String: DynamoDBAttributeValue]?,
        consumedCapacityUnits: Double?, scannedCount: Int
    ) {
        self.items = items
        self.lastEvaluatedKey = lastEvaluatedKey
        self.consumedCapacityUnits = consumedCapacityUnits
        self.scannedCount = scannedCount
    }
}

/// A connection that reads one partition of a DynamoDB table. Found with
/// `as? any PartitionQuerying`, like `ReadOnlyExecuting`. `keySchema` reads the
/// table's key attributes and index key schemas (`DescribeTable`);
/// `queryPartition` runs exactly one `Query`
/// (https://docs.aws.amazon.com/amazondynamodb/latest/APIReference/API_Query.html)
/// and returns its one page. Neither call issues anything else.
public protocol PartitionQuerying: DriverConnection {
    func keySchema(of table: String) async throws -> DynamoDBKeySchema
    func queryPartition(_ query: DynamoDBPartitionQuery) async throws -> DynamoDBQueryPage
}
