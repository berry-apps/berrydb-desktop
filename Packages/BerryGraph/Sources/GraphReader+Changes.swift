import BerryStore
import Foundation

extension GraphReader {
    /// One thing a schema change did. `diff` is set for `changed` only, when
    /// both versions have a readable definition; `relation` is set for the
    /// relation kinds, as `source.column -> target.column` with each table
    /// qualified by its namespace when it has one. A relation entry is named
    /// after its source table.
    public struct ChangeEntry: Sendable, Equatable, Codable {
        /// Raw values are snake_case, as every enumerated value the MCP tools
        /// return is.
        public enum Kind: String, Codable, Sendable {
            case added, changed, removed
            case relationAdded = "relation_added"
            case relationRemoved = "relation_removed"
        }
        public let at: Date
        public let kind: Kind
        public let database: String?
        public let name: String
        public let objectKind: String
        public let diff: SchemaDefinitionDiff?
        public let relation: String?
    }

    /// Entries in the order their changes were written. `nextSince` is an
    /// opaque cursor where the next page starts, or nil when no entry
    /// remains: pass it back as `since` to continue.
    public struct ChangePage: Sendable, Equatable {
        public let entries: [ChangeEntry]
        public let nextSince: String?
        public let checkedAt: Date?
    }

    /// A `since` that is neither a change position nor an ISO 8601 date.
    public struct InvalidChangeCursor: Error, Equatable {
        public let text: String
    }

    /// The entries of the changes from `since` on. `since` is nil for every
    /// change, an ISO 8601 date for the changes written at or after it,
    /// `id:<change>` for the changes from that one on, or the `nextSince` of
    /// an earlier page.
    ///
    /// Only the changes of passes that completed are listed: those written at
    /// or before the last check, and none before the first one. A pass stamps
    /// its change and, once it completes, the check with the same instant, so
    /// a pass still running, or one that stopped, is listed only after a later
    /// pass completes, when nothing can add to its change any more.
    ///
    /// A page holds `limit` entries, clamped to 1...`maximumPageSize`, and
    /// can stop inside a change: a first pass records every object under one
    /// change, which must not come back as one response. The entries of one
    /// change are ordered by the namespace, name and kind of their object,
    /// whatever happened to it, and its relations follow by source and target.
    /// Each side of a change is read from an index that holds only that
    /// side's entries, in that order, from where the page starts, so a page
    /// reads what it returns however large its change is.
    ///
    /// `nextSince` names the entry the next page starts at by its row and
    /// side, objects or relations, and counts the entries before it on that
    /// side of its change, which keeps it within the 64 characters the MCP
    /// tool accepts whatever the names are. It resumes at that entry on every
    /// read, whatever changes are written later. When retention has deleted
    /// that entry's version, the page resumes after skipping as many entries
    /// of that side as came before it, which lands on the next entry unless
    /// retention also deleted earlier entries of the same side. Definitions
    /// are read, and diffed, only for the `changed` entries a page returns.
    public func changes(profileID: UUID, since: String?, limit: Int) throws -> ChangePage {
        var afterID: Int64?
        var sinceDate: Date?
        var resume: ChangeCursor.Position?
        switch try since.map(ChangeCursor.init(parsing:)) {
        case let .date(date)?:
            sinceDate = date
        case let .position(position)?:
            afterID = position.changeID - 1
            resume = position
        case nil:
            break
        }
        let pageSize = Self.clampedLimit(limit)
        guard let checkedAt = try state(profileID: profileID).checkedAt else {
            return ChangePage(entries: [], nextSince: nil, checkedAt: nil)
        }
        // One entry past the page is read: it is where the next page starts,
        // and `nextSince` is nil exactly when there is none.
        let wanted = pageSize + 1
        var slots: [Slot] = []
        reading: while true {
            let batch = try store.schemaChanges(
                profileID: profileID, afterID: afterID, since: sinceDate, through: checkedAt, limit: Self.maximumPageSize
            )
            for change in batch {
                guard let id = change.id else { continue }
                let place = resume?.changeID == id ? resume?.place : nil
                slots += try self.slots(of: change, id: id, profileID: profileID, from: place, limit: wanted - slots.count)
                if slots.count == wanted { break reading }
                afterID = id
            }
            if batch.count < Self.maximumPageSize { break }
        }
        let nextSince = slots.count > pageSize ? ChangeCursor.text(of: slots[pageSize].position) : nil
        return ChangePage(entries: try entries(for: slots.prefix(pageSize)), nextSince: nextSince, checkedAt: checkedAt)
    }

