import BerryDriverKit
import Foundation

public actor LibSQLConnection: DriverConnection {
    public nonisolated let id = UUID()
    private nonisolated let client: LibSQLHTTPClient
    private let turn = ConnectionTurn()
    private var isClosed = false
    private var activeBaton: String?
    private var stickyBaseURL: URL?
    private var hasLostTransaction = false

    static let batchSize = 500

    init(
        baseURL: URL,
        authToken: String?,
        tlsMode: TLSMode,
        timeoutSeconds: TimeInterval,
        maxResponseBytes: Int = LibSQLHTTPClient.defaultMaxResponseBytes,
        sessionConfiguration: URLSessionConfiguration? = nil
    ) {
        self.client = LibSQLHTTPClient(
            baseURL: baseURL,
            authToken: authToken,
            tlsMode: tlsMode,
            timeoutSeconds: timeoutSeconds,
            maxResponseBytes: maxResponseBytes,
            sessionConfiguration: sessionConfiguration
        )
    }

    func verifyConnection() async throws {
        guard !isClosed else { throw DriverError.notConnected }
        let response = try await client.executePipeline(
            [.execute(HranaStatement(sql: "SELECT 1", args: nil, want_rows: true)), .close],
            baton: nil,
            stickyBaseURL: nil
        )
        guard let first = response.results.first else {
            throw DriverError.connectionFailed("Empty pipeline response during libSQL handshake")
        }
        if first.type == "error", let payload = first.error {
            throw LibSQLHTTPClient.mapHranaError(payload)
        }
    }

    // MARK: - DriverConnection

    public nonisolated func execute(_ sql: String) -> AsyncThrowingStream<ResultEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.run(sql: sql, continuation: continuation)
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination {
                    task.cancel()
                }
            }
        }
    }

    public nonisolated func cancelCurrentQuery() {
        client.cancelCurrentRequest()
    }

    public func setDatabase(_ name: String) async throws {
        throw DriverError.unsupported("libSQL has a single database per connection")
    }

    public nonisolated var introspector: any Introspector {
        LibSQLIntrospector(connection: self)
    }

    public func ping() async -> Bool {
        guard !isClosed else { return false }
        do {
            try await verifyConnection()
            return true
        } catch {
            return false
        }
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        hasLostTransaction = false
        let baton = activeBaton
        let sticky = stickyBaseURL
        activeBaton = nil
        stickyBaseURL = nil
        if let baton {
            await closeBatonBestEffort(baton: baton, stickyBaseURL: sticky)
        }
        client.invalidate()
    }

    // MARK: - Internal query helpers for introspection

    func queryAll(_ sql: String, binds: [SQLParameter] = []) async throws -> [[BerryValue]] {
        try await queryBatch([(sql: sql, binds: binds)]).first ?? []
    }

    func queryBatch(_ queries: [(sql: String, binds: [SQLParameter])]) async throws -> [[[BerryValue]]] {
        let results = try await queryBatchAllowingStepErrors(queries)
        return try results.map { try $0.get() }
    }

    func queryBatchAllowingStepErrors(
        _ queries: [(sql: String, binds: [SQLParameter])]
    ) async throws -> [Result<[[BerryValue]], DriverError>] {
        guard !isClosed else { throw DriverError.notConnected }
        guard !queries.isEmpty else { return [] }
        var requests: [HranaStreamRequest] = try queries.map { item in
            let args: [HranaValue]? = item.binds.isEmpty ? nil : try item.binds.map(HranaValue.from)
            return .execute(HranaStatement(sql: item.sql, args: args, want_rows: true))
        }
        requests.append(.close)
        let response = try await client.executePipeline(
            requests,
            baton: nil,
            stickyBaseURL: nil,
            isUserQuery: false
        )
        var allRows: [Result<[[BerryValue]], DriverError>] = []
        allRows.reserveCapacity(queries.count)
        for idx in 0..<queries.count {
            guard idx < response.results.count else {
                allRows.append(.success([]))
                continue
            }
            let outcome = response.results[idx]
            if let err = outcome.error {
                allRows.append(.failure(LibSQLHTTPClient.mapHranaError(err)))
                continue
            }
            if case .execute(let result) = outcome.response {
                allRows.append(.success(result.rows.map { row in row.map { $0.toBerryValue() } }))
            } else {
                allRows.append(.success([]))
            }
        }
        return allRows
    }

    // MARK: - Execution

    private func run(sql: String, continuation: AsyncThrowingStream<ResultEvent, Error>.Continuation) async {
        await turn.take()
        defer { turn.give() }

        if Task.isCancelled {
            continuation.finish(throwing: DriverError.cancelled)
            return
        }
        guard !isClosed else {
            continuation.finish(throwing: DriverError.notConnected)
            return
        }

        let statements = LibSQLSQLLexer.splitStatements(sql)
        guard !statements.isEmpty else {
            continuation.finish()
            return
        }

        if hasLostTransaction {
            if statements.count == 1 && Self.isFullRollback(statements[0]) {
                hasLostTransaction = false
                continuation.yield(.complete(QueryStats(rowsAffected: 0, duration: .zero)))
                continuation.finish()
                return
            }
            continuation.finish(throwing: Self.lostTransactionBlockedError())
            return
        }

        let previousBaton = activeBaton
        let previousStickyURL = stickyBaseURL
        let startedInTransaction = previousBaton != nil
        let mightStayInTransaction = startedInTransaction || Self.mayStartTransaction(statements)

        let primaryRequest: HranaStreamRequest
        if statements.count == 1 {
            primaryRequest = .execute(HranaStatement(sql: statements[0], args: nil, want_rows: true))
        } else {
            let steps = statements.enumerated().map { idx, statement in
                HranaBatchStep(
                    condition: idx == 0 ? nil : HranaBatchCondition(type: "ok", step: idx - 1),
                    stmt: HranaStatement(sql: statement, args: nil, want_rows: true)
                )
            }
            primaryRequest = .batch(HranaBatch(steps: steps))
        }

        let requests: [HranaStreamRequest] = mightStayInTransaction
            ? [primaryRequest, .getAutocommit]
            : [primaryRequest, .close]

        let clock = ContinuousClock()
        let started = clock.now

        do {
            let response = try await client.executePipeline(
                requests,
                baton: previousBaton,
                stickyBaseURL: previousStickyURL,
                isUserQuery: true
            )

            let keepStreamOpen: Bool
            if mightStayInTransaction,
               response.results.count >= 2,
               case .getAutocommit(let isAutocommit) = response.results[1].response {
                keepStreamOpen = !isAutocommit
            } else if mightStayInTransaction {
                keepStreamOpen = Self.shouldKeepStreamOpen(
                    statements: statements,
                    initiallyInTransaction: startedInTransaction
                )
            } else {
                keepStreamOpen = false
            }

            // Only apply `base_url` while keeping a baton open; autocommit and ended
            // streams never send follow-up requests against that URL.
            var postDeliveryError: Error?
            let nextBaton = response.baton.flatMap { $0.isEmpty ? nil : $0 }
            if keepStreamOpen, let nextBaton {
                if let rawBaseURL = response.base_url {
                    do {
                        let validatedStickyURL = try client.validateStickyBaseURL(rawBaseURL)
                        activeBaton = nextBaton
                        stickyBaseURL = validatedStickyURL
                    } catch {
                        activeBaton = nil
                        stickyBaseURL = nil
                        await closeBatonBestEffort(baton: nextBaton, stickyBaseURL: previousStickyURL)
                        if startedInTransaction {
                            hasLostTransaction = true
                            postDeliveryError = Self.withRollbackNotice(error)
                        } else {
                            postDeliveryError = error
                        }
                    }
                } else {
                    activeBaton = nextBaton
                    stickyBaseURL = previousStickyURL
                }
            } else {
                activeBaton = nil
                stickyBaseURL = nil
                if mightStayInTransaction, let endedBaton = nextBaton {
                    let closeStickyURL = response.base_url.flatMap { try? client.validateStickyBaseURL($0) } ?? previousStickyURL
                    await closeBatonBestEffort(baton: endedBaton, stickyBaseURL: closeStickyURL)
                }
                if keepStreamOpen, startedInTransaction {
                    hasLostTransaction = true
                    postDeliveryError = Self.lostTransactionBlockedError()
                }
            }

            guard let outcome = response.results.first else {
                if let postDeliveryError {
                    continuation.finish(throwing: postDeliveryError)
                } else {
                    continuation.finish()
                }
                return
            }
            if outcome.type == "error", let err = outcome.error {
                let mapped = LibSQLHTTPClient.mapHranaError(err)
                let droppedStream = LibSQLHTTPClient.isStreamError(code: err.code, message: err.message)
                if droppedStream {
                    activeBaton = nil
                    stickyBaseURL = nil
                }
                if startedInTransaction && (droppedStream || activeBaton == nil) {
                    hasLostTransaction = true
                    continuation.finish(throwing: Self.withRollbackNotice(mapped))
                    return
                }
                continuation.finish(throwing: mapped)
                return
            }

            switch outcome.response {
            case .execute(let result):
                let completed = await Self.yieldExecuteResult(
                    result,
                    duration: clock.now - started,
                    continuation: continuation
                )
                if !completed { return }
            case .batch(let batchResult):
                let count = max(batchResult.step_results.count, batchResult.step_errors.count)
                for idx in 0..<count {
                    if Task.isCancelled {
                        continuation.finish(throwing: DriverError.cancelled)
                        return
                    }
                    if idx < batchResult.step_errors.count, let err = batchResult.step_errors[idx] {
                        let mapped = LibSQLHTTPClient.mapHranaError(err)
                        continuation.finish(throwing: hasLostTransaction ? Self.withRollbackNotice(mapped) : mapped)
                        return
                    }
                    if idx < batchResult.step_results.count, let res = batchResult.step_results[idx] {
                        let completed = await Self.yieldExecuteResult(
                            res,
                            duration: clock.now - started,
                            continuation: continuation
                        )
                        if !completed { return }
                    }
                }
            case .getAutocommit, .close, nil:
                break
            }
            if let postDeliveryError {
                continuation.finish(throwing: postDeliveryError)
            } else {
                continuation.finish()
            }
        } catch let streamError as LibSQLWrappedStreamError {
            // Stream is expired or invalid on the server; clear without sending close.
            activeBaton = nil
            stickyBaseURL = nil
            if startedInTransaction {
                hasLostTransaction = true
                continuation.finish(throwing: Self.withRollbackNotice(streamError.underlying))
            } else {
                continuation.finish(throwing: streamError.underlying)
            }
        } catch {
            // Drop and close any open baton on transport, cancellation, or unknown failures so
            // server-side transaction locks are released promptly instead of timing out.
            if activeBaton == previousBaton, let baton = previousBaton {
                activeBaton = nil
                stickyBaseURL = nil
                hasLostTransaction = true
                await closeBatonBestEffort(baton: baton, stickyBaseURL: previousStickyURL)
                continuation.finish(throwing: Self.withRollbackNotice(error))
                return
            }
            continuation.finish(throwing: error)
        }
    }

    private func closeBatonBestEffort(baton: String, stickyBaseURL: URL?) async {
        guard !baton.isEmpty else { return }
        _ = try? await client.executePipeline(
            [.close],
            baton: baton,
            stickyBaseURL: stickyBaseURL,
            timeoutOverride: 5,
            ignoreTaskCancellation: true
        )
    }

    /// Hrana v3 HTTP pipeline buffers and decodes each response body in memory
    /// (bounded by `LibSQLHTTPClient.maxResponseBytes`) before yielding rows to
    /// callers in `batchSize` chunks so UI/stream consumers process incremental batches.
    private static func yieldExecuteResult(
        _ result: HranaExecuteResult,
        duration: Duration,
        continuation: AsyncThrowingStream<ResultEvent, Error>.Continuation
    ) async -> Bool {
        let columnCount = result.cols.count
        if columnCount > 0 {
            let metas = result.cols.enumerated().map { idx, col in
                ColumnMeta(
                    name: col.name ?? "col\(idx)",
                    declaredType: col.decltype ?? ""
                )
            }
            continuation.yield(.columns(metas))

            for start in stride(from: 0, to: result.rows.count, by: batchSize) {
                if Task.isCancelled {
                    continuation.finish(throwing: DriverError.cancelled)
                    return false
                }
                let end = min(start + batchSize, result.rows.count)
                let batch = result.rows[start..<end].map { row in
                    row.map { $0.toBerryValue() }
                }
                continuation.yield(.rows(batch))
                await Task.yield()
            }
        }

        let affected: Int64? = columnCount == 0 ? (result.affected_row_count ?? 0) : nil
        continuation.yield(.complete(QueryStats(rowsAffected: affected, duration: duration)))
        return true
    }

    private static func mayStartTransaction(_ statements: [String]) -> Bool {
        for statement in statements {
            guard let first = LibSQLSQLLexer.leadingKeywords(of: statement, maxCount: 1).first else {
                continue
            }
            if first == "BEGIN" || first == "SAVEPOINT" {
                return true
            }
        }
        return false
    }

    private static func isFullRollback(_ statement: String) -> Bool {
        let words = LibSQLSQLLexer.leadingKeywords(of: statement, maxCount: 3)
        guard words.first == "ROLLBACK" else { return false }
        let second = words.count > 1 ? words[1] : ""
        let third = words.count > 2 ? words[2] : ""
        return !(second == "TO" || (second == "TRANSACTION" && third == "TO"))
    }

    private static func lostTransactionBlockedError() -> DriverError {
        .queryFailed(
            message: "Current libSQL transaction was rolled back after the stream ended; execute ROLLBACK before running more statements.",
            code: nil
        )
    }

    private static func withRollbackNotice(_ error: Error) -> DriverError {
        let notice = "The active libSQL transaction was rolled back; execute ROLLBACK to reset the transaction."
        if let driverError = error as? DriverError {
            switch driverError {
            case .queryFailed(let message, let code):
                if message.localizedCaseInsensitiveContains("rolled back") {
                    return .queryFailed(message: "\(message) Execute ROLLBACK to reset the transaction.", code: code)
                }
                return .queryFailed(message: "\(message) \(notice)", code: code)
            case .connectionLost(let detail):
                return .connectionLost("\(detail) \(notice)")
            case .connectionFailed(let detail):
                return .connectionFailed("\(detail) \(notice)")
            case .cancelled:
                return .queryFailed(message: "Query cancelled. \(notice)", code: nil)
            case .unsupported(let detail):
                return .unsupported("\(detail) \(notice)")
            case .notConnected, .sshHostKeyChanged, .readOnlyUnavailable:
                return .queryFailed(message: "\(driverError.detail) \(notice)", code: nil)
            }
        }
        return .queryFailed(message: "\(error.localizedDescription) \(notice)", code: nil)
    }

    private static func shouldKeepStreamOpen(statements: [String], initiallyInTransaction: Bool) -> Bool {
        var inTransaction = initiallyInTransaction
        for statement in statements {
            let words = LibSQLSQLLexer.leadingKeywords(of: statement, maxCount: 1)
            guard let first = words.first else { continue }
            if first == "BEGIN" || first == "SAVEPOINT" {
                inTransaction = true
            } else if first == "COMMIT" || first == "END" || isFullRollback(statement) {
                inTransaction = false
            }
        }
        return inTransaction
    }
}

