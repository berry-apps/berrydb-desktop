import Foundation
import Testing
@testable import BerryAI

@Suite("ChatCommand registry")
struct ChatCommandTests {
    @Test func emptyQueryMatchesAllCommands() {
        #expect(ChatCommands.matching("").map(\.name) == ChatCommands.all.map(\.name))
    }

    @Test func queryMatchesByCaseInsensitivePrefix() {
        #expect(ChatCommands.matching("rep").map(\.name) == ["report"])
        #expect(ChatCommands.matching("REP").map(\.name) == ["report"])
    }

    @Test func fullNameStillMatches() {
        #expect(ChatCommands.matching("report").map(\.name) == ["report"])
    }

    @Test func nonMatchingQueryReturnsEmpty() {
        #expect(ChatCommands.matching("xyz").isEmpty)
    }

    @Test func reportCommandHasUsageHintAndDescription() {
        let report = ChatCommands.all.first { $0.name == "report" }
        #expect(report?.usageHint == "/report {message}")
        #expect(report?.description.isEmpty == false)
    }

    @Test func everyCommandsUsageHintMatchesItsName() {
        for command in ChatCommands.all {
            #expect(command.usageHint.hasPrefix("/\(command.name)"))
            #expect(command.name == command.name.lowercased())
            #expect(!command.name.contains(" "))
        }
    }

    @Test func matchingIsPrefixOnlyNotSubstring() {
        // "port" is a substring of "report" but not a prefix — must not match.
        // (The existing nonMatchingQueryReturnsEmpty test uses "xyz", which
        // doesn't distinguish prefix-matching from substring-matching.)
        #expect(ChatCommands.matching("port").isEmpty)
    }
}
