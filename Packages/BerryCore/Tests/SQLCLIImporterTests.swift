import Foundation
import Testing
@testable import BerryCore

@Suite("SQLCLIImporter Tests")
struct SQLCLIImporterTests {
    @Test("Builds correct psql arguments without leaking password in arg list")
    func testPsqlArguments() {
        let file = URL(fileURLWithPath: "/tmp/dump.sql")
        let args = SQLCLIImporter.buildArguments(
            for: .psql,
            fileURL: file,
            host: "127.0.0.1",
            port: 5432,
            database: "testdb",
            user: "postgres"
        )
        
        #expect(args.contains("-h"))
        #expect(args.contains("127.0.0.1"))
        #expect(args.contains("-p"))
        #expect(args.contains("5432"))
        #expect(args.contains("-U"))
        #expect(args.contains("postgres"))
        #expect(args.contains("-w"))
        #expect(args.contains("-d"))
        #expect(args.contains("testdb"))
        #expect(args.contains("-f"))
        #expect(args.contains("/tmp/dump.sql"))
    }

    @Test("Builds correct sqlite3 arguments")
    func testSqliteArguments() {
        let file = URL(fileURLWithPath: "/tmp/dump.sql")
        let args = SQLCLIImporter.buildArguments(
            for: .sqlite3,
            fileURL: file,
            host: nil,
            port: nil,
            database: "/tmp/target.db",
            user: nil
        )
        
        #expect(args == ["/tmp/target.db"])
    }

    @Test("Builds correct pg_restore arguments")
    func testPgRestoreArguments() {
        let file = URL(fileURLWithPath: "/tmp/dump.pgdump")
        let args = SQLCLIImporter.buildArguments(
            for: .pg_restore,
            fileURL: file,
            host: "localhost",
            port: 5432,
            database: "testdb",
            user: "pguser"
        )

        #expect(args.contains("-w"))
        #expect(args.contains("-h"))
        #expect(args.contains("localhost"))
        #expect(args.contains("-p"))
        #expect(args.contains("5432"))
        #expect(args.contains("-U"))
        #expect(args.contains("pguser"))
        #expect(args.contains("-d"))
        #expect(args.contains("testdb"))
        #expect(args.contains("/tmp/dump.pgdump"))
        #expect(!args.contains("-f"))
    }

    @Test("Builds correct mysql arguments")
    func testMysqlArguments() {
        let file = URL(fileURLWithPath: "/tmp/dump.sql")
        let args = SQLCLIImporter.buildArguments(
            for: .mysql,
            fileURL: file,
            host: "127.0.0.1",
            port: 3306,
            database: "mysqldb",
            user: "root"
        )

        #expect(args.contains("-h"))
        #expect(args.contains("127.0.0.1"))
        #expect(args.contains("-P"))
        #expect(args.contains("3306"))
        #expect(args.contains("-u"))
        #expect(args.contains("root"))
        #expect(args.contains("mysqldb"))
    }

    @Test("Finds local sqlite3 executable on system")
    func testFindExecutable() {
        let sqliteURL = SQLCLIImporter.findExecutable(.sqlite3)
        #expect(sqliteURL != nil)
        if let url = sqliteURL {
            #expect(FileManager.default.isExecutableFile(atPath: url.path))
        }
    }
}
