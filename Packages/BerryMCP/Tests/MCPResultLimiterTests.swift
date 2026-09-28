import Foundation
import Testing

@testable import BerryMCP

@Suite("MCP result limiter")
struct MCPResultLimiterTests {
    @Test func allCountCeilingsHaveExplicitOmissions() throws {
        let limits = MCPResultLimits(maximumRows: 1, maximumObjects: 1, maximumGraphNodes: 1, maximumGraphEdges: 2, maximumCellBytes: 100, maximumSerializedBytes: 10_000)
        let limiter = MCPResultLimiter(limits: limits)
        let values = [["id": "1"], ["id": "2"], ["id": "3"]]
        let result = try limiter.limit(rows: values, objects: values, graphNodes: values, graphEdges: values)
        #expect(result.rows.count == 1)
        #expect(result.metadata.omittedRows == 2)
        #expect(result.objects.count == 1)
        #expect(result.metadata.omittedObjects == 2)
        #expect(result.graphNodes.count == 1)
        #expect(result.metadata.omittedGraphNodes == 2)
        #expect(result.graphEdges.count == 2)
        #expect(result.metadata.omittedGraphEdges == 1)
        #expect(result.metadata.truncated)
    }

    @Test func omittedTailsAreNotRedactedOrCellTruncated() throws {
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

        #expect(result.metadata.omittedRows == 1)
        #expect(result.metadata.omittedObjects == 1)
        #expect(result.metadata.omittedGraphNodes == 1)
        #expect(result.metadata.omittedGraphEdges == 1)
        #expect(result.metadata.truncatedCells == 0)
        #expect(result.metadata.redactedColumns == [])
    }

    @Test func uTF8CellCeilingMeasuresJSONEncodedBytes() throws {
        let limits = MCPResultLimits(maximumRows: 1, maximumCellBytes: 12, maximumSerializedBytes: 2_000)
        let result = try MCPResultLimiter(limits: limits).limit(rows: [["emoji": "😀😀😀😀", "escape": "\\\"\\\"\\\""]])
        let encoder = JSONEncoder()
        for value in result.rows[0].values.compactMap({ $0 }) {
            do {
                let encoded = try encoder.encode(value)
                #expect(encoded.count <= 12)
            } catch {
                Issue.record(error)
            }
        }
        #expect(result.metadata.truncatedCells == 2)
    }

    @Test func uTF8TruncationPreservesValidOriginalPrefixWithoutReplacementCharacters() throws {
        let inputs = [
            "😀😀😀tail",
            "e\u{301}e\u{301}e\u{301}tail",
            "👨‍👩‍👧‍👦family-tail",
        ]
        for input in inputs {
            let byteCeiling = 10
            let limiter = MCPResultLimiter(limits: MCPResultLimits(maximumRows: 1, maximumCellBytes: byteCeiling, maximumSerializedBytes: 2_000))
            let result = try limiter.limit(rows: [["value": input]])
            let output = try #require(result.rows[0]["value"]!, "\(input)")
            #expect(output.hasSuffix("…"), "\(input)")
            let prefix = String(output.dropLast())
            #expect(input.hasPrefix(prefix), "Output must be a valid original prefix: \(output)")
            #expect(!output.contains("\u{FFFD}"), "Truncation introduced a replacement character")
            do {
                let encoded = try JSONEncoder().encode(output)
                #expect(encoded.count <= byteCeiling, "\(input)")
            } catch {
                Issue.record(error, "\(input)")
            }
        }
    }

    /// A multi-megabyte cell must cost work bounded by the cell ceiling, not
    /// by its own length: only a prefix of at most `maximumCellBytes`
    /// characters can ever fit, so nothing past it is indexed.
    @Test(arguments: [
        ("a", 8 << 20),
        ("😀", 2 << 20),
        ("\u{0}", 4 << 20),
        ("e\u{301}", 2 << 20),
    ])
    func multiMegabyteCellWorkIsBoundedByTheCellCeiling(unit: String, repetitions: Int) throws {
        let input = String(repeating: unit, count: repetitions)
        let ceiling = 65_536
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        let truncated = MCPResultLimiter.truncatedCell(input, maximumEncodedBytes: ceiling, encoder: encoder)

        #expect(truncated.examinedCharacters <= ceiling)
        #expect(truncated.value.hasSuffix("…"))
        #expect(input.hasPrefix(String(truncated.value.dropLast())))
        #expect(try encoder.encode(truncated.value).count <= ceiling)

        let limiter = MCPResultLimiter(limits: MCPResultLimits(maximumRows: 1, maximumCellBytes: ceiling))
        let result = try limiter.limit(rows: [["value": input]])
        let kept = try #require(result.rows.first?["value"] ?? nil)
        #expect(try encoder.encode(kept).count <= ceiling)
        #expect(result.metadata.truncatedCells == 1)
    }

    @Test func cellThatAlreadyFitsIsNotIndexed() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let input = String(repeating: "a", count: 1_000)

        let result = MCPResultLimiter.truncatedCell(input, maximumEncodedBytes: 65_536, encoder: encoder)

