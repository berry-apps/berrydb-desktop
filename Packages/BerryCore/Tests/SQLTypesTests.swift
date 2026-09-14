import BerryDriverKit
import Testing

@testable import BerryCore

@Suite("Dialect data types")
struct SQLTypesTests {
    @Test func postgresIncludesPgvectorAndJsonb() {
        let types = SQLTypes.types(for: .postgres)
        #expect(types.contains("vector"))
        #expect(types.contains("jsonb"))
        #expect(types.contains("timestamptz"))
        // MySQL-only spelling must not leak in.
        #expect(!types.contains("bigint unsigned"))
    }

    @Test func mysqlIncludesEnumSetAndUnsigned() {
        let types = SQLTypes.types(for: .mysql)
        #expect(types.contains("bigint unsigned"))
        #expect(types.contains { $0.hasPrefix("enum(") })
        #expect(types.contains("json"))
        #expect(!types.contains("jsonb")) // Postgres-only
    }

    @Test func sqliteStaysMinimal() {
        let types = SQLTypes.types(for: .sqlite)
        #expect(types.contains("INTEGER"))
        #expect(!types.contains("vector"))
    }
}
