import BerryDriverKit
import Testing

@Suite("SchemaObject qualified name (sidebar Copy Name)")
struct SchemaObjectNamingTests {
    @Test func qualifiedNameIncludesDatabaseWhenPresent() {
        let object = SchemaObject(kind: .table, name: "users", database: "public")
        #expect(object.qualifiedName == "public.users")
    }

    @Test func qualifiedNameFallsBackToBareNameWhenNoDatabase() {
        // SQLite: one file = one db, `database` is nil (Schema.swift:26).
        let object = SchemaObject(kind: .table, name: "users", database: nil)
        #expect(object.qualifiedName == "users")
    }
}
