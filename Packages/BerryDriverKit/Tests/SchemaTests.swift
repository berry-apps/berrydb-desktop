import BerryDriverKit
import Testing

struct SchemaTests {
    @Test func foreignKeyInfoStoresReferencedSchemaWithBackwardCompatibility() {
        let withSchema = ForeignKeyInfo(
            column: "item_id",
            referencedSchema: "berry_s2",
            referencedTable: "items",
            referencedColumn: "id"
        )
        #expect(withSchema.column == "item_id")
        #expect(withSchema.referencedSchema == "berry_s2")
        #expect(withSchema.referencedTable == "items")
        #expect(withSchema.referencedColumn == "id")

        // Legacy initializer compatibility
        let legacy = ForeignKeyInfo(
            column: "user_id",
            referencedTable: "users",
            referencedColumn: "id"
        )
        #expect(legacy.referencedSchema == nil)
        #expect(legacy.referencedTable == "users")
    }
}
