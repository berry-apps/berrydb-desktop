import BerryDriverKit
import Foundation
import Testing

@testable import BerryDriverDynamoDB

@Suite("PartiQLNativeTranslation — grid/ChangeSet PartiQL shapes → native item API")
struct PartiQLNativeTranslationTests {
    // MARK: scanTable

    @Test func gridUnfilteredUnsortedPageIsAScan() {
        // The exact text TableTabState.reload sends: limitClause is a no-op,
        // which leaves a trailing space.
        let sql = PartiQLDialect().select(
            from: TableRef(name: "Music"), whereClause: nil, orderBy: nil, limit: 1000
        )
        #expect(PartiQLNativeTranslation.scanTable(sql) == "Music")
    }

    @Test func scanTableNamesAreUnquotedExactly() {
        #expect(PartiQLNativeTranslation.scanTable(#"SELECT * FROM "a""b""#) == #"a"b"#)
        #expect(PartiQLNativeTranslation.scanTable(#"SELECT * FROM "my.table-1""#) == "my.table-1")
        #expect(PartiQLNativeTranslation.scanTable(#"select * from "Music""#) == "Music")
    }

    @Test(arguments: [
        PartiQLDialect().select(
            from: TableRef(name: "Music"), whereClause: #""Artist" = 'Acme'"#, orderBy: nil, limit: 1000
        ),
        PartiQLDialect().select(
            from: TableRef(name: "Music"), whereClause: nil, orderBy: ("Artist", false), limit: 1000
        ),
        #"SELECT "Artist" FROM "Music""#,
        #"SELECT * FROM "Music"."ByAlbum""#,
        "SELECT * FROM Music",
        #"SELECT * FROM "Music"; DELETE FROM "Music" WHERE "Artist" = 'a'"#,
        #"SELECT * FROM "Music"#,
    ])
    func anythingButAPlainSelectStarIsNotAScan(sql: String) {
        #expect(PartiQLNativeTranslation.scanTable(sql) == nil)
    }

    // MARK: write — literals rendered by PartiQLDialect.literal

    @Test(arguments: [
        (BerryValue.text("O'Brien; DROP TABLE x"), DynamoDBScalar.string("O'Brien; DROP TABLE x")),
        (.text(#"Hello, (World) = "x""#), .string(#"Hello, (World) = "x""#)),
        (.int(42), .number("42")),
        (.int(-7), .number("-7")),
        (.double(1.5), .number("1.5")),
        (.double(1e20), .number("1e+20")),
        (.decimal("12345678901234567890.123456789"), .number("12345678901234567890.123456789")),
        (.bool(true), .bool(true)),
        (.bool(false), .bool(false)),
        (.null, .null),
        // An edited M/L cell (shown as .json) is stored as an S string by the
        // PartiQL path today; the native path must store the same thing.
        (.json(#"{"a":1}"#), .string(#"{"a":1}"#)),
    ])
    func updateLiteralRendersBackToTheSameScalar(value: BerryValue, expected: DynamoDBScalar) {
        let sql = #"UPDATE "Music" SET "Awards" = \#(PartiQLDialect().literal(value)) WHERE "Artist" = 'Acme'"#
        #expect(PartiQLNativeTranslation.write(sql) == .update(
            table: "Music", key: ["Artist": .string("Acme")], column: "Awards", value: expected
        ))
    }

    // MARK: write — ChangeSet statement shapes

    @Test func updateWithCompositeKey() {
        let sql = #"UPDATE "Music" SET "Awards" = 1 WHERE "Artist" = 'Acme' AND "SongTitle" = 'Hit'"#
        #expect(PartiQLNativeTranslation.write(sql) == .update(
            table: "Music",
            key: ["Artist": .string("Acme"), "SongTitle": .string("Hit")],
            column: "Awards", value: .number("1")
        ))
    }

    @Test func insertInChangeSetShape() {
        let sql = #"INSERT INTO "Music" ("Artist", "Awards", "SongTitle") VALUES ('Acme', 10, 'Hit')"#
        #expect(PartiQLNativeTranslation.write(sql) == .insert(
            table: "Music",
            item: ["Artist": .string("Acme"), "Awards": .number("10"), "SongTitle": .string("Hit")]
        ))
    }

    @Test func deleteInChangeSetShape() {
        let sql = #"DELETE FROM "Music" WHERE "Artist" = 'Acme' AND "SongTitle" = 'Hit'"#
        #expect(PartiQLNativeTranslation.write(sql) == .delete(
            table: "Music", key: ["Artist": .string("Acme"), "SongTitle": .string("Hit")]
        ))
    }

    @Test(arguments: [
        // Binary has no PartiQL literal; the PartiQL error must surface, not an S of hex.
        #"UPDATE "Music" SET "Blob" = \#(PartiQLDialect().literal(.bytes(Data([0xde, 0xad])))) WHERE "Artist" = 'a'"#,
        // String(Double.infinity) == "inf" — not a valid N.
        #"UPDATE "Music" SET "Score" = \#(PartiQLDialect().literal(.double(.infinity))) WHERE "Artist" = 'a'"#,
        #"DELETE FROM "Music" WHERE "Artist" IS NULL"#,
        #"DELETE FROM "Music" WHERE "Artist" = NULL"#,
        #"DELETE FROM "Music" WHERE "Artist" = 'a' AND "Artist" = 'b'"#,
        #"DELETE FROM "Music" WHERE "Artist" = 'a' RETURNING ALL OLD *"#,
        #"DELETE FROM "Music" WHERE "Artist" = 'a'; DELETE FROM "Music" WHERE "Artist" = 'b'"#,
        #"UPDATE "Music" SET "a" = 1, "b" = 2 WHERE "Artist" = 'x'"#,
        #"UPDATE "Music" SET "a" = 'x WHERE "Artist" = 'y'"#,
        #"INSERT INTO "Music" VALUE {'Artist': 'a'}"#,
        #"INSERT INTO "Music" ("a", "b") VALUES ('x')"#,
        #"INSERT INTO "Music" ("a", "a") VALUES ('x', 'y')"#,
        #"INSERT INTO "Music" () VALUES ()"#,
        #"SELECT * FROM "Music""#,
    ])
    func untranslatableWritesReturnNil(sql: String) {
        #expect(PartiQLNativeTranslation.write(sql) == nil)
    }

    @Test func eachWriteNamesTheIAMActionThatGuardsIt() {
        #expect(NativeWrite.insert(table: "t", item: [:]).partiQLAction == .insert)
        #expect(NativeWrite.update(table: "t", key: [:], column: "c", value: .null).partiQLAction == .update)
        #expect(NativeWrite.delete(table: "t", key: [:]).partiQLAction == .delete)
    }
}
