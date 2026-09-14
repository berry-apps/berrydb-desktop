import BerryDataSourceKit
import BerryDriverKit
import Foundation

/// One row in the global quick-open palette (⌘P): a relational object
/// (table/view/function/…) or a Mongo/Qdrant collection — whichever the
/// active session has. Selecting one opens it the same way clicking it in
/// the sidebar would (WorkspaceView.open / .openCollection).
enum QuickOpenItem: Identifiable, Equatable {
    case object(SchemaObject)
    case collection(CollectionRef)

    var id: String {
        switch self {
        case .object(let object): "object:\(object.id)"
        case .collection(let ref): "collection:\(ref.id)"
        }
    }

    var name: String {
        switch self {
        case .object(let object): object.name
        case .collection(let ref): ref.name
        }
    }

    var iconName: String {
        switch self {
        case .object(let object):
            switch object.kind {
            case .table: "tablecells"
            case .view: "eye"
            case .function: "function"
            case .procedure: "gearshape"
            case .trigger: "bolt"
            case .index: "list.bullet.indent"
            }
        case .collection: "tray.full"
        }
    }

    /// Case-insensitive substring match over both lists — same matching rule
    /// as the sidebar's existing filter (objectFilterField), just reachable
    /// globally instead of requiring the sidebar to have focus. Objects sort
    /// before collections (a session has one kind of schema or the other, so
    /// in practice only one side is ever non-empty).
    static func filter(objects: [SchemaObject], collections: [CollectionRef], query: String) -> [QuickOpenItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let objectItems = objects
            .filter { trimmed.isEmpty || $0.name.localizedCaseInsensitiveContains(trimmed) }
            .map { QuickOpenItem.object($0) }
        let collectionItems = collections
            .filter { trimmed.isEmpty || $0.name.localizedCaseInsensitiveContains(trimmed) }
            .map { QuickOpenItem.collection($0) }
        return objectItems + collectionItems
    }
}
