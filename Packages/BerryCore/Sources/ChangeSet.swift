import BerryDriverKit
import Foundation

/// Staged grid edits.
///
/// Every mutation is keyed by the row's primary key; tables without a
/// PK/unique key stay read-only (`canEdit == false`), matching the safety
/// rule in the flow. Nothing touches the DBMS until `apply` — and even then
/// the generated SQL is shown to the user first (SQL preview) and runs
/// through the single QueryService path (N1) inside a transaction.
public struct ChangeSet: Sendable {
    public typealias RowKey = [String: BerryValue]

    public enum Change: Equatable, Sendable {
        case update(pk: RowKey, column: String, value: BerryValue)
        case insert(values: RowKey)
        case delete(pk: RowKey)
    }

    public let table: TableRef
    public let pkColumns: [String]
    public private(set) var changes: [Change] = []

    public init(table: TableRef, pkColumns: [String]) {
        self.table = table
        self.pkColumns = pkColumns
    }

    /// Editing requires a primary key — otherwise a WHERE clause could match
 /// more rows than the one the user touched.
    public var canEdit: Bool { !pkColumns.isEmpty }
    public var isEmpty: Bool { changes.isEmpty }
    public var count: Int { changes.count }

    // MARK: - Staging

    /// Coalesces repeated edits of the same cell — the last value wins.
    public mutating func stageUpdate(pk: RowKey, column: String, value: BerryValue) {
        changes.removeAll {
            if case .update(let existingPK, let existingColumn, _) = $0 {
                return existingPK == pk && existingColumn == column
            }
            return false
        }
        changes.append(.update(pk: pk, column: column, value: value))
    }

    public mutating func stageInsert(values: RowKey) {
        changes.append(.insert(values: values))
    }

    /// Deleting a row drops any pending updates for it — they would target a
    /// row that no longer exists.
    public mutating func stageDelete(pk: RowKey) {
        changes.removeAll {
            if case .update(let existingPK, _, _) = $0 {
                return existingPK == pk
            }
            return false
        }
        // Idempotent: a second delete of the same row is a no-op.
        guard !changes.contains(.delete(pk: pk)) else { return }
        changes.append(.delete(pk: pk))
    }

    public mutating func clear() {
        changes.removeAll()
    }

    // MARK: - SQL generation (SQL preview + apply)

    /// One statement per change, in staging order — this is exactly what the
    /// SQL preview shows and what `apply` executes.
    public func statements(dialect: any SQLDialect) -> [String] {
        changes.map { change in
            switch change {
            case .update(let pk, let column, let value):
                return "UPDATE \(dialect.qualifiedName(of: table)) SET "
                    + "\(dialect.quoteIdentifier(column)) = \(dialect.literal(value))"
                    + " WHERE " + whereClause(pk: pk, dialect: dialect)
            case .insert(let values):
                let columns = values.keys.sorted()
                let names = columns.map(dialect.quoteIdentifier).joined(separator: ", ")
                let rendered = columns.map { dialect.literal(values[$0]!) }.joined(separator: ", ")
                return "INSERT INTO \(dialect.qualifiedName(of: table)) (\(names)) VALUES (\(rendered))"
            case .delete(let pk):
                return "DELETE FROM \(dialect.qualifiedName(of: table))"
                    + " WHERE " + whereClause(pk: pk, dialect: dialect)
            }
        }
    }

    private func whereClause(pk: RowKey, dialect: any SQLDialect) -> String {
        pk.keys.sorted().map { column in
            let value = pk[column]!
            if case .null = value {
                return "\(dialect.quoteIdentifier(column)) IS NULL"
            }
            return "\(dialect.quoteIdentifier(column)) = \(dialect.literal(value))"
        }
        .joined(separator: " AND ")
    }

 // MARK: - Apply

    /// BEGIN → each statement → COMMIT; any failure rolls back and rethrows.
    /// Returns the number of executed statements.
    @discardableResult
    public func apply(on session: Session) async throws -> Int {
        guard !isEmpty else { return 0 }
        let useTransaction = session.capabilities.transactions

        func run(_ sql: String) async throws {
            for try await _ in QueryService.execute(
                sql, on: session, autoLimit: nil,
                // The SQL preview the user just approved IS the confirmation
 // (06) — don't stack a second delete dialog, and never
                // block a headless run on an alert.
                dangerPreconfirmed: true
            ) {}
        }

        if useTransaction { try await run("BEGIN") }
        do {
            for sql in statements(dialect: session.dialect) {
                try await run(sql)
            }
            if useTransaction { try await run("COMMIT") }
        } catch {
            if useTransaction { try? await run("ROLLBACK") }
            throw error
        }
        return changes.count
    }
}
