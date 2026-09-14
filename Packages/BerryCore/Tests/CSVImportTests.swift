import BerryDriverKit
import BerryDriverSQLite
import Foundation
import Testing

@testable import BerryCore

@Suite("CSV parser & importer")
struct CSVImportTests {
    // MARK: - Parser

    @Test func parsesSimpleRows() {
        let records = CSVParser.parse("a,b,c\n1,2,3\n4,5,6")
        #expect(records.map(\.fields) == [["a", "b", "c"], ["1", "2", "3"], ["4", "5", "6"]])
        #expect(records.map(\.line) == [1, 2, 3])
    }

    @Test func handlesQuotedFieldsWithCommasAndQuotes() {
        let records = CSVParser.parse(#"name,note"# + "\n" + #""Smith, John","he said ""hi""""#)
        #expect(records[1].fields == ["Smith, John", #"he said "hi""#])
    }

    @Test func handlesQuotedNewlinesAndTracksStartLine() {
        let text = "id,body\n1,\"line one\nline two\"\n2,ok"
        let records = CSVParser.parse(text)
        #expect(records.count == 3)
        #expect(records[1].fields == ["1", "line one\nline two"])
        // Record 2 ("2,ok") starts on physical line 4 because the quoted field
        // spanned an extra line.
        #expect(records[2].line == 4)
        #expect(records[2].fields == ["2", "ok"])
    }

    @Test func distinguishesEmptyFieldFromMissing() {
        let records = CSVParser.parse("a,b,c\n1,,3")
        #expect(records[1].fields == ["1", "", "3"])
    }

    @Test func skipsBlankLines() {
        let records = CSVParser.parse("a\n\n\nb\n")
        #expect(records.map(\.fields) == [["a"], ["b"]])
    }

    @Test func supportsAlternateDelimiter() {
        let records = CSVParser.parse("a;b;c", delimiter: ";")
        #expect(records[0].fields == ["a", "b", "c"])
    }

    // MARK: - Importer (integration against SQLite)

    private func makeSession() async throws -> (Session, String) {
        DriverRegistry.register(SQLiteDriver.self)
        let path = NSTemporaryDirectory() + "berrydb-import-\(UUID().uuidString).sqlite"
        FileManager.default.createFile(atPath: path, contents: nil)
        let session = try await ConnectionManager().open(.sqlite(path: path))
        return (session, path)
    }

    private func exec(_ sql: String, on session: Session) async throws -> [[BerryValue]] {
        var rows: [[BerryValue]] = []
        for try await event in QueryService.execute(sql, on: session, autoLimit: nil) {
            if case .rows(let batch) = event { rows += batch }
        }
        return rows
    }

    @Test func importsMappedRowsInBatches() async throws {
        let (session, path) = try await makeSession()
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try await exec("CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT, city TEXT)", on: session)

        // CSV columns: name, id, city → mapped by index to table columns.
        let records = CSVParser.parse("name,id,city\nAn,1,Hanoi\nBinh,2,\nChi,3,Hue")
        let dataRows = Array(records.dropFirst())   // strip header
        let result = try await CSVImporter.import(
            records: dataRows,
            into: TableRef(name: "people"),
            mapping: [
                .init(csvIndex: 1, tableColumn: "id"),
                .init(csvIndex: 0, tableColumn: "name"),
                .init(csvIndex: 2, tableColumn: "city"),
            ],
            batchSize: 2,
            on: session
        )
        #expect(result.failure == nil)
        #expect(result.insertedRows == 3)

        let rows = try await exec("SELECT id, name, city FROM people ORDER BY id", on: session)
        #expect(rows == [
            [.int(1), .text("An"), .text("Hanoi")],
            [.int(2), .text("Binh"), .null],   // empty field → NULL
            [.int(3), .text("Chi"), .text("Hue")],
        ])
    }

    @Test func reportsFailingSourceLineAndRollsBack() async throws {
        let (session, path) = try await makeSession()
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try await exec("CREATE TABLE t (id INTEGER PRIMARY KEY)", on: session)
        _ = try await exec("INSERT INTO t VALUES (2)", on: session)

        // Row for id=2 collides with the existing PK; it is on source line 3.
        let records = CSVParser.parse("id\n1\n2\n3")
        let dataRows = Array(records.dropFirst())
        let result = try await CSVImporter.import(
            records: dataRows,
            into: TableRef(name: "t"),
            mapping: [.init(csvIndex: 0, tableColumn: "id")],
            batchSize: 10,
            on: session
        )
        #expect(result.insertedRows == 0)
        #expect(result.failure?.line == 3)

        // All-or-nothing: only the pre-existing row remains.
        let rows = try await exec("SELECT id FROM t ORDER BY id", on: session)
        #expect(rows == [[.int(2)]])
    }
}
