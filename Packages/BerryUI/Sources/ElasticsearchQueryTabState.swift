import BerryCore
import BerryDataSourceKit
import Foundation
import Observation

/// One Elasticsearch query tab — the search-engine
/// sibling of `QdrantQueryTabState`, simpler: a single JSON editor (no
/// Form/JSON hybrid — Elasticsearch's Query DSL has no vector-shaped field
/// awkward to represent as JSON the way Qdrant's raw vector array is, so a
/// form surface adds no value here). `rawJSON` is the canonical, runnable
/// form used for run/history/save.
@MainActor
@Observable
public final class ElasticsearchQueryTabState: Identifiable {
    public let id: UUID
    public var title: String
    public let buffer = DataSourceResultBuffer()

    /// Canonical query text (the Elasticsearch query script format). Source
    /// of truth for `run()`.
    public var rawJSON: String

    public private(set) var isRunning = false
    /// Parse/apply error to surface without running (e.g. malformed JSON).
    public private(set) var lastError: String?
    public var pendingFocus = false
    /// Linked saved query (mirrors `EditorDocument.savedQueryID`).
    public var savedQueryID: UUID?
 /// Linked artifact, mirrors `EditorDocument.artifactID`.
    public var artifactID: UUID?

    private var lastSession: DataSourceSession?

    public init(id: UUID = UUID(), title: String, rawJSON: String = "", index: String = "") {
        self.id = id
        self.title = title
        // Seed the JSON from the index so a blank tab is already runnable (a
        // bare scroll), matching how a new SQL/Mongo/Qdrant tab is immediately usable.
        if rawJSON.isEmpty {
            self.rawJSON = index.isEmpty
                ? "{\n  \"index\": \"\"\n}"
                : ElasticsearchQueryScript.json(for: .scroll(index: index, query: .null))
        } else {
            self.rawJSON = rawJSON
        }
    }

    // MARK: - Run

    public func run(
        session: DataSourceSession,
        applyWrite: @escaping (DataSourceChangeSet) async -> DataSourceWriteOutcome,
        onComplete: (() -> Void)? = nil
    ) {
        guard !isRunning else { return }
        lastError = nil
        lastSession = session

        let query: ElasticsearchQuery
        do {
            query = try ElasticsearchQueryScript.parse(rawJSON)
        } catch {
            lastError = (error as? ElasticsearchQueryError)?.errorDescription ?? error.localizedDescription
            return
        }

        isRunning = true
        let startedAt = Date()
        let clock = ContinuousClock()
        let began = clock.now

        if let readQuery = query.readQuery {
            buffer.consume(session.connection.query(readQuery))
            Task { [weak self] in
                guard let self else { return }
                await self.buffer.waitUntilFinished()
                self.record(startedAt: startedAt, duration: clock.now - began, session: session)
                self.isRunning = false
                onComplete?()
            }
        } else if let changes = query.changeSets {
            Task { [weak self] in
                guard let self else { return }
                var succeeded = 0
                var outcome: DataSourceWriteOutcome = .succeeded
                for change in changes {
                    outcome = await applyWrite(change)
                    guard case .succeeded = outcome else { break }
                    succeeded += 1
                }
                switch outcome {
                case .succeeded:
                    self.buffer.consume(Self.ackStream(count: succeeded))
                case .cancelled:
                    self.buffer.consume(Self.ackStream(count: succeeded, cancelled: true, total: changes.count))
                case .failed(let message):
                    self.buffer.consume(Self.failedStream(message))
                }
                await self.buffer.waitUntilFinished()
                self.record(startedAt: startedAt, duration: clock.now - began, session: session)
                self.isRunning = false
                onComplete?()
            }
        } else {
            isRunning = false
        }
    }

    public func cancel() {
        lastSession?.connection.cancelCurrentQuery()
        buffer.cancel()
    }

    private func record(startedAt: Date, duration: Duration, session: DataSourceSession) {
        let status: ExecutedStatement.Status
        var errorMessage: String?
        switch buffer.state {
        case .complete: status = .success
        case .cancelled: status = .cancelled
        case .failed(let message): status = .failed; errorMessage = message
        case .running: return
        }
        // Record the canonical JSON verbatim so history/replay runs the exact query.
        QueryService.historySink?.record(ExecutedStatement(
            profileID: session.profileID, sql: rawJSON, startedAt: startedAt, duration: duration,
            status: status, rowCount: buffer.itemCount, errorMessage: errorMessage
        ))
    }

    private struct PlainMessageError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func failedStream(_ message: String) -> AsyncThrowingStream<DataSourceEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: PlainMessageError(message: message)) }
    }

    /// One-row synthetic acknowledgement, reusing the grid rendering path
    /// (mirrors `QdrantQueryTabState.ackStream`).
    private static func ackStream(count: Int, cancelled: Bool = false, total: Int? = nil) -> AsyncThrowingStream<DataSourceEvent, Error> {
        AsyncThrowingStream { continuation in
            var fields: [(String, BerryDocument)] = [
                ("acknowledged", .bool(!cancelled)),
                ("count", .int(Int64(count))),
            ]
            if cancelled { fields.append(("cancelled", .bool(true))); fields.append(("total", .int(Int64(total ?? count)))) }
            continuation.yield(.items([.object(fields)]))
            continuation.yield(.complete(DataSourceStats(itemsReturned: 1, duration: .zero)))
            continuation.finish()
        }
    }
}
