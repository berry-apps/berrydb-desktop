import BerryDriverKit
import BerryStore
import Foundation

/// A table's or view's structure in a canonical form: columns in ordinal
/// order, indexes sorted by name. Two equal definitions hash equal, so a
/// harvest writes a new version only when something an agent could observe
/// changed. Foreign keys are not part of it; they are relations between
/// objects and are stored and diffed separately.
public struct SchemaDefinition: Codable, Equatable, Sendable {
    public struct Column: Codable, Equatable, Sendable {
        public let name: String
        public let type: String
        public let nullable: Bool
        public let defaultValue: String?
        public let primaryKey: Bool

        public init(name: String, type: String, nullable: Bool, defaultValue: String?, primaryKey: Bool) {
            self.name = name
            self.type = type
            self.nullable = nullable
            self.defaultValue = defaultValue
            self.primaryKey = primaryKey
        }
    }

    public struct Index: Codable, Equatable, Sendable {
        public let name: String
        public let unique: Bool
        public let columns: [String]

        public init(name: String, unique: Bool, columns: [String]) {
            self.name = name
            self.unique = unique
            self.columns = columns
        }
    }

    public let columns: [Column]
    public let indexes: [Index]

    public init(columns: [Column], indexes: [Index]) {
        self.columns = columns
        self.indexes = indexes.sorted { $0.name < $1.name }
    }

    /// Routes decoded values through `init(columns:indexes:)`, so stored JSON
    /// whose indexes are not in name order, written by another build or by
    /// hand, still hashes and compares like the canonical definition.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            columns: try container.decode([Column].self, forKey: .columns),
            indexes: try container.decode([Index].self, forKey: .indexes)
        )
    }

    public init(detail: TableDetail) {
        self.init(
            columns: detail.columns.map {
                Column(name: $0.name, type: $0.declaredType, nullable: $0.isNullable,
                       defaultValue: $0.defaultValue, primaryKey: $0.isPrimaryKey)
            },
            indexes: detail.indexes.map { Index(name: $0.name, unique: $0.isUnique, columns: $0.columns) }
        )
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    /// Sorted keys and no whitespace, so the same definition always produces
    /// the same bytes and the same hash.
    public func json() throws -> String {
        String(decoding: try Self.encoder.encode(self), as: UTF8.self)
    }

    public static func decode(_ json: String) throws -> SchemaDefinition {
        try JSONDecoder().decode(SchemaDefinition.self, from: Data(json.utf8))
    }

    /// The hash of the canonical JSON. It encodes the definition; a caller
    /// that also stores the JSON hashes the text it encoded instead.
    public var hash: String {
        ContentHash.fnv1a64((try? json()) ?? "")
    }

    /// Every column name, folded and newline-separated: the text a column
    /// search matches against.
    public var columnText: String {
        SchemaSearchText.joined(columns.map(\.name))
    }

    /// Every index name, folded and newline-separated: the text an index
    /// search matches against.
    public var indexText: String {
        SchemaSearchText.joined(indexes.map(\.name))
    }

    public static func diff(from: SchemaDefinition, to: SchemaDefinition) -> SchemaDefinitionDiff {
        let before = Dictionary(from.columns.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let after = Dictionary(to.columns.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let added = to.columns.map(\.name).filter { before[$0] == nil }
        let removed = from.columns.map(\.name).filter { after[$0] == nil }
        let changed = to.columns.compactMap { column -> SchemaDefinitionDiff.ColumnChange? in
            guard let old = before[column.name], old != column else { return nil }
            return .init(name: column.name, from: old, to: column)
        }
        // Column order is part of the hash, so a reorder is a real change. Only
        // the names present on both sides are compared: an added or removed
        // column is reported by name and must not also read as a reorder.
        let commonColumns = Set(before.keys).intersection(after.keys)
        let reordered = from.columns.map(\.name).filter(commonColumns.contains)
            != to.columns.map(\.name).filter(commonColumns.contains)
        let beforeIndexes = Dictionary(from.indexes.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let afterIndexes = Set(to.indexes.map(\.name))
        let changedIndexes = to.indexes.compactMap { index -> SchemaDefinitionDiff.IndexChange? in
            guard let old = beforeIndexes[index.name], old != index else { return nil }
            return .init(name: index.name, from: old, to: index)
        }
        return SchemaDefinitionDiff(
            columnsAdded: added, columnsRemoved: removed, columnsChanged: changed,
            columnsReordered: reordered,
            indexesAdded: to.indexes.map(\.name).filter { beforeIndexes[$0] == nil },
            indexesRemoved: from.indexes.map(\.name).filter { !afterIndexes.contains($0) },
            indexesChanged: changedIndexes
        )
    }
}

public struct SchemaDefinitionDiff: Equatable, Sendable, Codable {
    public struct ColumnChange: Equatable, Sendable, Codable {
        public let name: String
        public let from: SchemaDefinition.Column
        public let to: SchemaDefinition.Column
    }

    public struct IndexChange: Equatable, Sendable, Codable {
        public let name: String
        public let from: SchemaDefinition.Index
        public let to: SchemaDefinition.Index
    }

    public let columnsAdded: [String]
    public let columnsRemoved: [String]
    public let columnsChanged: [ColumnChange]
    public let columnsReordered: Bool
    public let indexesAdded: [String]
    public let indexesRemoved: [String]
    public let indexesChanged: [IndexChange]

    public var isEmpty: Bool {
        columnsAdded.isEmpty && columnsRemoved.isEmpty && columnsChanged.isEmpty && !columnsReordered
            && indexesAdded.isEmpty && indexesRemoved.isEmpty && indexesChanged.isEmpty
    }
}
