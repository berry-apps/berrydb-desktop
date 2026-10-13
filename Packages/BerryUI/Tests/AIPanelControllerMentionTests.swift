import BerryLicense
import BerryStore
import Foundation
import Testing

@testable import BerryUI

/// `AIPanelController.artifactMentionQuery` — the
/// trigger-detection half of the `@` mention autocomplete, separate from
/// `ArtifactMentionItemTests`' coverage of the candidate-filtering half.
/// Changed 2026-07-31 from requiring "@{" to a bare "@" (matching the
/// Slack/Notion convention users expected) plus a word-boundary guard so an
/// "@" embedded mid-word (an email address, "foo@bar") doesn't false-trigger.
@MainActor
@Suite("AIPanelController mention trigger")
struct AIPanelControllerMentionTests {
    private func makeController() throws -> AIPanelController {
        let client = LicenseClient(baseURL: URL(string: "https://example.invalid")!)
        let license = LicenseManager(client: client)
        return AIPanelController(
            license: license, backendURL: URL(string: "https://example.invalid")!,
            store: try BerryStore(path: ":memory:")
        )
    }

    @Test func bareAtAtStartOfDraftTriggersWithAnEmptyQuery() throws {
        let controller = try makeController()
        controller.draft = "@"
        #expect(controller.artifactMentionQuery == "")
    }

    @Test func bareAtMidSentenceTriggersWhenPrecededByWhitespace() throws {
        let controller = try makeController()
        controller.draft = "show me @use"
        #expect(controller.artifactMentionQuery == "use")
    }

    @Test func atEmbeddedMidWordDoesNotTrigger() throws {
        let controller = try makeController()
        controller.draft = "email me at foo@bar"
        #expect(controller.artifactMentionQuery == nil)
    }

    @Test func atFollowedByWhitespaceClosesTheQuery() throws {
        let controller = try makeController()
        controller.draft = "@customers is great"
        #expect(controller.artifactMentionQuery == nil)
    }

    @Test func noAtInDraftReturnsNil() throws {
        let controller = try makeController()
        controller.draft = "how many rows are there"
        #expect(controller.artifactMentionQuery == nil)
    }

    @Test func mostRecentAtWinsWhenTwoArePresent() throws {
        let controller = try makeController()
        // As if the user already accepted one mention (@{Orders} always
        // leaves a trailing space) and started typing a second.
        controller.draft = "join @{Orders} with @cust"
        #expect(controller.artifactMentionQuery == "cust")
    }
}
