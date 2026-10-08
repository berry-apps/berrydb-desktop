import Foundation

/// Caps applied to a query result before `MCPResultLimiter` returns it to an
/// MCP client. Every count is inclusive — `maximumRows` items are kept, the
/// (`maximumRows` + 1)th is the first omission — and `maximumSerializedBytes`
/// bounds the JSON-encoded size of the whole `MCPBoundedResult`, including
/// its metadata, not just the item arrays.
public struct MCPResultLimits: Sendable, Equatable {
    public var maximumRows: Int
    public var maximumObjects: Int
    public var maximumGraphNodes: Int
    public var maximumGraphEdges: Int
    public var maximumCellBytes: Int
    public var maximumSerializedBytes: Int
    public var maximumElapsed: Duration

    public init(
        maximumRows: Int = 100,
        maximumObjects: Int = 200,
        maximumGraphNodes: Int = 500,
        maximumGraphEdges: Int = 1_000,
        maximumCellBytes: Int = 65_536,
        maximumSerializedBytes: Int = 1_048_576,
        maximumElapsed: Duration = .seconds(30)
    ) {
        self.maximumRows = maximumRows
        self.maximumObjects = maximumObjects
        self.maximumGraphNodes = maximumGraphNodes
        self.maximumGraphEdges = maximumGraphEdges
        self.maximumCellBytes = maximumCellBytes
        self.maximumSerializedBytes = maximumSerializedBytes
        self.maximumElapsed = maximumElapsed
    }
}

/// Counts and flags describing what `MCPResultLimiter.limit(...)` removed or
/// changed to satisfy `MCPResultLimits`. An agent reading a bounded result
/// can tell, from these fields alone, whether more data exists beyond what
/// was returned and whether a value was redacted rather than genuinely
/// absent — it never has to guess from a truncated payload.
public struct MCPTruncationMetadata: Codable, Sendable, Equatable {
    public var truncated: Bool
    public var omittedRows: Int
    public var omittedObjects: Int
    public var omittedGraphNodes: Int
    public var omittedGraphEdges: Int
    public var truncatedCells: Int
    public var byteLimitReached: Bool
    public var elapsedLimitReached: Bool
    public var redactedColumns: [String]
}

/// A query result bounded to `MCPResultLimits`. Its JSON encoding never
/// exceeds `limits.maximumSerializedBytes` — `MCPResultLimiter.limit(...)`
/// guarantees this exactly, not approximately, by accounting for every byte
/// it keeps.
public struct MCPBoundedResult: Codable, Sendable, Equatable {
    public var rows: [[String: String?]]
    public var objects: [[String: String?]]
    public var graphNodes: [[String: String?]]
    public var graphEdges: [[String: String?]]
    public var metadata: MCPTruncationMetadata
}

/// Errors from bounding or serializing a query result.
public enum MCPResultLimiterError: Error, Equatable {
    /// A `MCPResultLimits` value was internally inconsistent (a negative
    /// count/byte limit, a negative `maximumElapsed`, or a negative
    /// `elapsed` argument to `limit(...)`).
    case invalidLimits
    /// Even an empty result's metadata does not fit in
    /// `maximumSerializedBytes`; there is no valid `MCPBoundedResult` to
    /// return.
    case metadataExceedsByteLimit
    /// `serialized(_:)` was given a `MCPBoundedResult` whose encoding
    /// exceeds `limits.maximumSerializedBytes`.
    case serializedByteLimitExceeded
}

/// Bounds a query result to `MCPResultLimits`: caps item counts, truncates
/// individual cell values, redacts sensitive columns, and enforces an exact
/// ceiling on the JSON-encoded byte size. `limit(...)`'s cost is linear in
/// the input size (not just count — redaction and cell truncation scan each
/// item's content) of the items that survive the count-based trim, plus the
/// number of bytes in the items the byte budget actually keeps — each kept
/// item is encoded exactly once — never quadratic in either dimension. A
/// count-trimmed item that the byte budget later omits still costs
/// preparation work proportional to its own size; only an item cut by the
/// count trim itself is free.
public struct MCPResultLimiter: Sendable {
    public let limits: MCPResultLimits
    private let encode: @Sendable (any Encodable) throws -> Data

