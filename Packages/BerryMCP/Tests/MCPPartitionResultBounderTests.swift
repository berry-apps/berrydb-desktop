import BerryDriverKit
@testable import BerryMCP
import Foundation
import Testing

@Suite("MCP partition result bounder")
struct MCPPartitionResultBounderTests {
    @Test func redactedAttributesAreRemovedAndNamed() throws {
        let bounder = MCPPartitionResultBounder(
            limits: limits(ceiling: 10_000), reserve: 0, redactedAttributes: ["email", "ssn"]
        )
        let bounded = try bounder.bound([
            ["pk": .string("a"), "Email": .string("a@example.com")],
            ["pk": .string("b"), "phone": .string("555")],
        ])
        #expect(bounded.kept == [["pk": .string("a")], ["pk": .string("b"), "phone": .string("555")]])
        #expect(bounded.redactedAttributes == ["Email"])
        #expect(bounded.keptIndexes == [0, 1])
        #expect(bounded.cutByCeiling == false)
    }

    @Test func anAttributeOverTheCellLimitIsOmittedAndReported() throws {
        let wide = String(repeating: "x", count: 200)
        let wideBytes = try size(["body": .string(wide)])
        let bounder = MCPPartitionResultBounder(
            limits: limits(ceiling: 10_000, cell: wideBytes - 1), reserve: 0, redactedAttributes: []
        )
        let bounded = try bounder.bound([
            ["pk": .string("a")],
            ["pk": .string("b"), "body": .string(wide)],
        ])
        #expect(bounded.kept == [["pk": .string("a")], ["pk": .string("b")]])
        #expect(bounded.omittedAttributes == [MCPOmittedAttribute(item: 1, name: "body", bytes: wideBytes)])
        #expect(bounded.skippedItems.isEmpty)
    }

    @Test func anOmittedAttributesNameIsCut() throws {
        let name = String(repeating: "n", count: 300)
        let bounder = MCPPartitionResultBounder(limits: limits(ceiling: 10_000, cell: 10), reserve: 0, redactedAttributes: [])
        let bounded = try bounder.bound([[name: .string("value")]])
        let omitted = try #require(bounded.omittedAttributes.first)
        #expect(omitted.name == String(repeating: "n", count: 254) + "…")
    }

    @Test func dropTheLastKeptItemUndoesEverythingAfterIt() throws {
        let item: [String: DynamoDBAttributeValue] = ["pk": .string("a"), "email": .string("e"), "big": .string("xxxxxxxxxxxxxxxxxxxx")]
        // No attribute over the cell limit, the whole over the budget.
        var large: [String: DynamoDBAttributeValue] = ["pk": .string("b")]
        for number in 0..<10 { large["k\(number)"] = .string("vvvvvvvvvv") }
        let bounder = MCPPartitionResultBounder(
            limits: limits(ceiling: 1_000, cell: 25), reserve: 900, redactedAttributes: ["email"]
        )
        // Kept 0, skipped 1, kept 2, skipped 3.
        var bounded = try bounder.bound([item, large, item, large])
        #expect(bounded.keptIndexes == [0, 2])
        #expect(bounded.skippedItems.map(\.index) == [1, 3])
        #expect(bounded.lastProcessedIndex == 3)

        let droppedFirst = bounded.dropLastKept()
        #expect(droppedFirst)
        #expect(bounded.keptIndexes == [0])
        #expect(bounded.kept.count == 1)
        #expect(bounded.omittedAttributes.map(\.item) == [0])
        #expect(bounded.skippedItems.map(\.index) == [1])
        #expect(bounded.lastProcessedIndex == 1)
        #expect(bounded.cutByCeiling)
        #expect(bounded.redactedAttributes == ["email"])

        // Item 0 is the first processed, so it is skipped rather than
        // dropped and the next page starts after it.
        let droppedSecond = bounded.dropLastKept()
        #expect(droppedSecond)
        #expect(bounded.kept.isEmpty)
        #expect(bounded.omittedAttributes.isEmpty)
        #expect(bounded.redactedAttributes.isEmpty)
        #expect(bounded.skippedItems == [MCPSkippedItem(index: 0, bytes: try size(item.filter { $0.key == "pk" }))])
        #expect(bounded.lastProcessedIndex == 0)
        let droppedNothing = bounded.dropLastKept()
        #expect(droppedNothing == false)
    }

    @Test func anItemThatNeverFitsIsSkippedAndProcessingContinues() throws {
        let small: [String: DynamoDBAttributeValue] = ["pk": .string("a")]
        let large: [String: DynamoDBAttributeValue] = ["pk": .string("b"), "a": .string(String(repeating: "y", count: 300))]
        let budget = try size(small) * 3 + 2
        let largeBytes = try size(large)
        #expect(largeBytes > budget)
        let bounder = MCPPartitionResultBounder(
            limits: limits(ceiling: budget + 100), reserve: 100, redactedAttributes: []
        )
        let bounded = try bounder.bound([small, large, small])
        #expect(bounded.kept == [small, small])
        #expect(bounded.keptIndexes == [0, 2])
        #expect(bounded.skippedItems == [MCPSkippedItem(index: 1, bytes: largeBytes)])
        #expect(bounded.lastProcessedIndex == 2)
        #expect(bounded.cutByCeiling == false)
    }

    @Test func anItemThatWouldFitAnEmptyPageEndsThePage() throws {
        let item: [String: DynamoDBAttributeValue] = ["pk": .string("a"), "body": .string(String(repeating: "z", count: 40))]
        let bytes = try size(item)
        // Two items and their separator fit; a third would not, though it
        // would fit a page of its own.
        let bounder = MCPPartitionResultBounder(
            limits: limits(ceiling: 2 * bytes + 1 + 50 + bytes / 2), reserve: 50, redactedAttributes: []
        )
        let bounded = try bounder.bound([item, item, item, item])
        #expect(bounded.kept == [item, item])
        #expect(bounded.cutByCeiling)
        #expect(bounded.lastProcessedIndex == 1)
        #expect(bounded.skippedItems.isEmpty)
    }

    @Test func theBudgetChargesEachItemsBytesPlusASeparator() throws {
        let item: [String: DynamoDBAttributeValue] = ["pk": .string("a"), "n": .number("12")]
        let bytes = try size(item)
        let exact = MCPPartitionResultBounder(
            limits: limits(ceiling: 3 * bytes + 2 + 10), reserve: 10, redactedAttributes: []
        )
        let full = try exact.bound([item, item, item])
        #expect(full.kept.count == 3)
        #expect(full.cutByCeiling == false)

        let oneShort = MCPPartitionResultBounder(
            limits: limits(ceiling: 3 * bytes + 1 + 10), reserve: 10, redactedAttributes: []
        )
        let cut = try oneShort.bound([item, item, item])
        #expect(cut.kept.count == 2)
        #expect(cut.cutByCeiling)
    }

    @Test func aReserveThatFillsTheCeilingIsRefused() {
        let bounder = MCPPartitionResultBounder(limits: limits(ceiling: 100), reserve: 100, redactedAttributes: [])
        #expect(throws: MCPResultLimiterError.metadataExceedsByteLimit) { try bounder.bound([]) }
    }
}

private func limits(ceiling: Int, cell: Int = 65_536) -> MCPResultLimits {
    MCPResultLimits(maximumRows: 100, maximumCellBytes: cell, maximumSerializedBytes: ceiling, maximumElapsed: .seconds(30))
}

private func size(_ item: [String: DynamoDBAttributeValue]) throws -> Int {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(item).count
}
