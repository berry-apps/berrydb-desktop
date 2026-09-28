import XCTest
@testable import BerryMCP

final class MCPResultLimiterTests: XCTestCase {
    func testAllCountCeilingsHaveExplicitOmissions() throws {
        let limits = MCPResultLimits(maximumRows: 1, maximumObjects: 1, maximumGraphNodes: 1, maximumGraphEdges: 2, maximumCellBytes: 100, maximumSerializedBytes: 10_000)
        let limiter = MCPResultLimiter(limits: limits)
        let values = [["id": "1"], ["id": "2"], ["id": "3"]]
        let result = try limiter.limit(rows: values, objects: values, graphNodes: values, graphEdges: values)
        XCTAssertEqual(result.rows.count, 1)
        XCTAssertEqual(result.metadata.omittedRows, 2)
        XCTAssertEqual(result.objects.count, 1)
        XCTAssertEqual(result.metadata.omittedObjects, 2)
        XCTAssertEqual(result.graphNodes.count, 1)
        XCTAssertEqual(result.metadata.omittedGraphNodes, 2)
        XCTAssertEqual(result.graphEdges.count, 2)
        XCTAssertEqual(result.metadata.omittedGraphEdges, 1)
        XCTAssertTrue(result.metadata.truncated)
    }

    func testOmittedTailsAreNotRedactedOrCellTruncated() throws {
        let limits = MCPResultLimits(
            maximumRows: 1,
            maximumObjects: 1,
            maximumGraphNodes: 1,
            maximumGraphEdges: 1,
            maximumCellBytes: 8,
            maximumSerializedBytes: 10_000
        )
        let visible = [["value": "ok"]]
        let omittedTail = [["password": String(repeating: "secret", count: 10_000)]]
        let result = try MCPResultLimiter(limits: limits).limit(
            rows: visible + omittedTail,
            objects: visible + omittedTail,
            graphNodes: visible + omittedTail,
            graphEdges: visible + omittedTail,
            redaction: MCPRedactionPolicy(caseInsensitive: ["password"])
        )

        XCTAssertEqual(result.metadata.omittedRows, 1)
        XCTAssertEqual(result.metadata.omittedObjects, 1)
        XCTAssertEqual(result.metadata.omittedGraphNodes, 1)
        XCTAssertEqual(result.metadata.omittedGraphEdges, 1)
        XCTAssertEqual(result.metadata.truncatedCells, 0)
        XCTAssertEqual(result.metadata.redactedColumns, [])
    }

    func testUTF8CellCeilingMeasuresJSONEncodedBytes() throws {
        let limits = MCPResultLimits(maximumRows: 1, maximumCellBytes: 12, maximumSerializedBytes: 2_000)
        let result = try MCPResultLimiter(limits: limits).limit(rows: [["emoji": "😀😀😀😀", "escape": "\\\"\\\"\\\""]])
        let encoder = JSONEncoder()
        for value in result.rows[0].values.compactMap({ $0 }) { XCTAssertLessThanOrEqual(try encoder.encode(value).count, 12) }
        XCTAssertEqual(result.metadata.truncatedCells, 2)
    }

    func testUTF8TruncationPreservesValidOriginalPrefixWithoutReplacementCharacters() throws {
        let inputs = [
            "😀😀😀tail",
            "e\u{301}e\u{301}e\u{301}tail",
            "👨‍👩‍👧‍👦family-tail",
        ]
        for input in inputs {
            let byteCeiling = 10
            let limiter = MCPResultLimiter(limits: MCPResultLimits(maximumRows: 1, maximumCellBytes: byteCeiling, maximumSerializedBytes: 2_000))
            let result = try limiter.limit(rows: [["value": input]])
            let output = try XCTUnwrap(result.rows[0]["value"]!)
            XCTAssertTrue(output.hasSuffix("…"), input)
            let prefix = String(output.dropLast())
            XCTAssertTrue(input.hasPrefix(prefix), "Output must be a valid original prefix: \(output)")
            XCTAssertFalse(output.contains("\u{FFFD}"), "Truncation introduced a replacement character")
            XCTAssertLessThanOrEqual(try JSONEncoder().encode(output).count, byteCeiling)
        }
    }