    public init(limits: MCPResultLimits = MCPResultLimits()) {
        self.limits = limits
        self.encode = MCPResultLimiter.defaultEncode
    }

    /// Test-only seam: lets a test meter the encoding work `limit(...)` does
    /// without needing its own `JSONEncoder`.
    init(limits: MCPResultLimits, encode: @escaping @Sendable (any Encodable) throws -> Data) {
        self.limits = limits
        self.encode = encode
    }

    private static func defaultEncode(_ value: any Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    /// Bounds `rows`, `objects`, `graphNodes` and `graphEdges` to `limits`
    /// and returns the result together with metadata describing every
    /// omission, truncation and redaction. The JSON encoding of the
    /// returned value never exceeds `limits.maximumSerializedBytes`. The
    /// work done to guarantee that is linear in the input size of the items
    /// that survive each array's count-based trim (redaction and cell
    /// truncation scan every such item's content, whether or not the byte
    /// budget later keeps it), plus the number of bytes in the items the
    /// byte budget actually keeps — never quadratic in either dimension.
    public func limit(
        rows: [[String: String?]] = [],
        objects: [[String: String?]] = [],
        graphNodes: [[String: String?]] = [],
        graphEdges: [[String: String?]] = [],
        elapsed: Duration = .zero,
        redaction: MCPRedactionPolicy = MCPRedactionPolicy()
    ) throws -> MCPBoundedResult {
        guard limits.maximumRows >= 0,
              limits.maximumObjects >= 0,
              limits.maximumGraphNodes >= 0,
              limits.maximumGraphEdges >= 0,
              limits.maximumCellBytes >= 2,
              limits.maximumSerializedBytes > 0,
              limits.maximumElapsed >= .zero,
              elapsed >= .zero
        else {
            throw MCPResultLimiterError.invalidLimits
        }
        var metadata = MCPTruncationMetadata(
            truncated: false,
            omittedRows: 0,
            omittedObjects: 0,
            omittedGraphNodes: 0,
            omittedGraphEdges: 0,
            truncatedCells: 0,
            byteLimitReached: false,
            elapsedLimitReached: elapsed > limits.maximumElapsed,
            redactedColumns: []
        )
        // Shared across the whole call so cell-size measurement matches
        // exactly how the result itself gets encoded (see `truncateCell`).
        let cellEncoder = JSONEncoder()
        cellEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        let boundedRows = Array(rows.prefix(limits.maximumRows))
        let boundedObjects = Array(objects.prefix(limits.maximumObjects))
        let boundedNodes = Array(graphNodes.prefix(limits.maximumGraphNodes))
        let boundedEdges = Array(graphEdges.prefix(limits.maximumGraphEdges))
        metadata.omittedRows = rows.count - boundedRows.count
        metadata.omittedObjects = objects.count - boundedObjects.count
        metadata.omittedGraphNodes = graphNodes.count - boundedNodes.count
        metadata.omittedGraphEdges = graphEdges.count - boundedEdges.count

        let preparedRows = prepare(boundedRows, redaction: redaction, cellEncoder: cellEncoder)
        let preparedObjects = prepare(boundedObjects, redaction: redaction, cellEncoder: cellEncoder)
        let preparedNodes = prepare(boundedNodes, redaction: redaction, cellEncoder: cellEncoder)
        let preparedEdges = prepare(boundedEdges, redaction: redaction, cellEncoder: cellEncoder)
        // Every prepared item could still be dropped by the byte budget
        // below; using the full prepared count/columns here is a safe
        // upper bound for sizing that budget, corrected to the rows
        // actually kept once the budget has run (see the recomputation
        // after `keep(...)`).
        let allPrepared = [preparedRows, preparedObjects, preparedNodes, preparedEdges]
        metadata.truncatedCells = allPrepared
            .reduce(0) { $0 + $1.reduce(0) { $0 + $1.truncatedCellCount } }
        metadata.redactedColumns = Set(allPrepared.flatMap { $0.flatMap(\.redactedColumns) })
            .sorted()

        var result = MCPBoundedResult(
            rows: preparedRows.map(\.values),
            objects: preparedObjects.map(\.values),
            graphNodes: preparedNodes.map(\.values),
            graphEdges: preparedEdges.map(\.values),
            metadata: metadata
        )
        result.metadata.truncated = isTruncated(result.metadata)

        // Every kept item is encoded once and its size accumulated, so cost is
        // linear in the items kept. A JSON array of n items costs 2 + sizes +
        // (n-1) bytes, which makes the running total exact for the arrays; only
        // the metadata can grow as omitted counts gain digits, so the final
        // check below may drop a few more items but never loops over the whole
        // result.
        let worstCaseMetadata = pessimisticMetadata(
            result.metadata,
            rows: result.rows.count,
            objects: result.objects.count,
            graphNodes: result.graphNodes.count,
            graphEdges: result.graphEdges.count
        )
        var budget = limits.maximumSerializedBytes - (try encode(emptyResult(with: worstCaseMetadata)).count)
        guard budget >= 0 else {
            throw MCPResultLimiterError.metadataExceedsByteLimit
        }
        result.rows = try keep(
            result.rows,
            budget: &budget,
            omitted: &result.metadata.omittedRows,
            reached: &result.metadata.byteLimitReached
        )
        result.objects = try keep(
            result.objects,
            budget: &budget,
            omitted: &result.metadata.omittedObjects,
            reached: &result.metadata.byteLimitReached
        )
        result.graphNodes = try keep(
            result.graphNodes,
            budget: &budget,
            omitted: &result.metadata.omittedGraphNodes,
            reached: &result.metadata.byteLimitReached
        )
        result.graphEdges = try keep(
            result.graphEdges,
            budget: &budget,
            omitted: &result.metadata.omittedGraphEdges,
            reached: &result.metadata.byteLimitReached
        )
        // `keep(...)` only ever keeps a prefix of what it is given, so the
        // final counts here are exactly how many of each prepared array
        // survived; recompute the counters that depend on which specific
        // items those were, rather than leaving them at the pre-budget
        // (superset) values used only to size the reservation above.
        result.metadata.truncatedCells = [
            (preparedRows, result.rows.count), (preparedObjects, result.objects.count),
            (preparedNodes, result.graphNodes.count), (preparedEdges, result.graphEdges.count),
        ].reduce(0) { $0 + $1.0.prefix($1.1).reduce(0) { $0 + $1.truncatedCellCount } }
        result.metadata.redactedColumns = Set([
            preparedRows.prefix(result.rows.count), preparedObjects.prefix(result.objects.count),
            preparedNodes.prefix(result.graphNodes.count), preparedEdges.prefix(result.graphEdges.count),
        ].flatMap { $0.flatMap(\.redactedColumns) }).sorted()
        result.metadata.truncated = isTruncated(result.metadata)
        while try encode(result).count > limits.maximumSerializedBytes {
            guard dropLast(from: &result) else {
                throw MCPResultLimiterError.metadataExceedsByteLimit
            }
        }
        return result
    }

    /// One item after redaction and cell truncation, kept alongside what
    /// was done to it so the metadata counters can later be recomputed
    /// over only the items the byte budget actually keeps.
    private struct PreparedItem {
        let values: [String: String?]
        let redactedColumns: [String]
        let truncatedCellCount: Int
    }

    private func prepare(
        _ values: [[String: String?]], redaction: MCPRedactionPolicy, cellEncoder: JSONEncoder
    ) -> [PreparedItem] {
        values.map { row in
            let applied = redaction.redact(row)
            var truncatedCellCount = 0
            let mapped = applied.row.mapValues { value -> String? in
                guard let value else { return nil }
                let truncated = truncateCell(value, maximumEncodedBytes: limits.maximumCellBytes, encoder: cellEncoder)
                if truncated != value {
                    truncatedCellCount += 1
                }
                return truncated
            }
            return PreparedItem(values: mapped, redactedColumns: applied.columns, truncatedCellCount: truncatedCellCount)
        }
    }

    /// Encodes `result` and enforces `limits.maximumSerializedBytes` on the
    /// output. `limit(...)` already produces a result inside the ceiling;
    /// this exists to fail closed if a `MCPBoundedResult` reaches this call
    /// by some other path (for example, one assembled directly in a test).
    public func serialized(_ result: MCPBoundedResult) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(result)
        guard data.count <= limits.maximumSerializedBytes else {
            throw MCPResultLimiterError.serializedByteLimitExceeded
        }
        return data
    }

