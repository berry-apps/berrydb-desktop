import BerryDriverKit
import Foundation

public actor LibSQLConnection: DriverConnection, ReadOnlyExecuting {
    public nonisolated let id = UUID()
    private nonisolated let client: LibSQLHTTPClient
    private let tlsMode: TLSMode
    private var isClosed = false
    private var activeBaton: String?
    private var stickyBaseURL: URL?

    static let batchSize = 500

    init(
        baseURL: URL,
        authToken: String?,
        tlsMode: TLSMode,
        timeoutSeconds: TimeInterval,
        sessionConfiguration: URLSessionConfiguration? = nil
    ) {
        self.tlsMode = tlsMode
        self.client = LibSQLHTTPClient(
            baseURL: baseURL,
            authToken: authToken,
            timeoutSeconds: timeoutSeconds,
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
                    self.cancelCurrentQuery()
                }
            }
        }
    }

    public func prepareReadOnly() async throws {
        guard !isClosed else { throw DriverError.notConnected }
        let response = try await client.executePipeline(
            [
                .execute(HranaStatement(sql: "PRAGMA query_only = ON", args: nil, want_rows: false)),
                .execute(HranaStatement(sql: "PRAGMA query_only", args: nil, want_rows: true)),
                .close,
            ],
            baton: nil,
            stickyBaseURL: nil
        )
        guard response.results.count >= 2 else {
            throw DriverError.readOnlySetupFailure(
                .connectionFailed("Incomplete response while enabling libSQL read-only mode.")
            )
        }
        if let err = response.results[0].error {
            throw DriverError.readOnlySetupFailure(LibSQLHTTPClient.mapHranaError(err))
        }
        if let err = response.results[1].error {
            throw DriverError.readOnlySetupFailure(LibSQLHTTPClient.mapHranaError(err))
        }
        guard case .execute(let checkResult) = response.results[1].response,
              let firstValue = checkResult.rows.first?.first,
              firstValue == .integer(1) || firstValue == .text("1")
        else {
            throw DriverError.readOnlySetupFailure(
                .queryFailed(message: "PRAGMA query_only did not activate read-only mode.", code: nil)
            )
        }
    }

    public nonisolated func executeReadOnly(
        _ sql: String,
        timeout: Duration
    ) -> AsyncThrowingStream<ResultEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.runReadOnly(
                    sql: sql,
                    parameters: [],
                    timeoutOverride: Self.seconds(from: timeout),
                    continuation: continuation
                )
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination {
                    task.cancel()
                    self.cancelCurrentQuery()
                }
            }
        }
    }

    public nonisolated func executeReadOnly(
        _ sql: String,
        parameters: [SQLParameter]
    ) -> AsyncThrowingStream<ResultEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.runReadOnly(
                    sql: sql,
                    parameters: parameters,
                    timeoutOverride: nil,
                    continuation: continuation
                )
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination {
                    task.cancel()
                    self.cancelCurrentQuery()
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
        if let baton = activeBaton {
            let sticky = stickyBaseURL
            activeBaton = nil
            stickyBaseURL = nil
            _ = try? await client.executePipeline([.close], baton: baton, stickyBaseURL: sticky)
        }
        client.invalidate()
    }

    // MARK: - Internal query helper for introspection

    func queryAll(_ sql: String, binds: [SQLParameter] = []) async throws -> [[BerryValue]] {
        guard !isClosed else { throw DriverError.notConnected }
        let args: [HranaValue]? = binds.isEmpty ? nil : try binds.map(HranaValue.from)
        let response = try await client.executePipeline(
            [.execute(HranaStatement(sql: sql, args: args, want_rows: true)), .close],
            baton: nil,
            stickyBaseURL: nil
        )
        guard let outcome = response.results.first else { return [] }
        if let err = outcome.error {
            throw LibSQLHTTPClient.mapHranaError(err)
        }
        guard case .execute(let result) = outcome.response else { return [] }
        return result.rows.map { row in row.map { $0.toBerryValue() } }
    }

    // MARK: - Execution

    private func run(sql: String, continuation: AsyncThrowingStream<ResultEvent, Error>.Continuation) async {
        guard !isClosed else {
            continuation.finish(throwing: DriverError.notConnected)
            return
        }

        let statements = LibSQLSQLLexer.splitStatements(sql)
        guard !statements.isEmpty else {
            continuation.finish()
            return
        }

        let startedInTransaction = activeBaton != nil
        let keepStreamOpen = Self.shouldKeepStreamOpen(
            statements: statements,
            initiallyInTransaction: startedInTransaction
        )

        var requests = statements.map {
            HranaStreamRequest.execute(HranaStatement(sql: $0, args: nil, want_rows: true))
        }
        if !keepStreamOpen {
            requests.append(.close)
        }

        let clock = ContinuousClock()
        let started = clock.now

        do {
            let response = try await client.executePipeline(
                requests,
                baton: activeBaton,
                stickyBaseURL: stickyBaseURL
            )

            if keepStreamOpen {
                activeBaton = response.baton
                stickyBaseURL = response.base_url.flatMap(URL.init(string:)) ?? stickyBaseURL
            } else {
                activeBaton = nil
                stickyBaseURL = nil
            }

            let stepCount = min(statements.count, response.results.count)
            for idx in 0..<stepCount {
                if Task.isCancelled {
                    continuation.finish(throwing: DriverError.cancelled)
                    return
                }
                let outcome = response.results[idx]
                if outcome.type == "error", let err = outcome.error {
                    continuation.finish(throwing: LibSQLHTTPClient.mapHranaError(err))
                    return
                }
                if case .execute(let result) = outcome.response {
                    await Self.yieldExecuteResult(
                        result,
                        duration: clock.now - started,
                        continuation: continuation
                    )
                }
            }
            continuation.finish()
        } catch {
            if !keepStreamOpen {
                activeBaton = nil
                stickyBaseURL = nil
            }
            continuation.finish(throwing: error)
        }
    }

    private func runReadOnly(
        sql: String,
        parameters: [SQLParameter],
        timeoutOverride: TimeInterval?,
        continuation: AsyncThrowingStream<ResultEvent, Error>.Continuation
    ) async {
        guard !isClosed else {
            continuation.finish(throwing: DriverError.notConnected)
            return
        }

        let statements = LibSQLSQLLexer.splitStatements(sql)
        if statements.count > 1 {
            continuation.finish(throwing: DriverError.queryFailed(
                message: "The read-only connection runs one statement at a time, and this text holds more than one.",
                code: nil
            ))
            return
        }

        if let refusal = ReadOnlyAllowlist.sqlite.refusal(of: sql) {
            continuation.finish(throwing: refusal)
            return
        }

        guard let statement = statements.first else {
            continuation.finish()
            return
        }

        let expectedCount: Int
        do {
            expectedCount = try LibSQLSQLLexer.validatePlaceholders(in: statement)
        } catch {
            continuation.finish(throwing: error)
            return
        }

        if parameters.count != expectedCount {
            continuation.finish(throwing: DriverError.placeholderCountMismatch(
                placeholders: expectedCount,
                parameters: parameters.count
            ))
            return
        }

        let hranaArgs: [HranaValue]?
        do {
            hranaArgs = parameters.isEmpty ? nil : try parameters.map(HranaValue.from)
        } catch {
            continuation.finish(throwing: error)
            return
        }

        let clock = ContinuousClock()
        let started = clock.now
        do {
            // Enforce query_only on the same ephemeral Hrana stream immediately before the read.
            let response = try await client.executePipeline(
                [
                    .execute(HranaStatement(sql: "PRAGMA query_only = ON", args: nil, want_rows: false)),
                    .execute(HranaStatement(sql: statement, args: hranaArgs, want_rows: true)),
                    .close,
                ],
                baton: nil,
                stickyBaseURL: nil,
                timeoutOverride: timeoutOverride
            )
            guard response.results.count >= 2 else {
                continuation.finish(throwing: DriverError.readOnlySetupFailure(
                    .connectionFailed("Incomplete response during libSQL read-only execution.")
                ))
                return
            }
            if response.results[0].type == "error", let err = response.results[0].error {
                continuation.finish(throwing: DriverError.readOnlySetupFailure(LibSQLHTTPClient.mapHranaError(err)))
                return
            }
            let queryOutcome = response.results[1]
            if queryOutcome.type == "error", let err = queryOutcome.error {
                continuation.finish(throwing: LibSQLHTTPClient.mapHranaError(err))
                return
            }
            if case .execute(let result) = queryOutcome.response {
                await Self.yieldExecuteResult(
                    result,
                    duration: clock.now - started,
                    continuation: continuation
                )
            }
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }

    private static func yieldExecuteResult(
        _ result: HranaExecuteResult,
        duration: Duration,
        continuation: AsyncThrowingStream<ResultEvent, Error>.Continuation
    ) async {
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
    }

    private static func seconds(from duration: Duration) -> TimeInterval {
        let (secs, attos) = duration.components
        return max(0.001, Double(secs) + Double(attos) / 1_000_000_000_000_000_000)
    }

    private static func shouldKeepStreamOpen(statements: [String], initiallyInTransaction: Bool) -> Bool {
        var inTransaction = initiallyInTransaction
        for statement in statements {
            let words = LibSQLSQLLexer.leadingKeywords(of: statement, maxCount: 2)
            guard let first = words.first else { continue }
            if first == "BEGIN" {
                inTransaction = true
            } else if first == "COMMIT" || first == "END" {
                inTransaction = false
            } else if first == "ROLLBACK" {
                let second = words.count > 1 ? words[1] : ""
                if second != "TO" && second != "TRANSACTION" {
                    // ROLLBACK [TRANSACTION] (without TO <savepoint>) closes the transaction.
                    inTransaction = false
                } else if second == "TRANSACTION" {
                    inTransaction = false
                }
            }
        }
        return inTransaction
    }
}

