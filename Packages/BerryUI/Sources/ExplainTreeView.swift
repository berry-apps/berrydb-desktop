import BerryCore
import SwiftUI

private extension PlanNode {
    /// OutlineGroup wants nil for leaves.
    var outlineChildren: [PlanNode]? { children.isEmpty ? nil : children }
}

/// Query-plan tree renderer: EXPLAIN results shown as an expandable
/// operator tree instead of a flat grid.
struct ExplainTreeView: View {
    let nodes: [PlanNode]

    var body: some View {
        List(nodes, children: \.outlineChildren) { node in
            HStack(spacing: 6) {
                Image(systemName: node.children.isEmpty ? "line.horizontal.3" : "arrow.triangle.branch")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(node.text)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
            }
            .padding(.vertical, 1)
        }
        .listStyle(.inset)
    }
}
