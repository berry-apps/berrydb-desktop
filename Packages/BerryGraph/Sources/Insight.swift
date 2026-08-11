import BerryDriverKit
import Foundation

/// A finding produced by an analyzer over the DSG (docs/architecture/11 §7,
/// DI-05/07/09). Deterministic and offline — no LLM, no DBMS access; it reads
/// only the harvested graph + stats. Applying a `suggestedSQL` still goes
/// through SQL preview + DangerGuard like any statement (N1).
public struct Insight: Sendable, Equatable, Identifiable, Codable {
    public enum Severity: Int, Sendable, Comparable, Codable {
        case info = 0, warning = 1, critical = 2
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
        public var label: String {
            switch self {
            case .info: "info"
            case .warning: "warning"
            case .critical: "critical"
            }
        }
    }

    /// Which analyzer produced the finding.
    public enum Category: String, Sendable, Codable {
        case schema // Schema Analyzer (DI-07)
        case index // Index Advisor (DI-05)
        case query // Query Analyzer (DI-06)
    }

    /// Stable across runs (category.rule.target) so the UI can dedupe/track.
    public let id: String
    public let severity: Severity
    public let category: Category
    public let title: String
    public let detail: String
    /// DSG node id the finding is about, for jump-to in the graph/Insight panel.
    public let targetNode: String?
    /// Human name of the table to reveal for this finding (the sidebar/tab jump
    /// target) — the owning table for index findings.
    public let targetName: String?
    /// A starting-point fix, or nil when the fix needs human judgement / more
    /// data (e.g. which column to index — that needs the workload, DI-06).
    public let suggestedSQL: String?

    public init(
        id: String, severity: Severity, category: Category,
        title: String, detail: String,
        targetNode: String? = nil, targetName: String? = nil, suggestedSQL: String? = nil
    ) {
        self.id = id
        self.severity = severity
        self.category = category
        self.title = title
        self.detail = detail
        self.targetNode = targetNode
        self.targetName = targetName
        self.suggestedSQL = suggestedSQL
    }
}

/// Runs every analyzer over a DSG and returns the findings, most severe first
/// (docs/architecture/11 §7 — feeds the Insight Panel, DI-09). Which analyzers
/// run is chosen by the dialect's `DatabasePersona` (DI-27, docs/architecture
/// /13 §5.7) — relational rules never run against a document/key-value/vector
/// dialect, so a Qdrant or Redis connection doesn't get warned for missing a
/// primary key it was never meant to have.
public enum InsightEngine {
    public static func analyze(_ graph: SchemaGraph, dialect: DriverID) -> [Insight] {
        DatabasePersona.persona(for: dialect).analyzers
            .flatMap { $0.analyze(graph, dialect: dialect) }
            .sorted { $0.severity != $1.severity ? $0.severity > $1.severity : $0.id < $1.id }
    }
}
