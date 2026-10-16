import BerryDriverKit
import Foundation

public struct MCPLiveReadRequest: Sendable {
    public let profileID: UUID
    public let dialect: MCPSQLDialect
    public let sql: String
    public let parameters: [SQLParameter]
    /// Rows the caller wants at most; capped by the profile's limit.
    public let rowLimit: Int?

    public init(profileID: UUID, dialect: MCPSQLDialect, sql: String, parameters: [SQLParameter] = [], rowLimit: Int? = nil) {
        self.profileID = profileID
        self.dialect = dialect
        self.sql = sql
        self.parameters = parameters
        self.rowLimit = rowLimit
    }
}

/// A bounded live read. Its JSON stays within the profile's byte ceiling
/// when encoded with sorted keys and unescaped slashes
/// (`[.sortedKeys, .withoutEscapingSlashes]`), the settings
/// `MCPResultLimiter` measures with; escaping `/` as `\/` can exceed it.
public struct MCPLiveReadResult: Encodable, Equatable, Sendable {
    public let columns: [String]
    /// One array per row, aligned with `columns`; nil is SQL NULL.
    public let rows: [[String?]]
    public let rowCount: Int
    /// True when any row, cell or byte was left out.
    public let truncated: Bool
    /// True when the statement had more rows than were read.
    public let hasMoreRows: Bool
    public let truncatedCells: Int
    public let byteLimitReached: Bool
    public let elapsedMs: Int
    public let redactedColumns: [String]
}

public enum MCPLiveReadError: Error, Equatable, Sendable, CustomStringConvertible {
    case unknownConnection, liveReadNotEnabled, noProject, unsupportedDatabase
    case policy(String), readOnlyUnavailable, connectionFailed
    case timedOut(seconds: Int), queryFailed(String), resultTooLarge

    public var description: String {
        switch self {
        case .unknownConnection: "Unknown connection for this project"
        case .liveReadNotEnabled: "Live reads are not turned on for this connection. The user can turn them on in BerryDB Settings → AI Agents."
        case .noProject: "No BerryDB project is selected for this workspace. Call berrydb_status for details."
        case .unsupportedDatabase: "Live reads are available for PostgreSQL, MySQL, MariaDB and SQLite connections only."
        case .policy(let reason): "The query was refused before it ran: \(reason)"
        case .readOnlyUnavailable: "BerryDB could not open a read-only session on this database, so the query did not run."
        case .connectionFailed: "BerryDB could not connect to this database."
        case .timedOut(let seconds): "The query did not finish within \(seconds) seconds."
        case .queryFailed(let message): "The database refused the query: \(message)"
        case .resultTooLarge: "Result too large; narrow the request"
        }
    }
}

/// Runs one statement for a coding agent on a fresh session the database
/// itself keeps read-only, and returns at most the profile's limits of it.
public struct MCPLiveReadService: Sendable {
    private let coordinator: MCPConnectionCoordinator
    private let openBudget: Duration

    /// `openBudget` bounds resolving the profile and opening its session,
    /// tunnel included; the statement then has the profile's own limit.
    public init(coordinator: MCPConnectionCoordinator, openBudget: Duration = .seconds(15)) {
        self.coordinator = coordinator
        self.openBudget = openBudget
    }

