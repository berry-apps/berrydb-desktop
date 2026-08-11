import BerryDriverKit
import Testing

@testable import BerryDriverPostgres

/// Pure `SQLDialect` string generation — unlike `PostgresConformanceTests`,
/// these don't touch a real server, so they always run regardless of
/// `BERRYDB_TEST_POSTGRES`.
@Suite("Postgres dialect (no live server needed)")
struct PostgresDialectTests {
    @Test func truncateUsesTheDefaultTruncateTableStatement() {
        let sql = PostgresDialect().truncateSQL(TableRef(database: "shop", name: "orders"))
        #expect(sql == "TRUNCATE TABLE \"shop\".\"orders\";")
    }
}