enum LibSQLSQLLexer {
    /// Splits SQL text on semicolons at top level, respecting strings, quoted identifiers,
    /// SQLite comments (`--` and non-nested `/* ... */`), and `BEGIN ... END` / `CASE ... END` blocks.
    static func splitStatements(_ sql: String) -> [String] {
        let bytes = Array(sql.utf8)
        var results: [String] = []
        var statementStart = 0
        var i = 0
        var beginDepth = 0
        var expectingTriggerBody = false

        func appendSlice(upTo end: Int) {
            let sliceBytes = Array(bytes[statementStart..<end])
            let chunk = String(decoding: sliceBytes, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty {
                results.append(chunk)
            }
            statementStart = end + 1
            beginDepth = 0
            expectingTriggerBody = false
        }

        while i < bytes.count {
            let byte = bytes[i]
            if byte == UInt8(ascii: "-") && i + 1 < bytes.count && bytes[i + 1] == UInt8(ascii: "-") {
                i += 2
                while i < bytes.count && bytes[i] != UInt8(ascii: "\n") { i += 1 }
            } else if byte == UInt8(ascii: "/") && i + 1 < bytes.count && bytes[i + 1] == UInt8(ascii: "*") {
                i += 2
                while i + 1 < bytes.count && !(bytes[i] == UInt8(ascii: "*") && bytes[i + 1] == UInt8(ascii: "/")) {
                    i += 1
                }
                i = min(i + 2, bytes.count)
            } else if byte == UInt8(ascii: "'") || byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "`") {
                i = skipQuoted(bytes, from: i, quote: byte)
            } else if byte == UInt8(ascii: "[") {
                i += 1
                while i < bytes.count && bytes[i] != UInt8(ascii: "]") { i += 1 }
                if i < bytes.count { i += 1 }
            } else if isIdentifierStart(byte) {
                let start = i
                i += 1
                while i < bytes.count && isIdentifierContinue(bytes[i]) { i += 1 }
                let word = String(decoding: bytes[start..<i], as: UTF8.self).uppercased()
                if word == "TRIGGER" {
                    expectingTriggerBody = true
                } else if (word == "BEGIN" || word == "CASE") && expectingTriggerBody {
                    beginDepth += 1
                } else if word == "END" && beginDepth > 0 {
                    beginDepth -= 1
                }
            } else if byte == UInt8(ascii: ";") && beginDepth == 0 {
                appendSlice(upTo: i)
                i += 1
            } else {
                i += 1
            }
        }

        if statementStart < bytes.count {
            let tail = String(decoding: Array(bytes[statementStart..<bytes.count]), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty {
                results.append(tail)
            }
        }
        return results
    }

    static func leadingKeywords(of sql: String, maxCount: Int) -> [String] {
        let bytes = Array(sql.utf8)
        var words: [String] = []
        var i = 0
        while i < bytes.count && words.count < maxCount {
            let b = bytes[i]
            if b == UInt8(ascii: " ") || b == UInt8(ascii: "\t")
                || b == UInt8(ascii: "\n") || b == UInt8(ascii: "\r") {
                i += 1
            } else if b == UInt8(ascii: "-") && i + 1 < bytes.count && bytes[i + 1] == UInt8(ascii: "-") {
                i += 2
                while i < bytes.count && bytes[i] != UInt8(ascii: "\n") { i += 1 }
            } else if b == UInt8(ascii: "/") && i + 1 < bytes.count && bytes[i + 1] == UInt8(ascii: "*") {
                i += 2
                while i + 1 < bytes.count && !(bytes[i] == UInt8(ascii: "*") && bytes[i + 1] == UInt8(ascii: "/")) {
                    i += 1
                }
                i = min(i + 2, bytes.count)
            } else if isIdentifierStart(b) {
                let start = i
                i += 1
                while i < bytes.count && isIdentifierContinue(bytes[i]) { i += 1 }
                words.append(String(decoding: bytes[start..<i], as: UTF8.self).uppercased())
            } else {
                break
            }
        }
        return words
    }

    private static func skipQuoted(_ bytes: [UInt8], from start: Int, quote: UInt8) -> Int {
        var i = start + 1
        while i < bytes.count {
            if bytes[i] == quote {
                if i + 1 < bytes.count && bytes[i + 1] == quote {
                    i += 2
                } else {
                    return i + 1
                }
            } else {
                i += 1
            }
        }
        return bytes.count
    }

    private static func isIdentifierStart(_ byte: UInt8) -> Bool {
        (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
            || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
            || byte == UInt8(ascii: "_")
    }

    private static func isIdentifierContinue(_ byte: UInt8) -> Bool {
        isIdentifierStart(byte) || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
    }
}
