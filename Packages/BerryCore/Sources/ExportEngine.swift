import BerryDriverKit
import Foundation

/// Export formats. XLSX is a later phase.
public enum ExportFormat: Sendable {
    case csv(delimiter: String = ",", header: Bool = true, encoding: String.Encoding = .utf8)
    case jsonArray
    case ndjson
 /// INSERT statements — multi-row VALUES batched at `batchSize`,
    /// optionally prefixed with a DDL header (CREATE TABLE …).
    case sqlInsert(table: TableRef, dialect: any SQLDialect, batchSize: Int = 100, ddlHeader: String? = nil)
}

/// Streaming exporter: rows are encoded and
/// appended to the file batch by batch — RAM stays flat regardless of result
/// size (principle N3).
public enum ExportEngine {
    /// Export a live stream (no auto-LIMIT — the caller builds the stream).
    /// Returns the number of exported rows.
    @discardableResult
    public static func export(
        stream: AsyncThrowingStream<ResultEvent, Error>,
        to url: URL,
        format: ExportFormat
    ) async throws -> Int {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        return try await export(stream: stream, to: handle, format: format)
    }

    /// Append one exported stream to an already-open handle — lets a caller
    /// (e.g. `BackupService`) concatenate many objects' data into one file,
    /// interleaved with its own text (DDL headers), without truncating.
    @discardableResult
    public static func export(
        stream: AsyncThrowingStream<ResultEvent, Error>,
        to handle: FileHandle,
        format: ExportFormat
    ) async throws -> Int {
        var encoder = makeEncoder(format)
        var rowCount = 0
        var began = false

        for try await event in stream {
            switch event {
            case .columns(let columns):
                if !began {
                    began = true
                    if let head = encoder.begin(columns: columns) {
                        try handle.write(contentsOf: head)
                    }
                }
            case .rows(let batch):
                if !began {
                    began = true
                    if let head = encoder.begin(columns: []) {
                        try handle.write(contentsOf: head)
                    }
                }
                var chunk = Data()
                for row in batch {
                    chunk.append(encoder.encode(row: row))
                    rowCount += 1
                }
                try handle.write(contentsOf: chunk)
            case .complete:
                break
            }
        }
        if !began, let head = encoder.begin(columns: []) {
            try handle.write(contentsOf: head)
        }
        if let tail = encoder.end() {
            try handle.write(contentsOf: tail)
        }
        return rowCount
    }

    /// Export rows already in RAM (a grid's ResultBuffer content).
    @discardableResult
    public static func export(
        columns: [ColumnMeta],
        rows: [[BerryValue]],
        to url: URL,
        format: ExportFormat
    ) async throws -> Int {
        let stream = AsyncThrowingStream<ResultEvent, Error> { continuation in
            continuation.yield(.columns(columns))
            continuation.yield(.rows(rows))
            continuation.finish()
        }
        return try await export(stream: stream, to: url, format: format)
    }

    private static func makeEncoder(_ format: ExportFormat) -> any RowEncoder {
        switch format {
        case .csv(let delimiter, let header, let encoding):
            CSVRowEncoder(delimiter: delimiter, includeHeader: header, encoding: encoding)
        case .jsonArray:
            JSONArrayRowEncoder()
        case .ndjson:
            NDJSONRowEncoder()
        case .sqlInsert(let table, let dialect, let batchSize, let ddlHeader):
            SQLInsertRowEncoder(
                table: table, dialect: dialect,
                batchSize: max(1, batchSize), ddlHeader: ddlHeader
            )
        }
    }
}

// MARK: - Encoders

protocol RowEncoder {
    mutating func begin(columns: [ColumnMeta]) -> Data?
    mutating func encode(row: [BerryValue]) -> Data
    mutating func end() -> Data?
}

struct CSVRowEncoder: RowEncoder {
    let delimiter: String
    let includeHeader: Bool
    let encoding: String.Encoding
    private var columnNames: [String] = []

    init(delimiter: String, includeHeader: Bool, encoding: String.Encoding = .utf8) {
        self.delimiter = delimiter
        self.includeHeader = includeHeader
        self.encoding = encoding
    }

    /// Encode a chunk WITHOUT a byte-order mark — for UTF-16 the BOM is written
    /// once in `begin()`, so chunks use the fixed little-endian variant instead
    /// of `.utf16` (which would prepend a BOM to every row). Falls back to UTF-8.
    private func data(_ string: String) -> Data {
        let chunkEncoding: String.Encoding = (encoding == .utf16) ? .utf16LittleEndian : encoding
        return string.data(using: chunkEncoding) ?? Data(string.utf8)
    }

    mutating func begin(columns: [ColumnMeta]) -> Data? {
        columnNames = columns.map(\.name)
        var out = Data()
 // UTF-16 LE BOM up front so Excel reads non-ASCII correctly.
        if encoding == .utf16 { out.append(contentsOf: [0xFF, 0xFE]) }
        if includeHeader, !columnNames.isEmpty {
            out.append(data(columnNames.map(escape).joined(separator: delimiter) + "\n"))
        }
        return out.isEmpty ? nil : out
    }

