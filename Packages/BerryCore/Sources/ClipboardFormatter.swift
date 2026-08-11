import BerryDriverKit
import Foundation

/// Copy-as builders (DL-07): selection → CSV / JSON / SQL INSERT / Markdown.
/// Pure string builders so every format is unit-testable.
public enum ClipboardFormatter {
    public static func csv(columns: [ColumnMeta], rows: [[BerryValue]]) -> String {
        var encoder = CSVRowEncoder(delimiter: ",", includeHeader: true)
        var out = Data()
        if let head = encoder.begin(columns: columns) { out.append(head) }
        for row in rows { out.append(encoder.encode(row: row)) }
        return String(data: out, encoding: .utf8) ?? ""
    }

    public static func json(columns: [ColumnMeta], rows: [[BerryValue]]) -> String {
        let names = columns.map(\.name)
        let objects = rows.map { JSONValueEncoding.object(columnNames: names, row: $0) }
        return "[\n" + objects.joined(separator: ",\n") + "\n]"
    }

    /// Multi-row INSERT via the session dialect — pastes straight back into
    /// any SQL editor (values rendered by the same literal engine as
    /// ChangeSet, docs/architecture/06 · L3).
    public static func sqlInserts(
        table: TableRef,
        columns: [ColumnMeta],
        rows: [[BerryValue]],
        dialect: any SQLDialect
    ) -> String {
        guard !rows.isEmpty else { return "" }
        let names = columns.map { dialect.quoteIdentifier($0.name) }.joined(separator: ", ")
        let values = rows.map { row in
            "(" + row.map { dialect.literal($0) }.joined(separator: ", ") + ")"
        }
        return "INSERT INTO \(dialect.qualifiedName(of: table)) (\(names)) VALUES\n"
            + values.joined(separator: ",\n") + ";"
    }

    public static func markdown(columns: [ColumnMeta], rows: [[BerryValue]]) -> String {
        func cell(_ text: String) -> String {
            text.replacingOccurrences(of: "|", with: "\\|")
                .replacingOccurrences(of: "\n", with: " ")
        }
        let header = "| " + columns.map { cell($0.name) }.joined(separator: " | ") + " |"
        let divider = "|" + columns.map { _ in "---" }.joined(separator: "|") + "|"
        let body = rows.map { row in
            "| " + row.map { cell($0.displayString ?? "NULL") }.joined(separator: " | ") + " |"
        }
        return ([header, divider] + body).joined(separator: "\n")
    }
}
