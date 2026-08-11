import BerryDriverKit
import Testing

@testable import BerryDriverMySQL

/// Pure `SQLDialect` string generation — unlike `MySQLConformanceTests`,
/// these don't touch a real server, so they always run regardless of
/// `BERRYDB_TEST_MYSQL`.
@Suite("MySQL dialect (no live server needed)")
struct MySQLDialectTests {
    @Test func truncateUsesTheDefaultTruncateTableStatement() {
        let sql = MySQLDialect().truncateSQL(TableRef(database: "shop", name: "orders"))
        #expect(sql == "TRUNCATE TABLE `shop`.`orders`;")
    }
}
