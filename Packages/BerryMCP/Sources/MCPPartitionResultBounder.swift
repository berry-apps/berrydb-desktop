import BerryDriverKit
import Foundation

/// An attribute left out of a returned item because its own JSON entry was
/// larger than the per-attribute limit.
public struct MCPOmittedAttribute: Encodable, Equatable, Sendable {
    /// The item's position in the page DynamoDB returned.
    public let item: Int
    public let name: String
    public let bytes: Int
}

/// An item left out because it could not fit the page's byte ceiling even
/// alone.
public struct MCPSkippedItem: Encodable, Equatable, Sendable {
    /// The item's position in the page DynamoDB returned.
    public let index: Int
    public let bytes: Int
}

/// Fits the items of one DynamoDB page into the result's byte ceiling, in
/// the page's order, measuring each item as the result encodes it
/// (`[.sortedKeys, .withoutEscapingSlashes]`).
///
/// An item that cannot fit even an empty page is skipped and reported, and
/// the items after it are still read, so one oversized item never stops
/// paging; the first item that fits an empty page but not what is left ends
/// the page, so the next page starts with it.
struct MCPPartitionResultBounder {
    struct Bounded: Equatable, Sendable {
        var kept: [[String: DynamoDBAttributeValue]] = []
        /// For each kept item, its position in the page DynamoDB returned.
        var keptIndexes: [Int] = []
        /// For each kept item, its encoded bytes.
        var keptBytes: [Int] = []
        /// For each kept item, the attributes redaction removed from it.
        var keptRedactions: [[String]] = []
        var omittedAttributes: [MCPOmittedAttribute] = []
        var skippedItems: [MCPSkippedItem] = []
        var redactedAttributes: [String] = []
        /// The last item kept or skipped; the item after it is the first
        /// one the result leaves out.
        var lastProcessedIndex: Int?
        var cutByCeiling = false

        /// Gives back the last kept item and every item processed after
        /// it, so the page ends before it; false when no item is kept.
        /// Used when the whole result, cursor and metadata included, does
        /// not fit the ceiling the first pass budgeted with.
        ///
        /// When the dropped item was the first one processed, it is skipped
        /// and reported instead: a page starting at it would carry the same
        /// metadata and drop it again, so paging would never advance.
        mutating func dropLastKept() -> Bool {
            guard let dropped = keptIndexes.popLast() else { return false }
            kept.removeLast()
            let bytes = keptBytes.removeLast()
            keptRedactions.removeLast()
            omittedAttributes.removeAll { $0.item >= dropped }
            skippedItems.removeAll { $0.index > dropped }
            redactedAttributes = Set(keptRedactions.joined()).sorted()
            lastProcessedIndex = [keptIndexes.last, skippedItems.last?.index].compactMap { $0 }.max()
            if lastProcessedIndex == nil {
                skippedItems.append(MCPSkippedItem(index: dropped, bytes: bytes))
                lastProcessedIndex = dropped
            }
            cutByCeiling = true
            return true
        }
    }

    let limits: MCPResultLimits
    /// Bytes of the ceiling held back for the rest of the result.
    let reserve: Int
    /// Lowercased: redaction ignores the attribute name's case, as it does a
    /// SQL column's.
    let redactedAttributes: Set<String>

    init(limits: MCPResultLimits, reserve: Int, redactedAttributes: Set<String>) {
        self.limits = limits
        self.reserve = reserve
        self.redactedAttributes = Set(redactedAttributes.map { $0.lowercased() })
    }

    func bound(_ items: [[String: DynamoDBAttributeValue]]) throws -> Bounded {
        guard reserve < limits.maximumSerializedBytes else { throw MCPResultLimiterError.metadataExceedsByteLimit }
        let budget = limits.maximumSerializedBytes - reserve
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var bounded = Bounded()
        var redacted = Set<String>()
        var remaining = budget
        for (index, original) in items.enumerated() {
            var item = original
            var removed: [String] = []
            for name in item.keys where redactedAttributes.contains(name.lowercased()) {
                removed.append(name)
            }
            for name in removed { item.removeValue(forKey: name) }
            var omitted: [MCPOmittedAttribute] = []
            for name in item.keys.sorted() {
                guard let value = item[name] else { continue }
                let bytes = try encoder.encode([name: value]).count
                if bytes > limits.maximumCellBytes {
                    item.removeValue(forKey: name)
                    omitted.append(MCPOmittedAttribute(item: index, name: Self.reported(name), bytes: bytes))
                }
            }
            let bytes = try encoder.encode(item).count
            // Items are joined by a comma inside the result's array.
            let cost = bytes + (bounded.kept.isEmpty ? 0 : 1)
            if cost > remaining {
                guard bytes > budget else {
                    bounded.cutByCeiling = true
                    break
                }
                bounded.skippedItems.append(MCPSkippedItem(index: index, bytes: bytes))
                bounded.lastProcessedIndex = index
                continue
            }
            remaining -= cost
            bounded.kept.append(item)
            bounded.keptIndexes.append(index)
            bounded.keptBytes.append(bytes)
            bounded.keptRedactions.append(removed)
            bounded.omittedAttributes += omitted
            redacted.formUnion(removed)
            bounded.lastProcessedIndex = index
        }
        bounded.redactedAttributes = redacted.sorted()
        return bounded
    }

    /// An attribute name as `omitted_attributes` reports it. A non-key
    /// attribute name may be up to 64 KB
    /// (https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/HowItWorks.NamingRulesDataTypes.html#HowItWorks.NamingRules),
    /// so a few omitted attributes could otherwise fill the page by their
    /// names alone.
    private static func reported(_ name: String) -> String {
        name.count > 255 ? String(name.prefix(254)) + "…" : name
    }
}
