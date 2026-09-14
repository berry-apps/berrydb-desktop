import BerryAI
import BerryDriverKit
import BerryStore
import Foundation
import Testing

@testable import BerryUI

/// A user's own bubble linkifying `@{Name}`
/// `TurnView.styledMessageText` re-resolves each already-sent mention span
/// against the same candidate list the composer's autocomplete used, since
/// the bubble only stored the literal text, not which item was chosen.
@MainActor
@Suite("TurnView mention rendering")
struct TurnViewMentionTests {
    private let artifact = Artifact(profileID: UUID(), kind: .editorTab, title: "Top customers")
    private let object = SchemaObject(kind: .table, name: "orders", database: nil)

    private func makeTurnView(text: String = "") -> TurnView {
        let artifact = artifact
        let object = object
        var view = TurnView(turn: AITurn(role: .user, text: text))
        view.mentionCandidates = { query in
            ArtifactMentionItem.filter(artifacts: [artifact], objects: [object], query: query)
        }
        return view
    }

    @Test func exactMatchResolvesToTheArtifact() {
        let view = makeTurnView()
        let resolved = view.resolveMention("Top customers")
        #expect(resolved == .artifact(artifact))
    }

    @Test func exactMatchIsCaseInsensitive() {
        let view = makeTurnView()
        #expect(view.resolveMention("TOP CUSTOMERS") == .artifact(artifact))
    }

    @Test func exactMatchResolvesToASchemaObject() {
        let view = makeTurnView()
        #expect(view.resolveMention("orders") == .object(object))
    }

    @Test func noMatchReturnsNil() {
        let view = makeTurnView()
        #expect(view.resolveMention("nope") == nil)
    }

    /// A substring match must not resolve — only the composer's exact
    /// inserted name should linkify, else "Top" would falsely resolve to
    /// "Top customers".
    @Test func substringMatchDoesNotResolve() {
        let view = makeTurnView()
        #expect(view.resolveMention("Top") == nil)
    }

    @Test func resolvedMentionStripsBracesAndLinkifies() {
        let view = makeTurnView(text: "@{Top customers} viết gì thế")
        let styled = view.styledMessageText("@{Top customers} viết gì thế")
        #expect(String(styled.characters) == "@Top customers viết gì thế")
        let linkRun = styled.runs.first { $0.link != nil }
        #expect(linkRun != nil)
        #expect(linkRun?.link == view.mentionURL(for: .artifact(artifact)))
    }

    /// A mention that no longer resolves (renamed/deleted since it was sent)
    /// is left exactly as typed — braces included, no link.
    @Test func unresolvedMentionIsLeftLiteral() {
        let view = makeTurnView()
        let styled = view.styledMessageText("@{missing} hello")
        #expect(String(styled.characters) == "@{missing} hello")
        #expect(styled.runs.allSatisfy { $0.link == nil })
    }

    @Test func textWithNoMentionIsUnchanged() {
        let view = makeTurnView()
        let styled = view.styledMessageText("no mentions here")
        #expect(String(styled.characters) == "no mentions here")
    }

    @Test func objectMentionURLCarriesTheObjectHostAndID() {
        let view = makeTurnView()
        let url = view.mentionURL(for: .object(object))
        #expect(url?.host == "object")
        #expect(url?.query?.contains("id=\(object.id)") == true)
    }

    @Test func artifactMentionURLCarriesTheArtifactHostAndID() {
        let view = makeTurnView()
        let url = view.mentionURL(for: .artifact(artifact))
        #expect(url?.host == "artifact")
        #expect(url?.query?.contains("id=\(artifact.id.uuidString)") == true)
    }
}
