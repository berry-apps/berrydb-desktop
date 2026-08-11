import BerryDriverKit
import Foundation

/// `DatabaseDriver` for DynamoDB via PartiQL (NS-04/05, docs/architecture/12
/// §4) — the highest-reuse of the three NoSQL/vector drivers: it implements
/// the EXISTING `DatabaseDriver` contract (not `DataSourceDriver`) because
/// DynamoDB's `ExecuteStatement`/`BatchExecuteStatement` API is SQL-shaped.
public struct DynamoDBDriver: DatabaseDriver {
    public static let id: DriverID = .dynamodb
    public static let displayName = "DynamoDB"

    // Capability matrix: docs/architecture/05 §4 "DynamoDB (V2, PartiQL)" column
    // — kept in exact lockstep with that table.
    public static let capabilities = Capabilities(
        // TransactWriteItems (≤25 items) is the real atomic mechanism, not
        // BEGIN/COMMIT — doesn't fit the bool cleanly. `ChangeSet.apply` still
        // wraps runs in BEGIN/COMMIT/ROLLBACK text; `DynamoDBConnection.execute`
        // treats those three as client-side no-ops (no real atomicity/rollback)
        // rather than sending invalid PartiQL — documented in
        // docs/architecture/12 §4 "Trạng thái hiện thực".
        transactions: true,
        cancelQuery: false,          // ❌ chỉ hủy phía client (05 §4) — no server-side cancel API
        multipleDatabases: false,    // mỗi table độc lập, không có khái niệm database
        schemas: false,
        explain: false,
        processList: false,
        serverSideCursor: true,      // ⚠️ NextToken — phân trang tuần tự, không seek
        keyValueBrowser: false,      // dùng grid PartiQL bình thường
        // No real CREATE/DROP USER — DynamoDB has no in-DB user concept,
        // access is AWS IAM, outside the driver's reach. true here only
        // makes the Users tab show a static info panel (TI-03 Phase D,
        // WorkspaceViewModel.userManagementInfoMessage) instead of hiding
        // entirely — listUsersSQL() stays nil (inherited default), so real
        // management (userManagementSupported) is still always false.
        userManagement: true
    )

    public static let dialect: any SQLDialect = PartiQLDialect()

    public init() {}

    public func connect(_ config: ConnectionConfig) async throws -> any DriverConnection {
        try await DynamoDBConnection(config: config)
    }
}

/// `SQLDialect` for DynamoDB PartiQL — every rule below was verified against
/// a running `dynamodb-local` (docs/architecture/12 §10), not assumed.
public struct PartiQLDialect: SQLDialect {
    public init() {}

    /// Double-quoted, `""`-escaped — confirmed valid for table names AND
    /// attribute names/WHERE targets against dynamodb-local (`"Artist"`,
    /// `"TableName"."IndexName"` in AWS's own SELECT-with-index docs).
    public func quoteIdentifier(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// No-op — verified empirically: `SELECT * FROM "T" LIMIT 10` fails on
    /// dynamodb-local with `ValidationException: Unsupported clause: LIMIT`.
    /// PartiQL SELECT's grammar has no LIMIT clause at all (pagination is via
    /// `NextToken`/the request-level `Limit` field, not statement text) — so
    /// auto-LIMIT (ED-12) has no home in the SQL-text channel QueryService
    /// uses. Deliberate deviation, not a bug: DynamoDB SELECTs always run
    /// fully paginated (`DynamoDBConnection` follows every `NextToken`)
    /// unless the user's own WHERE narrows the result — see
    /// docs/architecture/12 §4 "Trạng thái hiện thực" for the full writeup
    /// (including why a hidden client-side row cap was rejected: it would
    /// silently truncate CSV export, which calls `execute` with
    /// `autoLimit: nil` expecting every row).
    public func limitClause(_ limit: Int) -> String { "" }

    /// PartiQL for DynamoDB has NO literal syntax for Binary — AWS's own data
    /// types reference lists it as "N/A — only supported via code" (i.e. the
    /// parameterized `?` + `Parameters` channel). `SQLDialect.literal(_:)` is
    /// a synchronous string producer with no channel for out-of-band
    /// parameters, so `.bytes`/`.unknown` BerryValues have no valid PartiQL
    /// representation here. Verified: `SET "Blob" = X'deadbeef'` (the
    /// inherited SQL-92-ish default) is rejected by dynamodb-local with
    /// `ValidationException: Statement wasn't well formed`. Kept as an
    /// explicit override (rather than silently inheriting the default) so
    /// this is documented at the call site: editing a Binary column via
    /// ChangeSet is a known, real gap — it fails loudly as a normal query
    /// error, not silent data corruption.
    public func blobLiteral(_ data: Data) -> String {
        "X'" + data.map { String(format: "%02x", $0) }.joined() + "'"
    }

    // boolLiteral: inherited default (TRUE/FALSE) already matches PartiQL's
    // documented Boolean literal exactly ("TRUE | FALSE, not case sensitive") —
    // no override needed.
    // explainPrefix/processListSQL/killSessionSQL: inherited defaults (nil for
    // the latter two) already match capabilities.explain/.processList == false
    // (05 §4) — unreachable from the UI, no override needed.
}
