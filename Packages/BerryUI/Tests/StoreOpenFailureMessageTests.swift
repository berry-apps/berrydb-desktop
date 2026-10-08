import BerryStore
import Foundation
import Testing

@testable import BerryUI

@Suite("Store open failure message")
struct StoreOpenFailureMessageTests {
    private struct UnreadableFile: LocalizedError {
        var errorDescription: String? { "unable to open database file" }
    }

    @Test func failedUpgradeNamesTheStepAndKeepsTheSQLiteTextAsDetails() {
        let reason = #"SQLite error 1: table "mcp_project" already exists - while executing `CREATE TABLE "mcp_project" ("id" BLOB)`"#
        let message = StoreOpenFailureMessage(
            BerryStore.OpenError.migrationFailed(identifier: "v30-mcp-project", reason: reason)
        )

        #expect(message.headline.contains("could not open its data store"))
        #expect(message.headline.contains("v30-mcp-project"))
        #expect(!message.headline.contains("SQLite"))
        #expect(message.details == reason)
    }

    @Test func otherOpenFailureGetsTheGenericHeadlineAndItsOwnTextAsDetails() {
        let message = StoreOpenFailureMessage(UnreadableFile())

        #expect(message.headline == "BerryDB could not open its data store.")
        #expect(message.details == "unable to open database file")
    }
}
