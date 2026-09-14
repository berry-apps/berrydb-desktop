import BerryCore
import BerryDriverKit
import SwiftUI

/// Visual WHERE builder: a few column/operator/value rows joined by AND.
/// It writes a fragment into the tab's raw filter field, which remains the
/// source of truth so power users can still hand-edit it.
struct FilterBuilderPopover: View {
    let columns: [String]
    let dialect: any SQLDialect
    let onApply: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var conditions: [FilterBuilder.Condition]

    init(columns: [String], dialect: any SQLDialect, onApply: @escaping (String) -> Void) {
        self.columns = columns
        self.dialect = dialect
        self.onApply = onApply
        _conditions = State(initialValue: [
            FilterBuilder.Condition(column: columns.first ?? "")
        ])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Filter rows")).font(.headline)

            ForEach($conditions) { $condition in
                conditionRow($condition)
            }

            Button {
                conditions.append(FilterBuilder.Condition(column: columns.first ?? ""))
            } label: {
                Label(L("Add condition"), systemImage: "plus")
            }
            .buttonStyle(.borderless)

            Divider()

            HStack {
                Button(L("Clear")) {
                    onApply("")
                    dismiss()
                }
                Spacer()
                Button(L("Apply Filter")) {
                    onApply(FilterBuilder.whereClause(conditions, dialect: dialect))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 440)
    }

    @ViewBuilder
    private func conditionRow(_ condition: Binding<FilterBuilder.Condition>) -> some View {
        HStack(spacing: 6) {
            Picker("", selection: condition.column) {
                ForEach(columns, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(width: 140)

            Picker("", selection: condition.op) {
                ForEach(FilterBuilder.Operator.allCases, id: \.self) { op in
                    Text(label(for: op)).tag(op)
                }
            }
            .labelsHidden()
            .frame(width: 96)

            if condition.wrappedValue.op.needsValue {
                TextField(L("value"), text: condition.value)
                    .textFieldStyle(.roundedBorder)
            } else {
                Spacer(minLength: 0)
            }

            Button {
                let id = condition.wrappedValue.id
                conditions.removeAll { $0.id == id }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .disabled(conditions.count <= 1)
        }
    }

    /// Symbolic operators show as-is; word operators are localized.
    private func label(for op: FilterBuilder.Operator) -> String {
        switch op {
        case .equals: "="
        case .notEquals: "≠"
        case .greater: ">"
        case .greaterOrEqual: "≥"
        case .less: "<"
        case .lessOrEqual: "≤"
        case .contains: L("contains")
        case .startsWith: L("starts with")
        case .isNull: L("is null")
        case .isNotNull: L("is not null")
        }
    }
}
