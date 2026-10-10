import Foundation
import Testing

@testable import BerryStore

@Suite("AI provider records")
struct AIProviderRecordTests {
    private func makeStore() throws -> BerryStore {
        try BerryStore(path: ":memory:")
    }

    @Test func savesAndListsProvidersInSortOrder() throws {
        let store = try makeStore()
        let first = AIProviderRecord(
            kind: .openAICompatible, displayName: "Local Ollama",
            baseURL: "http://127.0.0.1:11434/v1", model: "llama3", sortOrder: 0
        )
        let second = AIProviderRecord(
            kind: .anthropic, displayName: "Claude",
            baseURL: "https://api.anthropic.com", model: "claude-sonnet-4-5", sortOrder: 1
        )
        try store.saveAIProvider(second)
        try store.saveAIProvider(first)

        let all = try store.aiProviders()
        #expect(all.map(\.displayName) == ["Local Ollama", "Claude"])
        #expect(all[1].kind == .anthropic)
    }

    @Test func savePersistsAllFields() throws {
        let store = try makeStore()
        let provider = AIProviderRecord(
            kind: .openAICompatible, displayName: "OpenAI",
            baseURL: "https://api.openai.com/v1", model: "gpt-4o",
            embeddingModel: "text-embedding-3-small", detailLevel: "advanced",
            sortOrder: 2
        )
        try store.saveAIProvider(provider)

        let loaded = try #require(try store.aiProviders().first)
        #expect(loaded.id == provider.id)
        #expect(loaded.kind == .openAICompatible)
        #expect(loaded.model == "gpt-4o")
        #expect(loaded.embeddingModel == "text-embedding-3-small")
        #expect(loaded.detailLevel == "advanced")
        #expect(loaded.baseURL == "https://api.openai.com/v1")
    }

    @Test func onlyOneProviderIsActive() throws {
        let store = try makeStore()
        let a = AIProviderRecord(
            kind: .openAICompatible, displayName: "A", baseURL: "https://a", model: "m", isActive: true
        )
        let b = AIProviderRecord(
            kind: .anthropic, displayName: "B", baseURL: "https://b", model: "m", isActive: true
        )
        try store.saveAIProvider(a)
        try store.saveAIProvider(b)

        let active = try #require(try store.activeAIProvider())
        #expect(active.id == b.id)
        #expect(try store.aiProviders().filter(\.isActive).count == 1)
    }

    @Test func deactivatingLeavesNoActiveProvider() throws {
        let store = try makeStore()
        let a = AIProviderRecord(
            kind: .openAICompatible, displayName: "A", baseURL: "https://a", model: "m", isActive: true
        )
        try store.saveAIProvider(a)

        var deactivated = a
        deactivated.isActive = false
        try store.saveAIProvider(deactivated)
        #expect(try store.activeAIProvider() == nil)
    }

    @Test func deleteRemovesOnlyThatProvider() throws {
        let store = try makeStore()
        let a = AIProviderRecord(kind: .openAICompatible, displayName: "A", baseURL: "https://a", model: "m")
        let b = AIProviderRecord(kind: .anthropic, displayName: "B", baseURL: "https://b", model: "m")
        try store.saveAIProvider(a)
        try store.saveAIProvider(b)

        try store.deleteAIProvider(id: a.id)
        #expect(try store.aiProviders().map(\.id) == [b.id])
    }
}
