import BerryDriverKit
import BerryDriverSQLite
import Foundation
import Testing
@testable import BerryCore

@Suite("Restore and SQL Tools Integration Tests")
struct RestoreAndSQLToolsIntegrationTests {
    private func makeSession() async throws -> (Session, String) {
        DriverRegistry.register(SQLiteDriver.self)
        let path = NSTemporaryDirectory() + "berrydb-integ-\(UUID().uuidString).sqlite"
        FileManager.default.createFile(atPath: path, contents: nil)
        let session = try await ConnectionManager().open(.sqlite(path: path))
        return (session, path)
    }

    private func exec(_ sql: String, on session: Session) async throws -> [[BerryValue]] {
        var rows: [[BerryValue]] = []
        for try await event in QueryService.execute(sql, on: session, autoLimit: nil, dangerPreconfirmed: true) {
            if case .rows(let batch) = event { rows += batch }
        }
        return rows
    }

    @Test("Round-trip: Dump database, inspect dump format, and stream restore into fresh DB")
    func testDumpInspectAndStreamRestore() async throws {
        let (sourceSession, sourcePath) = try await makeSession()
        defer { try? FileManager.default.removeItem(atPath: sourcePath) }

        _ = try await exec("CREATE TABLE products (id INTEGER PRIMARY KEY, name TEXT, price REAL);", on: sourceSession)
        _ = try await exec("INSERT INTO products VALUES (1, 'BerryDB Pro', 49.99), (2, 'BerryDB Team', 99.99);", on: sourceSession)

        let dumpURL = FileManager.default.temporaryDirectory.appendingPathComponent("integ_dump_\(UUID().uuidString).sql")
        defer { try? FileManager.default.removeItem(at: dumpURL) }

        let objectCount = try await BackupService.backupSQL(session: sourceSession, to: dumpURL)
        #expect(objectCount == 1)

        // Pre-flight inspection
        let inspection = try DumpInspector.inspect(url: dumpURL)
        #expect(inspection.format == .genericSQL)
        #expect(inspection.isDirectory == false)

        // Restore into fresh DB via flat-memory streaming reader
        let (targetSession, targetPath) = try await makeSession()
        defer { try? FileManager.default.removeItem(atPath: targetPath) }

        var statementCount = 0
        for try await stmt in SQLStreamReader.statements(from: dumpURL) {
            for try await _ in QueryService.execute(stmt.sql, on: targetSession, autoLimit: nil, recordHistory: false, dangerPreconfirmed: true) {}
            statementCount += 1
        }
        #expect(statementCount >= 2)

        let rows = try await exec("SELECT id, name, price FROM products ORDER BY id;", on: targetSession)
        #expect(rows == [
            [.int(1), .text("BerryDB Pro"), .double(49.99)],
            [.int(2), .text("BerryDB Team"), .double(99.99)]
        ])
    }

    @Test("Dump inspection on SQLite binary database file")
    func testInspectSQLiteBinaryDatabase() async throws {
        let (session, path) = try await makeSession()
        defer { try? FileManager.default.removeItem(atPath: path) }

        _ = try await exec("CREATE TABLE sample (val TEXT);", on: session)

        let dbURL = URL(fileURLWithPath: path)
        let inspection = try DumpInspector.inspect(url: dbURL)
        #expect(inspection.format == .sqliteBinary)
        #expect(inspection.detectedDialectName == "SQLite")
        #expect(inspection.isDirectory == false)
    }

    @Test("Safe CLI argument construction for SQLite and PostgreSQL")
    func testCLIArgumentConstruction() {
        let fileURL = URL(fileURLWithPath: "/tmp/sample_dump.sql")
        let sqliteArgs = SQLCLIImporter.buildArguments(
            for: .sqlite3,
            fileURL: fileURL,
            host: nil,
            port: nil,
            database: "/tmp/test.db",
            user: nil
        )
        #expect(sqliteArgs == ["/tmp/test.db"])

        let pgRestoreArgs = SQLCLIImporter.buildArguments(
            for: .pg_restore,
            fileURL: fileURL,
            host: "localhost",
            port: 5432,
            database: "appdb",
            user: "postgres"
        )
        #expect(pgRestoreArgs.contains("-h"))
        #expect(pgRestoreArgs.contains("localhost"))
        #expect(pgRestoreArgs.contains("-U"))
        #expect(pgRestoreArgs.contains("postgres"))
        #expect(pgRestoreArgs.contains(fileURL.path))
    }
}
