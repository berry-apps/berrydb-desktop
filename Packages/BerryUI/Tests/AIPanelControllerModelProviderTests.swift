import Foundation
import Testing

@testable import BerryUI

/// Two providers can serve models with the same display name, e.g. "GPT-4o
/// Mini" from OpenAI directly and through OpenRouter, so a model entry from
/// `GET /v1/ai/balance` carries the provider that serves it. Backends that
/// predate `provider_id` and `provider_name` still have to parse, with the
/// provider taken from the model id's first path segment.
@Suite("AIPanelController.Balance model providers")
struct AIPanelControllerModelProviderTests {
    private typealias Model = AIPanelController.Balance.Model

    private func entry(_ fields: [String: Any]) -> [String: Any] {
        var entry: [String: Any] = [
            "id": "openrouter/openai/gpt-4o-mini",
            "name": "GPT-4o Mini",
            "tokens_remaining": 900,
            "tokens_total": 1_000,
            "tokens_used": 100,
        ]
        entry.merge(fields) { _, new in new }
        return entry
    }

    private func model(_ id: String, _ name: String, provider: String, providerName: String) -> Model {
        Model(
            id: id, name: name, providerID: provider, providerName: providerName,
            tokensRemaining: 0, tokensTotal: 0, tokensUsed: 0
        )
    }

    @Test func anEntryWithProviderFieldsUsesThem() throws {
        // The sent provider_id differs from the id's first segment only so the
        // assertion proves the field is read rather than derived from the id.
        let parsed = try #require(Model.parse(entry(["provider_id": "openrouter-eu", "provider_name": "OpenRouter"])))
        #expect(parsed.providerID == "openrouter-eu")
        #expect(parsed.providerName == "OpenRouter")
        #expect(parsed.id == "openrouter/openai/gpt-4o-mini")
        #expect(parsed.name == "GPT-4o Mini")
        #expect(parsed.tokensRemaining == 900)
        #expect(parsed.tokensTotal == 1_000)
        #expect(parsed.tokensUsed == 100)
    }

    @Test func anEntryFromAnOlderBackendTakesTheProviderFromTheIdsFirstSegment() throws {
        let parsed = try #require(Model.parse(entry([:])))
        #expect(parsed.providerID == "openrouter")
        #expect(parsed.providerName == "openrouter")
    }

    @Test func anIdWithoutASlashIsItsOwnProvider() throws {
        let parsed = try #require(Model.parse(entry(["id": "local-model"])))
        #expect(parsed.providerID == "local-model")
        #expect(parsed.providerName == "local-model")
    }

    @Test func aBlankProviderNameFallsBackToTheProviderID() throws {
        let parsed = try #require(Model.parse(entry(["provider_id": "openai", "provider_name": "  "])))
        #expect(parsed.providerName == "openai")
    }

    @Test func anEntryMissingARequiredKeyIsDropped() {
        var incomplete = entry(["provider_id": "openai", "provider_name": "OpenAI"])
        incomplete.removeValue(forKey: "tokens_used")
        #expect(Model.parse(incomplete) == nil)
    }

    @Test func groupsFollowTheOrderEachProviderFirstAppearsIn() {
        let models = [
            model("openai/gpt-4o-mini", "GPT-4o Mini", provider: "openai", providerName: "OpenAI"),
            model("openrouter/openai/gpt-4o-mini", "GPT-4o Mini", provider: "openrouter", providerName: "OpenRouter"),
            model("openai/gpt-4o", "GPT-4o", provider: "openai", providerName: "OpenAI"),
        ]
        let groups = AIPanelController.Balance.groupedByProvider(models)
        #expect(groups.map(\.id) == ["openai", "openrouter"])
        #expect(groups.map(\.name) == ["OpenAI", "OpenRouter"])
        #expect(groups.first?.models.map(\.id) == ["openai/gpt-4o-mini", "openai/gpt-4o"])
        #expect(groups.last?.models.map(\.id) == ["openrouter/openai/gpt-4o-mini"])
    }

    @Test func onlyModelsSharingANameAreLabelledWithTheirProvider() {
        let models = [
            model("openai/gpt-4o-mini", "GPT-4o Mini", provider: "openai", providerName: "OpenAI"),
            model("openrouter/openai/gpt-4o-mini", "GPT-4o Mini", provider: "openrouter", providerName: "openrouter"),
            model("google/gemini-2.5-flash", "Gemini 2.5 Flash", provider: "google", providerName: "Google"),
        ]
        #expect(models.map { Model.label(for: $0, in: models) } == [
            "GPT-4o Mini (OpenAI)", "GPT-4o Mini (openrouter)", "Gemini 2.5 Flash",
        ])
    }
}