    /// Keeps the longest prefix of `items` that fits in `budget`, charging
    /// each item's encoded size plus one separator byte after the first.
    private func keep(
        _ items: [[String: String?]], budget: inout Int, omitted: inout Int, reached: inout Bool
    ) throws -> [[String: String?]] {
        var kept: [[String: String?]] = []
        for (offset, item) in items.enumerated() {
            let cost = try encode(item).count + (kept.isEmpty ? 0 : 1)
            guard cost <= budget else {
                omitted += items.count - offset
                reached = true
                break
            }
            budget -= cost
            kept.append(item)
        }
        return kept
    }

    /// Metadata as large as truncation can make it: every omitted count at
    /// the widest value `keep(...)` could still produce — the count already
    /// omitted by the count-based prefix trim, plus every item currently
    /// being considered for that array, in case none of them fit — and both
    /// limit flags set to whichever spelling encodes wider. `false` (5
    /// bytes) is wider than `true` (4 bytes), so the reservation uses
    /// `false` for both, even though a value of `true` is what "as large as
    /// truncation can make it" would suggest at a glance — encoded size,
    /// not semantic pessimism about whether truncation happened, is what
    /// this reservation has to bound. Sizing the byte budget against this
    /// genuine worst case, rather than the metadata as it stands before any
    /// items are dropped, keeps the later digit growth of the omitted
    /// counts — and any swing in the boolean fields' encoded width — from
    /// pushing the encoded result over the ceiling, so the final correction
    /// loop below normally runs zero times. Bounding by the items actually
    /// being considered, rather than by `MCPResultLimits`' configured
    /// maxima, keeps the digit-growth part of this tight when far fewer
    /// items are present than the configured ceiling — otherwise the
    /// reservation can overshoot the metadata's real size enough to drop
    /// content that would have fit.
    private func pessimisticMetadata(
        _ metadata: MCPTruncationMetadata, rows: Int, objects: Int, graphNodes: Int, graphEdges: Int
    ) -> MCPTruncationMetadata {
        var worst = metadata
        worst.truncated = false
        worst.byteLimitReached = false
        worst.omittedRows = metadata.omittedRows + rows
        worst.omittedObjects = metadata.omittedObjects + objects
        worst.omittedGraphNodes = metadata.omittedGraphNodes + graphNodes
        worst.omittedGraphEdges = metadata.omittedGraphEdges + graphEdges
        return worst
    }

