import BerryDriverKit
import Foundation
import Testing

@testable import BerryCore

private struct TestDialect: SQLDialect {
    func quoteIdentifier(_ identifier: String) -> String { "\"\(identifier)\"" }
    func limitClause(_ limit: Int) -> String { "LIMIT \(limit)" }

    func createUserSQL(username: String, password: String, host: String?) -> String? {
        "CREATE USER \(quoteIdentifier(username)) [\(host ?? "-")] PW=\(stringLiteral(password))"
    }

    func grantSQL(privilege: String, on target: String, to username: String, host: String?) -> String? {
        "GRANT \(privilege) ON \(target) TO \(quoteIdentifier(username)) [\(host ?? "-")]"
    }
}

private struct UnsupportedDialect: SQLDialect {
    func quoteIdentifier(_ identifier: String) -> String { "\"\(identifier)\"" }
    func limitClause(_ limit: Int) -> String { "LIMIT \(limit)" }
    // No overrides — inherits the protocol's `nil` defaults, matching SQLite.
}

@Suite("User designer DDL")
struct UserDesignTests {
    private let dialect = TestDialect()

    @Test func createUserWithNoGrantsProducesOnlyTheCreateStatement() {
        let design = UserDesign(username: "alice", password: "s3cret", host: "")
        let sql = design.statements(dialect: dialect)
        #expect(sql == [#"CREATE USER "alice" [-] PW='s3cret'"#])
    }

    @Test func createUserWithHostAndGrants() {
        let design = UserDesign(
            username: "bob",
            password: "pw",
            host: "%",
            grants: [
                UserGrantDesign(privilege: "SELECT", database: "appdb"),
                UserGrantDesign(privilege: "CONNECT", database: "appdb"),
            ]
        )
        let sql = design.statements(dialect: dialect)
        #expect(sql == [
            #"CREATE USER "bob" [%] PW='pw'"#,
            #"GRANT SELECT ON appdb TO "bob" [%]"#,
            #"GRANT CONNECT ON appdb TO "bob" [%]"#,
        ])
    }

    @Test func passwordWithAQuoteIsEscaped() {
        let design = UserDesign(username: "eve", password: "o'brien")
        #expect(design.statements(dialect: dialect)[0].contains("'o''brien'"))
    }

    @Test func unsupportedDialectProducesNoStatements() {
        let design = UserDesign(username: "alice", password: "s3cret")
        #expect(design.statements(dialect: UnsupportedDialect()).isEmpty)
    }

    @Test func validityRequiresUsernamePasswordAndCompleteGrants() {
        #expect(!UserDesign(username: "", password: "pw").isValid)
        #expect(!UserDesign(username: "alice", password: "").isValid)
        #expect(UserDesign(username: "alice", password: "pw").isValid)
        #expect(!UserDesign(
            username: "alice", password: "pw",
            grants: [UserGrantDesign(privilege: "", database: "appdb")]
        ).isValid, "a grant missing a privilege must invalidate the whole design")
        #expect(UserDesign(
            username: "alice", password: "pw",
            grants: [UserGrantDesign(privilege: "SELECT", database: "appdb")]
        ).isValid)
    }
}
