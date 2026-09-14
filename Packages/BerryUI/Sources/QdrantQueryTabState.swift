import BerryCore
import BerryDataSourceKit
import Foundation
import Observation

/// One Qdrant query tab — the vector-store sibling of
/// `MongoShellTabState`/`EditorDocument`. Hybrid surface: a structured **Form**
/// and a **JSON** editor, kept in sync, with the JSON (`rawJSON`) as the
/// canonical, runnable form used for run/history/save. Reads stream into the
/// result grid; writes (upsert/delete points) go through the caller's
/// danger-gated `applyWrite`, never bypassing the confirm flow.
@MainActor
@Observable
public final class QdrantQueryTabState: Identifiable {
    public enum Mode: Sendable { case form, json }

    public let id: UUID
    public var title: String
    public let buffer = DataSourceResultBuffer()

    /// Canonical query text (the Qdrant JSON DSL). Source of truth for `run()`.
    public var rawJSON: String
    public var mode: Mode = .form

    // Form fields (read queries only — writes live in JSON mode).
    public var collection: String = ""
    public var vectorText: String = ""
    public var topK: Int = 10
    public var scoreThresholdText: String = ""
    public var payloadFilterText: String = ""

    public private(set) var isRunning = false
    /// Parse/apply error to surface without running (e.g. malformed JSON).
    public private(set) var lastError: String?
    public var pendingFocus = false
    /// Linked saved query (mirrors `EditorDocument.savedQueryID`).
    public var savedQueryID: UUID?
 /// Linked artifact, mirrors `EditorDocument.artifactID`.
    public var artifactID: UUID?

    private var lastSession: DataSourceSession?

    public init(id: UUID = UUID(), title: String, rawJSON: String = "", collection: String = "") {
        self.id = id
        self.title = title
        self.collection = collection
        // Seed the JSON from the collection so a blank tab is already runnable
        // (a bare scroll), matching how a new SQL/Mongo tab is immediately usable.
        if rawJSON.isEmpty {
            self.rawJSON = collection.isEmpty
                ? "{\n  \"collection\": \"\"\n}"
                : QdrantQueryScript.json(for: .scroll(collection: collection, filter: nil))
        } else {
            self.rawJSON = rawJSON
        }
        syncJSONToForm()
    }

    // MARK: - Form ⇄ JSON sync

    /// Rebuild `rawJSON` from the form fields (Form → JSON). Called as the user
    /// edits the form so switching to JSON shows the equivalent query.
    public func syncFormToJSON() {
        let filter = QdrantQueryScript.parseFilter(payloadFilterText)
        let query: QdrantQuery
        if let vector = QdrantQueryScript.parseVector(vectorText), !vector.isEmpty {
            query = .search(
                collection: collection, vector: vector, filter: filter,
                topK: topK, scoreThreshold: Double(scoreThresholdText.trimmingCharacters(in: .whitespaces))
            )
        } else {
            query = .scroll(collection: collection, filter: filter)
        }
        rawJSON = QdrantQueryScript.json(for: query)
    }

    /// Populate the form from `rawJSON` (JSON → Form) when it is a read query.
    /// A write query leaves the form untouched (writes are JSON-only).
    public func syncJSONToForm() {
        guard let query = try? QdrantQueryScript.parse(rawJSON) else { return }
        switch query {
        case let .search(collection, vector, filter, topK, threshold):
            self.collection = collection
            self.vectorText = QdrantQueryScript.json(forVector: vector)
            self.topK = topK
            self.scoreThresholdText = threshold.map { String($0) } ?? ""
            self.payloadFilterText = filter.map(QdrantQueryScript.jsonText(for:)) ?? ""
        case let .scroll(collection, filter):
            self.collection = collection
            self.vectorText = ""
            self.payloadFilterText = filter.map(QdrantQueryScript.jsonText(for:)) ?? ""
        case .upsert, .delete:
            break // write query — keep form as-is; JSON mode owns it
        }
    }

    // MARK: - Run

    public func run(
        session: DataSourceSession,
        applyWrite: @escaping (DataSourceChangeSet) async -> DataSourceWriteOutcome,
        onComplete: (() -> Void)? = nil
    ) {
        guard !isRunning else { return }
        if mode == .form { syncFormToJSON() }
        lastError = nil
        lastSession = session

        let query: QdrantQuery
        do {
            query = try QdrantQueryScript.parse(rawJSON)
        } catch {
            lastError = (error as? QdrantQueryError)?.errorDescription ?? error.localizedDescription
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
    /// (mirrors `MongoShellTabState.acknowledgedStream`).
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
