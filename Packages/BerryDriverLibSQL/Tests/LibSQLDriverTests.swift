import BerryDriverKit
@testable import BerryDriverLibSQL
import Foundation
import os
import Testing

@Suite("LibSQL Driver")
struct LibSQLDriverTests {
    // MARK: - Helpers

    private func makeHTTPResponse(
        url: URL,
        statusCode: Int = 200,
        headers: [String: String]? = nil
    ) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    private func jsonData(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private func parsePipelineRequest(_ data: Data?) throws -> (baton: String?, requests: [[String: Any]]) {
        guard let data,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let requests = json["requests"] as? [[String: Any]]
        else {
            throw URLError(.cannotParseResponse)
        }
        return (json["baton"] as? String, requests)
    }

    private func okAutocommitResult(_ isAutocommit: Bool) -> [String: Any] {
        [
            "type": "ok",
            "response": [
                "type": "get_autocommit",
                "is_autocommit": isAutocommit,
            ],
        ]
    }

    private func okExecuteResult(
        cols: [[String: String]] = [],
        rows: [[[String: Any]]] = [],
        affectedRowCount: Int = 0
    ) -> [String: Any] {
        [
            "type": "ok",
            "response": [
                "type": "execute",
                "result": [
                    "cols": cols,
                    "rows": rows,
                    "affected_row_count": affectedRowCount,
                    "last_insert_rowid": NSNull(),
                ],
            ],
        ]
    }

    private func okCloseResult() -> [String: Any] {
        [
            "type": "ok",
            "response": ["type": "close"],
        ]
    }

    private func collect(_ stream: AsyncThrowingStream<ResultEvent, Error>) async throws -> [ResultEvent] {
        var events: [ResultEvent] = []
        for try await event in stream {
            events.append(event)
        }
        return events
    }

    // MARK: - URL & Config Parsing

    @Test("parseLibSQLEndpoint derives TLS from libsql/https schemes and http/bare-host fallback")
    func endpointParsing() {
        let turso = ConnectionConfig.parseLibSQLEndpoint(host: "libsql://my-db-org.turso.io")
        #expect(turso?.baseURL.absoluteString == "https://my-db-org.turso.io")
        #expect(turso?.useTLS == true)
        #expect(turso?.port == 443)

        let libsqlSchemeIgnoresDisable = ConnectionConfig.parseLibSQLEndpoint(
            host: "libsql://my-db-org.turso.io",
            tlsMode: .disable
        )
        #expect(libsqlSchemeIgnoresDisable?.baseURL.absoluteString == "https://my-db-org.turso.io")
        #expect(libsqlSchemeIgnoresDisable?.useTLS == true)

        let localBareDisable = ConnectionConfig.parseLibSQLEndpoint(
            host: "127.0.0.1:8080",
            tlsMode: .disable
        )
        #expect(localBareDisable?.baseURL.absoluteString == "http://127.0.0.1:8080")
        #expect(localBareDisable?.useTLS == false)
        #expect(localBareDisable?.port == 8080)

        let bareWithPort = ConnectionConfig.parseLibSQLEndpoint(
            host: "sqld.internal",
            port: 8443,
            tlsMode: .require
        )
        #expect(bareWithPort?.baseURL.absoluteString == "https://sqld.internal:8443")
        #expect(bareWithPort?.port == 8443)

        let subpath = ConnectionConfig.parseLibSQLEndpoint(host: "https://proxy.example.com/db/")
        #expect(subpath?.baseURL.absoluteString == "https://proxy.example.com/db")

        let explicitHTTP = ConnectionConfig.parseLibSQLEndpoint(host: "http://localhost:8080", tlsMode: .require)
        #expect(explicitHTTP?.baseURL.absoluteString == "http://localhost:8080")
        #expect(explicitHTTP?.useTLS == false)

        #expect(ConnectionConfig.parseLibSQLEndpoint(host: "") == nil)
        #expect(ConnectionConfig.parseLibSQLEndpoint(host: "ftp://example.com") == nil)

        let withQueryToken = ConnectionConfig.parseLibSQLEndpoint(host: "libsql://my-db-org.turso.io?authToken=tok_123")
        #expect(withQueryToken?.baseURL.absoluteString == "https://my-db-org.turso.io")
        #expect(withQueryToken?.sanitizedHost == "libsql://my-db-org.turso.io")
        #expect(withQueryToken?.authToken == "tok_123")
        #expect(withQueryToken?.useTLS == true)

        let withSnakeToken = ConnectionConfig.parseLibSQLEndpoint(host: "https://my-db.turso.io/sub/?auth_token=tok_abc&foo=bar")
        #expect(withSnakeToken?.sanitizedHost == "https://my-db.turso.io/sub")
        #expect(withSnakeToken?.authToken == "tok_abc")

        let libsqlFactory = ConnectionConfig.libsql(host: "libsql://my-db-org.turso.io?authToken=secret_jwt")
        #expect(libsqlFactory.host == "libsql://my-db-org.turso.io")
        #expect(libsqlFactory.password == "secret_jwt")
        #expect(libsqlFactory.tlsMode == .require)
    }

    @Test("driver capabilities report cancelQuery false and reuse SQLiteDialect")
    func capabilitiesAndDialect() {
        #expect(LibSQLDriver.capabilities.transactions == true)
        #expect(LibSQLDriver.capabilities.cancelQuery == false)
        #expect(LibSQLDriver.capabilities.explain == true)

        #expect(LibSQLDriver.dialect.explainPrefix(analyze: false) == "EXPLAIN QUERY PLAN")
        #expect(LibSQLDriver.dialect.explainPrefix(analyze: true) == "EXPLAIN QUERY PLAN")
        #expect(LibSQLDriver.dialect.truncateSQL(TableRef(name: "orders")) == "DELETE FROM \"orders\";")
        #expect(LibSQLDriver.dialect.boolLiteral(true) == "1")
        #expect(LibSQLDriver.dialect.boolLiteral(false) == "0")
    }

    // MARK: - Auth & Handshake

    @Test("connect sends Bearer token and handles 401 authentication failure")
    func connectAuth() async throws {
        let host = "auth-\(UUID().uuidString).test"
        defer { LibSQLStubURLProtocol.unregister(host: host) }

        let seenAuth = OSAllocatedUnfairLock<[String?]>(initialState: [])
        LibSQLStubURLProtocol.register(host: host) { request, data in
            seenAuth.withLock { $0.append(request.value(forHTTPHeaderField: "Authorization")) }
            guard let url = request.url else { throw URLError(.badURL) }
            if request.value(forHTTPHeaderField: "Authorization") != "Bearer secret-token" {
                let errBody = try jsonData(["error": "invalid token"])
                return (makeHTTPResponse(url: url, statusCode: 401), errBody)
            }
            let (_, reqs) = try parsePipelineRequest(data)
            #expect(reqs.count == 2)
            let body = try jsonData([
                "baton": NSNull(),
                "base_url": NSNull(),
                "results": [
                    okExecuteResult(
                        cols: [["name": "1", "decltype": "INTEGER"]],
                        rows: [[["type": "integer", "value": "1"]]]
                    ),
                    okCloseResult(),
                ],
            ])
            return (makeHTTPResponse(url: url), body)
        }

        let badConfig = ConnectionConfig.libsql(host: "libsql://\(host)", authToken: "wrong-token")
        do {
            _ = try await LibSQLDriver.connect(
                badConfig,
                sessionConfiguration: LibSQLStubURLProtocol.sessionConfiguration()
            )
            Issue.record("Expected connectionFailed on 401")
        } catch let error as DriverError {
            guard case .connectionFailed(let msg) = error else {
                Issue.record("Expected connectionFailed, got \(error)")
                return
            }
            #expect(msg.contains("401"))
        }

        let goodConfig = ConnectionConfig.libsql(host: "libsql://\(host)", authToken: "secret-token")
        let conn = try await LibSQLDriver.connect(
            goodConfig,
            sessionConfiguration: LibSQLStubURLProtocol.sessionConfiguration()
        )
        #expect(await conn.ping() == true)
        await conn.close()
        #expect(await conn.ping() == false)
        #expect(seenAuth.withLock { $0 } == ["Bearer wrong-token", "Bearer secret-token", "Bearer secret-token"])
    }

    // MARK: - Types, Batching & DML

    @Test("execute decodes all Hrana value types and chunks rows in 500-row batches")
    func typesAndBatching() async throws {
        let host = "types-\(UUID().uuidString).test"
        defer { LibSQLStubURLProtocol.unregister(host: host) }

        let blobData = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let rowCount = 502

        LibSQLStubURLProtocol.register(host: host) { request, data in
            guard let url = request.url else { throw URLError(.badURL) }
            let (_, reqs) = try parsePipelineRequest(data)
            let stmt = (reqs.first?["stmt"] as? [String: Any])?["sql"] as? String ?? ""
            if stmt == "SELECT 1" {
                return (
                    makeHTTPResponse(url: url),
                    try jsonData(["results": [okExecuteResult(cols: [["name": "1"]], rows: [[["type": "integer", "value": "1"]]]), okCloseResult()]])
                )
            }
            if stmt.hasPrefix("UPDATE") {
                return (
                    makeHTTPResponse(url: url),
                    try jsonData(["results": [okExecuteResult(cols: [], rows: [], affectedRowCount: 3), okCloseResult()]])
                )
            }
            let rows: [[[String: Any]]] = (0..<rowCount).map { idx in
                [
                    ["type": "integer", "value": "\(idx)"],
                    ["type": "float", "value": 1.5],
                    ["type": "text", "value": "row-\(idx)"],
                    ["type": "blob", "base64": blobData.base64EncodedString()],
                    ["type": "null"],
                ]
            }
            return (
                makeHTTPResponse(url: url),
                try jsonData([
                    "results": [
                        okExecuteResult(
                            cols: [
                                ["name": "i", "decltype": "INTEGER"],
                                ["name": "f", "decltype": "REAL"],
                                ["name": "t", "decltype": "TEXT"],
                                ["name": "b", "decltype": "BLOB"],
                                ["name": "n", "decltype": ""],
                            ],
                            rows: rows
                        ),
                        okCloseResult(),
                    ],
                ])
            )
        }

        let conn = try await LibSQLDriver.connect(
            .libsql(host: "https://\(host)"),
            sessionConfiguration: LibSQLStubURLProtocol.sessionConfiguration()
        )
        defer { Task { await conn.close() } }

        let selectEvents = try await collect(conn.execute("SELECT i, f, t, b, n FROM items"))
        var batches: [[[BerryValue]]] = []
        var metas: [ColumnMeta] = []
        for event in selectEvents {
            switch event {
            case .columns(let cols): metas = cols
            case .rows(let chunk): batches.append(chunk)
            case .complete(let stats): #expect(stats.rowsAffected == nil)
            }
        }
        #expect(metas.map(\.name) == ["i", "f", "t", "b", "n"])
        #expect(batches.map(\.count) == [500, 2])
        #expect(batches[0][0] == [.int(0), .double(1.5), .text("row-0"), .bytes(blobData), .null])

        let dmlEvents = try await collect(conn.execute("UPDATE items SET f = 2.0"))
        guard case .complete(let stats) = dmlEvents.last else {
            Issue.record("Expected .complete")
            return
        }
        #expect(stats.rowsAffected == 3)
    }

    // MARK: - Stateful Transactions via Baton & get_autocommit

    @Test("BEGIN and SAVEPOINT track baton via get_autocommit and COMMIT/ROLLBACK close it")
    func transactionBatonLifecycle() async throws {
        let host = "tx-\(UUID().uuidString).test"
        defer { LibSQLStubURLProtocol.unregister(host: host) }

        let recordedBatons = OSAllocatedUnfairLock<[String?]>(initialState: [])
        let recordedRequests = OSAllocatedUnfairLock<[[String]]>(initialState: [])

        LibSQLStubURLProtocol.register(host: host) { request, data in
            guard let url = request.url else { throw URLError(.badURL) }
            #expect(url.path.hasSuffix("/v3/pipeline"))
            let (baton, reqs) = try parsePipelineRequest(data)
            let types = reqs.compactMap { $0["type"] as? String }
            let sql = (reqs.first?["stmt"] as? [String: Any])?["sql"] as? String ?? ""

            if sql == "SELECT 1" {
                return (
                    makeHTTPResponse(url: url),
                    try jsonData(["results": [okExecuteResult(), okCloseResult()]])
                )
            }

            if types == ["close"] {
                recordedBatons.withLock { $0.append(baton) }
                recordedRequests.withLock { $0.append(types) }
                return (makeHTTPResponse(url: url), try jsonData(["results": [okCloseResult()]]))
            }

            recordedBatons.withLock { $0.append(baton) }
            recordedRequests.withLock { $0.append(types) }

            if sql == "BEGIN" {
                return (
                    makeHTTPResponse(url: url),
                    try jsonData([
                        "baton": "baton-123",
                        "base_url": "https://\(host)",
                        "results": [okExecuteResult(), okAutocommitResult(false)],
                    ])
                )
            }
            if sql == "INSERT INTO t VALUES (1)" {
                return (
                    makeHTTPResponse(url: url),
                    try jsonData([
                        "baton": "baton-123",
                        "results": [okExecuteResult(affectedRowCount: 1), okAutocommitResult(false)],
                    ])
                )
            }
            if sql == "ROLLBACK TRANSACTION TO SAVEPOINT sp1" {
                return (
                    makeHTTPResponse(url: url),
                    try jsonData([
                        "baton": "baton-123",
                        "results": [okExecuteResult(), okAutocommitResult(false)],
                    ])
                )
            }
            return (
                makeHTTPResponse(url: url),
                try jsonData([
                    "baton": NSNull(),
                    "results": [okExecuteResult(), okAutocommitResult(true)],
                ])
            )
        }

        let conn = try await LibSQLDriver.connect(
            .libsql(host: "https://\(host)"),
            sessionConfiguration: LibSQLStubURLProtocol.sessionConfiguration()
        )
        defer { Task { await conn.close() } }
        #expect(!((conn as Any) is any ReadOnlyExecuting))

        _ = try await collect(conn.execute("BEGIN"))
        _ = try await collect(conn.execute("INSERT INTO t VALUES (1)"))
        _ = try await collect(conn.execute("ROLLBACK TRANSACTION TO SAVEPOINT sp1"))
        _ = try await collect(conn.execute("COMMIT"))

        #expect(recordedBatons.withLock { $0 } == [nil, "baton-123", "baton-123", "baton-123"])
        #expect(recordedRequests.withLock { $0 } == [
            ["execute", "get_autocommit"],
            ["execute", "get_autocommit"],
            ["execute", "get_autocommit"],
            ["execute", "get_autocommit"],
        ])
    }

    @Test("multi-statement scripts use conditional batch steps and stop on first error")
    func conditionalBatchStopsOnFirstError() async throws {
        struct RecordedStep: Sendable {
            let condType: String?
            let condStep: Int?
        }
        let host = "batch-\(UUID().uuidString).test"
        defer { LibSQLStubURLProtocol.unregister(host: host) }

        let seenBatchSteps = OSAllocatedUnfairLock<[RecordedStep]>(initialState: [])

        LibSQLStubURLProtocol.register(host: host) { request, data in
            guard let url = request.url else { throw URLError(.badURL) }
            let (_, reqs) = try parsePipelineRequest(data)
            if let sql = (reqs.first?["stmt"] as? [String: Any])?["sql"] as? String, sql == "SELECT 1" {
                return (makeHTTPResponse(url: url), try jsonData(["results": [okExecuteResult(), okCloseResult()]]))
            }

            #expect(reqs.first?["type"] as? String == "batch")
            let batch = reqs.first?["batch"] as? [String: Any]
            let rawSteps = batch?["steps"] as? [[String: Any]] ?? []
            let recorded = rawSteps.map { step in
                let cond = step["condition"] as? [String: Any]
                return RecordedStep(condType: cond?["type"] as? String, condStep: cond?["step"] as? Int)
            }
            seenBatchSteps.withLock { $0 = recorded }

            return (
                makeHTTPResponse(url: url),
                try jsonData([
                    "results": [
                        [
                            "type": "ok",
                            "response": [
                                "type": "batch",
                                "result": [
                                    "step_results": [
                                        [
                                            "cols": [],
                                            "rows": [],
                                            "affected_row_count": 1,
                                            "last_insert_rowid": NSNull(),
                                        ],
                                        NSNull(),
                                        NSNull(),
                                    ],
                                    "step_errors": [
                                        NSNull(),
                                        ["message": "no such table: missing_tbl", "code": "SQLITE_ERROR"],
                                        NSNull(),
                                    ],
                                ],
                            ],
                        ],
                        okCloseResult(),
                    ],
                ])
            )
        }

        let conn = try await LibSQLDriver.connect(
            .libsql(host: "https://\(host)"),
            sessionConfiguration: LibSQLStubURLProtocol.sessionConfiguration()
        )
        defer { Task { await conn.close() } }

        do {
            _ = try await collect(conn.execute("INSERT INTO t VALUES (1); SELECT * FROM missing_tbl; SELECT 99"))
            Issue.record("Expected step 1 error to halt script")
        } catch let error as DriverError {
            guard case .queryFailed(let message, _) = error else {
                Issue.record("Expected queryFailed, got \(error)")
                return
            }
            #expect(message.contains("no such table: missing_tbl"))
        }

        let steps = seenBatchSteps.withLock { $0 }
        #expect(steps.count == 3)
        #expect(steps[0].condType == nil)
        #expect(steps[0].condStep == nil)
        #expect(steps[1].condType == "ok")
        #expect(steps[1].condStep == 0)
        #expect(steps[2].condType == "ok")
        #expect(steps[2].condStep == 1)
    }

    @Test("STREAM_EXPIRED clears dead baton and surfaces inactivity message")
    func streamExpiredRecovery() async throws {
        let host = "expired-\(UUID().uuidString).test"
        defer { LibSQLStubURLProtocol.unregister(host: host) }

        let seenBatons = OSAllocatedUnfairLock<[String?]>(initialState: [])

        LibSQLStubURLProtocol.register(host: host) { request, data in
            guard let url = request.url else { throw URLError(.badURL) }
            let (baton, reqs) = try parsePipelineRequest(data)
            let sql = (reqs.first?["stmt"] as? [String: Any])?["sql"] as? String ?? ""

            if sql == "BEGIN" {
                return (
                    makeHTTPResponse(url: url),
                    try jsonData([
                        "baton": "baton-stale",
                        "results": [okExecuteResult(), okAutocommitResult(false)],
                    ])
                )
            }
            if baton == "baton-stale" {
                return (
                    makeHTTPResponse(url: url, statusCode: 400),
                    try jsonData(["message": "The stream has expired due to inactivity", "code": "STREAM_EXPIRED"])
                )
            }
            seenBatons.withLock { $0.append(baton) }
            return (
                makeHTTPResponse(url: url),
                try jsonData(["results": [okExecuteResult(cols: [["name": "1"]], rows: [[["type": "integer", "value": "1"]]]), okCloseResult()]])
            )
        }

        let conn = try await LibSQLDriver.connect(
            .libsql(host: "https://\(host)"),
            sessionConfiguration: LibSQLStubURLProtocol.sessionConfiguration()
        )
        defer { Task { await conn.close() } }

        _ = try await collect(conn.execute("BEGIN"))

        do {
            _ = try await collect(conn.execute("SELECT 42"))
            Issue.record("Expected expired transaction error")
        } catch let error as DriverError {
            guard case .queryFailed(let message, _) = error else {
                Issue.record("Expected queryFailed, got \(error)")
                return
            }
            #expect(message.lowercased().contains("expired due to inactivity"))
        }

        // Subsequent query must start fresh without the dead baton.
        seenBatons.withLock { $0.removeAll() }
        let events = try await collect(conn.execute("SELECT 1"))
        #expect(!events.isEmpty)
        #expect(seenBatons.withLock { $0 } == [nil])
    }

    @Test("splitStatements preserves CASE ... END inside CREATE TRIGGER bodies")
    func triggerCaseEndSplitting() {
        let script = """
        CREATE TRIGGER tr_items AFTER INSERT ON items BEGIN
            UPDATE audit SET tag = CASE WHEN NEW.v > 0 THEN 'pos' ELSE 'neg' END;
            INSERT INTO log VALUES (NEW.v);
        END;
        SELECT COUNT(*) FROM log;
        """
        let statements = LibSQLSQLLexer.splitStatements(script)
        #expect(statements.count == 2)
        #expect(statements[0].hasPrefix("CREATE TRIGGER tr_items"))
        #expect(statements[0].hasSuffix("END"))
        #expect(statements[1] == "SELECT COUNT(*) FROM log")
    }

    // MARK: - Introspection

    @Test("introspector retrieves objects, summaries, foreign keys, table detail, stats, and DDL")
    func introspection() async throws {
        let host = "introspect-\(UUID().uuidString).test"
        defer { LibSQLStubURLProtocol.unregister(host: host) }

        LibSQLStubURLProtocol.register(host: host) { request, data in
            guard let url = request.url else { throw URLError(.badURL) }
            let (_, reqs) = try parsePipelineRequest(data)

            let results: [[String: Any]] = reqs.map { req in
                if req["type"] as? String == "close" {
                    return okCloseResult()
                }
                let sql = (req["stmt"] as? [String: Any])?["sql"] as? String ?? ""
                if sql == "SELECT 1" {
                    return okExecuteResult(cols: [["name": "1"]], rows: [[["type": "integer", "value": "1"]]])
                } else if sql == "PRAGMA schema_version" {
                    return okExecuteResult(cols: [["name": "schema_version"]], rows: [[["type": "integer", "value": "42"]]])
                } else if sql.contains("FROM sqlite_master") && sql.contains("tbl_name = ?") {
                    return okExecuteResult(
                        cols: [["name": "sql"]],
                        rows: [[["type": "text", "value": "CREATE TABLE \"orders\" (\"id\" INTEGER PRIMARY KEY)"]]]
                    )
                } else if sql.contains("FROM sqlite_master") && sql.contains("tbl_name") {
                    return okExecuteResult(
                        cols: [["name": "type"], ["name": "name"], ["name": "tbl_name"], ["name": "sql"]],
                        rows: [[
                            ["type": "text", "value": "table"],
                            ["type": "text", "value": "orders"],
                            ["type": "text", "value": "orders"],
                            ["type": "text", "value": "CREATE TABLE orders (id INTEGER PRIMARY KEY)"],
                        ]]
                    )
                } else if sql.contains("FROM sqlite_master") && sql.contains("type = 'table'") {
                    return okExecuteResult(cols: [["name": "name"]], rows: [[["type": "text", "value": "orders"]]])
                } else if sql.contains("FROM sqlite_master") {
                    return okExecuteResult(
                        cols: [["name": "type"], ["name": "name"]],
                        rows: [[["type": "text", "value": "table"], ["type": "text", "value": "orders"]]]
                    )
                } else if sql.hasPrefix("PRAGMA table_info") {
                    return okExecuteResult(
                        cols: [["name": "cid"], ["name": "name"], ["name": "type"], ["name": "notnull"], ["name": "dflt_value"], ["name": "pk"]],
                        rows: [
                            [
                                ["type": "integer", "value": "0"],
                                ["type": "text", "value": "id"],
                                ["type": "text", "value": "INTEGER"],
                                ["type": "integer", "value": "1"],
                                ["type": "null"],
                                ["type": "integer", "value": "1"],
                            ],
                            [
                                ["type": "integer", "value": "1"],
                                ["type": "text", "value": "user_id"],
                                ["type": "text", "value": "INTEGER"],
                                ["type": "integer", "value": "0"],
                                ["type": "null"],
                                ["type": "integer", "value": "0"],
                            ],
                        ]
                    )
                } else if sql.hasPrefix("PRAGMA index_list") {
                    return okExecuteResult(
                        cols: [["name": "seq"], ["name": "name"], ["name": "unique"], ["name": "origin"], ["name": "partial"]],
                        rows: [[
                            ["type": "integer", "value": "0"],
                            ["type": "text", "value": "idx_orders_user"],
                            ["type": "integer", "value": "0"],
                            ["type": "text", "value": "c"],
                            ["type": "integer", "value": "0"],
                        ]]
                    )
                } else if sql.hasPrefix("PRAGMA index_info") {
                    return okExecuteResult(
                        cols: [["name": "seqno"], ["name": "cid"], ["name": "name"]],
                        rows: [[
                            ["type": "integer", "value": "0"],
                            ["type": "integer", "value": "1"],
                            ["type": "text", "value": "user_id"],
                        ]]
                    )
                } else if sql.hasPrefix("PRAGMA foreign_key_list") {
                    return okExecuteResult(
                        cols: [["name": "id"], ["name": "seq"], ["name": "table"], ["name": "from"], ["name": "to"]],
                        rows: [[
                            ["type": "integer", "value": "0"],
                            ["type": "integer", "value": "0"],
                            ["type": "text", "value": "users"],
                            ["type": "text", "value": "user_id"],
                            ["type": "text", "value": "id"],
                        ]]
                    )
                } else if sql.hasPrefix("SELECT COUNT(*)") {
                    return okExecuteResult(cols: [["name": "COUNT(*)"]], rows: [[["type": "integer", "value": "17"]]])
                } else {
                    return okExecuteResult()
                }
            }
            return (makeHTTPResponse(url: url), try jsonData(["results": results]))
        }

        let conn = try await LibSQLDriver.connect(
            .libsql(host: "https://\(host)"),
            sessionConfiguration: LibSQLStubURLProtocol.sessionConfiguration()
        )
        defer { Task { await conn.close() } }

        let inspector = conn.introspector
        #expect(try await inspector.databases().isEmpty)
        #expect(try await inspector.schemaVersionToken(scope: .allUserSchemas) == "42")

        let objects = try await inspector.objects(in: nil)
        #expect(objects == [SchemaObject(kind: .table, name: "orders")])

        let summaries = try await inspector.objectSummaries(scope: .allUserSchemas)
        #expect(summaries.count == 1)
        #expect(summaries.first?.fingerprint != nil)

        let fks = try await inspector.foreignKeys(scope: .allUserSchemas)
        #expect(fks == [ForeignKeyRelation(
            source: TableRef(name: "orders"),
            column: "user_id",
            target: TableRef(name: "users"),
            referencedColumn: "id"
        )])

        let detail = try await inspector.tableDetail(TableRef(name: "orders"))
        #expect(detail.columns.count == 2)
        #expect(detail.columns[0].isPrimaryKey == true)
        #expect(detail.indexes == [IndexInfo(name: "idx_orders_user", isUnique: false, columns: ["user_id"])])
        #expect(detail.foreignKeys.count == 1)

        let stats = try await inspector.tableStats(TableRef(name: "orders"))
        #expect(stats.estimatedRowCount == 17)
        #expect(stats.engine == "libSQL")

        let ddl = try await inspector.ddl(of: SchemaObject(kind: .table, name: "orders"))
        #expect(ddl == "CREATE TABLE \"orders\" (\"id\" INTEGER PRIMARY KEY);")
    }

    @Test("introspector resolves implicit foreign keys (NULL to) in batched round trips")
    func implicitForeignKeysAndBatching() async throws {
        let host = "implicit-fk-\(UUID().uuidString).test"
        defer { LibSQLStubURLProtocol.unregister(host: host) }

        let roundTrips = OSAllocatedUnfairLock<Int>(initialState: 0)

        LibSQLStubURLProtocol.register(host: host) { request, data in
            guard let url = request.url else { throw URLError(.badURL) }
            let (_, reqs) = try parsePipelineRequest(data)
            let firstSQL = (reqs.first?["stmt"] as? [String: Any])?["sql"] as? String ?? ""
            if firstSQL != "SELECT 1" {
                roundTrips.withLock { $0 += 1 }
            }

            let results: [[String: Any]] = reqs.map { req in
                if req["type"] as? String == "close" { return okCloseResult() }
                let sql = (req["stmt"] as? [String: Any])?["sql"] as? String ?? ""
                if sql == "SELECT 1" {
                    return okExecuteResult(cols: [["name": "1"]], rows: [[["type": "integer", "value": "1"]]])
                } else if sql.contains("FROM sqlite_master") {
                    return okExecuteResult(
                        cols: [["name": "name"]],
                        rows: [[["type": "text", "value": "Orders"]], [["type": "text", "value": "Users"]]]
                    )
                } else if sql == "PRAGMA foreign_key_list(\"Orders\")" {
                    return okExecuteResult(
                        cols: [["name": "id"], ["name": "seq"], ["name": "table"], ["name": "from"], ["name": "to"]],
                        rows: [[
                            ["type": "integer", "value": "0"],
                            ["type": "integer", "value": "0"],
                            ["type": "text", "value": "users"],
                            ["type": "text", "value": "user_id"],
                            ["type": "null"],
                        ]]
                    )
                } else if sql == "PRAGMA foreign_key_list(\"Users\")" {
                    return okExecuteResult()
                } else if sql == "PRAGMA table_info(\"Users\")" || sql == "PRAGMA table_info(\"users\")" {
                    return okExecuteResult(
                        cols: [["name": "cid"], ["name": "name"], ["name": "type"], ["name": "notnull"], ["name": "dflt_value"], ["name": "pk"]],
                        rows: [[
                            ["type": "integer", "value": "0"],
                            ["type": "text", "value": "user_pk"],
                            ["type": "text", "value": "INTEGER"],
                            ["type": "integer", "value": "1"],
                            ["type": "null"],
                            ["type": "integer", "value": "1"],
                        ]]
                    )
                } else if sql == "PRAGMA table_info(\"Orders\")" {
                    return okExecuteResult(
                        cols: [["name": "cid"], ["name": "name"], ["name": "type"], ["name": "notnull"], ["name": "dflt_value"], ["name": "pk"]],
                        rows: [
                            [
                                ["type": "integer", "value": "0"],
                                ["type": "text", "value": "id"],
                                ["type": "text", "value": "INTEGER"],
                                ["type": "integer", "value": "1"],
                                ["type": "null"],
                                ["type": "integer", "value": "1"],
                            ],
                            [
                                ["type": "integer", "value": "1"],
                                ["type": "text", "value": "user_id"],
                                ["type": "text", "value": "INTEGER"],
                                ["type": "integer", "value": "0"],
                                ["type": "null"],
                                ["type": "integer", "value": "0"],
                            ],
                        ]
                    )
                } else {
                    return okExecuteResult()
                }
            }
            return (makeHTTPResponse(url: url), try jsonData(["results": results]))
        }

        let conn = try await LibSQLDriver.connect(
            .libsql(host: "https://\(host)"),
            sessionConfiguration: LibSQLStubURLProtocol.sessionConfiguration()
        )
        defer { Task { await conn.close() } }

        let inspector = conn.introspector
        let fks = try await inspector.foreignKeys(scope: .allUserSchemas)
        #expect(fks == [ForeignKeyRelation(
            source: TableRef(name: "Orders"),
            column: "user_id",
            target: TableRef(name: "Users"),
            referencedColumn: "user_pk"
        )])
        // 1: table list, 2: batched PRAGMA foreign_key_list for all tables, 3: batched PRAGMA table_info for implicit FK parents.
        #expect(roundTrips.withLock { $0 } == 3)

        roundTrips.withLock { $0 = 0 }
        let detail = try await inspector.tableDetail(TableRef(name: "Orders"))
        #expect(detail.foreignKeys == [ForeignKeyInfo(
            column: "user_id",
            referencedSchema: nil,
            referencedTable: "Users",
            referencedColumn: "user_pk"
        )])
        #expect(roundTrips.withLock { $0 } == 2)
    }

    // MARK: - Cancellation

    @Test("cancelCurrentQuery cancels active HTTP task cleanly")
    func queryCancellation() async throws {
        let host = "cancel-\(UUID().uuidString).test"
        defer { LibSQLStubURLProtocol.unregister(host: host) }

        LibSQLStubURLProtocol.register(host: host) { request, data in
            guard let url = request.url else { throw URLError(.badURL) }
            let (_, reqs) = try parsePipelineRequest(data)
            let sql = (reqs.first?["stmt"] as? [String: Any])?["sql"] as? String ?? ""
            if sql == "SELECT 1" {
                return (
                    makeHTTPResponse(url: url),
                    try jsonData(["results": [okExecuteResult(cols: [["name": "1"]], rows: [[["type": "integer", "value": "1"]]]), okCloseResult()]])
                )
            }
            Thread.sleep(forTimeInterval: 0.25)
            return (makeHTTPResponse(url: url), try jsonData(["results": [okExecuteResult(), okCloseResult()]]))
        }

        let conn = try await LibSQLDriver.connect(
            .libsql(host: "https://\(host)"),
            sessionConfiguration: LibSQLStubURLProtocol.sessionConfiguration()
        )
        defer { Task { await conn.close() } }

        let cancelTrigger = Task {
            try? await Task.sleep(for: .milliseconds(30))
            conn.cancelCurrentQuery()
        }
        defer { cancelTrigger.cancel() }

        do {
            _ = try await collect(conn.execute("SELECT slow_query()"))
            Issue.record("Expected cancellation")
        } catch let error as DriverError {
            guard case .cancelled = error else {
                Issue.record("Expected DriverError.cancelled, got \(error)")
                return
            }
        }
    }

    // MARK: - Transport & Token Target Security

    @Test("ignores base_url when baton is not kept, follows sticky HTTPS hosts, and refuses HTTPS downgrade and redirects")
    func stickyBaseURLAndRedirectSecurity() async throws {
        let host = "primary-\(UUID().uuidString).test"
        let stickyHost = "sticky-node-1-\(UUID().uuidString).test"
        let attackerHost = "attacker-\(UUID().uuidString).test"
        defer {
            LibSQLStubURLProtocol.unregister(host: host)
            LibSQLStubURLProtocol.unregister(host: stickyHost)
            LibSQLStubURLProtocol.unregister(host: attackerHost)
        }

        let attackerRequests = OSAllocatedUnfairLock<Int>(initialState: 0)
        LibSQLStubURLProtocol.register(host: attackerHost) { request, _ in
            attackerRequests.withLock { $0 += 1 }
            guard let url = request.url else { throw URLError(.badURL) }
            return (makeHTTPResponse(url: url), try jsonData(["results": [okExecuteResult(), okCloseResult()]]))
        }

        let stickyRequests = OSAllocatedUnfairLock<[String]>(initialState: [])
        LibSQLStubURLProtocol.register(host: stickyHost) { request, data in
            guard let url = request.url else { throw URLError(.badURL) }
            let (_, reqs) = try parsePipelineRequest(data)
            let sql = (reqs.first?["stmt"] as? [String: Any])?["sql"] as? String ?? ""
            stickyRequests.withLock { $0.append(sql) }
            return (
                makeHTTPResponse(url: url),
                try jsonData([
                    "baton": NSNull(),
                    "base_url": "https://\(stickyHost):8443",
                    "results": [okExecuteResult(), okAutocommitResult(true)],
                ])
            )
        }

        let mode = OSAllocatedUnfairLock<String>(initialState: "autocommit-self-url")
        LibSQLStubURLProtocol.register(host: host) { request, data in
            guard let url = request.url else { throw URLError(.badURL) }
            let (_, reqs) = try parsePipelineRequest(data)
            let sql = (reqs.first?["stmt"] as? [String: Any])?["sql"] as? String ?? ""
            if sql == "SELECT 1" {
                return (
                    makeHTTPResponse(url: url),
                    try jsonData([
                        "baton": NSNull(),
                        "base_url": "http://sqld-node-1.internal:8080",
                        "results": [okExecuteResult(cols: [["name": "1"]], rows: [[["type": "integer", "value": "1"]]]), okCloseResult()],
                    ])
                )
            }
            let currentMode = mode.withLock { $0 }
            if currentMode == "autocommit-self-url" {
                return (
                    makeHTTPResponse(url: url),
                    try jsonData([
                        "baton": NSNull(),
                        "base_url": "http://sqld-node-1.internal:8080",
                        "results": [okExecuteResult(affectedRowCount: 1), okCloseResult()],
                    ])
                )
            }
            if currentMode == "sticky-cross-host" {
                return (
                    makeHTTPResponse(url: url),
                    try jsonData([
                        "baton": "baton-sticky-1",
                        "base_url": "https://\(stickyHost):8443",
                        "results": [okExecuteResult(), okAutocommitResult(false)],
                    ])
                )
            }
            if currentMode == "redirect" {
                return (
                    makeHTTPResponse(
                        url: url,
                        statusCode: 302,
                        headers: ["Location": "https://\(attackerHost)/v2/pipeline"]
                    ),
                    Data()
                )
            }
            let injectedBaseURL: String
            switch currentMode {
            case "downgrade":
                injectedBaseURL = "http://\(host)"
            case "credentials":
                injectedBaseURL = "https://user:pass@\(host)"
            default:
                injectedBaseURL = "https://\(host)"
            }
            return (
                makeHTTPResponse(url: url),
                try jsonData([
                    "baton": "baton-hijack",
                    "base_url": injectedBaseURL,
                    "results": [okExecuteResult(), okAutocommitResult(false)],
                ])
            )
        }

        let conn = try await LibSQLDriver.connect(
            .libsql(host: "https://\(host)", authToken: "super-secret-bearer"),
            sessionConfiguration: LibSQLStubURLProtocol.sessionConfiguration()
        )
        defer { Task { await conn.close() } }

        // 1. Autocommit responses with SQLD_HTTP_SELF_URL (including different host/http) succeed and deliver results.
        mode.withLock { $0 = "autocommit-self-url" }
        let insertEvents = try await collect(conn.execute("INSERT INTO t VALUES (1)"))
        guard case .complete(let stats) = insertEvents.last else {
            Issue.record("Expected .complete for autocommit INSERT with self base_url")
            return
        }
        #expect(stats.rowsAffected == 1)

        // 2. Sticky HTTPS host/port on a kept baton routes the next in-transaction statement to stickyHost.
        mode.withLock { $0 = "sticky-cross-host" }
        _ = try await collect(conn.execute("BEGIN"))
        _ = try await collect(conn.execute("COMMIT"))
        #expect(stickyRequests.withLock { $0 } == ["COMMIT"])

        // 3. Downgrade (https -> http), credentialed base_url, and HTTP redirects are rejected.
        for testMode in ["downgrade", "credentials", "redirect"] {
            mode.withLock { $0 = testMode }
            do {
                _ = try await collect(conn.execute("BEGIN"))
                Issue.record("Expected \(testMode) base_url/redirect to be rejected")
            } catch let error as DriverError {
                guard case .connectionFailed = error else {
                    Issue.record("Expected connectionFailed for \(testMode), got \(error)")
                    return
                }
            }
            let probe = try await collect(conn.execute("SELECT 1"))
            #expect(!probe.isEmpty)
        }

        #expect(attackerRequests.withLock { $0 } == 0)
    }

    @Test("serializes concurrent execute calls, keeps baton on SQL error, and closes dropped baton on transport failure")
    func serializesExecutionAndClosesDroppedBaton() async throws {
        let host = "serialize-\(UUID().uuidString).test"
        defer { LibSQLStubURLProtocol.unregister(host: host) }

        let inFlight = OSAllocatedUnfairLock<Int>(initialState: 0)
        let maxInFlight = OSAllocatedUnfairLock<Int>(initialState: 0)
        let recorded = OSAllocatedUnfairLock<[(baton: String?, types: [String], sql: String)]>(initialState: [])
        let failNextWrite = OSAllocatedUnfairLock<Bool>(initialState: false)

        LibSQLStubURLProtocol.register(host: host) { request, data in
            guard let url = request.url else { throw URLError(.badURL) }
            let (baton, reqs) = try parsePipelineRequest(data)
            let types = reqs.compactMap { $0["type"] as? String }
            let sql = (reqs.first?["stmt"] as? [String: Any])?["sql"] as? String ?? ""

            if sql == "SELECT 1" {
                return (
                    makeHTTPResponse(url: url),
                    try jsonData(["results": [okExecuteResult(cols: [["name": "1"]], rows: [[["type": "integer", "value": "1"]]]), okCloseResult()]])
                )
            }

            if types == ["close"] {
                recorded.withLock { $0.append((baton, types, "")) }
                return (makeHTTPResponse(url: url), try jsonData(["results": [okCloseResult()]]))
            }

            let concurrentNow = inFlight.withLock { count -> Int in
                count += 1
                return count
            }
            maxInFlight.withLock { $0 = max($0, concurrentNow) }
            defer { inFlight.withLock { $0 -= 1 } }

            recorded.withLock { $0.append((baton, types, sql)) }

            if sql.contains("SLOW") {
                Thread.sleep(forTimeInterval: 0.08)
            }
            if failNextWrite.withLock({ $0 }) && sql.contains("DROP_FAIL") {
                failNextWrite.withLock { $0 = false }
                throw URLError(.networkConnectionLost)
            }
            if sql.contains("BAD_SQL") {
                return (
                    makeHTTPResponse(url: url),
                    try jsonData([
                        "baton": "baton-after-sql-error",
                        "results": [
                            ["type": "error", "error": ["message": "no such table: missing", "code": "SQLITE_ERROR"]],
                            okAutocommitResult(false),
                        ],
                    ])
                )
            }
            if sql == "COMMIT" {
                return (
                    makeHTTPResponse(url: url),
                    try jsonData([
                        "baton": NSNull(),
                        "results": [okExecuteResult(), okAutocommitResult(true)],
                    ])
                )
            }
            let nextBaton = sql == "BEGIN" ? "baton-1" : "baton-2"
            return (
                makeHTTPResponse(url: url),
                try jsonData([
                    "baton": nextBaton,
                    "results": [okExecuteResult(), okAutocommitResult(false)],
                ])
            )
        }

        let conn = try await LibSQLDriver.connect(
            .libsql(host: "https://\(host)"),
            sessionConfiguration: LibSQLStubURLProtocol.sessionConfiguration()
        )
        defer { Task { await conn.close() } }

        _ = try await collect(conn.execute("BEGIN"))

        // Fire two overlapping statements simultaneously inside the transaction.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { _ = try await collect(conn.execute("INSERT INTO t VALUES (1) /* SLOW */")) }
            group.addTask { _ = try await collect(conn.execute("INSERT INTO t VALUES (2) /* SECOND */")) }
            try await group.waitForAll()
        }
        #expect(maxInFlight.withLock { $0 } == 1)

        // SQL error inside transaction keeps the baton.
        do {
            _ = try await collect(conn.execute("SELECT * FROM BAD_SQL"))
            Issue.record("Expected SQL error")
        } catch let error as DriverError {
            guard case .queryFailed = error else {
                Issue.record("Expected queryFailed, got \(error)")
                return
            }
        }

        // Transport error clears baton and sends best-effort close.
        failNextWrite.withLock { $0 = true }
        do {
            _ = try await collect(conn.execute("INSERT INTO t VALUES (3) /* DROP_FAIL */"))
            Issue.record("Expected transport error")
        } catch let error as DriverError {
            guard case .connectionFailed = error else {
                Issue.record("Expected connectionFailed, got \(error)")
                return
            }
        }

        let trace = recorded.withLock { $0 }
        let sqlTrace = trace.filter { $0.types != ["close"] }
        #expect(sqlTrace.map(\.baton) == [nil, "baton-1", "baton-2", "baton-2", "baton-after-sql-error"])
        #expect(trace.last?.types == ["close"])
        #expect(trace.last?.baton == "baton-after-sql-error")
    }

    @Test("isLoopbackHost requires strict loopback names or 127.0.0.0/8 IPv4 literals")
    func strictLoopbackValidation() {
        #expect(LibSQLHTTPClient.isLoopbackHost("localhost") == true)
        #expect(LibSQLHTTPClient.isLoopbackHost("127.0.0.1") == true)
        #expect(LibSQLHTTPClient.isLoopbackHost("127.255.0.1") == true)
        #expect(LibSQLHTTPClient.isLoopbackHost("::1") == true)
        #expect(LibSQLHTTPClient.isLoopbackHost("[::1]") == true)

        #expect(LibSQLHTTPClient.isLoopbackHost("127.attacker.example") == false)
        #expect(LibSQLHTTPClient.isLoopbackHost("127.0.0.256") == false)
        #expect(LibSQLHTTPClient.isLoopbackHost("127.1") == false)
        #expect(LibSQLHTTPClient.isLoopbackHost("example.com") == false)
    }

    @Test("introspector hashes resolved view columns in objectSummaries and batches tableDetails")
    func viewFingerprintsAndBulkTableDetails() async throws {
        let host = "bulk-intro-\(UUID().uuidString).test"
        defer { LibSQLStubURLProtocol.unregister(host: host) }

        let viewHasExtraColumn = OSAllocatedUnfairLock<Bool>(initialState: false)
        let roundTrips = OSAllocatedUnfairLock<Int>(initialState: 0)

        LibSQLStubURLProtocol.register(host: host) { request, data in
            guard let url = request.url else { throw URLError(.badURL) }
            let (_, reqs) = try parsePipelineRequest(data)
            let firstSQL = (reqs.first?["stmt"] as? [String: Any])?["sql"] as? String ?? ""
            if firstSQL != "SELECT 1" {
                roundTrips.withLock { $0 += 1 }
            }

            let results: [[String: Any]] = reqs.map { req in
                if req["type"] as? String == "close" { return okCloseResult() }
                let sql = (req["stmt"] as? [String: Any])?["sql"] as? String ?? ""
                if sql == "SELECT 1" {
                    return okExecuteResult(cols: [["name": "1"]], rows: [[["type": "integer", "value": "1"]]])
                } else if sql.contains("SELECT type, name, tbl_name, sql FROM sqlite_master") {
                    return okExecuteResult(
                        cols: [["name": "type"], ["name": "name"], ["name": "tbl_name"], ["name": "sql"]],
                        rows: [
                            [
                                ["type": "text", "value": "table"],
                                ["type": "text", "value": "t1"],
                                ["type": "text", "value": "t1"],
                                ["type": "text", "value": "CREATE TABLE t1 (a INTEGER)"],
                            ],
                            [
                                ["type": "text", "value": "view"],
                                ["type": "text", "value": "v1"],
                                ["type": "text", "value": "v1"],
                                ["type": "text", "value": "CREATE VIEW v1 AS SELECT * FROM t1"],
                            ],
                        ]
                    )
                } else if sql == "PRAGMA table_info(\"v1\")" {
                    var rows: [[[String: Any]]] = [[
                        ["type": "integer", "value": "0"],
                        ["type": "text", "value": "a"],
                        ["type": "text", "value": "INTEGER"],
                        ["type": "integer", "value": "0"],
                        ["type": "null"],
                        ["type": "integer", "value": "0"],
                    ]]
                    if viewHasExtraColumn.withLock({ $0 }) {
                        rows.append([
                            ["type": "integer", "value": "1"],
                            ["type": "text", "value": "b"],
                            ["type": "text", "value": "TEXT"],
                            ["type": "integer", "value": "0"],
                            ["type": "null"],
                            ["type": "integer", "value": "0"],
                        ])
                    }
                    return okExecuteResult(
                        cols: [["name": "cid"], ["name": "name"], ["name": "type"], ["name": "notnull"], ["name": "dflt_value"], ["name": "pk"]],
                        rows: rows
                    )
                } else if sql == "PRAGMA table_info(\"t1\")" || sql == "PRAGMA table_info(\"t2\")" {
                    return okExecuteResult(
                        cols: [["name": "cid"], ["name": "name"], ["name": "type"], ["name": "notnull"], ["name": "dflt_value"], ["name": "pk"]],
                        rows: [[
                            ["type": "integer", "value": "0"],
                            ["type": "text", "value": "id"],
                            ["type": "text", "value": "INTEGER"],
                            ["type": "integer", "value": "1"],
                            ["type": "null"],
                            ["type": "integer", "value": "1"],
                        ]]
                    )
                } else if sql == "PRAGMA table_info(\"broken_view\")" {
                    return ["type": "error", "error": ["message": "no such table: missing_base", "code": "SQLITE_ERROR"]]
                } else if sql.hasPrefix("PRAGMA index_list") {
                    return okExecuteResult(
                        cols: [["name": "seq"], ["name": "name"], ["name": "unique"], ["name": "origin"], ["name": "partial"]],
                        rows: []
                    )
                } else if sql.hasPrefix("PRAGMA foreign_key_list") {
                    return okExecuteResult(
                        cols: [["name": "id"], ["name": "seq"], ["name": "table"], ["name": "from"], ["name": "to"]],
                        rows: []
                    )
                } else {
                    return okExecuteResult()
                }
            }
            return (makeHTTPResponse(url: url), try jsonData(["results": results]))
        }

        let conn = try await LibSQLDriver.connect(
            .libsql(host: "https://\(host)"),
            sessionConfiguration: LibSQLStubURLProtocol.sessionConfiguration()
        )
        defer { Task { await conn.close() } }

        let before = try await conn.introspector.objectSummaries(scope: .allUserSchemas)
        viewHasExtraColumn.withLock { $0 = true }
        let after = try await conn.introspector.objectSummaries(scope: .allUserSchemas)

        let beforeView = before.first { $0.ref.name == "v1" }
        let afterView = after.first { $0.ref.name == "v1" }
        #expect(beforeView?.fingerprint != nil)
        #expect(beforeView?.fingerprint != afterView?.fingerprint)

        roundTrips.withLock { $0 = 0 }
        let details = try await conn.introspector.tableDetails([
            TableRef(name: "t1"),
            TableRef(name: "t2"),
            TableRef(name: "broken_view"),
        ])
        #expect(details.map(\.ref.name) == ["t1", "t2"])
        // One batched round trip when no follow-up index_info or implicit FK lookups are needed.
        #expect(roundTrips.withLock { $0 } == 1)
    }

    @Test("enforces maxResponseBytes safety limit during download streaming and via Content-Length")
    func responseSizeLimit() async throws {
        let host = "limit-\(UUID().uuidString).test"
        defer { LibSQLStubURLProtocol.unregister(host: host) }

        let sendContentLength = OSAllocatedUnfairLock<Bool>(initialState: false)
        let totalPayloadBytes = OSAllocatedUnfairLock<Int>(initialState: 0)

        LibSQLStubURLProtocol.register(host: host) { request, data in
            guard let url = request.url else { throw URLError(.badURL) }
            let (_, reqs) = try parsePipelineRequest(data)
            let sql = (reqs.first?["stmt"] as? [String: Any])?["sql"] as? String ?? ""
            if sql == "SELECT 1" {
                return (
                    makeHTTPResponse(url: url),
                    try jsonData(["results": [okExecuteResult(cols: [["name": "1"]], rows: [[["type": "integer", "value": "1"]]]), okCloseResult()]])
                )
            }
            let bigText = String(repeating: "x", count: 4096)
            let payload = try jsonData([
                "results": [
                    okExecuteResult(
                        cols: [["name": "payload", "decltype": "TEXT"]],
                        rows: [[["type": "text", "value": bigText]]]
                    ),
                    okCloseResult(),
                ],
            ])
            totalPayloadBytes.withLock { $0 = payload.count }
            let headers = sendContentLength.withLock { $0 }
                ? ["Content-Length": "\(payload.count)"]
                : nil
            return (makeHTTPResponse(url: url, headers: headers), payload)
        }

        let conn = try await LibSQLDriver.connect(
            .libsql(host: "https://\(host)"),
            sessionConfiguration: LibSQLStubURLProtocol.sessionConfiguration(),
            maxResponseBytes: 512
        )
        defer { Task { await conn.close() } }

        // 1. Streaming body without Content-Length cancels mid-download before loading the full body.
        LibSQLStubURLProtocol.resetLoadedBytes(host: host)
        sendContentLength.withLock { $0 = false }
        do {
            _ = try await collect(conn.execute("SELECT payload FROM huge_table"))
            Issue.record("Expected maxResponseBytes error on chunked download")
        } catch let error as DriverError {
            guard case .queryFailed(let message, nil) = error else {
                Issue.record("Expected queryFailed, got \(error)")
                return
            }
            #expect(message.contains("512-byte safety limit"))
            #expect(message.contains("LIMIT"))
        }
        let streamedBytes = LibSQLStubURLProtocol.loadedBytes(host: host)
        let fullPayloadCount = totalPayloadBytes.withLock { $0 }
        #expect(streamedBytes > 0)
        #expect(streamedBytes < fullPayloadCount)

        // 2. An oversized Content-Length is rejected without downloading the complete body.
        LibSQLStubURLProtocol.resetLoadedBytes(host: host)
        sendContentLength.withLock { $0 = true }
        do {
            _ = try await collect(conn.execute("SELECT payload FROM huge_table"))
            Issue.record("Expected maxResponseBytes error on Content-Length")
        } catch let error as DriverError {
            guard case .queryFailed(let message, nil) = error else {
                Issue.record("Expected queryFailed, got \(error)")
                return
            }
            #expect(message.contains("512-byte safety limit"))
        }
        #expect(LibSQLStubURLProtocol.loadedBytes(host: host) < fullPayloadCount)
    }

    @Test("refuses sending auth token over plain HTTP to non-loopback host while allowing loopback")
    func plainHTTPAuthTokenRefusal() async throws {
        let remoteHost = "remote-\(UUID().uuidString).example.com"
        let requestCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        LibSQLStubURLProtocol.register(host: remoteHost) { request, _ in
            requestCount.withLock { $0 += 1 }
            guard let url = request.url else { throw URLError(.badURL) }
            return (makeHTTPResponse(url: url), try jsonData(["results": [okExecuteResult(), okCloseResult()]]))
        }
        defer { LibSQLStubURLProtocol.unregister(host: remoteHost) }

        do {
            _ = try await LibSQLDriver.connect(
                .libsql(host: "http://\(remoteHost):8080", authToken: "secret-token", tlsMode: .disable),
                sessionConfiguration: LibSQLStubURLProtocol.sessionConfiguration()
            )
            Issue.record("Expected connectionFailed when sending auth token over plain HTTP to non-loopback host")
        } catch let error as DriverError {
            guard case .connectionFailed(let msg) = error else {
                Issue.record("Expected connectionFailed, got \(error)")
                return
            }
            #expect(msg.contains("non-loopback"))
        }
        #expect(requestCount.withLock { $0 } == 0)

        let loopbackHost = "localhost"
        LibSQLStubURLProtocol.register(host: loopbackHost) { request, _ in
            guard let url = request.url else { throw URLError(.badURL) }
            return (makeHTTPResponse(url: url), try jsonData(["results": [okExecuteResult(), okCloseResult()]]))
        }
        defer { LibSQLStubURLProtocol.unregister(host: loopbackHost) }

        let localConn = try await LibSQLDriver.connect(
            .libsql(host: "http://localhost:8080", authToken: "local-dev-token", tlsMode: .disable),
            sessionConfiguration: LibSQLStubURLProtocol.sessionConfiguration()
        )
        await localConn.close()
    }
}
