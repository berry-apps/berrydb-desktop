import Foundation
import Testing

@testable import BerryCore

@Suite("SnippetPlaceholder (saved-query placeholders)")
struct SnippetPlaceholderTests {
    @Test func resolvesFirstPlaceholderAndSelectsIt() {
        let result = SnippetPlaceholder.resolve("SELECT * FROM ${1:table_name} LIMIT 10")
        #expect(result.text == "SELECT * FROM table_name LIMIT 10")
        // "table_name" starts at index 14, is 10 UTF-16 units long.
        #expect(result.selection == NSRange(location: 14, length: 10))
    }

    @Test func onlyFirstPlaceholderIsSpecial_othersAreStrippedInOrder() {
        let result = SnippetPlaceholder.resolve("UPDATE ${1:t} SET ${2:col} = ${2:col}")
        #expect(result.text == "UPDATE t SET col = col")
        #expect(result.selection == NSRange(location: 7, length: 1)) // "t"
    }

    @Test func returnsNilSelectionWhenNoPlaceholders() {
        let result = SnippetPlaceholder.resolve("SELECT 1")
        #expect(result.text == "SELECT 1")
        #expect(result.selection == nil)
    }
}
