import Foundation
import Testing
@testable import BerryCore

@Suite("SQLStreamReader Tests")
struct SQLStreamReaderTests {
    @Test("Stream parses simple semicolon-delimited statements across chunks")
    func testSimpleStatements() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_\(UUID().uuidString).sql")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let script = "CREATE TABLE users (id INT);\nINSERT INTO users VALUES (1);\nSELECT * FROM users;"
        try script.write(to: tempURL, atomically: true, encoding: .utf8)

        var statements: [String] = []
        for try await stmt in SQLStreamReader.statements(from: tempURL, chunkSize: 16) {
            statements.append(stmt.sql)
        }

        #expect(statements.count == 3)
        #expect(statements[0] == "CREATE TABLE users (id INT)")
        #expect(statements[1] == "INSERT INTO users VALUES (1)")
        #expect(statements[2] == "SELECT * FROM users")
    }

    @Test("Stream correctly preserves dollar-quoted blocks without early splitting")
    func testDollarQuoting() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_dollar_\(UUID().uuidString).sql")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let script = """
        CREATE FUNCTION test_func() RETURNS void AS $$
        BEGIN
            INSERT INTO audit_log VALUES ('semicolon; inside; body');
        END;
        $$ LANGUAGE plpgsql;
        SELECT 1;
        """
        try script.write(to: tempURL, atomically: true, encoding: .utf8)

        var statements: [String] = []
        for try await stmt in SQLStreamReader.statements(from: tempURL, chunkSize: 32) {
            statements.append(stmt.sql)
        }

        #expect(statements.count == 2)
        #expect(statements[0].contains("INSERT INTO audit_log"))
        #expect(statements[1] == "SELECT 1")
    }

    @Test("Stream correctly handles comments and escaped quotes split across tiny chunk boundaries")
    func testCommentsAndQuotesCrossingChunkBoundaries() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_chunk_splits_\(UUID().uuidString).sql")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let script = """
        -- line comment with ; inside
        SELECT 'O''Reilly' AS author, 'escaped '' quote ; here' AS title;
        /* multi-line
           comment with ; semicolon */
        SELECT 2;
        """
        try script.write(to: tempURL, atomically: true, encoding: .utf8)

        for chunkSize in [3, 4, 7, 8] {
            var statements: [String] = []
            for try await stmt in SQLStreamReader.statements(from: tempURL, chunkSize: chunkSize) {
                statements.append(stmt.sql)
            }
            #expect(statements.count == 2)
            #expect(statements[0].contains("O''Reilly"))
            #expect(statements[0].contains("escaped '' quote ; here"))
            #expect(statements[1].contains("SELECT 2"))
        }
    }

    @Test("Stream accurately reports line number and byte offset at first non-whitespace character")
    func testLineNumberAndByteOffsetAccuracy() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_offsets_\(UUID().uuidString).sql")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let script = "CREATE TABLE users (id INT);\n\n    SELECT 2;\n\nSELECT 3;"
        let scriptData = script.data(using: .utf8)!
        try scriptData.write(to: tempURL)

        var statements: [SQLStreamStatement] = []
        for try await stmt in SQLStreamReader.statements(from: tempURL, chunkSize: 16) {
            statements.append(stmt)
        }

        #expect(statements.count == 3)
        #expect(statements[0].lineNumber == 1)
        #expect(statements[0].byteOffset == 0)
        #expect(statements[0].sql == "CREATE TABLE users (id INT)")

        #expect(statements[1].lineNumber == 3)
        let prefix1 = "CREATE TABLE users (id INT);\n\n    "
        #expect(statements[1].byteOffset == prefix1.utf8.count)
        #expect(statements[1].sql == "SELECT 2")

        #expect(statements[2].lineNumber == 5)
        let prefix2 = "CREATE TABLE users (id INT);\n\n    SELECT 2;\n\n"
        #expect(statements[2].byteOffset == prefix2.utf8.count)
        #expect(statements[2].sql == "SELECT 3")
    }

    @Test("Stream handles multi-byte UTF-8 international characters split across chunk boundaries")
    func testMultiByteUTF8Strings() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_utf8_\(UUID().uuidString).sql")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let script = "INSERT INTO t VALUES ('Hello 世界 🌍 日本語 café');\nSELECT '🎉 BerryDB' AS brand;"
        try script.write(to: tempURL, atomically: true, encoding: .utf8)

        for chunkSize in [3, 4, 5, 8, 32] {
            var statements: [SQLStreamStatement] = []
            for try await stmt in SQLStreamReader.statements(from: tempURL, chunkSize: chunkSize) {
                statements.append(stmt)
            }
            #expect(statements.count == 2)
            #expect(statements[0].sql == "INSERT INTO t VALUES ('Hello 世界 🌍 日本語 café')")
            #expect(statements[1].sql == "SELECT '🎉 BerryDB' AS brand")

            let expectedOffset2 = "INSERT INTO t VALUES ('Hello 世界 🌍 日本語 café');\n".utf8.count
            #expect(statements[1].byteOffset == expectedOffset2)
        }
    }

    @Test("Stream throws invalidEncoding error on non-UTF8 corrupted bytes")
    func testInvalidUTF8ThrowsError() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_invalid_utf8_\(UUID().uuidString).sql")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        var data = "SELECT 1; ".data(using: .utf8)!
        data.append(contentsOf: [0xFF, 0xFE, 0xFD, 0xFC, 0xFB])
        try data.write(to: tempURL)

        var didCatchInvalidEncoding = false
        do {
            for try await _ in SQLStreamReader.statements(from: tempURL, chunkSize: 8) {}
        } catch let error as SQLStreamError {
            if case .invalidEncoding = error {
                didCatchInvalidEncoding = true
            }
        } catch {
            // Other error
        }

        #expect(didCatchInvalidEncoding)
    }

    @Test("Stream parses single quotes escaped with backslash (e.g. MySQL dump)")
    func testBackslashEscapedQuotes() async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_escaped_quotes_\(UUID().uuidString).sql")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let sql = "INSERT INTO books (title) VALUES ('It\\'s a great book; really!'); SELECT 2;"
        try sql.write(to: tempURL, atomically: true, encoding: .utf8)

        var statements: [SQLStreamStatement] = []
        for try await stmt in SQLStreamReader.statements(from: tempURL, chunkSize: 16) {
            statements.append(stmt)
        }

        #expect(statements.count == 2)
        #expect(statements[0].sql == "INSERT INTO books (title) VALUES ('It\\'s a great book; really!')")
        #expect(statements[1].sql == "SELECT 2")
    }
}
