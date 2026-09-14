import BerryDriverKit
import Foundation
import Testing

@testable import BerryCore

@Suite("ExportEngine & ClipboardFormatter")
struct ExportEngineTests {
    private let columns = [
        ColumnMeta(name: "id", declaredType: "INTEGER"),
        ColumnMeta(name: "name", declaredType: "TEXT"),
        ColumnMeta(name: "note", declaredType: "TEXT"),
    ]
    private let rows: [[BerryValue]] = [
        [.int(1), .text("an"), .null],
        [.int(2), .text("has,comma"), .text("quote \" and\nnewline")],
        [.int(3), .text(""), .double(2.5)],
    ]

    private func tempURL(_ ext: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("berrydb-export-\(UUID().uuidString).\(ext)")
    }

    @Test func csvEscapesAndDistinguishesNull() async throws {
        let url = tempURL("csv")
        defer { try? FileManager.default.removeItem(at: url) }
        let count = try await ExportEngine.export(columns: columns, rows: rows, to: url, format: .csv())
        #expect(count == 3)

        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines[0] == "id,name,note")
        // NULL → empty unquoted; empty string → quoted "".
        #expect(lines[1] == "1,an,")
        #expect(lines[2] == "2,\"has,comma\",\"quote \"\" and")
        #expect(content.contains("quote \"\" and"))   // escaped quote survived
        #expect(lines.contains { $0.hasPrefix("3,\"\",") })
    }

    @Test func tsvUsesTabDelimiter() async throws {
        let url = tempURL("tsv")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try await ExportEngine.export(
            columns: columns, rows: rows, to: url, format: .csv(delimiter: "\t")
        )
        let content = try String(contentsOf: url, encoding: .utf8)
        #expect(content.split(separator: "\n")[0] == "id\tname\tnote")
    }

    @Test func utf16ExportStartsWithBOMAndDecodes() async throws {
        let url = tempURL("csv")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try await ExportEngine.export(
            columns: columns, rows: rows, to: url, format: .csv(encoding: .utf16)
        )
        let data = try Data(contentsOf: url)
        // Single UTF-16 LE BOM at the very start, then decodable content.
        #expect(Array(data.prefix(2)) == [0xFF, 0xFE])
        let decoded = try #require(String(data: data, encoding: .utf16))
        #expect(decoded.contains("id,name,note"))
        // The BOM must appear exactly once, not per row.
        #expect(!decoded.dropFirst().contains("\u{FEFF}"))
    }

    @Test func jsonArrayRoundTripsThroughFoundation() async throws {
        let url = tempURL("json")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try await ExportEngine.export(columns: columns, rows: rows, to: url, format: .jsonArray)

        let data = try Data(contentsOf: url)
        let parsed = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        let objects = try #require(parsed)
        #expect(objects.count == 3)
        #expect(objects[0]["id"] as? Int == 1)
        #expect(objects[0]["note"] is NSNull)
        #expect(objects[1]["name"] as? String == "has,comma")
        #expect(objects[2]["note"] as? Double == 2.5)
    }

    @Test func ndjsonWritesOneObjectPerLine() async throws {
        let url = tempURL("ndjson")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try await ExportEngine.export(columns: columns, rows: rows, to: url, format: .ndjson)

        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.split(separator: "\n")
        #expect(lines.count == 3)
        for line in lines {
            #expect((try? JSONSerialization.jsonObject(with: Data(line.utf8))) != nil)
        }
    }

    @Test func emptyResultStillProducesValidFiles() async throws {
        let url = tempURL("json")
        defer { try? FileManager.default.removeItem(at: url) }
        let count = try await ExportEngine.export(columns: columns, rows: [], to: url, format: .jsonArray)
        #expect(count == 0)
        let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [Any]
        #expect(parsed?.isEmpty == true)
    }

 // MARK: copy-as

    private struct TestDialect: SQLDialect {
        func quoteIdentifier(_ identifier: String) -> String { "\"\(identifier)\"" }
        func limitClause(_ limit: Int) -> String { "LIMIT \(limit)" }
    }

    @Test func sqlInsertsUseDialectLiterals() {
        let sql = ClipboardFormatter.sqlInserts(
            table: TableRef(name: "users"),
            columns: columns,
            rows: [[.int(1), .text("O'Brien"), .null]],
            dialect: TestDialect()
        )
        #expect(sql == #"INSERT INTO "users" ("id", "name", "note") VALUES"#
            + "\n(1, 'O''Brien', NULL);")
    }

 // MARK: SQL export

    @Test func sqlExportBatchesRowsIntoMultiRowInserts() async throws {
        let url = tempURL("sql")
        defer { try? FileManager.default.removeItem(at: url) }
        let count = try await ExportEngine.export(
            columns: columns, rows: rows, to: url,
            format: .sqlInsert(table: TableRef(name: "t"), dialect: TestDialect(), batchSize: 2)
        )
        #expect(count == 3)

        let content = try String(contentsOf: url, encoding: .utf8)
        // 3 rows at batchSize 2 → two INSERT statements.
        #expect(content.components(separatedBy: "INSERT INTO").count - 1 == 2)
        #expect(content.contains(#"INSERT INTO "t" ("id", "name", "note") VALUES"#))
        // Literals escaped through the dialect; NULL preserved.
        #expect(content.contains("'has,comma'"))
        #expect(content.contains("NULL"))
        #expect(content.hasSuffix(";\n"))
    }

    @Test func sqlExportEmitsDDLHeaderWhenProvided() async throws {
        let url = tempURL("sql")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try await ExportEngine.export(
            columns: columns, rows: [[.int(1), .text("a"), .null]], to: url,
            format: .sqlInsert(
                table: TableRef(name: "t"), dialect: TestDialect(),
                batchSize: 100, ddlHeader: "CREATE TABLE \"t\" (\"id\" INTEGER);"
            )
        )
        let content = try String(contentsOf: url, encoding: .utf8)
        #expect(content.hasPrefix("CREATE TABLE \"t\""))
        #expect(content.contains("INSERT INTO \"t\""))
    }

    @Test func tableDesignFromDetailReconstructsCreate() {
        let detail = TableDetail(
            ref: TableRef(name: "users"),
            columns: [
                ColumnInfo(name: "id", declaredType: "INTEGER", isNullable: false, defaultValue: nil, isPrimaryKey: true),
                ColumnInfo(name: "name", declaredType: "TEXT", isNullable: true, defaultValue: nil, isPrimaryKey: false),
            ],
            indexes: [IndexInfo(name: "idx_name", isUnique: false, columns: ["name"])],
            foreignKeys: []
        )
        let sql = TableDesign(detail: detail).statements(dialect: TestDialect())
        #expect(sql[0].contains(#"CREATE TABLE "users""#))
        #expect(sql[0].contains(#""id" INTEGER NOT NULL"#))
        #expect(sql[0].contains(#"PRIMARY KEY ("id")"#))
        #expect(sql[1] == #"CREATE INDEX "idx_name" ON "users" ("name")"#)
    }

    @Test func markdownEscapesPipes() {
        let markdown = ClipboardFormatter.markdown(
            columns: columns,
            rows: [[.int(1), .text("a|b"), .null]]
        )
        let lines = markdown.split(separator: "\n")
        #expect(lines[0] == "| id | name | note |")
        #expect(lines[1] == "|---|---|---|")
        #expect(lines[2] == #"| 1 | a\|b | NULL |"#)
    }

    @Test func csvClipboardMatchesFileEncoding() {
        let csv = ClipboardFormatter.csv(columns: columns, rows: [[.int(9), .text("x"), .null]])
        #expect(csv == "id,name,note\n9,x,\n")
    }
}
