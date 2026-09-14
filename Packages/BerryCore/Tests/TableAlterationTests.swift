import BerryDriverKit
import Testing

@testable import BerryCore

private struct QuoteDialect: SQLDialect {
    func quoteIdentifier(_ identifier: String) -> String { "\"\(identifier)\"" }
    func limitClause(_ limit: Int) -> String { "LIMIT \(limit)" }
}

/// ALTER TABLE diffing.
@Suite("TableAlteration")
struct TableAlterationTests {
    private let dialect = QuoteDialect()

    private func base() -> TableDesign {
        TableDesign(
            name: "users",
            columns: [
                ColumnDesign(name: "id", type: "integer", isNullable: false, isPrimaryKey: true, defaultValue: nil),
                ColumnDesign(name: "email", type: "text", isNullable: false, isPrimaryKey: false, defaultValue: nil),
            ],
            indexes: [IndexDesign(name: "idx_email", columns: ["email"], isUnique: true)],
            foreignKeys: []
        )
    }

    @Test func addAndDropColumn() {
        var edited = base()
        edited.columns.removeAll { $0.name == "email" }
        edited.columns.append(ColumnDesign(
            name: "age", type: "integer", isNullable: true, isPrimaryKey: false, defaultValue: "0"
        ))
        let sqls = TableAlteration(original: base(), edited: edited, driver: .postgres)
            .statements(dialect: dialect)
        #expect(sqls.contains(#"ALTER TABLE "users" ADD COLUMN "age" integer DEFAULT 0"#))
        #expect(sqls.contains(#"ALTER TABLE "users" DROP COLUMN "email""#))
    }

    @Test func indexAddAndDropPerDialect() {
        var edited = base()
        edited.indexes = [IndexDesign(name: "idx_new", columns: ["id"], isUnique: false)]
        let pg = TableAlteration(original: base(), edited: edited, driver: .postgres)
            .statements(dialect: dialect)
        #expect(pg.contains(#"DROP INDEX "idx_email""#))
        #expect(pg.contains(#"CREATE INDEX "idx_new" ON "users" ("id")"#))

        let mysql = TableAlteration(original: base(), edited: edited, driver: .mysql)
            .statements(dialect: dialect)
        #expect(mysql.contains(#"ALTER TABLE "users" DROP INDEX "idx_email""#))
    }

    @Test func addForeignKeyOnlyOffSQLite() {
        var edited = base()
        edited.foreignKeys = [ForeignKeyDesign(
            column: "org_id", referencedTable: "orgs", referencedColumn: "id",
            onDelete: .cascade, onUpdate: .noAction
        )]
        let pg = TableAlteration(original: base(), edited: edited, driver: .postgres)
        #expect(pg.statements(dialect: dialect).contains(
            #"ALTER TABLE "users" ADD FOREIGN KEY ("org_id") REFERENCES "orgs" ("id") ON DELETE CASCADE"#
        ))
        let lite = TableAlteration(original: base(), edited: edited, driver: .sqlite)
        #expect(!lite.statements(dialect: dialect).contains { $0.contains("FOREIGN KEY") })
        #expect(lite.warnings.contains { $0.contains("SQLite") })
    }

    @Test func typeChangesWarnInsteadOfGuessing() {
        var edited = base()
        edited.columns[1].type = "varchar(255)"
        let alteration = TableAlteration(original: base(), edited: edited, driver: .postgres)
        #expect(alteration.statements(dialect: dialect).isEmpty)
        #expect(alteration.warnings.contains { $0.contains("email") })
    }

    @Test func noChangesNoStatements() {
        let alteration = TableAlteration(original: base(), edited: base(), driver: .postgres)
        #expect(alteration.statements(dialect: dialect).isEmpty)
        #expect(alteration.warnings.isEmpty)
    }

    /// T-SQL rejects the ADD COLUMN keyword pair outright ("Incorrect syntax
    /// near 'COLUMN'") — ADD takes no COLUMN keyword, unlike Postgres/MySQL.
    @Test func addColumnOmitsTheColumnKeywordOnSQLServer() {
        var edited = base()
        edited.columns.append(ColumnDesign(
            name: "age", type: "int", isNullable: true, isPrimaryKey: false, defaultValue: "0"
        ))
        let sqls = TableAlteration(original: base(), edited: edited, driver: .sqlserver)
            .statements(dialect: dialect)
        #expect(sqls.contains(#"ALTER TABLE "users" ADD "age" int DEFAULT 0"#))
        #expect(!sqls.contains { $0.contains("ADD COLUMN") })
    }

    /// T-SQL has no `ALTER TABLE ... DROP INDEX` clause at all — only the
    /// standalone `DROP INDEX index ON table` form works (matches
    /// IndexAdvisor.swift's own dropIndexSQL, which already groups
    /// .mysql/.sqlserver together for this exact reason, in ITS chosen
    /// statement shape — not the same shape TableAlteration's MySQL branch
    /// uses, which is why SQL Server needs its own branch here, not just
    /// joining MySQL's).
    @Test func dropIndexUsesTheStandaloneOnTableFormOnSQLServer() {
        var edited = base()
        edited.indexes = []
        let sqls = TableAlteration(original: base(), edited: edited, driver: .sqlserver)
            .statements(dialect: dialect)
        #expect(sqls.contains(#"DROP INDEX "idx_email" ON "users""#))
    }
}
