import BerryDriverKit
import Foundation

/// The app's single SQL execution path (principle N1) — grid, editor,
/// designer, import, and the future AI agent all go through here, so
/// auto-LIMIT, DangerGuard, and history only need one hook (docs/architecture/04 §6).
public enum QueryService {
    /// Default LIMIT for SELECTs without a LIMIT (ED-12).
    public static let defaultAutoLimit = 1000

    /// History sink (ED-06) — wired once at startup by the app layer.
    nonisolated(unsafe) private static var _historySink: (any QueryHistorySink)?
    /// Danger confirmation gate (07 §6) — wired once by the UI layer.
    nonisolated(unsafe) private static var _dangerConfirmer: (any DangerConfirmer)?
    private static let sinkLock = NSLock()

    public static var historySink: (any QueryHistorySink)? {
        get { sinkLock.lock(); defer { sinkLock.unlock() }; return _historySink }
        set { sinkLock.lock(); defer { sinkLock.unlock() }; _historySink = newValue }
    }

    public static var dangerConfirmer: (any DangerConfirmer)? {
        get { sinkLock.lock(); defer { sinkLock.unlock() }; return _dangerConfirmer }
        set { sinkLock.lock(); defer { sinkLock.unlock() }; _dangerConfirmer = newValue }
    }

    /// User switch for the soft data-deletion confirms (docs/ui) — production
    /// rules (07 §6) are NOT affected by this.
    nonisolated(unsafe) private static var _confirmsDataDeletion = true
    public static var confirmsDataDeletion: Bool {
        get { sinkLock.lock(); defer { sinkLock.unlock() }; return _confirmsDataDeletion }
        set { sinkLock.lock(); defer { sinkLock.unlock() }; _confirmsDataDeletion = newValue }
    }

    public static func execute(
        _ sql: String,
        on session: Session,
        autoLimit: Int? = defaultAutoLimit,
        recordHistory: Bool = true,
        dangerPreconfirmed: Bool = false
    ) -> AsyncThrowingStream<ResultEvent, Error> {
        let effectiveSQL = applyAutoLimitIfNeeded(sql, dialect: session.dialect, limit: autoLimit)
        return instrumented(
            sql: effectiveSQL, session: session, recordHistory: recordHistory,
            dangerPreconfirmed: dangerPreconfirmed
        ) {
            session.connection.execute(effectiveSQL)
        }
    }

    /// SELECT an entire table for the grid (DL-01) with optional filter/sort
    /// (DL-02) — generated via dialect, with auto-LIMIT.
    public static func selectAll(
        table: TableRef,
        on session: Session,
        whereClause: String? = nil,
        orderBy: (column: String, ascending: Bool)? = nil,
        limit: Int = defaultAutoLimit
    ) -> AsyncThrowingStream<ResultEvent, Error> {
        let sql = session.dialect.select(
            from: table, whereClause: whereClause, orderBy: orderBy, limit: limit
        )
        return instrumented(sql: sql, session: session) {
            session.connection.execute(sql)
        }
    }

    // MARK: - Danger gate (07 §6) + history instrumentation (ED-06)

    /// Pass-through stream that (1) gates dangerous statements behind the
    /// confirmer and (2) reports the outcome to the history sink. One hook
    /// covers every SQL path in the app (N1). The inner stream is built
    /// LAZILY — drivers must not start work before the user confirms.
    private static func instrumented(
        sql: String,
        session: Session,
        recordHistory: Bool = true,
        dangerPreconfirmed: Bool = false,
        makeInner: @escaping @Sendable () -> AsyncThrowingStream<ResultEvent, Error>
    ) -> AsyncThrowingStream<ResultEvent, Error> {
        let profileID = session.profileID
        // ED-06: also honor the connection's history switch, not just the
        // per-call opt-out used by background harvesters.
        let shouldRecord = recordHistory && session.recordHistory
        // Soft data-deletion confirms (docs/ui): skipped when the user turned
        // them off, or when the whole run was already confirmed in one summary
        // dialog. Production rules (07 §6) never downgrade.
        let classified = DangerGuard.classify(sql, isProduction: session.isProduction)
        let danger: DangerLevel
        if case .confirm(let reason) = classified, reason.isSoftDataDeletion,
           dangerPreconfirmed || !confirmsDataDeletion {
            danger = .safe
        } else {
            danger = classified
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                let startedAt = Date()
                let clock = ContinuousClock()
                let began = clock.now
                var rowCount = 0
                var sawRows = false

                func report(_ status: ExecutedStatement.Status, error: String? = nil) {
                    // Background metadata harvesters (stats, EXPLAIN plans — DI-01/06)
                    // opt out so they don't masquerade as user history (11 §4);
                    // ED-06 lets a connection disable history entirely.
                    guard shouldRecord else { return }
                    historySink?.record(ExecutedStatement(
                        profileID: profileID,
                        sql: sql,
                        startedAt: startedAt,
                        duration: clock.now - began,
                        status: status,
                        rowCount: sawRows ? rowCount : nil,
                        errorMessage: error
                    ))
                }

                if danger != .safe, let confirmer = dangerConfirmer {
                    guard await confirmer.confirm(danger, sql: sql) else {
                        report(.cancelled)
                        continuation.finish(throwing: DriverError.cancelled)
                        return
                    }
                }

                do {
                    for try await event in makeInner() {
                        if case .rows(let batch) = event {
                            sawRows = true
                            rowCount += batch.count
                        }
                        continuation.yield(event)
                    }
                    report(.success)
                    continuation.finish()
                } catch let error as DriverError {
                    if case .cancelled = error {
                        report(.cancelled)
                    } else {
                        report(.failed, error: error.localizedDescription)
                    }
                    continuation.finish(throwing: error)
                } catch {
                    report(.failed, error: error.localizedDescription)
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination {
                    task.cancel()
                }
            }
        }
    }

    // MARK: - Auto-LIMIT (ED-12)

    /// Add a LIMIT to a single SELECT that has none. Simple token-level check;
    /// the tree-sitter parser in M2 will replace this detection.
    static func applyAutoLimitIfNeeded(_ sql: String, dialect: any SQLDialect, limit: Int?) -> String {
        guard let limit else { return sql }
        var trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only applies to a single statement (multi-statement strings are left as-is).
        guard !trimmed.isEmpty else { return sql }
        var hadTrailingSemicolon = false
        if trimmed.hasSuffix(";") {
            hadTrailingSemicolon = true
            trimmed = String(trimmed.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !trimmed.contains(";") else { return sql }

        let lowered = trimmed.lowercased()
        let isSelect = lowered.hasPrefix("select") || lowered.hasPrefix("with")
        guard isSelect else { return sql }

        let tokens = lowered.split(whereSeparator: { $0.isWhitespace || $0 == "(" || $0 == ")" })
        guard !tokens.contains("limit") else { return sql }

        // T-SQL's OFFSET...FETCH (SQL Server's limitClause) requires an
        // ORDER BY — a plain `SELECT * FROM t` has none, so append a no-op
        // sort key first rather than emit a statement that fails to parse.
        // A real ORDER BY already present (e.g. a sorted grid column) is left
        // untouched — adding a second one would itself be a syntax error.
        var orderByPrefix = ""
        if dialect.requiresOrderByForLimit(), !lowered.contains("order by") {
            orderByPrefix = " ORDER BY (SELECT NULL)"
        }

        return trimmed + orderByPrefix + " " + dialect.limitClause(limit) + (hadTrailingSemicolon ? ";" : "")
    }
}