        #expect(result.value == input)
        #expect(result.examinedCharacters == 0)
    }

    @Test func existingReplacementCharacterIsPreservedWhenItFits() throws {
        let input = "ok\u{FFFD}" + String(repeating: "x", count: 30)
        let limiter = MCPResultLimiter(limits: MCPResultLimits(maximumRows: 1, maximumCellBytes: 14, maximumSerializedBytes: 2_000))
        let output = try #require(try limiter.limit(rows: [["value": input]]).rows[0]["value"]!)
        #expect(output.contains("\u{FFFD}"))
        #expect(input.hasPrefix(String(output.dropLast())))
        #expect(try JSONEncoder().encode(output).count <= 14)
    }

    @Test func serializedByteCeilingIsExact() throws {
        let baseline = MCPResultLimiter(limits: MCPResultLimits(maximumSerializedBytes: 10_000))
        let full = try baseline.limit(rows: (0..<20).map { ["value": String(repeating: "é", count: 20) + "\($0)"] })
        let metadataOnlySize = try baseline.serialized(MCPBoundedResult(rows: [], objects: [], graphNodes: [], graphEdges: [], metadata: full.metadata)).count
        let ceiling = metadataOnlySize + 80
        let limiter = MCPResultLimiter(limits: MCPResultLimits(maximumSerializedBytes: ceiling))
        let bounded = try limiter.limit(rows: (0..<20).map { ["value": String(repeating: "é", count: 20) + "\($0)"] })
        do {
            let size = try limiter.serialized(bounded).count
            #expect(size <= ceiling)
        } catch {
            Issue.record(error)
        }
        #expect(bounded.metadata.byteLimitReached)
        #expect(bounded.metadata.omittedRows > 0)
    }

    @Test func exactSerializedBoundaryDoesNotReportTruncation() throws {
        let generous = MCPResultLimiter(limits: MCPResultLimits(maximumSerializedBytes: 10_000))
        let input = try generous.limit(rows: [["value": "é😀\\\""]])
        let exactSize = try generous.serialized(input).count
        let exact = MCPResultLimiter(limits: MCPResultLimits(maximumSerializedBytes: exactSize))
        let result = try exact.limit(rows: [["value": "é😀\\\""]])
        do {
            let size = try exact.serialized(result).count
            #expect(size == exactSize)
        } catch {
            Issue.record(error)
        }
        #expect(!result.metadata.byteLimitReached)
        #expect(!result.metadata.truncated)
    }

    @Test func elapsedLimitIsReportedWithoutSilentDrop() throws {
        let result = try MCPResultLimiter(limits: MCPResultLimits(maximumElapsed: .milliseconds(10))).limit(rows: [["id": "1"]], elapsed: .milliseconds(11))
        #expect(result.metadata.elapsedLimitReached)
        #expect(result.metadata.truncated)
    }

    @Test func exactAndCaseInsensitiveRedaction() throws {
        let policy = MCPRedactionPolicy(exact: ["apiKey"], caseInsensitive: ["password"])
        let result = try MCPResultLimiter().limit(rows: [["apiKey": "one", "apikey": "two", "PASSWORD": "three", "public": "ok"]], redaction: policy)
        #expect(result.rows[0]["apiKey"]! == "[REDACTED]")
        #expect(result.rows[0]["apikey"]! == "two")
        #expect(result.rows[0]["PASSWORD"]! == "[REDACTED]")
        #expect(result.rows[0]["public"]! == "ok")
        #expect(result.metadata.redactedColumns == ["PASSWORD", "apiKey"])
    }

    @Test func caseInsensitiveRedactionDoesNotBecomeSubstringMatching() throws {
        let policy = MCPRedactionPolicy(exact: ["token"], caseInsensitive: ["password"])
        let result = try MCPResultLimiter().limit(rows: [[
            "token": "secret", "Token": "public", "PASSWORD": "secret",
            "password_hint": "public", "my_password": "public",
        ]], redaction: policy)
        #expect(result.rows[0]["token"]! == "[REDACTED]")
        #expect(result.rows[0]["Token"]! == "public")
        #expect(result.rows[0]["PASSWORD"]! == "[REDACTED]")
        #expect(result.rows[0]["password_hint"]! == "public")
        #expect(result.rows[0]["my_password"]! == "public")
    }

    /// `redactedColumns`/`truncatedCells` must reflect only rows actually
    /// returned. A row dropped by the *byte budget* (not the count-based
    /// prefix trim) is prepared — redacted and cell-truncated — before the
    /// budget decides it doesn't fit, so its contribution must be excluded
    /// from the final metadata once it's dropped.
    @Test func byteBudgetDroppedRowRedactionIsNotReported() throws {
        let redaction = MCPRedactionPolicy(caseInsensitive: ["password"])
        let visible = ["value": "ok"]
        let droppedByByteBudget = ["password": String(repeating: "x", count: 500)]
        let baseline = MCPResultLimiter(limits: MCPResultLimits(maximumSerializedBytes: 100_000))
        let visibleOnly = try baseline.limit(rows: [visible], redaction: redaction)
        let ceiling = try baseline.serialized(visibleOnly).count + 10
        let limiter = MCPResultLimiter(limits: MCPResultLimits(maximumRows: 10, maximumSerializedBytes: ceiling))
        let result = try limiter.limit(rows: [visible, droppedByByteBudget], redaction: redaction)

        #expect(result.rows.count == 1)
        #expect(result.metadata.omittedRows == 1)
        #expect(result.metadata.byteLimitReached)
        #expect(result.metadata.redactedColumns == [], "A byte-budget-dropped row's redacted column must not be reported")
    }

    @Test func twoByteCellLimitProducesValidEmptyJSONStringAndMetadata() throws {
        let limiter = MCPResultLimiter(limits: MCPResultLimits(maximumCellBytes: 2, maximumSerializedBytes: 2_000))
        let result = try limiter.limit(rows: [["emoji": "😀"]])
        #expect(result.rows[0]["emoji"]! == "")
        #expect(result.metadata.truncatedCells == 1)
        #expect(result.metadata.truncated)
        #expect(try JSONEncoder().encode(result.rows[0]["emoji"]!).count == 2)
    }

    @Test func metadataTooLargeFailsClosed() {
        let limiter = MCPResultLimiter(limits: MCPResultLimits(maximumSerializedBytes: 1))
        #expect(throws: MCPResultLimiterError.metadataExceedsByteLimit) {
            try limiter.limit(rows: [["id": "1"]])
        }
    }

    @Test func serializedCannotBeUsedToBypassLimiter() throws {
        let metadata = MCPTruncationMetadata(truncated: false, omittedRows: 0, omittedObjects: 0, omittedGraphNodes: 0, omittedGraphEdges: 0, truncatedCells: 0, byteLimitReached: false, elapsedLimitReached: false, redactedColumns: [])
        let forged = MCPBoundedResult(rows: [["value": String(repeating: "x", count: 500)]], objects: [], graphNodes: [], graphEdges: [], metadata: metadata)
        let limiter = MCPResultLimiter(limits: MCPResultLimits(maximumSerializedBytes: 256))
        #expect(throws: MCPResultLimiterError.serializedByteLimitExceeded) {
            try limiter.serialized(forged)
        }
    }

    @Test func encodingWorkIsLinearInKeptItems() throws {
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
        do {
            let size = try encoder.encode(result).count
            #expect(size <= 64 * 1024)
        } catch {
            Issue.record(error)
        }
        // Quadratic re-encoding measures in the gigabytes; linear stays well under this.
        #expect(meter.bytes < 4 * 1024 * 1024)
    }

    @Test func omittedCountDigitGrowthStaysUnderTheCeiling() throws {
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
            do {
                let size = try encoder.encode(result).count
                #expect(size <= ceiling, "ceiling \(ceiling)")
            } catch {
                Issue.record(error, "ceiling \(ceiling)")
            }
        }
        #expect(producedResults > 0, "At least one ceiling in the sweep must produce a result")
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
    @Test func exactFitBoundariesNeverReportSpuriousTruncation() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        for itemCount in 1...6 {
            let rows = (0..<itemCount).map { ["v": "\($0)"] }
            let generous = MCPResultLimiter(limits: MCPResultLimits(maximumSerializedBytes: 10_000))
            let full = try generous.limit(rows: rows)
            let exactSize = try generous.serialized(full).count
            let exact = MCPResultLimiter(limits: MCPResultLimits(maximumSerializedBytes: exactSize))
            let result = try exact.limit(rows: rows)
            do {
                let size = try exact.serialized(result).count
                #expect(size == exactSize, "item count \(itemCount)")
            } catch {
                Issue.record(error, "item count \(itemCount)")
            }
            #expect(!result.metadata.byteLimitReached, "item count \(itemCount)")
            #expect(!result.metadata.truncated, "item count \(itemCount)")
        }
    }

    /// At a ceiling just under the exact fit, dropping the excess must
    /// happen inside `keep(...)`'s own budget accounting, not via the
    /// final `while` correction loop: the reservation already accounts for
    /// the true worst-case metadata width, so the loop's single pass
    /// should always pass, needing no correction (no second whole-result
    /// encode). A `true`-reservation would under-reserve here and need one
    /// more whole-result encode to notice and correct the overshoot.
    @Test func exactFitMinusOneOrTwoNeedsNoExtraWholeResultEncode() throws {
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
            do {
                let size = try plainEncoder.encode(result).count
                #expect(size <= ceiling, "delta \(delta)")
            } catch {
                Issue.record(error, "delta \(delta)")
            }
            // One encode to size the reservation, one to check the final
            // result against the ceiling — no correction-loop iterations.
            #expect(counter.wholeResultEncodes == 2, "delta \(delta)")
        }
    }

    @Test func negativeElapsedInputsFailClosed() {
        #expect(throws: (any Error).self) { try MCPResultLimiter(limits: MCPResultLimits(maximumElapsed: .seconds(-1))).limit() }
        #expect(throws: (any Error).self) { try MCPResultLimiter().limit(elapsed: .milliseconds(-1)) }
    }
}
