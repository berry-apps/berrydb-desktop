import BerryCore
import BerryGraph
import Testing
@testable import BerryAI

@Suite("preview_migration client tool")
struct PreviewMigrationToolExecutorTests {
    private func sampleInsight() -> Insight {
        Insight(
            id: "schema.missing_pk.users", severity: .warning, category: .schema,
            title: "Missing primary key", detail: "Table users has no primary key."
        )
    }

    @MainActor
    @Test func performsTheReviewAndReturnsFormattedFindings() async {
        var seen: (table: String, column: ColumnDesign)?
        let executor = PreviewMigrationToolExecutor(previewNewColumn: { table, column in
            seen = (table, column)
            return [self.sampleInsight()]
        })

        let outcome = await executor.execute(AIToolCall(
            id: "c1", name: "preview_migration",
            args: ["table": "users", "column_name": "phone", "column_type": "VARCHAR(255)"]
        ))

        #expect(outcome.status == "ok")
        #expect(outcome.resultJSON?.contains("Missing primary key") == true)
        #expect(outcome.resultJSON?.contains("\"severity\":\"warning\"") == true)
        #expect(outcome.resultJSON?.contains("\"category\":\"schema\"") == true)
        #expect(seen?.table == "users")
        #expect(seen?.column.name == "phone")
        #expect(seen?.column.type == "VARCHAR(255)")
        #expect(seen?.column.isNullable == true) // default when 'nullable' arg is absent
        #expect(seen?.column.isPrimaryKey == false)
    }

    @MainActor
    @Test func parsesNullableAndPrimaryKeyFlagsAndDefaultValue() async {
        var seen: ColumnDesign?
        let executor = PreviewMigrationToolExecutor(previewNewColumn: { _, column in
            seen = column
            return []
        })

        _ = await executor.execute(AIToolCall(
            id: "c1", name: "preview_migration",
            args: [
                "table": "users", "column_name": "id", "column_type": "INTEGER",
                "nullable": "false", "primary_key": "true", "default_value": "0",
            ]
        ))

        #expect(seen?.isNullable == false)
        #expect(seen?.isPrimaryKey == true)
        #expect(seen?.defaultValue == "0")
    }

    @MainActor
    @Test func rejectsMissingRequiredArguments() async {
        let executor = PreviewMigrationToolExecutor(previewNewColumn: { _, _ in [] })

        let missingTable = await executor.execute(AIToolCall(
            id: "c1", name: "preview_migration", args: ["column_name": "phone", "column_type": "TEXT"]
        ))
        #expect(missingTable.status == "error")

        let missingType = await executor.execute(AIToolCall(
            id: "c2", name: "preview_migration", args: ["table": "users", "column_name": "phone"]
        ))
        #expect(missingType.status == "error")
    }

    @MainActor
    @Test func reportsATableNotFoundInTheHarvestedSchemaAsAnError() async {
        let executor = PreviewMigrationToolExecutor(previewNewColumn: { _, _ in nil })

        let outcome = await executor.execute(AIToolCall(
            id: "c1", name: "preview_migration",
            args: ["table": "ghost", "column_name": "phone", "column_type": "TEXT"]
        ))

        #expect(outcome.status == "error")
    }

    @MainActor
    @Test func aDeniedLeaseNeverInvokesThePreview() async {
        var invoked = false
        let executor = PreviewMigrationToolExecutor(previewNewColumn: { _, _ in
            invoked = true
            return []
        })
        let deniedLease = AIExecutionLease(validate: { false })

        let outcome = await executor.execute(
            AIToolCall(id: "c1", name: "preview_migration", args: ["table": "users", "column_name": "phone", "column_type": "TEXT"]),
            lease: deniedLease
        )

        #expect(outcome == .denied)
        #expect(invoked == false)
    }
}