    /// Final-correction step: removes one item, lowest-priority array first
    /// (edges, then nodes, then objects, then rows — rows are what a query
    /// asked for). The budget in `limit(...)` is sized against
    /// `pessimisticMetadata`, so this normally runs zero times; it exists to
    /// fail closed rather than silently exceed the ceiling if it ever does.
    private func dropLast(from result: inout MCPBoundedResult) -> Bool {
        result.metadata.byteLimitReached = true
        result.metadata.truncated = true
        if !result.graphEdges.isEmpty {
            result.graphEdges.removeLast()
            result.metadata.omittedGraphEdges += 1
            return true
        }
        if !result.graphNodes.isEmpty {
            result.graphNodes.removeLast()
            result.metadata.omittedGraphNodes += 1
            return true
        }
        if !result.objects.isEmpty {
            result.objects.removeLast()
            result.metadata.omittedObjects += 1
            return true
        }
        if !result.rows.isEmpty {
            result.rows.removeLast()
            result.metadata.omittedRows += 1
            return true
        }
        return false
    }

    /// Measures candidate substrings with `encoder` — the same encoder
    /// configuration (`.withoutEscapingSlashes` in particular) used for the
    /// result itself, created once per `limit(...)` call — so a cell
    /// containing `/` is not measured as larger here than it actually ends
    /// up being in the final output, which would truncate more than
    /// necessary.
    private func truncateCell(_ value: String, maximumEncodedBytes: Int, encoder: JSONEncoder) -> String {
        Self.truncatedCell(value, maximumEncodedBytes: maximumEncodedBytes, encoder: encoder).value
    }

