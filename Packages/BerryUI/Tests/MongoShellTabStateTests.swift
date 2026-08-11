import BerryDataSourceKit
import BerryCore
import Foundation
import Testing
@testable import BerryUI

private final class QueryBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: DataSourceQuery?
    var current: DataSourceQuery? {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); defer { lock.unlock() }; value = newValue }
    }
}

private struct StubIntrospector: DataSourceIntrospector {
    func collections() async throws -> [CollectionRef] { [] }
    func inferredSchema(of collection: CollectionRef, sampleSize: Int) async throws -> [String: String] { [:] }
}

/// Mirrors `CollectionTabStateTests.RecordingConnection` (same fixture shape,
/// same project convention) but also yields a fixed document batch for
/// `.query`, so `find`/`aggregate` results are observable in the test.
private actor RecordingConnection: DataSourceConnection {
    nonisolated let id = UUID()
    private nonisolated let box = QueryBox()
    var lastQuery: DataSourceQuery? { box.current }
    var writes: [DataSourceChangeSet] = []
    var fixedItems: [BerryDocument] = []

    func listCollections() async throws -> [CollectionRef] { [] }
    func createCollection(_ ref: CollectionRef, options: BerryDocument) async throws {}

    nonisolated func query(_ request: DataSourceQuery) -> AsyncThrowingStream<DataSourceEvent, Error> {
        box.current = request
        return AsyncThrowingStream { continuation in
            continuation.yield(.complete(DataSourceStats(itemsReturned: 0, duration: .zero)))
            continuation.finish()
        }
    }

    func write(_ change: DataSourceChangeSet) async throws -> DataSourceWriteResult {
        writes.append(change)
        return DataSourceWriteResult(affectedCount: 1)
    }

    nonisolated func cancelCurrentQuery() {}
    nonisolated var introspector: any DataSourceIntrospector { StubIntrospector() }
    func ping() async -> Bool { true }
    func close() async {}
}

@MainActor
@Suite("MongoShellTabState")
struct MongoShellTabStateTests {
    private func makeSession(connection: RecordingConnection) -> DataSourceSession {
        DataSourceSession(
            profileID: nil, isProduction: false, connection: connection, kind: .document,
            capabilities: DataSourceCapabilities(write: true), driverDisplayName: "MongoDB", displayName: "test"
        )
    }

    @Test func runProducesOneResultPerStatement() async {
        let connection = RecordingConnection()
        let state = MongoShellTabState(title: "Untitled")
        state.text = #"""
        db.users.find({});
        db.users.insertOne({ name: "A" });
        """#
        state.run(session: makeSession(connection: connection), applyWrite: { change in
            _ = try? await connection.write(change)
            return .succeeded
        })
        while state.isRunning { await Task.yield() }
        #expect(state.results.count == 2)
        #expect(state.results[0].buffer.state == .complete)
        #expect(state.results[1].buffer.state == .complete)
    }

    @Test func runStopsAtTheFirstParseError() async {
        let connection = RecordingConnection()
        let state = MongoShellTabState(title: "Untitled")
        state.text = "not mongo shell syntax at all"
        state.run(session: makeSession(connection: connection), applyWrite: { _ in .succeeded })
        while state.isRunning { await Task.yield() }
        #expect(state.results.count == 1)
        guard case .failed = state.results[0].buffer.state else {
            Issue.record("expected the sole result to have failed")
            return
        }
    }

    @Test func writeStatementRoutesThroughTheSuppliedApplyWriteClosure() async {
        let connection = RecordingConnection()
        let state = MongoShellTabState(title: "Untitled")
        state.text = #"db.users.deleteOne({ email: "a@x.com" });"#
        var captured: DataSourceChangeSet?
        state.run(session: makeSession(connection: connection), applyWrite: { change in
            captured = change
            return .succeeded
        })
        while state.isRunning { await Task.yield() }
        guard case .deleteByFilter(let collection, let filter, let multi) = captured else {
            Issue.record("expected applyWrite to receive .deleteByFilter")
            return
        }
        #expect(collection == "users")
        #expect(filter == .object([("email", .string("a@x.com"))]))
        #expect(multi == false)
        #expect(state.results[0].buffer.itemCount == 1) // synthetic ack row
    }

    @Test func writeErrorFailsThatStatementsResult() async {
        let connection = RecordingConnection()
        let state = MongoShellTabState(title: "Untitled")
        state.text = #"db.users.deleteOne({ email: "a@x.com" });"#
        state.run(session: makeSession(connection: connection), applyWrite: { _ in .failed("boom") })
        while state.isRunning { await Task.yield() }
        guard case .failed(let message) = state.results[0].buffer.state else {
            Issue.record("expected the result to have failed")
            return
        }
        #expect(message == "boom")
    }

    @Test func writeCancelledByUserIsNotReportedAsAcknowledged() async {
        let connection = RecordingConnection()
        let state = MongoShellTabState(title: "Untitled")
        state.text = #"db.users.deleteOne({ email: "a@x.com" });"#
        state.run(session: makeSession(connection: connection), applyWrite: { _ in .cancelled })
        while state.isRunning { await Task.yield() }
        guard case .complete = state.results[0].buffer.state else {
            Issue.record("expected the result to complete (cancel is not a failure)")
            return
        }
        // The synthetic row must NOT claim acknowledged: true.
        let items = state.results[0].buffer.items
        guard case .object(let fields)? = items.first else {
            Issue.record("expected a synthetic result row")
            return
        }
        guard case .bool(let acknowledged)? = fields.first(where: { $0.0 == "acknowledged" })?.1 else {
            Issue.record("expected an 'acknowledged' field")
            return
        }
        #expect(acknowledged == false)
    }

    @Test func bulkWriteStopsAtTheFirstCancelledOperationAndDoesNotCountItAsSucceeded() async {
        let connection = RecordingConnection()
        let state = MongoShellTabState(title: "Untitled")
        state.text = #"""
        db.users.bulkWrite([
          { insertOne: { document: { name: "A" } } },
          { deleteMany: { filter: {} } },
          { insertOne: { document: { name: "B" } } }
        ]);
        """#
        var callCount = 0
        state.run(session: makeSession(connection: connection), applyWrite: { _ in
            callCount += 1
            return callCount == 2 ? .cancelled : .succeeded
        })
        while state.isRunning { await Task.yield() }
        // Only the first 2 operations should have been attempted (insertOne, then the
        // cancelled deleteMany) — the third insertOne must NOT have run.
        #expect(callCount == 2)
        guard case .complete = state.results[0].buffer.state else {
            Issue.record("expected the result to complete (cancel is not a failure)")
            return
        }
        let items = state.results[0].buffer.items
        guard case .object(let fields)? = items.first else {
            Issue.record("expected a synthetic result row")
            return
        }
        guard case .int(let count)? = fields.first(where: { $0.0 == "count" })?.1 else {
            Issue.record("expected a 'count' field")
            return
        }
        #expect(count == 1) // only the first insertOne succeeded before the cancel
    }
}
