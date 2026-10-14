/// Schema description types — introspection results,
/// fed into SchemaCatalog to serve the sidebar and autocomplete.

public struct DatabaseInfo: Sendable, Hashable {
    public let name: String
    public init(name: String) { self.name = name }
}

public enum SchemaObjectKind: String, Sendable, Hashable {
    case table
    case view
    case function
    case procedure
    case trigger
    case index

 /// Whether the object holds rows and can open in a data grid.
 /// Routines and triggers are DDL-only in the sidebar.
    public var isRelational: Bool { self == .table || self == .view }
}

public struct SchemaObject: Sendable, Hashable, Identifiable {
    public let kind: SchemaObjectKind
    public let name: String
    /// Database/schema containing the object — nil for SQLite (one file = one db).
    public let database: String?

    public var id: String { "\(database ?? "").\(kind.rawValue).\(name)" }

    /// Display form for "Copy Qualified Name" (sidebar) — `database.name` when
    /// the driver has a database/schema concept, else the bare name (SQLite).
    public var qualifiedName: String {
        database.map { "\($0).\(name)" } ?? name
    }

    public init(kind: SchemaObjectKind, name: String, database: String? = nil) {
        self.kind = kind
        self.name = name
        self.database = database
    }
}

public struct TableRef: Sendable, Hashable {
    public let database: String?
    public let name: String
    public init(database: String? = nil, name: String) {
        self.database = database
        self.name = name
    }
}

public struct ColumnInfo: Sendable, Hashable {
    public let name: String
    public let declaredType: String
    public let isNullable: Bool
    public let defaultValue: String?
    public let isPrimaryKey: Bool

    public init(name: String, declaredType: String, isNullable: Bool,
                defaultValue: String?, isPrimaryKey: Bool) {
        self.name = name
        self.declaredType = declaredType
        self.isNullable = isNullable
        self.defaultValue = defaultValue
        self.isPrimaryKey = isPrimaryKey
    }
}

public struct IndexInfo: Sendable, Hashable {
    public let name: String
    public let isUnique: Bool
    public let columns: [String]
    public init(name: String, isUnique: Bool, columns: [String]) {
        self.name = name
        self.isUnique = isUnique
        self.columns = columns
    }
}

public struct ForeignKeyInfo: Sendable, Hashable {
    public let column: String
    public let referencedSchema: String?
    public let referencedTable: String
    public let referencedColumn: String

    public init(
        column: String,
        referencedSchema: String? = nil,
        referencedTable: String,
        referencedColumn: String
    ) {
        self.column = column
        self.referencedSchema = referencedSchema
        self.referencedTable = referencedTable
        self.referencedColumn = referencedColumn
    }
}

public struct TableDetail: Sendable {
    public let ref: TableRef
    public let columns: [ColumnInfo]
    public let indexes: [IndexInfo]
    public let foreignKeys: [ForeignKeyInfo]

    public init(ref: TableRef, columns: [ColumnInfo],
                indexes: [IndexInfo], foreignKeys: [ForeignKeyInfo]) {
        self.ref = ref
        self.columns = columns
        self.indexes = indexes
        self.foreignKeys = foreignKeys
    }
}

/// Which schemas a harvest reads. `allUserSchemas` is the default scope:
/// every schema except the engine's own system schemas, which each driver
/// names. On MySQL and MariaDB, where a schema is a database, it is the
/// connection's database when one is selected, and every database but the
/// system ones only when none is. Engines with a single namespace ignore the
/// scope.
public enum SchemaScope: Sendable, Hashable {
    case allUserSchemas
    case schemas([String])
}

/// One table or view as the catalog lists it, with the engine's own
/// fingerprint of its definition, computed in the same query that lists the
/// object. Two equal fingerprints mean the definition did not change; the
/// value is otherwise opaque. Nil when the engine has no such signal, in
/// which case the table is fetched in full on every change of the catalog
/// version.
public struct SchemaObjectSummary: Sendable, Hashable {
    public let ref: TableRef
    public let kind: SchemaObjectKind
    public let fingerprint: String?

    public init(ref: TableRef, kind: SchemaObjectKind, fingerprint: String?) {
        self.ref = ref
        self.kind = kind
        self.fingerprint = fingerprint
    }
}

/// One column pair of a foreign key, listed for a whole scope at once. A
/// multi-column key is one element per pair, as `ForeignKeyInfo` models it
/// per table.
public struct ForeignKeyRelation: Sendable, Hashable {
    public let source: TableRef
    public let column: String
    public let target: TableRef
    public let referencedColumn: String
    public let constraintName: String?

    public init(
        source: TableRef, column: String, target: TableRef, referencedColumn: String,
        constraintName: String? = nil
    ) {
        self.source = source
        self.column = column
        self.target = target
        self.referencedColumn = referencedColumn
        self.constraintName = constraintName
    }
}

/// Best-effort quick-info stats for a table. `estimatedRowCount` is a
/// cheap catalog estimate where the DBMS tracks one (Postgres/MySQL/DynamoDB),
/// an exact `COUNT(*)` for SQLite (no catalog estimate available there). Any
/// field the DBMS doesn't support/expose is nil — the UI shows "—" for it,
/// never a fake value.
public struct TableStats: Sendable {
    public let estimatedRowCount: Int64?
    public let sizeBytes: Int64?
    public let engine: String?
    public let comment: String?

    public init(estimatedRowCount: Int64?, sizeBytes: Int64?, engine: String?, comment: String?) {
        self.estimatedRowCount = estimatedRowCount
        self.sizeBytes = sizeBytes
        self.engine = engine
        self.comment = comment
    }
}
