import BerryDriverKit
import Testing

@testable import BerryCore

/// Per-engine built-in function lists incl. vector / time-series.
@Suite("SQLBuiltins")
struct SQLBuiltinsTests {
    @Test func postgresIncludesPgvectorAndTimescale() {
        let fns = SQLBuiltins.functions(for: .postgres)
        #expect(fns.contains("COSINE_DISTANCE"))   // pgvector
        #expect(fns.contains("L2_DISTANCE"))
        #expect(fns.contains("TIME_BUCKET"))       // TimescaleDB
        #expect(fns.contains("COALESCE"))          // common
    }

    @Test func mysqlIncludesVectorFunctions() {
        let fns = SQLBuiltins.functions(for: .mysql)
        #expect(fns.contains("VEC_FROMTEXT"))
        #expect(fns.contains("DISTANCE"))
    }

    @Test func sqliteStaysMinimal() {
        let fns = SQLBuiltins.functions(for: .sqlite)
        #expect(fns.contains("JSON_EXTRACT"))
        #expect(!fns.contains("TIME_BUCKET"))
    }
}
