import Foundation

/// Line-comment toggling for the SQL editor (⌘/, docs/ui): comments every line
/// touched by the selection with `-- `, or uncomments when ALL non-blank
/// touched lines are already commented. Pure — the editor applies the result.
public enum SQLCommentToggler {
    public struct Result: Equatable {
        public let text: String
        /// Selection covering the same lines after the edit.
        public let selection: NSRange
    }

    public static func toggle(_ text: String, selection: NSRange) -> Result {
        let ns = text as NSString
        let clamped = NSRange(
            location: min(selection.location, ns.length),
            length: min(selection.length, ns.length - min(selection.location, ns.length))
        )
        let lineRange = ns.lineRange(for: clamped)
        let block = ns.substring(with: lineRange)
        let hadTrailingNewline = block.hasSuffix("\n")
        var lines = block.components(separatedBy: "\n")
        if hadTrailingNewline { lines.removeLast() }

        let nonBlank = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let allCommented = !nonBlank.isEmpty && nonBlank.allSatisfy {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("--")
        }

        let toggled: [String] = lines.map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if allCommented {
                guard trimmed.hasPrefix("--") else { return line }
                // Remove the first "--" (and one following space) after indent.
                if let range = line.range(of: "-- ") ?? line.range(of: "--") {
                    var result = line
                    result.removeSubrange(range)
                    return result
                }
                return line
            } else {
                guard !trimmed.isEmpty else { return line }
                return "-- " + line
            }
        }

        var newBlock = toggled.joined(separator: "\n")
        if hadTrailingNewline { newBlock += "\n" }
        let newText = ns.replacingCharacters(in: lineRange, with: newBlock)
        return Result(
            text: newText,
            selection: NSRange(location: lineRange.location, length: (newBlock as NSString).length)
        )
    }
}
