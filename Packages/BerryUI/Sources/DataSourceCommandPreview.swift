import BerryDataSourceKit
import Foundation

/// Native-command preview for a `DataSourceChangeSet` (DL-03/04 sibling,
/// docs/architecture/12 §6/§7) — shown before every write via
/// `WorkspaceViewModel.applyDataSourceWrite`, same "preview then apply" rule
/// as SQL's `ChangeSet.statements()`. Pseudo-mongosh for Mongo; the literal
/// REST method/path/JSON body for Qdrant.
public enum DataSourceCommandPreview {
    public static func render(_ change: DataSourceChangeSet, kind: DataSourceKind) -> String {
        switch kind {
        case .document: return mongo(change)
        case .vector: return qdrant(change)
        case .search: return elasticsearch(change)
        }
    }

    private static func mongo(_ change: DataSourceChangeSet) -> String {
        switch change {
        case .insert(let collection, let document):
            return "db.\(collection).insertOne(\(json(document)))"
        case .update(let collection, let id, let patch):
            return "db.\(collection).updateOne({ _id: \(json(id)) }, { $set: \(json(patch)) })"
        case .delete(let collection, let id):
            if DataSourceDangerGuard.classify(change) == .confirm(.deleteWithoutFilter) {
                return "db.\(collection).deleteMany({})"
            }
            return "db.\(collection).deleteOne({ _id: \(json(id)) })"
        case .updateByFilter(let collection, let filter, let update, let multi):
            return "db.\(collection).\(multi ? "updateMany" : "updateOne")(\(json(filter)), \(json(update)))"
        case .deleteByFilter(let collection, let filter, let multi):
            return "db.\(collection).\(multi ? "deleteMany" : "deleteOne")(\(json(filter)))"
        case .dropCollection(let collection):
            return "db.\(collection).drop()"
        case .createIndex(let collection, let keys, let options):
            if let options {
                return "db.\(collection).createIndex(\(json(keys)), \(json(options)))"
            }
            return "db.\(collection).createIndex(\(json(keys)))"
        case .dropIndex(let collection, let indexName):
            return "db.\(collection).dropIndex(\"\(indexName)\")"
        case .renameCollection(let collection, let newName):
            return "db.\(collection).renameCollection(\"\(newName)\")"
        }
    }

    private static func qdrant(_ change: DataSourceChangeSet) -> String {
        switch change {
        case .insert(let collection, let document):
            return "PUT /collections/\(collection)/points\n\(json(document))"
        case .update(let collection, let id, let patch):
            return "PUT /collections/\(collection)/points (or .../payload)\nid: \(json(id))\n\(json(patch))"
        case .delete(let collection, let id):
            if DataSourceDangerGuard.classify(change) == .confirm(.deleteWithoutFilter) {
                return "POST /collections/\(collection)/points/delete\n{ \"filter\": {} }"
            }
            return "POST /collections/\(collection)/points/delete\n{ \"points\": [\(json(id))] }"
        case .updateByFilter(let collection, let filter, let update, _):
            return "PUT /collections/\(collection)/points (filter)\n\(json(filter))\n\(json(update))"
        case .deleteByFilter(let collection, let filter, _):
            return "POST /collections/\(collection)/points/delete\n{ \"filter\": \(json(filter)) }"
        case .dropCollection(let collection):
            return "DELETE /collections/\(collection)"
        case .createIndex, .dropIndex:
            return "(index management is not supported for Qdrant)"
        case .renameCollection(let collection, let newName):
            return "(rename is not supported for Qdrant: \(collection) → \(newName))"
        }
    }

    private static func elasticsearch(_ change: DataSourceChangeSet) -> String {
        switch change {
        case .insert(let index, let document):
            return "POST /\(index)/_doc\n\(json(document))"
        case .update(let index, let id, let patch):
            return "POST /\(index)/_update/\(idString(id))\n{ \"doc\": \(json(patch)) }"
        case .delete(let index, let id):
            if DataSourceDangerGuard.classify(change) == .confirm(.deleteWithoutFilter) {
                return "POST /\(index)/_delete_by_query\n{ \"query\": { \"match_all\": {} } }"
            }
            return "DELETE /\(index)/_doc/\(idString(id))"
        case .updateByFilter:
            return "(filter-based bulk update is not supported for Elasticsearch — no Painless script support in v1)"
        case .deleteByFilter(let index, let filter, _):
            return "POST /\(index)/_delete_by_query\n{ \"query\": \(json(filter)) }"
        case .dropCollection(let index):
            return "DELETE /\(index)"
        case .createIndex, .dropIndex:
            return "(index management is not supported for Elasticsearch — every field is indexed automatically)"
        case .renameCollection(let index, let newName):
            return "(rename is not supported for Elasticsearch: \(index) → \(newName))"
        }
    }

    private static func idString(_ id: BerryDocument) -> String {
        if case .string(let s) = id { return s }
        return json(id)
    }

    private static func json(_ document: BerryDocument) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: document.jsonObject, options: [.sortedKeys, .fragmentsAllowed]
        ), let string = String(data: data, encoding: .utf8) else {
            return "null"
        }
        return string
    }
}