    /// Truncates `value` to the longest whole-character prefix that, with
    /// a trailing `…`, encodes within `maximumEncodedBytes`; returns it with
    /// the number of characters indexed to find it, which tests use to
    /// check the work stays bounded by the ceiling rather than by the cell.
    ///
    /// JSON encoding writes each UTF-8 byte as one to six bytes, plus two
    /// quotes. So a value of at most `(maximumEncodedBytes - 2) / 6` UTF-8
    /// bytes always fits and is returned without encoding; a value whose
    /// UTF-8 count alone exceeds the ceiling never fits and is never encoded
    /// whole. When truncating, no prefix longer than the ceiling minus the
    /// encoded marker in UTF-8 bytes can fit, so characters are indexed
    /// only up to that many bytes — at most `maximumEncodedBytes`
    /// characters, however long the cell is — before the binary search.
    /// Indexing stays on `Character` boundaries, so a grapheme cluster is
    /// never split and no replacement character is introduced.
    static func truncatedCell(
        _ value: String, maximumEncodedBytes: Int, encoder: JSONEncoder
    ) -> (value: String, examinedCharacters: Int) {
        func size(_ string: String) -> Int { (try? encoder.encode(string).count) ?? Int.max }
        let utf8Count = value.utf8.count
        if utf8Count <= (maximumEncodedBytes - 2) / 6 { return (value, 0) }
        if utf8Count + 2 <= maximumEncodedBytes, size(value) <= maximumEncodedBytes { return (value, 0) }
        let marker = "…"
        let markerSize = size(marker)
        if markerSize > maximumEncodedBytes { return ("", 0) }
        let prefixByteBudget = maximumEncodedBytes - markerSize
        var boundaries = [value.startIndex]
        var examined = 0
        var prefixBytes = 0
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(after: index)
            examined += 1
            prefixBytes += value.utf8.distance(from: index, to: next)
            guard prefixBytes <= prefixByteBudget else { break }
            boundaries.append(next)
            index = next
        }
        var low = 0
        var high = boundaries.count - 1
        while low < high {
            let midpoint = (low + high + 1) / 2
            let candidate = String(value[..<boundaries[midpoint]]) + marker
            if size(candidate) <= maximumEncodedBytes {
                low = midpoint
            } else {
                high = midpoint - 1
            }
        }
        return (String(value[..<boundaries[low]]) + marker, examined)
    }

    private func emptyResult(with metadata: MCPTruncationMetadata) -> MCPBoundedResult {
        MCPBoundedResult(rows: [], objects: [], graphNodes: [], graphEdges: [], metadata: metadata)
    }

    private func isTruncated(_ metadata: MCPTruncationMetadata) -> Bool {
        let omittedOrTruncatedCount = metadata.omittedRows + metadata.omittedObjects
            + metadata.omittedGraphNodes + metadata.omittedGraphEdges + metadata.truncatedCells
        return omittedOrTruncatedCount > 0
            || metadata.byteLimitReached
            || metadata.elapsedLimitReached
    }
}
