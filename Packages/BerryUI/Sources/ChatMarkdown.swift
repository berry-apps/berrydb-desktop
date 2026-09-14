import Foundation

/// A block-level element parsed from an assistant message. The chat renderer
/// turns each into a native view: paragraphs/lists via AttributedString markdown
/// (inline **bold**/`code`/links), code as a monospace box, mermaid via an
/// offline WebView. A small hand-rolled parser instead of a dependency — the
/// chat only needs these few blocks (simplicity first).
public enum ChatBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case code(language: String?, code: String)
    case mermaid(String)
    case bulletList([String])
    case orderedList(startIndex: Int, items: [String])
    case table(header: [String], rows: [[String]])
    case divider
}

public enum ChatMarkdown {
    /// Split an assistant reply into block elements, in order.
    public static func parse(_ source: String) -> [ChatBlock] {
        var blocks: [ChatBlock] = []
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraph = []
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block — captured verbatim, so `* ` / `# ` inside stay code.
            if trimmed.hasPrefix("```") {
                flushParagraph()
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index])
                    index += 1
                }
                index += 1 // consume the closing fence (harmless if absent)
                let body = code.joined(separator: "\n")
                blocks.append(language.lowercased() == "mermaid"
                    ? .mermaid(body)
                    : .code(language: language.isEmpty ? nil : language, code: body))
                continue
            }

            // GFM table: a header row of `|`-cells followed by a delimiter row
            // (`| --- | :--: |`). Without the delimiter underneath it's just prose.
            if trimmed.contains("|"), index + 1 < lines.count,
               isTableDelimiter(lines[index + 1].trimmingCharacters(in: .whitespaces)) {
                flushParagraph()
                let header = tableCells(trimmed)
                index += 2 // header + delimiter
                var rows: [[String]] = []
                while index < lines.count {
                    let row = lines[index].trimmingCharacters(in: .whitespaces)
                    guard row.contains("|"), !row.isEmpty else { break }
                    rows.append(tableCells(row))
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            if isHorizontalRule(trimmed) {
                flushParagraph()
                blocks.append(.divider)
                index += 1
                continue
            }

            if let heading = heading(trimmed) {
                flushParagraph()
                blocks.append(heading)
                index += 1
                continue
            }

            if isBullet(trimmed) {
                flushParagraph()
                var items: [String] = []
                while index < lines.count {
                    let item = lines[index].trimmingCharacters(in: .whitespaces)
                    guard isBullet(item) else { break }
                    items.append(String(item.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.bulletList(items))
                continue
            }

            if let firstMarker = orderedMarker(trimmed) {
                flushParagraph()
                let startIndex = firstMarker.number
                var items: [String] = []
                var lookAhead = index
                while lookAhead < lines.count {
                    let item = lines[lookAhead].trimmingCharacters(in: .whitespaces)
                    if let marker = orderedMarker(item) {
                        items.append(String(item.dropFirst(marker.length)).trimmingCharacters(in: .whitespaces))
                        lookAhead += 1
                    } else if item.isEmpty {
                        var peek = lookAhead + 1
                        while peek < lines.count && lines[peek].trimmingCharacters(in: .whitespaces).isEmpty {
                            peek += 1
                        }
                        if peek < lines.count, orderedMarker(lines[peek].trimmingCharacters(in: .whitespaces)) != nil {
                            lookAhead = peek
                        } else {
                            break
                        }
                    } else {
                        break
                    }
                }
                index = lookAhead
                blocks.append(.orderedList(startIndex: startIndex, items: items))
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            paragraph.append(line)
            index += 1
        }
        flushParagraph()
        return blocks
    }

    private static func isHorizontalRule(_ line: String) -> Bool {
        let noSpaces = line.replacingOccurrences(of: " ", with: "")
        guard noSpaces.count >= 3 else { return false }
        return noSpaces.allSatisfy { $0 == "-" }
            || noSpaces.allSatisfy { $0 == "*" }
            || noSpaces.allSatisfy { $0 == "_" }
    }

    private static func heading(_ line: String) -> ChatBlock? {
        guard line.hasPrefix("#") else { return nil }
        let level = line.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let rest = line.dropFirst(level)
        guard rest.hasPrefix(" ") else { return nil }
        return .heading(level: level, text: rest.trimmingCharacters(in: .whitespaces))
    }

    /// Split a table row into trimmed cells, ignoring the outer pipes.
    private static func tableCells(_ line: String) -> [String] {
        var body = line.trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|") { body.removeLast() }
        return body.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// A GFM delimiter row: every cell is dashes with optional alignment colons.
    private static func isTableDelimiter(_ line: String) -> Bool {
        guard line.contains("-") else { return false }
        let cells = tableCells(line)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            !cell.isEmpty && cell.contains("-") && cell.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    private static func isBullet(_ line: String) -> Bool {
        line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ")
    }

    /// Returns the starting number and marker length of an ordered-list marker (`1. ` / `2) `), or nil.
    private static func orderedMarker(_ line: String) -> (number: Int, length: Int)? {
        let digitsCount = line.prefix { $0.isNumber }.count
        guard digitsCount > 0, line.count > digitsCount + 1 else { return nil }
        guard let num = Int(line.prefix(digitsCount)) else { return nil }
        let afterIndex = line.index(line.startIndex, offsetBy: digitsCount)
        let after = line[afterIndex]
        guard after == "." || after == ")" else { return nil }
        let rest = line.dropFirst(digitsCount + 1)
        return rest.hasPrefix(" ") ? (num, digitsCount + 2) : nil
    }
}