    func testExistingReplacementCharacterIsPreservedWhenItFits() throws {
        let input = "ok\u{FFFD}" + String(repeating: "x", count: 30)
        let limiter = MCPResultLimiter(limits: MCPResultLimits(maximumRows: 1, maximumCellBytes: 14, maximumSerializedBytes: 2_000))
        let output = try XCTUnwrap(try limiter.limit(rows: [["value": input]]).rows[0]["value"]!)
        XCTAssertTrue(output.contains("\u{FFFD}"))
        XCTAssertTrue(input.hasPrefix(String(output.dropLast())))
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(output).count, 14)
    }

    func testSerializedByteCeilingIsExact() throws {
        let baseline = MCPResultLimiter(limits: MCPResultLimits(maximumSerializedBytes: 10_000))
        let full = try baseline.limit(rows: (0..<20).map { ["value": String(repeating: "é", count: 20) + "\($0)"] })
        let metadataOnlySize = try baseline.serialized(MCPBoundedResult(rows: [], objects: [], graphNodes: [], graphEdges: [], metadata: full.metadata)).count
        let ceiling = metadataOnlySize + 80
        let limiter = MCPResultLimiter(limits: MCPResultLimits(maximumSerializedBytes: ceiling))
        let bounded = try limiter.limit(rows: (0..<20).map { ["value": String(repeating: "é", count: 20) + "\($0)"] })
        XCTAssertLessThanOrEqual(try limiter.serialized(bounded).count, ceiling)
        XCTAssertTrue(bounded.metadata.byteLimitReached)
        XCTAssertGreaterThan(bounded.metadata.omittedRows, 0)
    }

    func testExactSerializedBoundaryDoesNotReportTruncation() throws {
        let generous = MCPResultLimiter(limits: MCPResultLimits(maximumSerializedBytes: 10_000))
        let input = try generous.limit(rows: [["value": "é😀\\\""]])
        let exactSize = try generous.serialized(input).count
        let exact = MCPResultLimiter(limits: MCPResultLimits(maximumSerializedBytes: exactSize))
        let result = try exact.limit(rows: [["value": "é😀\\\""]])
        XCTAssertEqual(try exact.serialized(result).count, exactSize)
        XCTAssertFalse(result.metadata.byteLimitReached)
        XCTAssertFalse(result.metadata.truncated)
    }

    func testElapsedLimitIsReportedWithoutSilentDrop() throws {
        let result = try MCPResultLimiter(limits: MCPResultLimits(maximumElapsed: .milliseconds(10))).limit(rows: [["id": "1"]], elapsed: .milliseconds(11))
        XCTAssertTrue(result.metadata.elapsedLimitReached)
        XCTAssertTrue(result.metadata.truncated)
    }

    func testExactAndCaseInsensitiveRedaction() throws {
        let policy = MCPRedactionPolicy(exact: ["apiKey"], caseInsensitive: ["password"])
        let result = try MCPResultLimiter().limit(rows: [["apiKey": "one", "apikey": "two", "PASSWORD": "three", "public": "ok"]], redaction: policy)
        XCTAssertEqual(result.rows[0]["apiKey"]!, "[REDACTED]")
        XCTAssertEqual(result.rows[0]["apikey"]!, "two")
        XCTAssertEqual(result.rows[0]["PASSWORD"]!, "[REDACTED]")
        XCTAssertEqual(result.rows[0]["public"]!, "ok")
        XCTAssertEqual(result.metadata.redactedColumns, ["PASSWORD", "apiKey"])
    }

    func testCaseInsensitiveRedactionDoesNotBecomeSubstringMatching() throws {
        let policy = MCPRedactionPolicy(exact: ["token"], caseInsensitive: ["password"])
        let result = try MCPResultLimiter().limit(rows: [[
            "token": "secret", "Token": "public", "PASSWORD": "secret",
            "password_hint": "public", "my_password": "public",
        ]], redaction: policy)
        XCTAssertEqual(result.rows[0]["token"]!, "[REDACTED]")
        XCTAssertEqual(result.rows[0]["Token"]!, "public")
        XCTAssertEqual(result.rows[0]["PASSWORD"]!, "[REDACTED]")
        XCTAssertEqual(result.rows[0]["password_hint"]!, "public")
        XCTAssertEqual(result.rows[0]["my_password"]!, "public")
    }

    /// `redactedColumns`/`truncatedCells` must reflect only rows actually
    /// returned. A row dropped by the *byte budget* (not the count-based
    /// prefix trim) is prepared — redacted and cell-truncated — before the
    /// budget decides it doesn't fit, so its contribution must be excluded
    /// from the final metadata once it's dropped.
    func testByteBudgetDroppedRowRedactionIsNotReported() throws {
        let redaction = MCPRedactionPolicy(caseInsensitive: ["password"])
        let visible = ["value": "ok"]
        let droppedByByteBudget = ["password": String(repeating: "x", count: 500)]
        let baseline = MCPResultLimiter(limits: MCPResultLimits(maximumSerializedBytes: 100_000))
        let visibleOnly = try baseline.limit(rows: [visible], redaction: redaction)
        let ceiling = try baseline.serialized(visibleOnly).count + 10
        let limiter = MCPResultLimiter(limits: MCPResultLimits(maximumRows: 10, maximumSerializedBytes: ceiling))
        let result = try limiter.limit(rows: [visible, droppedByByteBudget], redaction: redaction)

        XCTAssertEqual(result.rows.count, 1)
        XCTAssertEqual(result.metadata.omittedRows, 1)
        XCTAssertTrue(result.metadata.byteLimitReached)
        XCTAssertEqual(result.metadata.redactedColumns, [], "A byte-budget-dropped row's redacted column must not be reported")
    }

    func testTwoByteCellLimitProducesValidEmptyJSONStringAndMetadata() throws {
        let limiter = MCPResultLimiter(limits: MCPResultLimits(maximumCellBytes: 2, maximumSerializedBytes: 2_000))
        let result = try limiter.limit(rows: [["emoji": "😀"]])
        XCTAssertEqual(result.rows[0]["emoji"]!, "")
        XCTAssertEqual(result.metadata.truncatedCells, 1)
        XCTAssertTrue(result.metadata.truncated)
        XCTAssertEqual(try JSONEncoder().encode(result.rows[0]["emoji"]!).count, 2)
    }

    func testMetadataTooLargeFailsClosed() {
        let limiter = MCPResultLimiter(limits: MCPResultLimits(maximumSerializedBytes: 1))
        XCTAssertThrowsError(try limiter.limit(rows: [["id": "1"]])) { XCTAssertEqual($0 as? MCPResultLimiterError, .metadataExceedsByteLimit) }
    }

    func testSerializedCannotBeUsedToBypassLimiter() throws {
        let metadata = MCPTruncationMetadata(truncated: false, omittedRows: 0, omittedObjects: 0, omittedGraphNodes: 0, omittedGraphEdges: 0, truncatedCells: 0, byteLimitReached: false, elapsedLimitReached: false, redactedColumns: [])
        let forged = MCPBoundedResult(rows: [["value": String(repeating: "x", count: 500)]], objects: [], graphNodes: [], graphEdges: [], metadata: metadata)
        let limiter = MCPResultLimiter(limits: MCPResultLimits(maximumSerializedBytes: 256))
        XCTAssertThrowsError(try limiter.serialized(forged)) {
            XCTAssertEqual($0 as? MCPResultLimiterError, .serializedByteLimitExceeded)
        }
    }

    func testEncodingWorkIsLinearInKeptItems() throws {
        final class Meter: @unchecked Sendable { var bytes = 0 }
        let meter = Meter()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let limits = MCPResultLimits(
            maximumRows: 0, maximumObjects: 0, maximumGraphNodes: 0, maximumGraphEdges: 2_000,
            maximumCellBytes: 2_048, maximumSerializedBytes: 64 * 1024
        )
        let limiter = MCPResultLimiter(limits: limits, encode: { value in
            let data = try encoder.encode(value)
            meter.bytes += data.count
            return data
        })
        let edges = (0..<2_000).map { ["id": "\($0)", "payload": String(repeating: "x", count: 1_000)] }
        let result = try limiter.limit(graphEdges: edges)
        XCTAssertLessThanOrEqual(try encoder.encode(result).count, 64 * 1024)
        // Quadratic re-encoding measures in the gigabytes; linear stays well under this.
        XCTAssertLessThan(meter.bytes, 4 * 1024 * 1024)
    }

    func testOmittedCountDigitGrowthStaysUnderTheCeiling() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var producedResults = 0
        for ceiling in stride(from: 300, through: 1_400, by: 7) {
            let limits = MCPResultLimits(
                maximumRows: 10_000, maximumObjects: 0, maximumGraphNodes: 0, maximumGraphEdges: 0,
                maximumCellBytes: 64, maximumSerializedBytes: ceiling
            )
            let rows = (0..<10_000).map { ["v": "\($0)"] }
            guard let result = try? MCPResultLimiter(limits: limits).limit(rows: rows) else { continue }
            producedResults += 1
            XCTAssertLessThanOrEqual(try encoder.encode(result).count, ceiling, "ceiling \(ceiling)")
        }
        XCTAssertGreaterThan(producedResults, 0, "At least one ceiling in the sweep must produce a result")
    }

    /// `pessimisticMetadata` must reserve using whichever boolean spelling
    /// encodes wider (`false`, 5 bytes, not `true`, 4 bytes) so the
    /// reservation is a genuine upper bound and the final correction loop
    /// is not needed to compensate for an under-reservation. This sweeps a
    /// range of small item counts/ceilings around several exact-fit
    /// boundaries, where an under-reservation would otherwise cause the
    /// keep phase to admit content the true (unreserved-for) metadata size
    /// cannot actually afford, forcing the correction loop to drop it back
    /// out and mark `byteLimitReached`/`truncated` even though the exact
    /// fit needed no truncation at all.
    func testExactFitBoundariesNeverReportSpuriousTruncation() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        for itemCount in 1...6 {
            let rows = (0..<itemCount).map { ["v": "\($0)"] }
            let generous = MCPResultLimiter(limits: MCPResultLimits(maximumSerializedBytes: 10_000))
            let full = try generous.limit(rows: rows)
            let exactSize = try generous.serialized(full).count
            let exact = MCPResultLimiter(limits: MCPResultLimits(maximumSerializedBytes: exactSize))
            let result = try exact.limit(rows: rows)
            XCTAssertEqual(try exact.serialized(result).count, exactSize, "item count \(itemCount)")
            XCTAssertFalse(result.metadata.byteLimitReached, "item count \(itemCount)")
            XCTAssertFalse(result.metadata.truncated, "item count \(itemCount)")
        }
    }

    /// At a ceiling just under the exact fit, dropping the excess must
    /// happen inside `keep(...)`'s own budget accounting, not via the
    /// final `while` correction loop: the reservation already accounts for
    /// the true worst-case metadata width, so the loop's single pass
    /// should always pass, needing no correction (no second whole-result
    /// encode). A `true`-reservation would under-reserve here and need one
    /// more whole-result encode to notice and correct the overshoot.
    func testExactFitMinusOneOrTwoNeedsNoExtraWholeResultEncode() throws {
        let plainEncoder = JSONEncoder()
        plainEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let rows = (0..<5).map { ["v": "\($0)"] }
        let generous = MCPResultLimiter(limits: MCPResultLimits(maximumSerializedBytes: 10_000))
        let full = try generous.limit(rows: rows)
        let exactSize = try generous.serialized(full).count

        for delta in [1, 2] {
            final class Counter: @unchecked Sendable { var wholeResultEncodes = 0 }
            let counter = Counter()
            let ceiling = exactSize - delta
            let limiter = MCPResultLimiter(
                limits: MCPResultLimits(maximumSerializedBytes: ceiling),
                encode: { value in
                    if value is MCPBoundedResult { counter.wholeResultEncodes += 1 }
                    return try plainEncoder.encode(value)
                }
            )
            let result = try limiter.limit(rows: rows)
            XCTAssertLessThanOrEqual(try plainEncoder.encode(result).count, ceiling, "delta \(delta)")
            // One encode to size the reservation, one to check the final
            // result against the ceiling — no correction-loop iterations.
            XCTAssertEqual(counter.wholeResultEncodes, 2, "delta \(delta)")
        }
    }

    func testNegativeElapsedInputsFailClosed() {
        XCTAssertThrowsError(try MCPResultLimiter(limits: MCPResultLimits(maximumElapsed: .seconds(-1))).limit())
        XCTAssertThrowsError(try MCPResultLimiter().limit(elapsed: .milliseconds(-1)))
    }
}