    func encode(row: [BerryValue]) -> Data {
        let line = row.map { value -> String in
            // NULL exports as an empty unquoted field — distinguishable from
 // the quoted empty string "" (carried into exports).
            guard let text = value.displayString else { return "" }
            return escape(text)
        }
        .joined(separator: delimiter)
        return data(line + "\n")
    }

    func end() -> Data? { nil }

    private func escape(_ field: String) -> String {
        if field.contains(delimiter) || field.contains("\"") || field.contains("\n")
            || field.contains("\r") || field.isEmpty {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }
}

struct JSONArrayRowEncoder: RowEncoder {
    private var columnNames: [String] = []
    private var first = true

    mutating func begin(columns: [ColumnMeta]) -> Data? {
        columnNames = columns.map(\.name)
        return Data("[".utf8)
    }

    mutating func encode(row: [BerryValue]) -> Data {
        let object = JSONValueEncoding.object(columnNames: columnNames, row: row)
        let prefix = first ? "\n" : ",\n"
        first = false
        return Data((prefix + object).utf8)
    }

    mutating func end() -> Data? {
        Data((first ? "]" : "\n]").utf8)
    }
}

struct NDJSONRowEncoder: RowEncoder {
    private var columnNames: [String] = []

    mutating func begin(columns: [ColumnMeta]) -> Data? {
        columnNames = columns.map(\.name)
        return nil
    }

    func encode(row: [BerryValue]) -> Data {
        Data((JSONValueEncoding.object(columnNames: columnNames, row: row) + "\n").utf8)
    }

    func end() -> Data? { nil }
}

/// INSERT-statement encoder: buffers up to `batchSize` rows into one
/// multi-row `INSERT … VALUES (…),(…)` statement — RAM stays flat because the
/// buffer never exceeds one batch (principle N3). Values render through the
/// dialect's literal escaping, the same safe path as ChangeSet.
struct SQLInsertRowEncoder: RowEncoder {
    let table: TableRef
    let dialect: any SQLDialect
    let batchSize: Int
    let ddlHeader: String?
    private var columnNames: [String] = []
    private var pending: [[BerryValue]] = []

    init(table: TableRef, dialect: any SQLDialect, batchSize: Int, ddlHeader: String?) {
        self.table = table
        self.dialect = dialect
        self.batchSize = batchSize
        self.ddlHeader = ddlHeader
    }

    mutating func begin(columns: [ColumnMeta]) -> Data? {
        columnNames = columns.map(\.name)
        guard let ddlHeader, !ddlHeader.isEmpty else { return nil }
        return Data((ddlHeader + "\n\n").utf8)
    }

    mutating func encode(row: [BerryValue]) -> Data {
        pending.append(row)
        guard pending.count >= batchSize else { return Data() }
        return flush()
    }

    mutating func end() -> Data? {
        pending.isEmpty ? nil : flush()
    }

    private mutating func flush() -> Data {
        guard !pending.isEmpty else { return Data() }
        let cols = columnNames.map(dialect.quoteIdentifier).joined(separator: ", ")
        let tuples = pending
            .map { row in "(" + row.map(dialect.literal).joined(separator: ", ") + ")" }
            .joined(separator: ",\n  ")
        pending.removeAll(keepingCapacity: true)
        let target = dialect.qualifiedName(of: table)
        return Data("INSERT INTO \(target) (\(cols)) VALUES\n  \(tuples);\n".utf8)
    }
}

/// Hand-rolled JSON encoding: keeps column order, streams row by row, and
/// maps BerryValue types faithfully (numbers stay numbers, NULL stays null,
/// bytes become base64).
enum JSONValueEncoding {
    static func object(columnNames: [String], row: [BerryValue]) -> String {
        var parts: [String] = []
        parts.reserveCapacity(row.count)
        for (index, value) in row.enumerated() {
            let name = index < columnNames.count ? columnNames[index] : "col\(index)"
            parts.append("\(string(name)):\(scalar(value))")
        }
        return "{" + parts.joined(separator: ",") + "}"
    }

    static func scalar(_ value: BerryValue) -> String {
        switch value {
        case .null:
            return "null"
        case .bool(let b):
            return b ? "true" : "false"
        case .int(let i):
            return String(i)
        case .double(let d):
            return d.isFinite ? String(d) : "null"
        case .decimal(let s):
            // Verbatim when numeric, else quoted — never lose precision.
            let numeric = CharacterSet(charactersIn: "0123456789.+-eE")
            return s.unicodeScalars.allSatisfy { numeric.contains($0) } && !s.isEmpty
                ? s : string(s)
        case .text(let s):
            return string(s)
        case .json(let s):
            // Already JSON from the DBMS — embed as-is.
            return s
        case .bytes(let data):
            return string(data.base64EncodedString())
        case .date, .timestamp, .uuid:
            return string(value.displayString ?? "")
        case .unknown(let raw, _):
            return string(raw.base64EncodedString())
        }
    }

    static func string(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
