import Foundation
import GRDB

/// The kind of AI backend a provider row talks to, which determines the HTTP
/// client and wire protocol used for chat and embeddings.
public enum AIProviderKind: String, Codable, Sendable, CaseIterable, Equatable {
    /// Any OpenAI-compatible chat-completions endpoint (OpenAI, OpenRouter,
    /// Ollama, vLLM, LM Studio, and similar). The only kind that offers an
    /// embeddings endpoint, so conversation and schema search are available
    /// only when this is the active provider.
    case openAICompatible = "openai"
    /// The Anthropic Messages API. No embeddings endpoint, so search degrades
    /// to empty matches while this is the active provider.
    case anthropic = "anthropic"
}

/// A user-configured AI provider. At most one row is marked active; its API
/// key lives in Keychain (see `AIProviderKeyStore` in BerryCredentials), never
/// in this table, user defaults, or logs.
public struct AIProviderRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord, Identifiable {
    public var id: UUID
    public var kind: AIProviderKind
    public var displayName: String
    public var baseURL: String
    public var model: String
    /// The embeddings model name, meaningful only for `.openAICompatible`.
    /// Nil falls back to the provider client's default model.
    public var embeddingModel: String?
    /// The explanation register ("beginner", "intermediate", "advanced",
    /// "dba"), or nil to let the provider/system default apply.
    public var detailLevel: String?
    public var isActive: Bool
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date

    public static let databaseTableName = "ai_provider"

    public init(
        id: UUID = UUID(),
        kind: AIProviderKind,
        displayName: String,
        baseURL: String,
        model: String,
        embeddingModel: String? = nil,
        detailLevel: String? = nil,
        isActive: Bool = false,
        sortOrder: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.baseURL = baseURL
        self.model = model
        self.embeddingModel = embeddingModel
        self.detailLevel = detailLevel
        self.isActive = isActive
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
