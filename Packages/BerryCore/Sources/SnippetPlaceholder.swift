import Foundation

/// Saved-query snippet placeholders: `${N:label}` in a saved query's
/// SQL is stripped down to `label` on insert. The FIRST occurrence (by
/// placeholder number, not source position) is reported back as a selection
/// range so the editor can pre-select it — the user types straight over it,
/// matching the snippet placeholder behavior specified in the feature spec.
/// Only one auto-selected stop per insert (v1); full Tab-cycling between
/// multiple stops is out of scope for this pass.
public enum SnippetPlaceholder {
    private static let pattern = try! NSRegularExpression(pattern: #"\$\{(\d+):([^}]*)\}"#)

    public static func resolve(_ text: String) -> (text: String, selection: NSRange?) {
        let ns = text as NSString
        var result = ""
        var firstStopRange: NSRange?
        var lowestNumberSeen: Int?
        var cursor = 0

        let matches = pattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for match in matches {
            let literalRange = NSRange(location: cursor, length: match.range.location - cursor)
            result += ns.substring(with: literalRange)

            let number = Int(ns.substring(with: match.range(at: 1))) ?? 0
            let label = ns.substring(with: match.range(at: 2))
            let labelStart = (result as NSString).length
            result += label

            if lowestNumberSeen == nil || number < lowestNumberSeen! {
                lowestNumberSeen = number
                firstStopRange = NSRange(location: labelStart, length: (label as NSString).length)
            }
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return (result, firstStopRange)
    }
}
