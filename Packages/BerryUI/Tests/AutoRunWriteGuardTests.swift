import BerryDataSourceKit
import Testing

@testable import BerryUI

@Suite("Automatic runs never write to a document store")
struct AutoRunWriteGuardTests {
    private func action(_ script: String) throws -> MongoShellAction {
        try MongoShellResolver.resolve(try #require(try MongoShellParser.parse(script).first))
    }

    @Test(arguments: [
        "db.users.deleteMany({})",
        "db.users.insertOne({name: 'ann'})",
        "db.users.insertMany([{name: 'ann'}, {name: 'bob'}])",
        "db.users.updateOne({name: 'ann'}, {$set: {name: 'bob'}})",
    ])
    func aWriteThatWouldRunWithoutACardIsRefused(_ script: String) throws {
        #expect(AutoRunWriteGuard.refusal(for: try action(script), autoRun: true) != nil)
    }

    /// Guard: a write the user approved on its card still runs.
    @Test func aWriteApprovedOnItsCardRuns() throws {
        #expect(AutoRunWriteGuard.refusal(for: try action("db.users.deleteMany({})"), autoRun: false) == nil)
    }

    @Test func aReadRunsEitherWay() throws {
        let read = try action(#"db.users.find({note: "deleteMany"})"#)
        #expect(AutoRunWriteGuard.refusal(for: read, autoRun: true) == nil)
        #expect(AutoRunWriteGuard.refusal(for: read, autoRun: false) == nil)
    }
}
