import BerryDriverKit
@testable import BerryDriverLibSQL
import Foundation
import os
import Testing

@Suite("LibSQL Driver")
struct LibSQLDriverTests {
    // MARK: - Helpers

    private func makeHTTPResponse(url: URL, statusCode: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil)!
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

    @Test("parseLibSQLEndpoint normalizes libsql, https, http, and bare hosts")
    func endpointParsing() {
        let turso = ConnectionConfig.parseLibSQLEndpoint(host: "libsql://my-db-org.turso.io")
        #expect(turso?.baseURL.absoluteString == "https://my-db-org.turso.io")
        #expect(turso?.useTLS == true)
        #expect(turso?.port == 443)

        let localDisable = ConnectionConfig.parseLibSQLEndpoint(
            host: "libsql://127.0.0.1:8080",
            tlsMode: .disable
        )
        #expect(localDisable?.baseURL.absoluteString == "http://127.0.0.1:8080")
        #expect(localDisable?.useTLS == false)
        #expect(localDisable?.port == 8080)

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

    // MARK: - Stateful Transactions via Baton

    @Test("BEGIN keeps baton across execute calls and COMMIT closes the stream")
    func transactionBatonLifecycle() async throws {
        let host = "tx-\(UUID().uuidString).test"
        defer { LibSQLStubURLProtocol.unregister(host: host) }

        let recordedBatons = OSAllocatedUnfairLock<[String?]>(initialState: [])
        let recordedCloses = OSAllocatedUnfairLock<[Bool]>(initialState: [])

        LibSQLStubURLProtocol.register(host: host) { request, data in
            guard let url = request.url else { throw URLError(.badURL) }
            let (baton, reqs) = try parsePipelineRequest(data)
            let sql = (reqs.first?["stmt"] as? [String: Any])?["sql"] as? String ?? ""
            let hasClose = reqs.contains { ($0["type"] as? String) == "close" }

            if sql != "SELECT 1" {
                recordedBatons.withLock { $0.append(baton) }
                recordedCloses.withLock { $0.append(hasClose) }
            }

            if sql == "BEGIN" {
                return (
                    makeHTTPResponse(url: url),
                    try jsonData([
                        "baton": "baton-123",
                        "base_url": "https://\(host)",
                        "results": [okExecuteResult()],
                    ])
                )
            }
            if sql == "INSERT INTO t VALUES (1)" {
                return (
                    makeHTTPResponse(url: url),
                    try jsonData([
                        "baton": "baton-123",
                        "results": [okExecuteResult(affectedRowCount: 1)],
                    ])
                )
            }
            return (
                makeHTTPResponse(url: url),
                try jsonData([
                    "baton": NSNull(),
                    "results": [okExecuteResult(), okCloseResult()],
                ])
            )
        }

        let conn = try await LibSQLDriver.connect(
            .libsql(host: "https://\(host)"),
            sessionConfiguration: LibSQLStubURLProtocol.sessionConfiguration()
        )
        defer { Task { await conn.close() } }

        _ = try await collect(conn.execute("BEGIN"))
        _ = try await collect(conn.execute("INSERT INTO t VALUES (1)"))
        _ = try await collect(conn.execute("COMMIT"))

        #expect(recordedBatons.withLock { $0 } == [nil, "baton-123", "baton-123"])
        #expect(recordedCloses.withLock { $0 } == [false, false, true])
    }

    // MARK: - ReadOnlyExecuting Contract

    @Test("read-only execution enforces allowlist, ?/?NNN placeholders, PRAGMA query_only, and SQLITE_READONLY")
    func readOnlyContract() async throws {
        let host = "ro-\(UUID().uuidString).test"
        defer { LibSQLStubURLProtocol.unregister(host: host) }

        LibSQLStubURLProtocol.register(host: host) { request, data in
            guard let url = request.url else { throw URLError(.badURL) }
            let (_, reqs) = try parsePipelineRequest(data)
            let sqls = reqs.compactMap { ($0["stmt"] as? [String: Any])?["sql"] as? String }

            if sqls == ["SELECT 1"] {
                return (
                    makeHTTPResponse(url: url),
                    try jsonData(["results": [okExecuteResult(cols: [["name": "1"]], rows: [[["type": "integer", "value": "1"]]]), okCloseResult()]])
                )
            }
            if sqls == ["PRAGMA query_only = ON", "PRAGMA query_only"] {
                return (
                    makeHTTPResponse(url: url),
                    try jsonData([
                        "results": [
                            okExecuteResult(),
                            okExecuteResult(cols: [["name": "query_only"]], rows: [[["type": "integer", "value": "1"]]]),
                            okCloseResult(),
                        ],
                    ])
                )
            }
            if sqls.count == 2, sqls[0] == "PRAGMA query_only = ON" {
                let args = (reqs[1]["stmt"] as? [String: Any])?["args"] as? [[String: Any]] ?? []
                if sqls[1].contains("readonly_trigger") {
                    return (
                        makeHTTPResponse(url: url),
                        try jsonData([
                            "results": [
                                okExecuteResult(),
                                ["type": "error", "error": ["message": "attempt to write a readonly database", "code": "SQLITE_READONLY"]],
                                okCloseResult(),
                            ],
                        ])
                    )
                }
                let firstArg = (args.first?["value"] as? String) ?? ""
                return (
                    makeHTTPResponse(url: url),
                    try jsonData([
                        "results": [
                            okExecuteResult(),
                            okExecuteResult(
                                cols: [["name": "v", "decltype": "TEXT"]],
                                rows: [[["type": "text", "value": firstArg]]]
                            ),
                            okCloseResult(),
                        ],
                    ])
                )
            }
            return (makeHTTPResponse(url: url), try jsonData(["results": [okExecuteResult(), okCloseResult()]]))
        }

        let conn = try await LibSQLDriver.connect(
            .libsql(host: "https://\(host)"),
            sessionConfiguration: LibSQLStubURLProtocol.sessionConfiguration()
        )
        defer { Task { await conn.close() } }

        try await conn.prepareReadOnly()

        let timeoutEvents = try await collect(conn.executeReadOnly("SELECT 1 AS v", timeout: .seconds(5)))
        _ = timeoutEvents

        let validEvents = try await collect(conn.executeReadOnly("SELECT ? AS v", parameters: [.text("ok")]))
        #expect(validEvents.contains { if case .rows(let r) = $0 { return r == [[.text("ok")]] }; return false })

        // Multiple statements rejected locally
        do {
            _ = try await collect(conn.executeReadOnly("SELECT 1; SELECT 2", parameters: []))
            Issue.record("Expected multi-statement rejection")
        } catch let err as DriverError {
            guard case .queryFailed(let msg, nil) = err else {
                Issue.record("Unexpected error: \(err)")
                return
            }
            #expect(msg.contains("one statement"))
        }

        // Write statement rejected locally by allowlist
        do {
            _ = try await collect(conn.executeReadOnly("DELETE FROM users", parameters: []))
            Issue.record("Expected write refusal")
        } catch let err as DriverError {
            guard case .queryFailed = err else {
                Issue.record("Unexpected error: \(err)")
                return
            }
        }

        // Named placeholder rejected
        do {
            _ = try await collect(conn.executeReadOnly("SELECT :id", parameters: [.int(1)]))
            Issue.record("Expected named placeholder refusal")
        } catch let err as DriverError {
            guard case .queryFailed = err else {
                Issue.record("Unexpected error: \(err)")
                return
            }
        }

        // Mixed ? and ?1 rejected
        do {
            _ = try await collect(conn.executeReadOnly("SELECT ?, ?1", parameters: [.int(1)]))
            Issue.record("Expected mixed placeholder refusal")
        } catch let err as DriverError {
            guard case .queryFailed = err else {
                Issue.record("Unexpected error: \(err)")
                return
            }
        }

        // Parameter count mismatch rejected
        do {
            _ = try await collect(conn.executeReadOnly("SELECT ?1, ?2", parameters: [.int(1)]))
            Issue.record("Expected placeholderCountMismatch")
        } catch let err as DriverError {
            let expected = DriverError.placeholderCountMismatch(placeholders: 2, parameters: 1)
            #expect(err.detail == expected.detail)
        }

        // Server SQLITE_READONLY mapped to code 8
        do {
            _ = try await collect(conn.executeReadOnly("SELECT readonly_trigger FROM dual", parameters: []))
            Issue.record("Expected SQLITE_READONLY error")
        } catch let err as DriverError {
            guard case .queryFailed(_, let code) = err else {
                Issue.record("Unexpected error: \(err)")
                return
            }
            #expect(code == 8)
        }
    }

    // MARK: - Introspection

    @Test("introspector retrieves objects, summaries, foreign keys, table detail, stats, and DDL")
    func introspection() async throws {
        let host = "introspect-\(UUID().uuidString).test"
        defer { LibSQLStubURLProtocol.unregister(host: host) }

        LibSQLStubURLProtocol.register(host: host) { request, data in
            guard let url = request.url else { throw URLError(.badURL) }
            let (_, reqs) = try parsePipelineRequest(data)
            let sql = (reqs.first?["stmt"] as? [String: Any])?["sql"] as? String ?? ""

            let result: [String: Any]
            if sql == "SELECT 1" {
                result = okExecuteResult(cols: [["name": "1"]], rows: [[["type": "integer", "value": "1"]]])
            } else if sql == "PRAGMA schema_version" {
                result = okExecuteResult(cols: [["name": "schema_version"]], rows: [[["type": "integer", "value": "42"]]])
            } else if sql.contains("FROM sqlite_master") && sql.contains("tbl_name = ?") {
                result = okExecuteResult(
                    cols: [["name": "sql"]],
                    rows: [[["type": "text", "value": "CREATE TABLE \"orders\" (\"id\" INTEGER PRIMARY KEY)"]]]
                )
            } else if sql.contains("FROM sqlite_master") && sql.contains("tbl_name") {
                result = okExecuteResult(
                    cols: [["name": "type"], ["name": "name"], ["name": "tbl_name"], ["name": "sql"]],
                    rows: [[
                        ["type": "text", "value": "table"],
                        ["type": "text", "value": "orders"],
                        ["type": "text", "value": "orders"],
                        ["type": "text", "value": "CREATE TABLE orders (id INTEGER PRIMARY KEY)"],
                    ]]
                )
            } else if sql.contains("FROM sqlite_master") && sql.contains("type = 'table'") {
                result = okExecuteResult(cols: [["name": "name"]], rows: [[["type": "text", "value": "orders"]]])
            } else if sql.contains("FROM sqlite_master") {
                result = okExecuteResult(
                    cols: [["name": "type"], ["name": "name"]],
                    rows: [[["type": "text", "value": "table"], ["type": "text", "value": "orders"]]]
                )
            } else if sql.hasPrefix("PRAGMA table_info") {
                result = okExecuteResult(
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
                result = okExecuteResult(
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
                result = okExecuteResult(
                    cols: [["name": "seqno"], ["name": "cid"], ["name": "name"]],
                    rows: [[
                        ["type": "integer", "value": "0"],
                        ["type": "integer", "value": "1"],
                        ["type": "text", "value": "user_id"],
                    ]]
                )
            } else if sql.hasPrefix("PRAGMA foreign_key_list") {
                result = okExecuteResult(
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
                result = okExecuteResult(cols: [["name": "COUNT(*)"]], rows: [[["type": "integer", "value": "17"]]])
            } else {
                result = okExecuteResult()
            }
            return (makeHTTPResponse(url: url), try jsonData(["results": [result, okCloseResult()]]))
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
}
