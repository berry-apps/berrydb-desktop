import BerryDriverKit
import Foundation

/// Declarative new-user definition for the user designer
/// Mirrors `TableDesign`'s shape: the
/// form edits this model, the dialect renders DDL, the SQL preview is ALWAYS
/// shown before applying, and apply runs through the single QueryService
/// path (N1).
///
/// v1 scope: create only (no edit-existing-user mode — password rotation and
/// per-grant revoke are separate per-row actions in the user list, not part
/// of this sheet), database-level grants only (no per-table/per-column, no
/// role membership).
public struct UserGrantDesign: Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var privilege: String
    public var database: String

    public init(id: UUID = UUID(), privilege: String = "", database: String = "") {
        self.id = id
        self.privilege = privilege
        self.database = database
    }
}

public struct UserDesign: Sendable, Equatable {
    public var username: String
    public var password: String
    /// MySQL only (`'user'@'host'`) — ignored by dialects with no host-scoped
    /// user concept (Postgres). `nil`/empty defaults to `%` at the dialect level.
    public var host: String
    public var grants: [UserGrantDesign]

    public init(
        username: String = "",
        password: String = "",
        host: String = "",
        grants: [UserGrantDesign] = []
    ) {
        self.username = username
        self.password = password
        self.host = host
        self.grants = grants
    }

    public var isValid: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.isEmpty
            && grants.allSatisfy { grant in
                !grant.privilege.trimmingCharacters(in: .whitespaces).isEmpty
                    && !grant.database.trimmingCharacters(in: .whitespaces).isEmpty
            }
    }

    public func statements(dialect: any SQLDialect) -> [String] {
        var result: [String] = []
        let effectiveHost = host.trimmingCharacters(in: .whitespaces).isEmpty ? nil : host
        if let create = dialect.createUserSQL(username: username, password: password, host: effectiveHost) {
            result.append(create)
        }
        for grant in grants {
            if let sql = dialect.grantSQL(
                privilege: grant.privilege, on: grant.database, to: username, host: effectiveHost
            ) {
                result.append(sql)
            }
        }
        return result
    }

    /// Runs the generated DDL through the single SQL path (N1), inside a
    /// transaction when the driver supports it — same shape as
    /// `TableDesign.apply`.
    @discardableResult
    public func apply(on session: Session) async throws -> Int {
        let sqls = statements(dialect: session.dialect)
        guard !sqls.isEmpty else { return 0 }
        let useTransaction = session.capabilities.transactions

        func run(_ sql: String) async throws {
            for try await _ in QueryService.execute(
                sql, on: session, autoLimit: nil,
                // The SQL preview the user just approved IS the confirmation,
                // same reasoning as TableDesign.apply.
                dangerPreconfirmed: true
            ) {}
        }

        if useTransaction { try await run("BEGIN") }
        do {
            for sql in sqls { try await run(sql) }
            if useTransaction { try await run("COMMIT") }
        } catch {
            if useTransaction { try? await run("ROLLBACK") }
            throw error
        }
        return sqls.count
    }
}