    /// The change rows of the profile, newest first, under the same gate as
    /// `changes`: only those written at or before the last check, so a pass
    /// still running, whose change can still grow, is not listed yet.
    public func changeMarks(profileID: UUID) throws -> [SchemaChangeRecord] {
        guard let checkedAt = try state(profileID: profileID).checkedAt else { return [] }
        return try store.schemaChangeMarks(profileID: profileID).filter { $0.at <= checkedAt }
    }

    /// An entry before its diff is read, with the cursor of a page that would
    /// start at it: a `changed` one carries the ids of its two versions.
    private struct Slot {
        let entry: ChangeEntry
        let position: ChangeCursor.Position
        let versions: (current: Int64, previous: Int64)?
    }

    /// At most `limit` entries of one change from `place` on, or from its
    /// start when `place` is nil: its object entries, then its relation
    /// entries. A place whose entry no longer exists is found again by the
    /// number of entries of its side before it.
    private func slots(
        of change: SchemaChangeRecord, id: Int64, profileID: UUID, from place: ChangeCursor.Place?, limit: Int
    ) throws -> [Slot] {
        var slots: [Slot] = []
        var relationsFrom: (SchemaRelationChangePosition?, offset: Int) = (nil, 0)
        switch place {
        case let .relation(row, introduced, offset)?:
            relationsFrom = (
                try store.schemaRelationChangePosition(profileID: profileID, changeID: id, id: row, introduced: introduced), offset
            )
        case let .object(row, introduced, offset)?:
            let from = try store.schemaObjectChangePosition(profileID: profileID, changeID: id, id: row, introduced: introduced)
            slots = try objectSlots(of: change, id: id, profileID: profileID, from: from, offset: offset, limit: limit)
        case nil:
            slots = try objectSlots(of: change, id: id, profileID: profileID, from: nil, offset: 0, limit: limit)
        }
        guard slots.count < limit else { return slots }
        let (from, offset) = relationsFrom
        let relations = try store.schemaRelationChangeEntries(
            profileID: profileID, changeID: id, from: from, skipping: from == nil ? offset : 0, limit: limit - slots.count
        )
        return slots + relations.enumerated().map { index, relation in
            Slot(
                entry: ChangeEntry(at: change.at, kind: relation.introduced ? .relationAdded : .relationRemoved, relation: relation.ends),
                position: ChangeCursor.Position(
                    changeID: id, place: .relation(
                        row: relation.id, introduced: relation.introduced, offset: ChangeCursor.offset(offset, plus: index)
                    )
                ),
                versions: nil
            )
        }
    }

    /// The object entries of one change from `from`, which is `offset`
    /// entries in, or from the start skipping `offset` entries when `from`
    /// is nil.
    private func objectSlots(
        of change: SchemaChangeRecord, id: Int64, profileID: UUID, from: SchemaObjectChangePosition?, offset: Int, limit: Int
    ) throws -> [Slot] {
        let objects = try store.schemaObjectChangeEntries(
            profileID: profileID, changeID: id, from: from, skipping: from == nil ? offset : 0, limit: limit
        )
        return objects.enumerated().map { index, object in
            let position = object.position
            let kind: ChangeEntry.Kind = position.introduced ? (object.previousID == nil ? .added : .changed) : .removed
            return Slot(
                entry: ChangeEntry(at: change.at, kind: kind, object: position),
                position: ChangeCursor.Position(
                    changeID: id, place: .object(
                        row: position.id, introduced: position.introduced, offset: ChangeCursor.offset(offset, plus: index)
                    )
                ),
                versions: kind == .changed ? object.previousID.map { (position.id, $0) } : nil
            )
        }
    }

    /// The entries of `slots`, with a diff for each `changed` one. Only these
    /// slots' versions are read with their definitions, in one statement.
    /// Retention can delete the earlier version; the change is then reported
    /// without a diff.
    private func entries(for slots: ArraySlice<Slot>) throws -> [ChangeEntry] {
        let ids = slots.flatMap { slot in slot.versions.map { [$0.current, $0.previous] } ?? [] }
        var definitions: [Int64: SchemaDefinition] = [:]
        for (id, json) in try store.schemaObjectDefinitions(ids: ids) {
            if let definition = try? SchemaDefinition.decode(json) { definitions[id] = definition }
        }
        return slots.map { slot in
            guard let versions = slot.versions else { return slot.entry }
            let diff = definitions[versions.previous].flatMap { old in
                definitions[versions.current].map { SchemaDefinition.diff(from: old, to: $0) }
            }
            return slot.entry.with(diff: diff)
        }
    }
}

