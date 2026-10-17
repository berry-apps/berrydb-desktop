import BerryDriverKit
import BerryDriverTestKit
import Foundation
import Network
import PostgresNIO
import Testing

@testable import BerryDriverPostgres

/// A `PSQLError` without server information comes from PostgresNIO itself,
/// and only its code is mapped.
@Suite("Postgres client error codes")
struct PostgresClientErrorTests {
    @Test func aConnectionThatIsGoneIsALostConnection() {
        for code in [PSQLError.Code.serverClosedConnection, .clientClosedConnection, .connectionError, .uncleanShutdown] {
            guard case .connectionLost(let detail) = PostgresDriverConnection.clientError(code) else {
                Issue.record("\(code): \(PostgresDriverConnection.clientError(code))")
                continue
            }
            #expect(detail == "PostgreSQL client error: \(code)")
        }
    }

    /// PostgresNIO raises `queryCancelled` when the reader of a statement's
    /// rows goes away and keeps the connection open
    /// (`ConnectionStateMachine.shouldCloseConnection`, PostgresNIO 1.33.0).
    @Test func aCancelPostgresNIOMadeIsACancel() {
        #expect({ if case .cancelled = PostgresDriverConnection.clientError(.queryCancelled) { true } else { false } }())
    }

    @Test func anyOtherCodeIsAFailedStatementThatNamesTheCode() {
        for code in [PSQLError.Code.tooManyParameters, .messageDecodingFailure, .unexpectedBackendMessage, .invalidCommandTag] {
            guard case .queryFailed(let message, nil) = PostgresDriverConnection.clientError(code) else {
                Issue.record("\(code): \(PostgresDriverConnection.clientError(code))")
                continue
            }
            #expect(message == "PostgreSQL client error: \(code)")
        }
    }
}

/// How `DroppingRelay` ends the connections it carries.
enum RelayDrop: Sendable {
    /// Each socket ends with FIN, as when the far end closes it.
    case close
    /// Each socket ends with RST, as when the far end resets it.
    case reset
}

/// Runs against a real PostgreSQL from `BERRYDB_TEST_POSTGRES`; skipped when
/// the variable is unset.
@Suite("Postgres client-side errors", .serialized, .enabled(if: TestServer.postgres != nil))
struct PostgresClientErrorLiveTests {
    private static let probe = "berry-client-error-probe"

    private func config(port: Int? = nil) -> ConnectionConfig {
        let server = TestServer.postgres!
        return ConnectionConfig(
            driver: .postgres, name: "client-error", host: port == nil ? server.host : "127.0.0.1",
            port: port ?? server.port, username: server.username, password: server.password,
            database: server.database
        )
    }

    @discardableResult
    private func drain(_ stream: AsyncThrowingStream<ResultEvent, Error>) async throws -> [[BerryValue]] {
        var rows: [[BerryValue]] = []
        for try await event in stream {
            if case let .rows(batch) = event { rows += batch }
        }
        return rows
    }

    /// What PostgresNIO 1.33.0's `PSQLError.debugDescription` carries
    /// besides the code: the query, the file and line of the call, and the
    /// underlying error.
    private func debugText(in text: String) -> [String] {
        ["PSQLError", "PostgresQuery", Self.probe, "triggeredFromRequestInFile", "line:", ".swift", "underlying"]
            .filter { text.contains($0) }
    }