    /// Checks the statement against the read policy, then resolves the
    /// profile, opens a read-only session and reads the statement up to the
    /// profile's limits. A statement the policy refuses never opens a
    /// connection. Throws `MCPLiveReadError`, or `CancellationError` when
    /// the calling task was cancelled; no error carries a host, a user, a
    /// file path or a raw connection error.
    public func run(_ request: MCPLiveReadRequest) async throws -> MCPLiveReadResult {
        let decision: MCPReadDecision
        do {
            decision = try MCPReadPolicy().validate(request.sql, dialect: request.dialect)
        } catch let error as MCPReadPolicyError {
            throw MCPLiveReadError.policy(error.description)
        } catch {
            throw MCPLiveReadError.queryFailed(Self.unexpected)
        }
        let requestID = UUID().uuidString
        let coordinator = self.coordinator
        do {
            // The statement's own bound already has a second for the server's
            // bound to fire first; two more cover building the result and
            // closing the session.
            return try await MCPRequestDeadline.run(
                openBudget + MCPResultLimits.liveRead.maximumElapsed + .seconds(2), opening: openBudget
            ) { opening in
                try await coordinator.withSQLSession(requestID: requestID, profileID: request.profileID) { session in
                    do {
                        return try await Self.read(decision, request: request, session: session, opening: opening)
                    } catch {
                        throw ReadFailure(underlying: error)
                    }
                }
            }
        } catch {
            throw Self.mapped(error)
        }
    }

    private static let unexpected = "unexpected error"

    /// Wraps an error raised once the session was open, so it is told apart
    /// from one raised while resolving or opening, which can name the host,
    /// the user or a file path and is never forwarded.
    private struct ReadFailure: Error {
        let underlying: Error
    }

    private enum SessionFault: Error {
        case missingProfile
    }

    private struct Collected: Sendable {
        let columns: [ColumnMeta]
        let rows: [[BerryValue]]
        let hasMoreRows: Bool
        let elapsed: Duration
    }

    private static func read(
        _ decision: MCPReadDecision, request: MCPLiveReadRequest, session: MCPSQLSession,
        opening: MCPRequestDeadline.Opening
    ) async throws -> MCPLiveReadResult {
        // The profile carries the production label and the redactions;
        // without it neither is known, so nothing runs.
        guard let profile = session.profile else { throw SessionFault.missingProfile }
        guard profile.driverID == driverID(for: request.dialect) else { throw MCPLiveReadError.unsupportedDatabase }
        let limits: MCPResultLimits = profile.isProduction ? .productionLiveRead : .liveRead
        opening.opened(statementLimit: limits.maximumElapsed)
        let rowLimit = max(0, min(request.rowLimit ?? limits.maximumRows, limits.maximumRows))
        guard let readOnly = session.connection as? any ReadOnlyExecuting else {
            throw MCPLiveReadError.readOnlyUnavailable
        }

        let collected: Collected
        do {
            // SQLite has no server-side bound on a statement. The extra
            // second lets the PostgreSQL and MySQL bound, which the driver
            // sets from `timeout`, end the statement first.
            collected = try await MCPRequestDeadline.run(limits.maximumElapsed + .seconds(1)) {
                try await collectRows(
                    decision.normalizedSQL, parameters: request.parameters, from: readOnly,
                    rowLimit: rowLimit, timeout: limits.maximumElapsed
                )
            }
        } catch MCPLiveReadError.timedOut {
            throw MCPLiveReadError.timedOut(seconds: MCPRequestDeadline.wholeSeconds(limits.maximumElapsed))
        } catch DriverError.cancelled where !Task.isCancelled {
            // Nothing in this process cancelled the statement, so the server
            // ended it at its time bound: the drivers report PostgreSQL's
            // query_canceled (SQLSTATE 57014,
            // https://www.postgresql.org/docs/current/errcodes-appendix.html)
            // and MySQL's interrupted statement (error 3024,
            // https://dev.mysql.com/doc/mysql-errors/8.0/en/server-error-reference.html)
            // as `DriverError.cancelled`.
            throw MCPLiveReadError.timedOut(seconds: MCPRequestDeadline.wholeSeconds(limits.maximumElapsed))
        }

        let names = collected.columns.map(\.name)
        let keys = uniqueKeys(names)
        let redactedNames = Set(profile.redactedColumns.map { $0.lowercased() })
        var redactedKeys = Set(profile.redactedColumns)
        for (key, name) in zip(keys, names) where redactedNames.contains(name.lowercased()) {
            redactedKeys.insert(key)
        }
        // The limiter bounds its own encoding; `columns` and the remaining
        // fields of the result are reserved out of the same ceiling.
        let reserve = try JSONEncoder().encode(names).count + 1_024
        guard reserve < limits.maximumSerializedBytes else { throw MCPLiveReadError.resultTooLarge }
        let limiter = MCPResultLimiter(limits: MCPResultLimits(
            maximumRows: rowLimit,
            maximumCellBytes: limits.maximumCellBytes,
            maximumSerializedBytes: limits.maximumSerializedBytes - reserve,
            maximumElapsed: limits.maximumElapsed
        ))
        let keyedRows = collected.rows.map { row in
            var values: [String: String?] = [:]
            values.reserveCapacity(keys.count)
            // A NULL cell stays in the row as a nil value, so the redaction
            // policy replaces a redacted NULL too and NULL-ness never leaks.
            for (key, value) in zip(keys, row) { values.updateValue(value.displayString, forKey: key) }
            return values
        }
        let bounded = try limiter.limit(
            rows: keyedRows, elapsed: collected.elapsed,
            redaction: MCPRedactionPolicy(caseInsensitive: redactedKeys)
        )
        let nameForKey = Dictionary(zip(keys, names), uniquingKeysWith: { first, _ in first })
        let rows = bounded.rows.map { row in keys.map { row[$0] ?? nil } }
        return MCPLiveReadResult(
            columns: names,
            rows: rows,
            rowCount: rows.count,
            truncated: leftSomethingOut(hasMoreRows: collected.hasMoreRows, bounded.metadata),
            hasMoreRows: collected.hasMoreRows,
            truncatedCells: bounded.metadata.truncatedCells,
            byteLimitReached: bounded.metadata.byteLimitReached,
            elapsedMs: milliseconds(collected.elapsed),
            redactedColumns: Set(bounded.metadata.redactedColumns.compactMap { nameForKey[$0] }).sorted()
        )
    }

