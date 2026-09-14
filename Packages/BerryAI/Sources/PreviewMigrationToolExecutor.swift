import BerryCore
import BerryGraph
import Foundation

/// Client-executed `preview_migration`:
/// reviews a proposed new column on an existing table before it's executed —
/// runs the same AI Schema Review analyzer the table designer uses
/// (`WorkspaceViewModel.migrationPreview(editing:)`), reusing its existing
/// entitlement gate and harvested-graph comparison rather than duplicating
/// either. Harmless: never touches the database, only reads local metadata.
@MainActor
public final class PreviewMigrationToolExecutor: AIToolExecutor {
    private let previewNewColumn: (String, ColumnDesign) async -> [Insight]?

    public init(previewNewColumn: @escaping (String, ColumnDesign) async -> [Insight]?) {
        self.previewNewColumn = previewNewColumn
    }

    public var toolSpecs: [AIToolSpec] {
        [AIToolSpec(
            name: "preview_migration",
            description: "Review a proposed new column on an existing table before it's executed — runs the same AI Schema Review analyzer the table designer uses, comparing the change against the table's current harvested schema. Never touches the database. Call get_schema first to confirm the table exists and see its current columns.",
            parametersJSON: #"""
            {"type":"object","properties":{"table":{"type":"string","description":"The existing table to add a column to."},"column_name":{"type":"string"},"column_type":{"type":"string","description":"SQL type, e.g. VARCHAR(255), INTEGER."},"nullable":{"type":"boolean","description":"Defaults to true."},"primary_key":{"type":"boolean","description":"Defaults to false."},"default_value":{"type":"string","description":"Optional SQL default expression."}},"required":["table","column_name","column_type"]}
            """#
        )]
    }

    public func execute(_ call: AIToolCall) async -> ToolOutcome {
        await executePreview(call)
    }

    public func execute(_ call: AIToolCall, lease: AIExecutionLease) async -> ToolOutcome {
        guard lease.isValid else { return .denied }
        let outcome = await executePreview(call)
        guard lease.isValid else { return .denied }
        return outcome
    }

    private func executePreview(_ call: AIToolCall) async -> ToolOutcome {
        guard call.name == "preview_migration" else { return .failed("Unknown tool '\(call.name)'") }
        guard let table = call.args["table"], !table.isEmpty,
              let name = call.args["column_name"], !name.isEmpty,
              let type = call.args["column_type"], !type.isEmpty
        else {
            return .failed("Missing 'table', 'column_name', or 'column_type'")
        }
        let column = ColumnDesign(
            name: name, type: type,
            isNullable: call.args["nullable"].map { $0 != "false" } ?? true,
            isPrimaryKey: call.args["primary_key"] == "true",
            defaultValue: call.args["default_value"]
        )
        guard let insights = await previewNewColumn(table, column) else {
            return .failed("'\(table)' isn't in the harvested schema yet — refresh the schema first")
        }
        let findings = insights.map {
            ["title": $0.title, "detail": $0.detail, "severity": $0.severity.label, "category": $0.category.rawValue]
        }
        let json = (try? JSONSerialization.data(withJSONObject: ["findings": findings]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? #"{"findings":[]}"#
        return .ok(json)
    }
}
