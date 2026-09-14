import Foundation

/// RFC 4180-style CSV parser. A small state machine: fields may be
/// quoted, quotes escape as `""`, and quoted fields may contain the delimiter
/// or newlines. Each emitted record carries the 1-based physical line where it
/// starts, so the importer can report failures by source line.
public enum CSVParser {
    public struct Record: Equatable, Sendable {
        public let line: Int
        public let fields: [String]
    }

    /// Streaming parse: invokes `onRecord` per record so callers can batch
    /// without materializing every row. Blank trailing lines are ignored.
    public static func parse(
        _ text: String,
        delimiter: Character = ",",
        _ onRecord: (Record) -> Void
    ) {
        var field = ""
        var fields: [String] = []
        var inQuotes = false
        var lineNumber = 1
        var recordStartLine = 1
        var sawAnyChar = false
        var fieldStarted = false

        let scalars = Array(text)
        var i = 0

        func endField() {
            fields.append(field)
            field = ""
            fieldStarted = false
        }
        func endRecord() {
            endField()
            // Skip a fully blank line (single empty field, nothing seen).
            if !(fields.count == 1 && fields[0].isEmpty) {
                onRecord(Record(line: recordStartLine, fields: fields))
            }
            fields = []
            sawAnyChar = false
        }

        while i < scalars.count {
            let c = scalars[i]
            if !sawAnyChar, !inQuotes {
                recordStartLine = lineNumber
            }
            if inQuotes {
                if c == "\"" {
                    // Escaped quote?
                    if i + 1 < scalars.count, scalars[i + 1] == "\"" {
                        field.append("\"")
                        i += 2
                        continue
                    }
                    inQuotes = false
                    i += 1
                    continue
                }
                if c == "\n" { lineNumber += 1 }
                field.append(c)
                i += 1
                continue
            }
            switch c {
            case "\"" where !fieldStarted:
                sawAnyChar = true
                fieldStarted = true
                inQuotes = true
                i += 1
            case delimiter:
                sawAnyChar = true
                endField()
                i += 1
            case "\r":
                // Swallow CR; the following LF ends the record.
                i += 1
            case "\n":
                lineNumber += 1
                endRecord()
                i += 1
            default:
                sawAnyChar = true
                fieldStarted = true
                field.append(c)
                i += 1
            }
        }
        // Final record without a trailing newline.
        if sawAnyChar || !fields.isEmpty {
            endRecord()
        }
    }

    /// Convenience: parse the whole text into records (used by tests and small
    /// imports). Large imports should prefer the streaming `parse`.
    public static func parse(_ text: String, delimiter: Character = ",") -> [Record] {
        var out: [Record] = []
        parse(text, delimiter: delimiter) { out.append($0) }
        return out
    }
}
