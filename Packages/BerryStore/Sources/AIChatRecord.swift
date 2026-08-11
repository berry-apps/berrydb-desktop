import Foundation
import GRDB

/// A locally-owned chat thread — client is the source of truth (Q17,
/// docs/agents/architecture/11 §7.3), scoped by dialect + `connectionKey`
/// (v28) so switching between two connections that share a dialect (e.g. two
/// Postgres servers) can't surface one connection's history under another's.
public struct AIThreadRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord, Identifiable {
    public var id: UUID
    public var dialect: String
    /// Identifies the connection this thread belongs to — the saved
    /// profile's `UUID.uuidString`, or nil for a profileless quick-open
    /// connection (which, like its other AI settings, gets no persistent
    /// identity — see `AIPanelController.loadSettings`/`saveSettings`).
    public var connectionKey: String?
    public var title: String?
    public var summary: String?
    /// Highest message sequence already folded into `summary`. Nil means a
    /// pre-v18 thread whose summary coverage is unknown and must be rebuilt
    /// once before incremental folding can begin.
    public var summaryThroughSeq: Int?
    public var createdAt: Date
    public var updatedAt: Date

    public static let databaseTableName = "ai_thread"

    public init(
        id: UUID = UUID(), dialect: String, connectionKey: String? = nil, title: String? = nil,
        summary: String? = nil, summaryThroughSeq: Int? = nil,
        createdAt: Date, updatedAt: Date
    ) {
        self.id = id
        self.dialect = dialect
        self.connectionKey = connectionKey
        self.title = title
        self.summary = summary
        self.summaryThroughSeq = summaryThroughSeq
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A single turn in an `AIThreadRecord`, ordered by `seq` within the thread.
public struct AIMessageRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord, Identifiable {
    public var id: UUID
    public var threadID: UUID
    public var seq: Int
    public var role: String
    public var content: String
    public var toolCalls: String?
    public var toolCallID: String?
    public var createdAt: Date
    /// Which artifacts (AI-29/30) this turn's tool calls touched, JSON-encoded
    /// (AI-31, v26) — nil for a turn that didn't touch one, or one persisted
    /// before this column existed.
    public var artifactsJSON: String?

    public static let databaseTableName = "ai_message"

    public init(
        id: UUID = UUID(), threadID: UUID, seq: Int, role: String, content: String,
        toolCalls: String? = nil, toolCallID: String? = nil, createdAt: Date, artifactsJSON: String? = nil
    ) {
        self.id = id
        self.threadID = threadID
        self.seq = seq
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.createdAt = createdAt
        self.artifactsJSON = artifactsJSON
    }
}

/// Opaque control-plane state for one suspended backend interaction.
///
/// This deliberately lives outside `ai_message`: it must never be summarized,
/// embedded, searched, or attached to a report. `argsJSON` is retained only so
/// the root chat UI can reconstruct the bounded review/clarification card
/// after an app restart.
public struct AIPendingInteractionRecord:
    Codable, Sendable, Equatable, FetchableRecord, PersistableRecord, Identifiable
{
    public var id: String
    public var threadID: UUID
    public var kind: String
    public var argsJSON: String
    public var resumeToken: String
    public var origin: String
    public var originThreadID: String
    public var originPath: String
    public var parentThreadID: String
    public var expiresAtUnix: Int64
    public var registryVersion: String
    public var toolVersion: String
    public var schemaVersion: String
    /// Canonical JSON array of actions accepted by this interaction kind.
    public var allowedActionsJSON: String
    /// `pending` or `resolving`. A resolving row is a crash-safe tombstone:
    /// it is never replayed blindly after restart.
    public var state: String
    public var selectedAction: String?
    /// User-controlled answer kept in this isolated table solely for a
    /// deterministic in-process retry; it never enters chat search/RAG.
    public var responseText: String?
    public var clientRequestID: String?
    public var requestDigest: String?
    public var createdAt: Date

    public static let databaseTableName = "ai_pending_interaction"

    public init(
        id: String,
        threadID: UUID,
        kind: String,
        argsJSON: String,
        resumeToken: String,
        origin: String,
        originThreadID: String,
        originPath: String,
        parentThreadID: String,
        expiresAtUnix: Int64,
        registryVersion: String,
        toolVersion: String,
        schemaVersion: String,
        allowedActionsJSON: String,
        state: String = "pending",
        selectedAction: String? = nil,
        responseText: String? = nil,
        clientRequestID: String? = nil,
        requestDigest: String? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.threadID = threadID
        self.kind = kind
        self.argsJSON = argsJSON
        self.resumeToken = resumeToken
        self.origin = origin
        self.originThreadID = originThreadID
        self.originPath = originPath
        self.parentThreadID = parentThreadID
        self.expiresAtUnix = expiresAtUnix
        self.registryVersion = registryVersion
        self.toolVersion = toolVersion
        self.schemaVersion = schemaVersion
        self.allowedActionsJSON = allowedActionsJSON
        self.state = state
        self.selectedAction = selectedAction
        self.responseText = responseText
        self.clientRequestID = clientRequestID
        self.requestDigest = requestDigest
        self.createdAt = createdAt
    }
}

/// The rough `/report` text, kept purely local until the user explicitly
/// consents to send it (plus optional recent context) for backend refinement
/// (docs/agents/architecture Task 4.1 pre-refinement consent gate). Lives
/// outside `ai_message`/`ai_message_embedding` for the same reason
/// `AIPendingInteractionRecord` does: it must never enter chat RAG, rolling
/// summaries, search results, or a report attachment. One row per thread — a
/// fresh `/report` in the same thread replaces any earlier undecided draft.
public struct AIPendingReportDraftRecord:
    Codable, Sendable, Equatable, FetchableRecord, PersistableRecord, Identifiable
{
    public var threadID: UUID
    public var text: String
    public var attachContext: Bool
    public var createdAt: Date

    public var id: UUID { threadID }

    public static let databaseTableName = "ai_pending_report_draft"

    public init(threadID: UUID, text: String, attachContext: Bool = true, createdAt: Date) {
        self.threadID = threadID
        self.text = text
        self.attachContext = attachContext
        self.createdAt = createdAt
    }
}
