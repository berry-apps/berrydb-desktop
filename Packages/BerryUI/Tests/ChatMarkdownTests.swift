import Foundation
import Testing

@testable import BerryUI

/// The chat message renderer splits an assistant reply into block elements
/// (headings, paragraphs, code, mermaid, lists) before rendering each natively.
@Suite("Chat markdown parsing")
struct ChatMarkdownTests {
    @Test func plainTextIsOneParagraph() {
        #expect(ChatMarkdown.parse("You have 3 tables.") == [.paragraph("You have 3 tables.")])
    }

    @Test func headingThenParagraph() {
        let blocks = ChatMarkdown.parse("## Schema\nThree tables found.")
        #expect(blocks == [.heading(level: 2, text: "Schema"), .paragraph("Three tables found.")])
    }

    @Test func fencedCodeKeepsLanguageAndBody() {
        let src = "Here:\n```sql\nSELECT 1;\nSELECT 2;\n```\nDone."
        #expect(ChatMarkdown.parse(src) == [
            .paragraph("Here:"),
            .code(language: "sql", code: "SELECT 1;\nSELECT 2;"),
            .paragraph("Done."),
        ])
    }

    @Test func mermaidFenceBecomesItsOwnBlock() {
        let src = "```mermaid\nerDiagram\n  A ||--o{ B : has\n```"
        #expect(ChatMarkdown.parse(src) == [.mermaid("erDiagram\n  A ||--o{ B : has")])
    }

    @Test func bulletAndOrderedListsGroup() {
        let bullets = ChatMarkdown.parse("- one\n- two")
        #expect(bullets == [.bulletList(["one", "two"])])
        let ordered = ChatMarkdown.parse("1. first\n2. second")
        #expect(ordered == [.orderedList(startIndex: 1, items: ["first", "second"])])
    }

    @Test func orderedListPreservesCustomStartIndexAndBlankLines() {
        let src = "5. fifth\n\n6. sixth"
        #expect(ChatMarkdown.parse(src) == [.orderedList(startIndex: 5, items: ["fifth", "sixth"])])
    }

    @Test func blankLineSeparatesParagraphs() {
        #expect(ChatMarkdown.parse("A\n\nB") == [.paragraph("A"), .paragraph("B")])
    }

    @Test func gfmTableParsesHeaderAndRows() {
        let src = "| Name | Age |\n| --- | --- |\n| Ann | 30 |\n| Bob | 25 |"
        #expect(ChatMarkdown.parse(src) == [
            .table(header: ["Name", "Age"], rows: [["Ann", "30"], ["Bob", "25"]]),
        ])
    }

    @Test func tableWithAlignmentColonsAndSurroundingText() {
        let src = "Results:\n| a | b |\n|:--|--:|\n| 1 | 2 |\nDone."
        #expect(ChatMarkdown.parse(src) == [
            .paragraph("Results:"),
            .table(header: ["a", "b"], rows: [["1", "2"]]),
            .paragraph("Done."),
        ])
    }

    @Test func pipeInProseIsNotATable() {
        // No delimiter row underneath → it's just a paragraph.
        #expect(ChatMarkdown.parse("use a | b for OR") == [.paragraph("use a | b for OR")])
    }

    @Test func codeFenceIsNotMistakenForAList() {
        // A '* ' inside a fenced block must stay code, not a bullet.
        let src = "```\nSELECT * FROM t;\n```"
        #expect(ChatMarkdown.parse(src) == [.code(language: nil, code: "SELECT * FROM t;")])
    }

    @Test func horizontalRuleParsesToDivider() {
        let src = "Above\n---\nBelow"
        #expect(ChatMarkdown.parse(src) == [.paragraph("Above"), .divider, .paragraph("Below")])
    }

    /// Reported as a table rendering with its header and no rows at all.
    ///
    /// A GFM delimiter row is `| --- | --- |`, which `isHorizontalRule` also
    /// matches once the pipes are ignored — and the horizontal-rule branch is
    /// checked first for a table whose header line happens not to be recognised.
    /// The rows are then consumed as prose. Pinned with the exact shape a model
    /// emits for a stats table.
    @Test func aTableKeepsItsRows() {
        let src = """
        | Bảng | Live | Dead | % Chết |
        | --- | --- | --- | --- |
        | ai_usage_event | 1 | 401 | 99.8% |
        | device_token | 12 | 88 | 88.0% |
        """
        #expect(ChatMarkdown.parse(src) == [
            .table(
                header: ["Bảng", "Live", "Dead", "% Chết"],
                rows: [
                    ["ai_usage_event", "1", "401", "99.8%"],
                    ["device_token", "12", "88", "88.0%"],
                ]
            )
        ])
    }

    /// A table is commonly the last thing in a reply, with no trailing newline.
    @Test func aTableAtTheEndOfInputKeepsItsRows() {
        let src = "| a | b |\n| --- | --- |\n| 1 | 2 |"
        #expect(ChatMarkdown.parse(src) == [
            .table(header: ["a", "b"], rows: [["1", "2"]])
        ])
    }

    /// A `---` delimiter must not be mistaken for a horizontal rule when it is
    /// underneath a header row.
    @Test func aTableDelimiterIsNotAHorizontalRule() {
        let blocks = ChatMarkdown.parse("| a |\n| --- |\n| 1 |")
        #expect(!blocks.contains(.divider))
    }
}
