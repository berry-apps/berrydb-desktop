import Foundation
import Testing

@testable import BerryCore

/// ⌘/ line-comment toggling.
@Suite("SQLCommentToggler (⌘/)")
struct SQLCommentTogglerTests {
    @Test func commentsTheCaretLine() {
        let result = SQLCommentToggler.toggle("SELECT 1\nSELECT 2", selection: NSRange(location: 0, length: 0))
        #expect(result.text == "-- SELECT 1\nSELECT 2")
    }

    @Test func commentsEverySelectedLine() {
        let text = "SELECT 1\nSELECT 2\nSELECT 3"
        let result = SQLCommentToggler.toggle(text, selection: NSRange(location: 0, length: text.count))
        #expect(result.text == "-- SELECT 1\n-- SELECT 2\n-- SELECT 3")
    }

    @Test func uncommentsWhenAllLinesAreCommented() {
        let text = "-- SELECT 1\n--SELECT 2"
        let result = SQLCommentToggler.toggle(text, selection: NSRange(location: 0, length: text.count))
        #expect(result.text == "SELECT 1\nSELECT 2")
    }

    @Test func mixedLinesGetCommented() {
        // One uncommented line in the block → comment everything (VS Code rule).
        let text = "-- a\nb"
        let result = SQLCommentToggler.toggle(text, selection: NSRange(location: 0, length: text.count))
        #expect(result.text == "-- -- a\n-- b")
    }

    @Test func blankLinesAreLeftAlone() {
        let text = "a\n\nb"
        let result = SQLCommentToggler.toggle(text, selection: NSRange(location: 0, length: text.count))
        #expect(result.text == "-- a\n\n-- b")
    }

    @Test func preservesIndentationOnUncomment() {
        let text = "  -- SELECT 1"
        let result = SQLCommentToggler.toggle(text, selection: NSRange(location: 0, length: 0))
        #expect(result.text == "  SELECT 1")
    }
}
