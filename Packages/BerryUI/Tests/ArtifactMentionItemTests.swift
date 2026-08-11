import BerryDriverKit
import BerryStore
import Foundation
import Testing

@testable import BerryUI

@Suite("ArtifactMentionItem.filter (AI-32 composer @{...} mention)")
struct ArtifactMentionItemTests {
    private let artifacts = [
        Artifact(profileID: UUID(), kind: .editorTab, title: "Top customers"),
        Artifact(profileID: UUID(), kind: .mongoShell, title: "Recent orders"),
    ]
    private let objects = [
        SchemaObject(kind: .table, name: "customers", database: "public"),
        SchemaObject(kind: .view, name: "active_customers", database: "public"),
        SchemaObject(kind: .function, name: "customer_count", database: "public"),
    ]

    @Test func emptyQueryReturnsEverythingArtifactsFirst() {
        let items = ArtifactMentionItem.filter(artifacts: artifacts, objects: objects, query: "")
        #expect(items.map(\.name) == ["Top customers", "Recent orders", "public.customers", "public.active_customers"])
    }

    @Test func queryMatchesCaseInsensitiveSubstringAcrossBoth() {
        let items = ArtifactMentionItem.filter(artifacts: artifacts, objects: objects, query: "CUSTOMER")
        #expect(items.map(\.name) == ["Top customers", "public.customers", "public.active_customers"])
    }

    @Test func noMatchReturnsEmpty() {
        let items = ArtifactMentionItem.filter(artifacts: artifacts, objects: objects, query: "zzz")
        #expect(items.isEmpty)
    }

    /// Only `.table`/`.view` are mentionable schema objects — matches
    /// `QuickOpenItem`'s own relational-only scope; a function/procedure/
    /// trigger/index isn't something `@{...}` should suggest here.
    @Test func onlyTablesAndViewsAreEligibleSchemaObjectCandidates() {
        let items = ArtifactMentionItem.filter(artifacts: [], objects: objects, query: "customer")
        #expect(items.map(\.name) == ["public.customers", "public.active_customers"])
    }

    @Test func artifactAndTableCanShareANameWithoutMerging() {
        let sameNamed = [Artifact(profileID: UUID(), kind: .editorTab, title: "customers")]
        // A SQLite-style object (no database, so qualifiedName == name) —
        // isolates the "still not merged/deduped" case being tested;
        // a Postgres/MySQL object would already disambiguate via
        // qualifiedName, per `objectNameIsQualifiedWhenItHasADatabase` below.
        let tableOnly = [SchemaObject(kind: .table, name: "customers", database: nil)]
        let items = ArtifactMentionItem.filter(artifacts: sameNamed, objects: tableOnly, query: "customers")
        #expect(items.count == 2)
        #expect(items[0].id != items[1].id)
        #expect(items.allSatisfy { $0.name == "customers" })
    }

    /// Multi-db drivers (Postgres/MySQL) can have same-named tables in
    /// different databases — `qualifiedName` disambiguates them, same as the
    /// sidebar's "Copy Qualified Name."
    @Test func objectNameIsQualifiedWhenItHasADatabase() {
        let object = SchemaObject(kind: .table, name: "orders", database: "shop")
        #expect(ArtifactMentionItem.object(object).name == "shop.orders")
    }

    @Test func objectNameIsUnqualifiedWithoutADatabase() {
        let object = SchemaObject(kind: .table, name: "orders", database: nil)
        #expect(ArtifactMentionItem.object(object).name == "orders")
    }

    /// Same-titled (e.g. never-renamed) artifacts otherwise look identical in
    /// the dropdown — the subtitle's last-updated time is the only thing
    /// telling them apart. Schema objects never carry one: their row already
    /// has a distinct icon per kind, and `qualifiedName` disambiguates same-
    /// named tables across databases.
    @Test func onlyArtifactsCarryASubtitleDate() {
        let artifact = Artifact(profileID: UUID(), kind: .editorTab, title: "Untitled")
        #expect(ArtifactMentionItem.artifact(artifact).subtitleDate == artifact.updatedAt)
        let object = SchemaObject(kind: .table, name: "orders", database: nil)
        #expect(ArtifactMentionItem.object(object).subtitleDate == nil)
    }

    /// A "select search," not a silent dump of everything a large-schema
    /// connection has — a small inline popup can't usefully browse hundreds
    /// of unfiltered results.
    @Test func resultsAreCappedAtMaxResults() {
        let manyObjects = (0..<50).map { SchemaObject(kind: .table, name: "t\($0)", database: nil) }
        let items = ArtifactMentionItem.filter(artifacts: [], objects: manyObjects, query: "")
        #expect(items.count == ArtifactMentionItem.maxResults)
    }
}
