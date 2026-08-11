import BerryCore
import BerryDataSourceKit
import Foundation
import Observation

/// Result of one statement inside a Mongo shell run (mirrors `EditorResult`,
/// one result tab per statement — every statement gets a tab here, unlike
/// SQL's Message/Result split, since every Mongo action either streams
/// documents or gets a synthetic one-row acknowledgement, docs/feedback/01.md
/// item 2).
@MainActor
public struct MongoShellResult: Identifiable {
    public let id = UUID()
    public let script: String
    public let buffer = DataSourceResultBuffer()

    public var label: String {
        let flat = script.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 32 ? String(flat.prefix(32)) + "…" : flat
    }
}

/// One Mongo shell query tab (docs/feedback/01.md item 2): script text + its
/// per-statement results. Sibling of `EditorDocument` for the SQL side.
@MainActor
@Observable
public final class MongoShellTabState: Identifiable {
    public let id: UUID
    public var title: String
    public var text: String
    public private(set) var results: [MongoShellResult] = []
    public var selectedResultID: MongoShellResult.ID?
    public private(set) var isRunning = false
    public var cursorLocation: Int = 0
    public var pendingFocus = false
    /// Linked saved query (docs/ui), mirrors `EditorDocument.savedQueryID`.
    public var savedQueryID: UUID?
    /// Linked artifact (AI-29, docs/draft/09.md), mirrors `EditorDocument.artifactID`.
    public var artifactID: UUID?
    /// Set when this tab was opened by double-clicking a collection in the
    /// sidebar (`WorkspaceViewModel.openCollection`) so re-clicking the same
    /// collection re-focuses this tab instead of duplicating it. `nil` for a
    /// blank "New Query" tab.
    public var sourceCollectionName: String?
    /// The session passed to the most recent `run(session:applyWrite:)` call,
    /// kept only so `cancel()` can also tell the connection to abort the
    /// in-flight request server-side (`DataSourceConnection.cancelCurrentQuery()`)
    /// — cancelling the local buffer alone stops consumption but leaves the
    /// server-side query running, unlike SQL's `EditorDocument.cancel(session:)`.
    private var lastSession: DataSourceSession?

    public init(id: UUID = UUID(), title: String, text: String = "") {
        self.id = id
        self.title = title
        self.text = text
    }

    /// Parses `text` and runs every statement in order against `session`,
    /// stopping at the first failure (mirrors `EditorDocument.runStatements`).
    /// Reads go straight through `session.connection.query(_:)`; writes go
    /// through the caller-supplied `applyWrite` so danger-gating
    /// (`WorkspaceViewModel.applyDataSourceWrite`) is never bypassed.
    public func run(
        session: DataSourceSession,
        applyWrite: @escaping (DataSourceChangeSet) async -> DataSourceWriteOutcome,
        onComplete: (() -> Void)? = nil
    ) {
        guard !isRunning else { return }
        isRunning = true
        lastSession = session
        results = []
        selectedResultID = nil

        Task { [weak self] in
            guard let self else { return }
            let statements: [MongoShellStatement]
            do {
                statements = try MongoShellParser.parse(self.text)
            } catch {
                await self.appendAndRun(script: self.text, session: session) { _ in
                    throw error
                }
                self.isRunning = false
                onComplete?()
                return
            }
            guard !statements.isEmpty else {
                self.isRunning = false
                onComplete?()
                return
            }
            for statement in statements {
                let state = await self.appendAndRun(script: statement.rawText, session: session) { buffer in
                    let action = try MongoShellResolver.resolve(statement)
                    switch action {
                    case .query(let query):
                        buffer.consume(session.connection.query(query))
                        await buffer.waitUntilFinished()
                    case .write(let change):
                        switch await applyWrite(change) {
                        case .succeeded:
                            buffer.consume(Self.acknowledgedStream(count: 1))
                        case .cancelled:
                            buffer.consume(Self.cancelledStream(succeeded: 0, total: 1))
                        case .failed(let message):
                            buffer.consume(Self.failedStream(message))
                        }
                        await buffer.waitUntilFinished()
                    case .writeMany(let changes):
                        var succeeded = 0
                        var outcome: DataSourceWriteOutcome = .succeeded
                        for change in changes {
                            outcome = await applyWrite(change)
                            guard case .succeeded = outcome else { break }
                            succeeded += 1
                        }
                        switch outcome {
                        case .succeeded:
                            buffer.consume(Self.acknowledgedStream(count: succeeded))
                        case .cancelled:
                            buffer.consume(Self.cancelledStream(succeeded: succeeded, total: changes.count))
                        case .failed(let message):
                            buffer.consume(Self.failedStream(message))
                        }
                        await buffer.waitUntilFinished()
                    }
                }
                if case .failed = state { break }
                if state == .cancelled { break }
            }
            self.isRunning = false
            onComplete?()
        }
    }

