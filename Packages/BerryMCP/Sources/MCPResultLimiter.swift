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
/// the number of items it keeps — each kept item is encoded exactly once —
/// never in the number of items considered.
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
    /// returned value never exceeds `limits.maximumSerializedBytes`; the
    /// work done to guarantee that is linear in the number of items kept,
    /// not in the number of items considered.
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
        var redacted = Set<String>()
        func prepare(_ values: [[String: String?]]) -> [[String: String?]] {
            values.map { row in
                let applied = redaction.redact(row)
                redacted.formUnion(applied.columns)
                return applied.row.mapValues { value in
                    guard let value else { return nil }
                    let truncated = truncateCell(value, maximumEncodedBytes: limits.maximumCellBytes)
                    if truncated != value {
                        metadata.truncatedCells += 1
                    }
                    return truncated
                }
            }
        }
        let boundedRows = Array(rows.prefix(limits.maximumRows))
        let boundedObjects = Array(objects.prefix(limits.maximumObjects))
        let boundedNodes = Array(graphNodes.prefix(limits.maximumGraphNodes))
        let boundedEdges = Array(graphEdges.prefix(limits.maximumGraphEdges))
        metadata.omittedRows = rows.count - boundedRows.count
        metadata.omittedObjects = objects.count - boundedObjects.count
        metadata.omittedGraphNodes = graphNodes.count - boundedNodes.count
        metadata.omittedGraphEdges = graphEdges.count - boundedEdges.count
        var result = MCPBoundedResult(
            rows: prepare(boundedRows),
            objects: prepare(boundedObjects),
            graphNodes: prepare(boundedNodes),
            graphEdges: prepare(boundedEdges),
            metadata: metadata
        )
        result.metadata.redactedColumns = redacted.sorted()
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
        result.rows = try keep(result.rows, budget: &budget, omitted: &result.metadata.omittedRows, reached: &result.metadata.byteLimitReached)
        result.objects = try keep(result.objects, budget: &budget, omitted: &result.metadata.omittedObjects, reached: &result.metadata.byteLimitReached)
        result.graphNodes = try keep(result.graphNodes, budget: &budget, omitted: &result.metadata.omittedGraphNodes, reached: &result.metadata.byteLimitReached)
        result.graphEdges = try keep(result.graphEdges, budget: &budget, omitted: &result.metadata.omittedGraphEdges, reached: &result.metadata.byteLimitReached)
        result.metadata.truncated = isTruncated(result.metadata)
        while try encode(result).count > limits.maximumSerializedBytes {
            guard dropLast(from: &result) else {
                throw MCPResultLimiterError.metadataExceedsByteLimit
            }
        }
        return result
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
    /// limit flags set. Sizing the byte budget against this worst case,
    /// rather than the metadata as it stands before any items are dropped,
    /// keeps the later digit growth of the omitted counts from pushing the
    /// encoded result over the ceiling. Bounding by the items actually being
    /// considered, rather than by `MCPResultLimits`' configured maxima,
    /// keeps this tight when far fewer items are present than the
    /// configured ceiling — otherwise the reservation can overshoot the
    /// metadata's real size enough to drop content that would have fit.
    private func pessimisticMetadata(
        _ metadata: MCPTruncationMetadata, rows: Int, objects: Int, graphNodes: Int, graphEdges: Int
    ) -> MCPTruncationMetadata {
        var worst = metadata
        worst.truncated = true
        worst.byteLimitReached = true
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

    private func truncateCell(_ value: String, maximumEncodedBytes: Int) -> String {
        func size(_ string: String) -> Int { (try? JSONEncoder().encode(string).count) ?? Int.max }
        guard size(value) > maximumEncodedBytes else { return value }
        let marker = "…"
        if size(marker) > maximumEncodedBytes { return "" }
        let boundaries = Array(value.indices) + [value.endIndex]
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
        return String(value[..<boundaries[low]]) + marker
    }

    private func emptyResult(with metadata: MCPTruncationMetadata) -> MCPBoundedResult {
        MCPBoundedResult(rows: [], objects: [], graphNodes: [], graphEdges: [], metadata: metadata)
    }

    private func isTruncated(_ metadata: MCPTruncationMetadata) -> Bool {
        metadata.omittedRows + metadata.omittedObjects + metadata.omittedGraphNodes + metadata.omittedGraphEdges + metadata.truncatedCells > 0
            || metadata.byteLimitReached
            || metadata.elapsedLimitReached
    }
}
