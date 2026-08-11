import BerryDriverKit
import Foundation
import Testing

@testable import BerryDriverDynamoDB

@Suite("PartiQLDialect — SQL generation, verified against dynamodb-local behavior")
struct PartiQLDialectTests {
    private let dialect = PartiQLDialect()

    @Test func quoteIdentifierDoubleQuotesAndDoublesEmbeddedQuotes() {
        #expect(dialect.quoteIdentifier("Music") == "\"Music\"")
        #expect(dialect.quoteIdentifier("a\"b") == "\"a\"\"b\"")
    }

    /// Verified against dynamodb-local: `SELECT * FROM "T" LIMIT 10` fails
    /// with `ValidationException: Unsupported clause: LIMIT` — PartiQL SELECT
    /// has no LIMIT clause in its grammar at all, so this MUST be a no-op,
    /// not just a style choice (docs/architecture/12 §4).
    @Test func limitClauseIsANoOp() {
        #expect(dialect.limitClause(1000) == "")
    }

    /// select(...) appends `" " + limitClause(...)` when a limit is given —
    /// confirms the no-op leaves a syntactically-harmless trailing space
    /// rather than an actual LIMIT keyword.
    @Test func selectWithLimitProducesNoLimitKeyword() {
        let sql = dialect.select(
            from: TableRef(name: "Music"), whereClause: nil, orderBy: nil, limit: 1000
        )
        #expect(sql == "SELECT * FROM \"Music\" ")
        #expect(!sql.uppercased().contains("LIMIT"))
    }

    @Test func selectAllWithNoLimitHasNoTrailingSpace() {
        #expect(dialect.selectAll(from: TableRef(name: "Music"), limit: nil) == "SELECT * FROM \"Music\"")
    }

    /// Boolean literal is inherited (no override) — verify the default
    /// (TRUE/FALSE) matches PartiQL's documented "TRUE | FALSE, not case
    /// sensitive" exactly, since a wrong assumption here would silently
    /// produce invalid PartiQL for every boolean ChangeSet edit.
    @Test func boolLiteralMatchesPartiQLSyntax() {
        #expect(dialect.literal(.bool(true)) == "TRUE")
        #expect(dialect.literal(.bool(false)) == "FALSE")
    }

    @Test func nullLiteralMatchesPartiQLSyntax() {
        #expect(dialect.literal(.null) == "NULL")
    }

    @Test func numberLiteralsAreBareText() {
        #expect(dialect.literal(.int(42)) == "42")
        #expect(dialect.literal(.decimal("12345.6789")) == "12345.6789")
    }

    /// String literal escaping ('' for an embedded quote) — verified against
    /// dynamodb-local's documented rule: "escape by using two consecutive
    /// single quotes; a backslash does NOT escape and causes a validation error."
    @Test func stringLiteralUsesDoubledSingleQuoteEscaping() {
        #expect(dialect.literal(.text("it's here")) == "'it''s here'")
    }

    /// PartiQL has no Binary literal syntax at all ("N/A — only supported via
    /// code" per AWS's own data-types reference) — the override exists only
    /// to document that fact explicitly; the value it produces is NOT valid
    /// PartiQL and dynamodb-local rejects it, verified empirically.
    @Test func blobLiteralIsDocumentedAsNonFunctional() {
        let literal = dialect.literal(.bytes(Data([0xDE, 0xAD])))
        #expect(literal == "X'dead'")
    }

    @Test func qualifiedNameIgnoresDatabaseSinceDynamoDBHasNone() {
        // TableRef.database is always nil for DynamoDB (multipleDatabases == false).
        #expect(dialect.qualifiedName(of: TableRef(name: "Music")) == "\"Music\"")
    }

    @Test func processListAndKillAreUnsupported() {
        #expect(dialect.processListSQL() == nil)
        #expect(dialect.killSessionSQL(id: "1") == nil)
    }
}
