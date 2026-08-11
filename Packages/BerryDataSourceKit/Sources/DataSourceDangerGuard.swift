import Foundation

/// Danger classification for a `DataSourceChangeSet` about to run — the
/// non-SQL sibling of `DangerGuard` (BerryCore, docs/architecture/07 §6).
/// SQL `DangerGuard` parses statement TEXT; document/vector stores have no
/// text to parse, so this classifies by QUERY STRUCTURE instead
/// (docs/architecture/12 §6, NS-08). Deliberately separate from BerryCore's
/// `DangerGuard` — the SQL classifier and its tests stay untouched.
public enum DataSourceDangerLevel: Equatable, Sendable {
    case safe
    case confirm(DataSourceDangerReason)
    /// Mirrors SQL's `DangerLevel.typedConfirm` (`DangerGuard.swift`,
    /// docs/architecture/07 §6 CT-04) — the user must retype the exact
    /// object name, not just click a button, for an operation with no
    /// filter to scope its blast radius.
    case typedConfirm(objectName: String, reason: DataSourceDangerReason)
}

public enum DataSourceDangerReason: Equatable, Sendable {
    /// A delete with no id/filter targets — structurally the same risk as SQL
    /// DELETE without WHERE (docs/architecture/12 §6): every point/document in
    /// the collection matches, so this deletes the whole collection.
    case deleteWithoutFilter
    case updateWithoutFilter
    /// `drop()` — paired only with `.typedConfirm`.
    case dropCollection
    /// `dropIndex(...)` — paired only with the plain `.confirm` (reversible).
    case dropIndex
}

/// Lives in `BerryDataSourceKit` (not `BerryDriverQdrant`) because it operates
/// only on the shared `DataSourceChangeSet`/`BerryDocument` types — the same
/// "empty id = no filter" shape also applies to Mongo's `deleteMany`/
/// `updateMany` with `{}` (docs/architecture/12 §6), not just Qdrant.
public enum DataSourceDangerGuard {
    public static func classify(_ change: DataSourceChangeSet) -> DataSourceDangerLevel {
        switch change {
        case .delete(_, let id):
            return isEmptyDocument(id) ? .confirm(.deleteWithoutFilter) : .safe
        case .insert, .update:
            return .safe
        case .deleteByFilter(_, let filter, _):
            return isEmptyDocument(filter) ? .confirm(.deleteWithoutFilter) : .safe
        case .updateByFilter(_, let filter, _, _):
            return isEmptyDocument(filter) ? .confirm(.updateWithoutFilter) : .safe
        case .dropCollection(let collection):
            return .typedConfirm(objectName: collection, reason: .dropCollection)
        case .createIndex, .renameCollection:
            return .safe
        case .dropIndex:
            return .confirm(.dropIndex)
        }
    }

    /// `.null` or an empty object/string stands in for "no filter" — used both
    /// for `.delete`'s `id` (whose contract carries only an id, not a separate
    /// filter field, so an empty id IS the no-filter case) and for
    /// `.deleteByFilter`/`.updateByFilter`'s `filter` (docs/architecture/12 §6).
    private static func isEmptyDocument(_ id: BerryDocument) -> Bool {
        switch id {
        case .null: return true
        case .object(let fields): return fields.isEmpty
        case .string(let s): return s.isEmpty
        default: return false
        }
    }
}