    /// Whether any row, cell or byte was left out. The limiter's own
    /// `truncated` also counts a read that ran past its time limit, which
    /// leaves nothing out once every row was read.
    static func leftSomethingOut(hasMoreRows: Bool, _ metadata: MCPTruncationMetadata) -> Bool {
        hasMoreRows || metadata.omittedRows > 0 || metadata.truncatedCells > 0 || metadata.byteLimitReached
    }

    /// Keeps at most `rowLimit` rows and reads one more only to learn that
    /// the statement has more.
    private static func collectRows(
        _ sql: String, parameters: [SQLParameter], from readOnly: any ReadOnlyExecuting,
        rowLimit: Int, timeout: Duration
    ) async throws -> Collected {
        var columns: [ColumnMeta] = []
        var rows: [[BerryValue]] = []
        var hasMoreRows = false
        let clock = ContinuousClock()
        let started = clock.now
        collect: for try await event in readOnly.executeReadOnly(sql, parameters: parameters, timeout: timeout) {
            switch event {
            case .columns(let metas):
                columns = metas
            case .rows(let batch):
                for row in batch {
                    guard rows.count < rowLimit else {
                        // Leaving the loop ends the stream, which cancels the
                        // statement: a huge result is never read to its end.
                        hasMoreRows = true
                        break collect
                    }
                    rows.append(row)
                }
            case .complete:
                break
            }
        }
        // A stream whose reader is cancelled ends without an error; the rows
        // read until then are not the statement's result.
        try Task.checkCancellation()
        return Collected(columns: columns, rows: rows, hasMoreRows: hasMoreRows, elapsed: clock.now - started)
    }

    /// Rows are keyed by column name for the limiter and the redaction
    /// policy, so a repeated name, such as `email` from both sides of a
    /// join, gets `#2`, `#3`, … instead of overwriting the first value.
    private static func uniqueKeys(_ names: [String]) -> [String] {
        var used = Set<String>()
        var lastSuffix: [String: Int] = [:]
        return names.map { name in
            var key = name
            var suffix = lastSuffix[name, default: 1]
            while used.contains(key) {
                suffix += 1
                key = "\(name)#\(suffix)"
            }
            lastSuffix[name] = suffix
            used.insert(key)
            return key
        }
    }

