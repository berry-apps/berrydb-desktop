import BerryDriverKit
import BerryStore
import Foundation

/// One row in the composer's `@{...}` mention autocomplete (AI-32,
/// docs/draft/09.md): an artifact (AI-29) or a relational schema object
/// (table/view/…) this connection has. Mirrors `QuickOpenItem`'s shape and
/// matching rule — case-insensitive substring, no extra ranking — deliberately
/// not deduped across the two: an artifact and a table can share a name, and
/// each stays addressable by its own `id` (kind-prefixed), not merged by name.
public enum ArtifactMentionItem: Identifiable, Equatable {
    case artifact(Artifact)
    case object(SchemaObject)

    public var id: String {
        switch self {
        case .artifact(let artifact): "artifact:\(artifact.id)"
        case .object(let object): "object:\(object.id)"
        }
    }

    /// Multi-database drivers (Postgres/MySQL) can have same-named tables in
    /// different databases — `qualifiedName` (`database.name`) disambiguates
    /// them the same way the sidebar's "Copy Qualified Name" does. SQLite has
    /// no database concept (`database` is always nil), so this is just `name`
    /// there, unchanged from before.
    public var name: String {
        switch self {
        case .artifact(let artifact): artifact.title
        case .object(let object): object.qualifiedName
        }
    }

    /// Extra context shown as a smaller secondary line below `name` — nil for
    /// a schema object (its row already carries a distinct icon per kind, and
    /// `qualifiedName` already disambiguates same-named tables). For an
    /// artifact, its last-updated time: artifacts commonly share a generic
    /// title (an untitled/never-renamed query tab), where the name alone
    /// can't distinguish "which one," but recency usually can.
    public var subtitleDate: Date? {
        switch self {
        case .artifact(let artifact): artifact.updatedAt
        case .object: nil
        }
    }

    public var iconName: String {
        switch self {
        case .artifact(let artifact): artifact.kind.systemImage
        case .object(let object):
            switch object.kind {
            case .table: "tablecells"
            case .view: "eye"
            case .function: "function"
            case .procedure: "gearshape"
            case .trigger: "bolt"
            case .index: "list.bullet.indent"
            }
        }
    }

    /// Bounds the dropdown to a scannable "select search" size (a small
    /// inline popup, not a full quick-open modal) — without this, a
    /// large-schema connection or an empty query would dump every artifact
    /// and every table/view into a 200pt-tall list with no way to browse it.
    static let maxResults = 20

    /// Case-insensitive substring match over both lists (same rule as
    /// `QuickOpenItem.filter`). Artifacts sort before schema objects — they're
    /// usually what the user just did something with, so more likely to be
    /// what "@{" was reaching for. Bounded by `maxResults`; narrowing the
    /// query (typing more) is how the rest become reachable, same as any
    /// other capped/paginated list in this codebase (e.g. `get_schema`'s
    /// overview cap) — never a silent, unbounded dump.
    public static func filter(artifacts: [Artifact], objects: [SchemaObject], query: String) -> [ArtifactMentionItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let artifactItems = artifacts
            .filter { trimmed.isEmpty || $0.title.localizedCaseInsensitiveContains(trimmed) }
            .map { ArtifactMentionItem.artifact($0) }
        let objectItems = objects
            .filter { ($0.kind == .table || $0.kind == .view) && (trimmed.isEmpty || $0.name.localizedCaseInsensitiveContains(trimmed)) }
            .map { ArtifactMentionItem.object($0) }
        return Array((artifactItems + objectItems).prefix(maxResults))
    }
}
