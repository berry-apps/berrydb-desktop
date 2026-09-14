import BerryDriverKit
import Testing

@testable import BerryCore

private struct TestDialect: SQLDialect {
    func quoteIdentifier(_ identifier: String) -> String { "\"\(identifier)\"" }
    func limitClause(_ limit: Int) -> String { "LIMIT \(limit)" }
}

/// Auto-LIMIT
@Suite("QueryService auto-LIMIT")
struct QueryServiceAutoLimitTests {
    private let dialect = TestDialect()

    private func apply(_ sql: String, limit: Int? = 1000) -> String {
        QueryService.applyAutoLimitIfNeeded(sql, dialect: dialect, limit: limit)
    }

    @Test func appendsLimitToBareSelect() {
        #expect(apply("SELECT * FROM users") == "SELECT * FROM users LIMIT 1000")
    }

    @Test func keepsTrailingSemicolon() {
        #expect(apply("SELECT * FROM users;") == "SELECT * FROM users LIMIT 1000;")
    }

    @Test func respectsExistingLimit() {
        let sql = "SELECT * FROM users LIMIT 5"
        #expect(apply(sql) == sql)
    }

    @Test func detectsLimitCaseInsensitively() {
        let sql = "select * from users limit 5"
        #expect(apply(sql) == sql)
    }

    @Test func appliesToWithQueries() {
        #expect(
            apply("WITH x AS (SELECT 1) SELECT * FROM x")
                == "WITH x AS (SELECT 1) SELECT * FROM x LIMIT 1000"
        )
    }

    @Test func skipsNonSelect() {
        let update = "UPDATE users SET name = 'a'"
        #expect(apply(update) == update)
        let ddl = "CREATE TABLE t (x INTEGER)"
        #expect(apply(ddl) == ddl)
    }

    @Test func skipsMultiStatementScripts() {
        let script = "SELECT 1; SELECT 2"
        #expect(apply(script) == script)
    }

    @Test func skipsWhenDisabled() {
        #expect(apply("SELECT * FROM users", limit: nil) == "SELECT * FROM users")
    }
}