enum LibSQLSQLLexer {
    /// Splits SQL text on semicolons at top level, respecting strings, quoted identifiers,
    /// SQLite comments (`--` and non-nested `/* ... */`), and `BEGIN ... END` blocks.
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
                } else if word == "BEGIN" && expectingTriggerBody {
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

    static func validatePlaceholders(in sql: String) throws -> Int {
        let bytes = Array(sql.utf8)
        var bareCount = 0
        var numbered: Set<Int> = []
        var i = 0

        while i < bytes.count {
            let b = bytes[i]
            if b == UInt8(ascii: "-") && i + 1 < bytes.count && bytes[i + 1] == UInt8(ascii: "-") {
                i += 2
                while i < bytes.count && bytes[i] != UInt8(ascii: "\n") { i += 1 }
            } else if b == UInt8(ascii: "/") && i + 1 < bytes.count && bytes[i + 1] == UInt8(ascii: "*") {
                i += 2
                while i + 1 < bytes.count && !(bytes[i] == UInt8(ascii: "*") && bytes[i + 1] == UInt8(ascii: "/")) {
                    i += 1
                }
                i = min(i + 2, bytes.count)
            } else if b == UInt8(ascii: "'") || b == UInt8(ascii: "\"") || b == UInt8(ascii: "`") {
                i = skipQuoted(bytes, from: i, quote: b)
            } else if b == UInt8(ascii: "[") {
                i += 1
                while i < bytes.count && bytes[i] != UInt8(ascii: "]") { i += 1 }
                if i < bytes.count { i += 1 }
            } else if b == UInt8(ascii: ":") || b == UInt8(ascii: "@") || b == UInt8(ascii: "$") {
                if i + 1 < bytes.count && isIdentifierContinue(bytes[i + 1]) {
                    throw DriverError.queryFailed(
                        message: "The read-only connection binds only ? and ?NNN placeholders on SQLite.",
                        code: nil
                    )
                }
                i += 1
            } else if b == UInt8(ascii: "?") {
                i += 1
                let digitStart = i
                while i < bytes.count && bytes[i] >= UInt8(ascii: "0") && bytes[i] <= UInt8(ascii: "9") {
                    i += 1
                }
                if i == digitStart {
                    bareCount += 1
                } else {
                    let digits = String(decoding: bytes[digitStart..<i], as: UTF8.self)
                    guard let index = Int(digits), index >= 1 else {
                        throw DriverError.queryFailed(
                            message: "On SQLite, ?NNN placeholders must use every number from 1 to the highest, without a bare ?.",
                            code: nil
                        )
                    }
                    numbered.insert(index)
                }
            } else {
                i += 1
            }
        }

        if numbered.isEmpty {
            return bareCount
        }
        guard bareCount == 0, let highest = numbered.max(), numbered.count == highest else {
            throw DriverError.queryFailed(
                message: "On SQLite, ?NNN placeholders must use every number from 1 to the highest, without a bare ?.",
                code: nil
            )
        }
        return highest
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
