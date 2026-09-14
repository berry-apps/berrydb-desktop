import Testing

@testable import BerryCore

/// Single-table SELECT detection for editable query results (D4a).
@Suite("EditableSelect (D4a)")
struct EditableSelectTests {
    @Test func plainSingleTableSelectsAreEditable() {
        #expect(EditableSelect.baseTable(for: "SELECT * FROM users") == "users")
        #expect(EditableSelect.baseTable(for: "select id, name from Accounts") == "Accounts")
        #expect(EditableSelect.baseTable(for: "SELECT * FROM users WHERE id > 3 ORDER BY id") == "users")
        #expect(EditableSelect.baseTable(for: "SELECT * FROM users u WHERE u.active") == "users")
        #expect(EditableSelect.baseTable(for: "SELECT * FROM public.orders LIMIT 100") == "public.orders")
        #expect(EditableSelect.baseTable(for: "SELECT * FROM \"Users\";") == "Users")
    }

    @Test func complexQueriesAreNotEditable() {
        #expect(EditableSelect.baseTable(for: "SELECT * FROM a JOIN b ON a.id = b.a_id") == nil)
        #expect(EditableSelect.baseTable(for: "SELECT count(*) FROM users") == nil)
        #expect(EditableSelect.baseTable(for: "SELECT DISTINCT city FROM users") == nil)
        #expect(EditableSelect.baseTable(for: "SELECT * FROM a, b") == nil)
        #expect(EditableSelect.baseTable(for: "SELECT * FROM (SELECT * FROM users) t") == nil)
        #expect(EditableSelect.baseTable(for: "SELECT city, count(*) FROM users GROUP BY city") == nil)
        #expect(EditableSelect.baseTable(for: "SELECT * FROM a UNION SELECT * FROM b") == nil)
        #expect(EditableSelect.baseTable(for: "UPDATE users SET x = 1") == nil)
        #expect(EditableSelect.baseTable(for: "SELECT * FROM a; SELECT * FROM b") == nil)
    }
}