/// A change cursor: the changes written at or after a date, or the changes
/// from one on, from one of its entries when the cursor names one.
///
/// A page's `nextSince` is `id:<change>:<side><row><i|c><offset>`: the side,
/// `o` for objects or `r` for relations, the row of the entry the next page
/// starts at, whether the change introduced or closed that row, and how many
/// entries of that side of the change come before it. A page starts at the
/// entry's key, which is looked up by the row. The cursor holds no name,
/// only three numbers between fixed letters, so it stays within 64
/// characters whatever the names are. The offset finds the place again only when the
/// row no longer exists.
private enum ChangeCursor {
    case date(Date)
    case position(Position)

    struct Position {
        let changeID: Int64
        /// Nil for the start of the change.
        let place: Place?
    }

    enum Place {
        case object(row: Int64, introduced: Bool, offset: Int)
        case relation(row: Int64, introduced: Bool, offset: Int)
    }

    /// The largest offset a cursor may carry. One side of a change holds an
    /// entry per version or relation row the change wrote or closed, and the
    /// harvest asks for a narrower scope above 20,000 objects, so no reachable
    /// offset comes near 2^31 - 1. A larger one is refused as an invalid
    /// cursor: counted up while a page is read, it could pass `Int.max` and
    /// trap, ending the process that serves the request.
    static let maximumOffset = Int(Int32.max)

    /// The offset of the entry `index` places after one at `offset`. Parsing
    /// bounds `offset`, so the sum cannot overflow; it saturates rather than
    /// trap if it ever did, and the saturated cursor is then refused.
    static func offset(_ offset: Int, plus index: Int) -> Int {
        let (sum, overflow) = offset.addingReportingOverflow(index)
        return overflow ? .max : sum
    }

    init(parsing text: String) throws {
        if text.hasPrefix("id:") {
            let parts = text.dropFirst(3).split(separator: ":", omittingEmptySubsequences: false)
            guard (1...2).contains(parts.count), let changeID = Int64(parts[0]), changeID >= 0 else {
                throw GraphReader.InvalidChangeCursor(text: text)
            }
            var place: Place?
            if parts.count == 2 {
                guard let decoded = Self.place(parsing: parts[1]) else { throw GraphReader.InvalidChangeCursor(text: text) }
                place = decoded
            }
            self = .position(Position(changeID: changeID, place: place))
            return
        }
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = plain.date(from: text) ?? fractional.date(from: text) else {
            throw GraphReader.InvalidChangeCursor(text: text)
        }
        self = .date(date)
    }

    static func text(of position: Position) -> String {
        guard let place = position.place else { return "id:\(position.changeID)" }
        switch place {
        case let .object(row, introduced, offset):
            return "id:\(position.changeID):o\(row)\(introduced ? "i" : "c")\(offset)"
        case let .relation(row, introduced, offset):
            return "id:\(position.changeID):r\(row)\(introduced ? "i" : "c")\(offset)"
        }
    }

    /// The place `text(of:)` wrote, or nil for any text it cannot have
    /// written, such as the bare entry offset an earlier build wrote.
    private static func place(parsing text: Substring) -> Place? {
        guard let side = text.first, side == "o" || side == "r",
              let marker = text.firstIndex(where: { $0 == "i" || $0 == "c" }),
              let row = Int64(text[text.index(after: text.startIndex)..<marker]), row >= 0,
              let offset = Int(text[text.index(after: marker)...]), (0...maximumOffset).contains(offset)
        else { return nil }
        let introduced = text[marker] == "i"
        return side == "o"
            ? .object(row: row, introduced: introduced, offset: offset)
            : .relation(row: row, introduced: introduced, offset: offset)
    }
}

extension GraphReader.ChangeEntry {
    fileprivate init(at: Date, kind: Kind, object: SchemaObjectChangePosition) {
        self.init(
            at: at, kind: kind, database: object.database, name: object.name, objectKind: object.kind,
            diff: nil, relation: nil
        )
    }

    fileprivate init(at: Date, kind: Kind, relation: SchemaRelationEnds) {
        func qualified(_ database: String?, _ name: String, _ column: String) -> String {
            [database, name, column].compactMap { $0 }.joined(separator: ".")
        }
        self.init(
            at: at, kind: kind, database: relation.srcDatabase, name: relation.srcName, objectKind: "table", diff: nil,
            relation: qualified(relation.srcDatabase, relation.srcName, relation.srcColumn)
                + " -> " + qualified(relation.dstDatabase, relation.dstName, relation.dstColumn)
        )
    }

    fileprivate func with(diff: SchemaDefinitionDiff?) -> Self {
        Self(at: at, kind: kind, database: database, name: name, objectKind: objectKind, diff: diff, relation: relation)
    }
}