    /// Waits, at most 30 s, until the server runs `statement`.
    private func waitUntilRunning(_ statement: String, on watcher: PostgresDriverConnection) async throws {
        let quoted = "'" + statement.replacingOccurrences(of: "'", with: "''") + "'"
        let deadline = ContinuousClock.now + .seconds(30)
        while try await drain(watcher.execute(
            "SELECT count(*) FROM pg_stat_activity WHERE state = 'active' AND query = \(quoted)"
        )) != [[.int(1)]] {
            guard ContinuousClock.now < deadline else {
                Issue.record("the statement never ran")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// A connection that drops while a statement runs, with no message from
    /// the server, fails the statement on the client.
    @Test(arguments: [RelayDrop.close, .reset])
    func aConnectionThatDropsMidReadIsALostConnection(drop: RelayDrop) async throws {
        let server = TestServer.postgres!
        let relay = try DroppingRelay(host: server.host, port: server.port)
        let port = try await relay.start()
        defer { relay.stop() }
        let connection = try await PostgresDriverConnection(config: config(port: port))
        let admin = try await PostgresDriverConnection(config: config())
        defer { Task { await connection.close(); await admin.close() } }
        // Long enough to stay running through the wait below on a loaded
        // machine; the client fails at once on the drop either way.
        let statement = "SELECT pg_sleep(15), '\(Self.probe) \(drop)'"

        let running = Task { try await drain(connection.execute(statement)) }
        try await waitUntilRunning(statement, on: admin)
        relay.drop(drop)
        let error = await #expect(throws: DriverError.self) {
            try await within(.seconds(10)) { try await running.value }
        }
        // The backend learns of the drop only when it next writes, after its
        // sleep, so it is ended here.
        let quoted = "'" + statement.replacingOccurrences(of: "'", with: "''") + "'"
        try await drain(admin.execute("SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE query = \(quoted)"))

        guard case .connectionLost(let detail)? = error else {
            Issue.record("not a lost connection: \(String(describing: error))")
            return
        }
        #expect(debugText(in: detail).isEmpty, "\(detail)")
    }

    /// Waits, at most 10 s, until PostgresNIO has seen `connection` close.
    private func waitUntilClosed(_ connection: PostgresDriverConnection) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while await !connection.connectionClosedForTesting {
            guard ContinuousClock.now < deadline else {
                Issue.record("the connection never saw its backend go")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// The text of an error that reports the closed connection, through
    /// whichever wrapper the path puts around it; nil for any other error.
    private func lostConnection(_ error: DriverError?) -> String? {
        switch error {
        case .connectionLost(let detail)?: detail
        case .readOnlyUnavailable(let detail)? where detail.contains("PostgreSQL connection closed"): detail
        default: nil
        }
    }

    /// `pg_terminate_backend` with a timeout returns once the backend has
    /// exited (https://www.postgresql.org/docs/16/functions-admin.html#FUNCTIONS-ADMIN-SIGNAL),
    /// and the driver's connection then sees its socket close. Every way the
    /// driver sends a statement answers at once afterwards; each is bounded,
    /// so a statement that waits forever fails the test.
    @Test func aConnectionWhoseBackendWasTerminatedAnswersAtOnce() async throws {
        let connection = try await PostgresDriverConnection(config: config())
        let readOnly = try await PostgresDriverConnection(config: config())
        let admin = try await PostgresDriverConnection(config: config())
        defer { Task { await connection.close(); await readOnly.close(); await admin.close() } }
        try await readOnly.prepareReadOnly()
        for pid in [connection.debugBackendPID, readOnly.debugBackendPID] {
            let pid = try #require(pid)
            #expect(try await drain(admin.execute("SELECT pg_terminate_backend(\(pid), 10000)")) == [[.bool(true)]])
        }
        try await waitUntilClosed(connection)
        try await waitUntilClosed(readOnly)

        let executed = await #expect(throws: DriverError.self) {
            try await within(.seconds(10)) { try await drain(connection.execute("SELECT '\(Self.probe)'")) }
        }
        let listed = await #expect(throws: DriverError.self) {
            try await within(.seconds(10)) { try await connection.queryAll("SELECT '\(Self.probe)'") }
        }
        let read = await #expect(throws: DriverError.self) {
            try await within(.seconds(10)) {
                try await drain(readOnly.executeReadOnly("SELECT '\(Self.probe)'", timeout: .seconds(5)))
            }
        }
        let answered = try await within(.seconds(10)) { await connection.ping() }

        for (path, error) in [("execute", executed), ("queryAll", listed), ("read-only", read)] {
            let detail = lostConnection(error)
            #expect(detail != nil, "\(path): \(String(describing: error))")
            #expect(debugText(in: detail ?? "").isEmpty, "\(path): \(detail ?? "")")
        }
        #expect(answered == false)
    }

    /// The extended query protocol counts parameters in 16 bits
    /// (https://www.postgresql.org/docs/16/protocol-message-formats.html,
    /// Bind), and PostgresNIO 1.33.0 refuses a query with more than 65535
    /// binds before sending it, with a `PSQLError` that has no server
    /// information. The connection stays usable.
    @Test func moreBindsThanTheProtocolCountsIsAClientErrorThatNamesOnlyItsCode() async throws {
        let readOnly = try await PostgresDriverConnection(config: config())
        defer { Task { await readOnly.close() } }
        try await readOnly.prepareReadOnly()
        let parameters = Array(repeating: SQLParameter.text(Self.probe), count: 65_536)

        let error = await #expect(throws: DriverError.self) {
            try await drain(readOnly.executeReadOnly("SELECT '\(Self.probe)'", parameters: parameters, timeout: .seconds(30)))
        }

        guard case .queryFailed(let message, nil)? = error else {
            Issue.record("not a failed query: \(String(describing: error))")
            return
        }
        #expect(message == "PostgreSQL client error: tooManyParameters")
        #expect(debugText(in: message).isEmpty, "\(message)")
        #expect(try await drain(readOnly.executeReadOnly("SELECT 1", timeout: .seconds(30))) == [[.int(1)]])
    }
}

/// A TCP relay on the loopback interface to the test server that can drop
/// every connection it carries at once, as a network failure does: the
/// client's socket ends with no message from the server first.
private final class DroppingRelay: @unchecked Sendable {
    private let queue = DispatchQueue(label: "berrydb.test.dropping-relay")
    private let listener: NWListener
    private let target: NWEndpoint
    /// Touched on `queue` only, after `start()` sets it.
    private var ready: CheckedContinuation<Void, Error>?
    /// Touched on `queue` only.
    private var carried: [NWConnection] = []

    init(host: String, port: Int) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        target = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(port))!)
    }

    /// Starts listening and returns the port the relay listens on.
    func start() async throws -> Int {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            ready = continuation
            listener.newConnectionHandler = { [self] client in accept(client) }
            listener.stateUpdateHandler = { [self] state in
                switch state {
                case .ready: resumeReady(throwing: nil)
                case .failed(let error): resumeReady(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
        return Int(listener.port!.rawValue)
    }

    func drop(_ drop: RelayDrop) {
        queue.sync {
            for connection in carried {
                switch drop {
                case .close: connection.cancel()
                case .reset: connection.forceCancel()
                }
            }
            carried.removeAll()
        }
    }

    func stop() {
        drop(.close)
        listener.cancel()
    }

    private func resumeReady(throwing error: Error?) {
        guard let continuation = ready else { return }
        ready = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }

    private func accept(_ client: NWConnection) {
        let server = NWConnection(to: target, using: .tcp)
        carried += [client, server]
        client.start(queue: queue)
        server.start(queue: queue)
        relay(from: client, to: server)
        relay(from: server, to: client)
    }

    private func relay(from source: NWConnection, to sink: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                sink.send(content: data, completion: .contentProcessed { _ in })
            }
            guard !isComplete, error == nil else {
                sink.cancel()
                source.cancel()
                return
            }
            relay(from: source, to: sink)
        }
    }
}
