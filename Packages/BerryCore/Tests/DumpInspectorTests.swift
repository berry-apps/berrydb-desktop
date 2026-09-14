import Foundation
import Testing
@testable import BerryCore

@Suite("DumpInspector Tests")
struct DumpInspectorTests {
    @Test("Detects PostgreSQL custom dump header magic bytes")
    func testPostgresCustomDump() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("pg_\(UUID().uuidString).dump")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        
        let pgHeader = Data([0x50, 0x47, 0x44, 0x4D, 0x50, 0x01, 0x0C, 0x00]) // "PGDMP"
        try pgHeader.write(to: tempURL)
        
        let result = try DumpInspector.inspect(url: tempURL)
        #expect(result.format == .postgresCustomDump)
        #expect(result.detectedDialectName == "PostgreSQL")
    }

    @Test("Detects SQLite binary database file header")
    func testSQLiteBinary() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("sqlite_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        
        var sqliteHeader = Data("SQLite format 3".utf8)
        sqliteHeader.append(0x00)
        try sqliteHeader.write(to: tempURL)
        
        let result = try DumpInspector.inspect(url: tempURL)
        #expect(result.format == .sqliteBinary)
        #expect(result.detectedDialectName == "SQLite")
    }

    @Test("Detects BerryDB bundle folder containing manifest.json")
    func testBerryBundle() throws {
        let bundleURL = FileManager.default.temporaryDirectory.appendingPathComponent("bundle_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        
        let manifest = "{\"kind\":\"document\",\"driver\":\"MongoDB\",\"createdAt\":\"2026-09-11\"}"
        try manifest.write(to: bundleURL.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        
        let result = try DumpInspector.inspect(url: bundleURL)
        #expect(result.format == .berryBundle)
        #expect(result.isDirectory == true)
    }
}
