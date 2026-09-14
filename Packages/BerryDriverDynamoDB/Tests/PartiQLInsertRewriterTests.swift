import Foundation
import Testing

@testable import BerryDriverDynamoDB

/// `PartiQLInsertRewriter` translates ChangeSet's generic
/// `INSERT INTO t (c1, c2) VALUES (v1, v2)` into DynamoDB's actual
/// `INSERT INTO t VALUE {'c1': v1, 'c2': v2}` syntax — verified necessary
/// against dynamodb-local (the generic form is rejected with
/// `ValidationException: Statement wasn't well formed`).
@Suite("PartiQLInsertRewriter")
struct PartiQLInsertRewriterTests {
    @Test func rewritesTheExactShapeChangeSetGenerates() {
        let input = #"INSERT INTO "Music" ("Artist", "SongTitle") VALUES ('Acme Band', 'PartiQL Rocks')"#
        let output = PartiQLInsertRewriter.rewrite(input)
        #expect(output == #"INSERT INTO "Music" VALUE {'Artist': 'Acme Band', 'SongTitle': 'PartiQL Rocks'}"#)
    }

    @Test func handlesNumericBooleanAndNullValues() {
        let input = #"INSERT INTO "T" ("A", "B", "C") VALUES (42, TRUE, NULL)"#
        let output = PartiQLInsertRewriter.rewrite(input)
        #expect(output == #"INSERT INTO "T" VALUE {'A': 42, 'B': TRUE, 'C': NULL}"#)
    }

    @Test func doesNotSplitOnACommaInsideAStringValue() {
        let input = #"INSERT INTO "T" ("Note") VALUES ('Hello, World')"#
        let output = PartiQLInsertRewriter.rewrite(input)
        #expect(output == #"INSERT INTO "T" VALUE {'Note': 'Hello, World'}"#)
    }

    @Test func doesNotSplitOnACloseParenInsideAStringValue() {
        let input = #"INSERT INTO "T" ("Note") VALUES ('a) b')"#
        let output = PartiQLInsertRewriter.rewrite(input)
        #expect(output == #"INSERT INTO "T" VALUE {'Note': 'a) b'}"#)
    }

    /// `"a""b"` un-escapes (double-quote doubling) to the raw name `a"b` —
    /// which then needs NO further escaping once single-quoted, since a bare
    /// `"` isn't the delimiter character inside a `'...'` string.
    @Test func unescapesDoubledQuotesInColumnNames() {
        let input = #"INSERT INTO "T" ("a""b") VALUES ('x')"#
        let output = PartiQLInsertRewriter.rewrite(input)
        #expect(output == #"INSERT INTO "T" VALUE {'a"b': 'x'}"#)
    }

    @Test func preservesDoubledSingleQuotesInsideStringValues() {
        let input = #"INSERT INTO "T" ("Note") VALUES ('it''s here')"#
        let output = PartiQLInsertRewriter.rewrite(input)
        #expect(output == #"INSERT INTO "T" VALUE {'Note': 'it''s here'}"#)
    }

    @Test func singleColumnInsert() {
        let input = #"INSERT INTO "T" ("UserID") VALUES ('u1')"#
        let output = PartiQLInsertRewriter.rewrite(input)
        #expect(output == #"INSERT INTO "T" VALUE {'UserID': 'u1'}"#)
    }

    // MARK: - Passthrough (anything that doesn't match ChangeSet's exact shape)

    @Test func passesThroughAHandWrittenValueFormInsertUnchanged() {
        let input = #"INSERT INTO "Music" VALUE {'Artist': 'Acme Band'}"#
        #expect(PartiQLInsertRewriter.rewrite(input) == input)
    }

    @Test func passesThroughNonInsertStatementsUnchanged() {
        let select = #"SELECT * FROM "Music" WHERE "Artist" = 'Acme Band'"#
        #expect(PartiQLInsertRewriter.rewrite(select) == select)
        let update = #"UPDATE "Music" SET "Awards" = 1 WHERE "Artist" = 'Acme Band'"#
        #expect(PartiQLInsertRewriter.rewrite(update) == update)
        let delete = #"DELETE FROM "Music" WHERE "Artist" = 'Acme Band'"#
        #expect(PartiQLInsertRewriter.rewrite(delete) == delete)
    }

    @Test func passesThroughMalformedInsertsUnchanged() {
        let noParens = #"INSERT INTO "Music" VALUES ('x')"#
        #expect(PartiQLInsertRewriter.rewrite(noParens) == noParens)
        let mismatchedCounts = #"INSERT INTO "T" ("a", "b") VALUES ('x')"#
        #expect(PartiQLInsertRewriter.rewrite(mismatchedCounts) == mismatchedCounts)
    }
}
