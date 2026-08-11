import BerryCore
import Testing
@testable import BerryUI

@Suite("MongoShellCompletionProvider")
struct MongoShellCompletionProviderTests {
    @Test func suggestsCollectionNamesRightAfterDbDot() {
        let script = "db."
        let items = MongoShellCompletionProvider.suggestions(
            script: script, utf16Cursor: script.utf16.count, collections: ["users", "orders"]
        )
        #expect(items.map(\.display).sorted() == ["orders", "users"])
    }

    @Test func suggestsMethodsAfterCollectionDot() {
        let script = "db.users."
        let items = MongoShellCompletionProvider.suggestions(
            script: script, utf16Cursor: script.utf16.count, collections: ["users"]
        )
        #expect(items.contains { $0.display == "find" && $0.detail == "find(query, projection)" })
        #expect(items.contains { $0.display == "insertOne" && $0.detail == "insertOne(document)" })
    }

    @Test func suggestsOperatorsRightAfterADollarSign() {
        let script = "db.users.find({ age: { $"
        let items = MongoShellCompletionProvider.suggestions(
            script: script, utf16Cursor: script.utf16.count, collections: []
        )
        #expect(items.contains { $0.insert == "gt" })
        #expect(items.contains { $0.insert == "set" })
    }

    @Test func suggestsNothingMidIdentifier() {
        let script = "db.users.fi"
        let items = MongoShellCompletionProvider.suggestions(
            script: script, utf16Cursor: script.utf16.count, collections: ["users"]
        )
        #expect(items.isEmpty)
    }
}