    /// Appends one result, runs `body` against its buffer, records history,
    /// and returns the buffer's final state. `body` throwing (a parse/resolve
    /// error) fails the buffer directly — errors never propagate past here.
    @discardableResult
    private func appendAndRun(
        script: String, session: DataSourceSession,
        _ body: @escaping (DataSourceResultBuffer) async throws -> Void
    ) async -> DataSourceResultBuffer.State {
        let result = MongoShellResult(script: script)
        results.append(result)
        if selectedResultID == nil { selectedResultID = result.id }

        let startedAt = Date()
        let clock = ContinuousClock()
        let began = clock.now
        do {
            try await body(result.buffer)
        } catch {
            result.buffer.consume(Self.failedStream("\(error)"))
            await result.buffer.waitUntilFinished()
        }
        selectedResultID = result.id
        Self.recordHistory(
            profileID: session.profileID, sql: script, startedAt: startedAt,
            duration: clock.now - began, buffer: result.buffer
        )
        return result.buffer.state
    }

    public func cancel() {
        lastSession?.connection.cancelCurrentQuery()
        results.last?.buffer.cancel()
    }

    /// Plain error whose `localizedDescription` is exactly `message` (unlike
    /// `DataSourceError.queryFailed`, which prefixes "Query failed: ") —
    /// `applyWrite` failures and parse/resolve errors already carry a
    /// complete, user-facing message that must land in `buffer.state.failed`
    /// unmodified.
    private struct PlainMessageError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func failedStream(_ message: String) -> AsyncThrowingStream<DataSourceEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: PlainMessageError(message: message))
        }
    }

    /// One-row synthetic acknowledgement for a write statement, reusing the
    /// existing `DataSourceResultBuffer`/`DocumentGridView` rendering path
    /// instead of a bespoke "write succeeded" view (mirrors real mongosh
    /// printing `{ acknowledged: true, insertedId: ... }`).
    private static func acknowledgedStream(count: Int) -> AsyncThrowingStream<DataSourceEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.items([.object([("acknowledged", .bool(true)), ("count", .int(Int64(count)))])]))
            continuation.yield(.complete(DataSourceStats(itemsReturned: 1, duration: .zero)))
            continuation.finish()
        }
    }

    /// One-row synthetic result for a write the user declined at the
    /// confirmation prompt — distinct from `acknowledgedStream` so the shell
    /// never reports a cancelled write as having succeeded.
    private static func cancelledStream(succeeded: Int, total: Int) -> AsyncThrowingStream<DataSourceEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.items([
                .object([
                    ("acknowledged", .bool(false)), ("cancelled", .bool(true)),
                    ("count", .int(Int64(succeeded))), ("total", .int(Int64(total))),
                ]),
            ]))
            continuation.yield(.complete(DataSourceStats(itemsReturned: 1, duration: .zero)))
            continuation.finish()
        }
    }

    private static func recordHistory(
        profileID: UUID?, sql: String, startedAt: Date, duration: Duration, buffer: DataSourceResultBuffer
    ) {
        let status: ExecutedStatement.Status
        var errorMessage: String?
        switch buffer.state {
        case .complete: status = .success
        case .cancelled: status = .cancelled
        case .failed(let message): status = .failed; errorMessage = message
        case .running: return // never reached — callers always await waitUntilFinished first
        }
        QueryService.historySink?.record(ExecutedStatement(
            profileID: profileID, sql: sql, startedAt: startedAt, duration: duration,
            status: status, rowCount: buffer.itemCount, errorMessage: errorMessage
        ))
    }
}
