import Foundation
import Testing

@testable import BerryCore

@Suite("HexDump & pretty JSON (DL-06)")
struct HexDumpTests {
    @Test func formatsClassicHexLines() {
        let dump = HexDump.format(Data("Hello, Berry!".utf8))
        let lines = dump.split(separator: "\n")
        #expect(lines.count == 1)
        #expect(lines[0].hasPrefix("00000000  48 65 6c 6c 6f"))
        #expect(lines[0].hasSuffix("|Hello, Berry!|"))
    }

    @Test func nonPrintableBytesBecomeDots() {
        let dump = HexDump.format(Data([0x00, 0x41, 0xFF]))
        #expect(dump.contains("|.A.|"))
    }

    @Test func truncatesHugeBlobs() {
        let dump = HexDump.format(Data(repeating: 0xAB, count: 100), maxBytes: 32)
        #expect(dump.contains("more bytes"))
    }

    @Test func prettyPrintsValidJSON() {
        let pretty = HexDump.prettyJSON(#"{"b":1,"a":{"x":[1,2]}}"#)
        #expect(pretty?.contains("\"a\" : {") == true)
        #expect(HexDump.prettyJSON("not json {") == nil)
    }
}
