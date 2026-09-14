import BerryDriverKit
import Foundation

/// Quantifies blast radius against the actual workload instead of
/// just topology. Ranks affected queries
/// by how often they actually ran, so a change touching a query called 12M
/// times/day surfaces above one called 15 times/day — topology alone treats
/// them the same.
///
/// v1 scope: topology + call-frequency ranking only, computed entirely from
/// the already-harvested DSG and local query history — no
/// DBMS access. A quantified latency estimate needs a live hypothetical-index
/// capable EXPLAIN (Postgres + `hypopg`) and is a documented follow-up, not
/// guessed at here (.1 — `IndexAdvisor`'s existing
/// `confidence` precedent: report less rather than report wrong).
public enum ImpactSimulator {
    public struct AffectedQuery: Sendable, Equatable {
        public let sql: String
        public let frequency: Int
    }

    public struct Report: Sendable, Equatable {
        /// Tables that would be affected — the node itself (or its owning
        /// table, for an index) plus everything reachable via blast radius.
        public let affectedTables: [String]
        /// Distinct recent queries touching an affected table, most-called first.
        public let affectedQueries: [AffectedQuery]

        public var totalCallCount: Int { affectedQueries.reduce(0) { $0 + $1.frequency } }
    }

    /// Simulates dropping/changing `nodeID` (a table or index in `graph`):
 /// which tables would break (blast radius) and, of the recent
    /// `workload`, which queries actually touch those tables — ranked by call
    /// frequency. Empty report when the node is unknown.
    public static func simulate(changing nodeID: String, in graph: SchemaGraph, workload: [String]) -> Report {
        let tableNames = blastRadiusTableNames(of: nodeID, in: graph)
        guard !tableNames.isEmpty else {
            return Report(affectedTables: [], affectedQueries: [])
        }

        var frequency: [String: Int] = [:]
        for sql in workload {
            let normalized = normalize(sql)
            guard !normalized.isEmpty, tableNames.contains(where: { references($0, in: sql) }) else { continue }
            frequency[normalized, default: 0] += 1
        }

        let affectedQueries = frequency
            .map { AffectedQuery(sql: $0.key, frequency: $0.value) }
            .sorted { $0.frequency != $1.frequency ? $0.frequency > $1.frequency : $0.sql < $1.sql }

        return Report(affectedTables: tableNames.sorted(), affectedQueries: affectedQueries)
    }

    // MARK: - Helpers

    /// The node's own table (an index's OWNING table, since that's what
    /// queries actually touch) plus everything that would break with it.
    private static func blastRadiusTableNames(of nodeID: String, in graph: SchemaGraph) -> Set<String> {
        guard let node = graph.nodes[nodeID] else { return [] }
        let anchor: String
        if node.kind == .index,
           let owner = graph.neighbors(of: nodeID, direction: .incoming, kinds: [.hasIndex]).first {
            anchor = owner
        } else {
            anchor = nodeID
        }
        var ids = graph.blastRadius(of: anchor)
        ids.insert(anchor)
        return Set(ids.compactMap { graph.nodes[$0] }.filter { $0.kind == .table }.map(\.name))
    }

    /// Whole-word, case-insensitive match — enough to tell "touches this
    /// table" from "happens to contain the substring" without a SQL parser.
    private static func references(_ table: String, in sql: String) -> Bool {
        guard !table.isEmpty else { return false }
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: table))\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return false }
        return regex.firstMatch(in: sql, range: NSRange(sql.startIndex..., in: sql)) != nil
    }

    /// Collapse whitespace so trivially-different spellings count as one query.
    private static func normalize(_ sql: String) -> String {
        sql.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0.isNewline })
            .joined(separator: " ")
    }
}
