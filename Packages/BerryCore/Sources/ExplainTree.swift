import BerryDriverKit
import Foundation

/// One node of a query plan tree.
public struct PlanNode: Identifiable, Equatable, Sendable {
    public let id: Int
    public let text: String
    public var children: [PlanNode]

    public init(id: Int, text: String, children: [PlanNode] = []) {
        self.id = id
        self.text = text
        self.children = children
    }
}

extension PlanNode {
    /// Hand-rolled JSON since `PlanNode` deliberately isn't `Codable` (it's a
    /// display type, not a wire contract) — same shape the AI's
    /// `explain_query` tool already builds (BerryAI/QueryToolExecutor.swift),
 /// reused here for Query Replay's stored plan snapshots.
    public static func jsonObject(of nodes: [PlanNode]) -> [[String: Any]] {
        nodes.map { ["id": $0.id, "text": $0.text, "children": jsonObject(of: $0.children)] }
    }

    /// `jsonObject(of:)` serialized to a string for storage (e.g.
    /// `QueryReplaySnapshotRecord.planJSON`). Nil only on a genuine
    /// serialization failure — never a placeholder like "[]", so callers
    /// don't mistake a failed capture for a real empty plan.
    public static func jsonString(of nodes: [PlanNode]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: jsonObject(of: nodes)) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Turns EXPLAIN output rows into a plan tree. Two shapes are
/// recognized; anything else falls back to the flat grid:
/// - SQLite `EXPLAIN QUERY PLAN`: id/parent/…/detail columns.
/// - Postgres `EXPLAIN` / MySQL `EXPLAIN ANALYZE` (TREE): one text column whose
///   lines nest by indentation with "->" operators.
public enum ExplainTreeParser {
    public static func parse(columns: [ColumnMeta], rows: [[BerryValue]]) -> [PlanNode]? {
        guard !rows.isEmpty else { return nil }
        if let tree = parseIDParent(columns: columns, rows: rows) { return tree }
        if let tree = parseIndented(columns: columns, rows: rows) { return tree }
        return nil
    }

    // MARK: - SQLite EXPLAIN QUERY PLAN (id, parent, …, detail)

    private static func parseIDParent(columns: [ColumnMeta], rows: [[BerryValue]]) -> [PlanNode]? {
        let names = columns.map { $0.name.lowercased() }
        guard let idIndex = names.firstIndex(of: "id"),
              let parentIndex = names.firstIndex(of: "parent"),
              let detailIndex = names.firstIndex(of: "detail")
        else { return nil }

        struct Row { let id: Int; let parent: Int; let detail: String }
        let parsed: [Row] = rows.compactMap { row in
            guard case .int(let id) = row[idIndex],
                  case .int(let parent) = row[parentIndex] else { return nil }
            let detail = row[detailIndex].displayString ?? ""
            return Row(id: Int(id), parent: Int(parent), detail: detail)
        }
        guard parsed.count == rows.count else { return nil }

        func build(childrenOf parent: Int) -> [PlanNode] {
            parsed.filter { $0.parent == parent }.map { row in
                PlanNode(id: row.id, text: row.detail, children: build(childrenOf: row.id))
            }
        }
        let roots = build(childrenOf: 0)
        return roots.isEmpty ? nil : roots
    }

    // MARK: - Indented text plans (Postgres, MySQL TREE)

    private static func parseIndented(columns: [ColumnMeta], rows: [[BerryValue]]) -> [PlanNode]? {
        guard columns.count == 1 else { return nil }
        let lines = rows
            .compactMap { $0.first?.displayString }
            .flatMap { $0.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        // Only treat it as a tree when the arrow operators are present.
        guard lines.contains(where: { $0.contains("->") }) else { return nil }

        // Depth = leading-space count; nodes are "-> " lines plus the very first
        // line (the root operator); other lines (Filter:, Index Cond:, costs)
        // attach as leaf details under the most recent node.
        final class Builder {
            let indent: Int
            let text: String
            var children: [Builder] = []
            init(indent: Int, text: String) {
                self.indent = indent
                self.text = text
            }
            func toNode(counter: inout Int) -> PlanNode {
                counter += 1
                let id = counter
                return PlanNode(
                    id: id,
                    text: text,
                    children: children.map { $0.toNode(counter: &counter) }
                )
            }
        }

        var roots: [Builder] = []
        var stack: [Builder] = []

        for line in lines {
            let indent = line.prefix { $0 == " " }.count
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isOperator = trimmed.hasPrefix("->") || stack.isEmpty
            let text = trimmed.hasPrefix("->")
                ? trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
                : trimmed

            if isOperator {
                let node = Builder(indent: indent, text: text)
                while let top = stack.last, top.indent >= indent { stack.removeLast() }
                if let parent = stack.last {
                    parent.children.append(node)
                } else {
                    roots.append(node)
                }
                stack.append(node)
            } else {
                // Detail line → leaf under the nearest shallower node.
                while let top = stack.last, top.indent >= indent { stack.removeLast() }
                let leaf = Builder(indent: indent, text: text)
                if let parent = stack.last {
                    parent.children.append(leaf)
                } else {
                    roots.append(leaf)
                }
            }
        }

        var counter = 0
        let nodes = roots.map { $0.toNode(counter: &counter) }
        return nodes.isEmpty ? nil : nodes
    }
}