    /// The agent-facing error for `error`. An unrecognized error raised while
    /// resolving or opening becomes `connectionFailed`, because a driver's or
    /// a tunnel's connect error can name the host, the user or a file path;
    /// a statement's own error is forwarded as one sanitized line.
    private static func mapped(_ error: Error) -> Error {
        // A cancelled caller gets cancellation whatever its request ended
        // with; it is never turned into a tool error.
        if Task.isCancelled { return CancellationError() }
        let readFailure = error as? ReadFailure
        let underlying = readFailure?.underlying ?? error
        let wasRead = readFailure != nil
        var isCancel = underlying is CancellationError
        if case .cancelled? = underlying as? DriverError { isCancel = true }
        if isCancel {
            // The calling task is not cancelled, so the cancel came from the
            // coordinator shutting down.
            return MCPLiveReadError.queryFailed(unexpected)
        }
        switch underlying {
        case let error as MCPLiveReadError:
            return error
        case let error as MCPProjectResolutionError:
            switch error {
            case .unauthorizedProfile, .missingProfile: return MCPLiveReadError.unknownConnection
            case .liveReadNotEnabled: return MCPLiveReadError.liveReadNotEnabled
            case .projectNotFound, .projectDisabled: return MCPLiveReadError.noProject
            case .unsupportedDriver: return MCPLiveReadError.unsupportedDatabase
            }
        case let error as MCPConnectionCoordinatorError:
            switch error {
            case .wrongDriverFamily, .sqlReadOnlyEnforcementUnavailable: return MCPLiveReadError.unsupportedDatabase
            case .duplicateRequestID, .shuttingDown: return MCPLiveReadError.queryFailed(unexpected)
            }
        case let error as MCPResultLimiterError where error == .metadataExceedsByteLimit:
            return MCPLiveReadError.resultTooLarge
        case let error as DriverError:
            switch error {
            case .readOnlyUnavailable:
                return MCPLiveReadError.readOnlyUnavailable
            case .connectionFailed, .connectionLost, .notConnected, .sshHostKeyChanged:
                return MCPLiveReadError.connectionFailed
            case .queryFailed(let message, _) where wasRead:
                return MCPLiveReadError.queryFailed(sanitized(message))
            case .unsupported(let message) where wasRead:
                return MCPLiveReadError.queryFailed(sanitized(message))
            default:
                break
            }
        default:
            break
        }
        return wasRead ? MCPLiveReadError.queryFailed(unexpected) : MCPLiveReadError.connectionFailed
    }

    /// One line of at most 500 characters: a server message can span lines
    /// and quote the whole statement back. MySQL and MariaDB name an account
    /// as `'user'@'host'` (https://dev.mysql.com/doc/refman/8.4/en/account-names.html),
    /// for example in error 1142, "SELECT command denied to user …"; every
    /// such pair is masked before the cut, so neither the user name nor the
    /// client host reaches the agent, even in part. `[^']*` cannot match a
    /// quote, so no attempt scans past the next quote and masking stays
    /// linear in the message.
    private static func sanitized(_ message: String) -> String {
        let masked = message.replacing(#/'[^']*'@'[^']*'/#, with: "'…'@'…'")
        let line = masked.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard line.count > 500 else { return line }
        return String(line.prefix(499)) + "…"
    }

    private static func driverID(for dialect: MCPSQLDialect) -> DriverID {
        switch dialect {
        case .postgresql: .postgres
        case .mysql: .mysql
        case .sqlite: .sqlite
        }
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        return Int(seconds) * 1_000 + Int(attoseconds / 1_000_000_000_000_000)
    }
}
