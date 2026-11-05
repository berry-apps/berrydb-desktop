import CryptoKit
import Foundation

/// One tool call as written to the audit file. It carries no query text, row
/// values or error detail beyond a short classification, since the file sits
/// in a user-readable directory; its digest still confirms a guessed query.
public struct MCPAuditRecord: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case ok, error, invalidParams = "invalid_params", cancelled
    }

    public var v: Int
    public var at: Date
    public var host: String
    public var projectID: UUID?
    public var profileID: UUID?
    public var tool: String
    public var outcome: Outcome
    public var error: String?
    public var digest: String?
    public var durationMs: Int
    public var rows: Int?
    public var bytes: Int
    public var truncated: Bool?
    public var redacted: Bool?
    public var consumedCapacityUnits: Double?

    public init(
        at: Date, host: String, projectID: UUID?, profileID: UUID?, tool: String, outcome: Outcome,
        error: String? = nil, digest: String? = nil, durationMs: Int, rows: Int? = nil, bytes: Int,
        truncated: Bool? = nil, redacted: Bool? = nil, consumedCapacityUnits: Double? = nil
    ) {
        self.v = 1
        self.at = at
        self.host = host
        self.projectID = projectID
        self.profileID = profileID
        self.tool = tool
        self.outcome = outcome
        self.error = error
        self.digest = digest
        self.durationMs = durationMs
        self.rows = rows
        self.bytes = bytes
        self.truncated = truncated
        self.redacted = redacted
        self.consumedCapacityUnits = consumedCapacityUnits
    }

    /// Spelled out because the snake_case key strategies map `projectID` to
    /// `project_id` when encoding but back to `projectId` when decoding.
    private enum CodingKeys: String, CodingKey {
        case v, at, host, tool, outcome, error, digest, rows, bytes, truncated, redacted
        case projectID = "project_id"
        case profileID = "profile_id"
        case durationMs = "duration_ms"
        case consumedCapacityUnits = "consumed_capacity_units"
    }
}

public enum MCPAuditLog {
    public static let fileName = "mcp-audit.jsonl"

    /// A record written by the helper is far smaller. The agent can edit this
    /// file, and a line it inflates must not stall the app while it reads.
    public static let maximumLineBytes = 4096

    /// Once the file passes the threshold it is cut back to the keep size, so
    /// trimming happens rarely instead of on every append, and the file stays
    /// small enough to read whole.
    public static let capThresholdBytes = 4_194_304
    public static let capKeepBytes = 2_097_152

    public static func url(besideStore storePath: String) -> URL {
        URL(fileURLWithPath: storePath).deletingLastPathComponent().appendingPathComponent(fileName)
    }

    /// Only computes the location; the directory is the app's to create.
    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("BerryDB").appendingPathComponent(fileName)
    }

    /// A formatter is built per call because `ISO8601DateFormatter` is not
    /// `Sendable` and cannot be shared by the `@Sendable` date strategies.
    private static func makeFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }

    public static func line(_ record: MCPAuditRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(makeFormatter().string(from: date))
        }
        return try encoder.encode(record) + Data([0x0A])
    }

    public static func record(from line: Data) -> MCPAuditRecord? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = makeFormatter().date(from: text) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "Not an ISO 8601 timestamp"))
            }
            return date
        }
        guard let record = try? decoder.decode(MCPAuditRecord.self, from: line), record.v == 1 else { return nil }
        return record
    }

    public static func read(from url: URL) -> [MCPAuditRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A, omittingEmptySubsequences: true)
            .compactMap { $0.count <= maximumLineBytes ? record(from: Data($0)) : nil }
    }

    /// The replacement is written beside the original and swapped in, so a
    /// reader never sees a half-written file. Records a helper appends
    /// between the read here and the rename go to the replaced file and are
    /// lost; the helper opens the file per record, so the next one lands in
    /// the new file.
    ///
    /// Lines longer than `maximumLineBytes` are dropped rather than kept,
    /// since `read` would skip them anyway, and the newest valid line is kept
    /// even when it alone exceeds `keepBytes`, so one inflated line cannot
    /// empty the file.
    public static func cap(
        at url: URL, thresholdBytes: Int = capThresholdBytes, keepBytes: Int = capKeepBytes
    ) throws {
        guard let data = try? Data(contentsOf: url), data.count > thresholdBytes else { return }
        var newestFirst: [Data.SubSequence] = []
        var kept = 0
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true).reversed() {
            guard line.count <= maximumLineBytes else { continue }
            let size = line.count + 1
            if kept + size > keepBytes, !newestFirst.isEmpty { break }
            kept += size
            newestFirst.append(line)
        }
        var tail = Data(capacity: kept)
        for line in newestFirst.reversed() {
            tail.append(contentsOf: line)
            tail.append(0x0A)
        }

        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).tmp-\(ProcessInfo.processInfo.processIdentifier)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: tail, attributes: [.posixPermissions: 0o600])
        else { throw CocoaError(.fileWriteUnknown) }
        // rename(2) rather than `replaceItemAt`, which keeps the old file's
        // permissions: the trimmed file must come out owner-only either way.
        guard rename(temporary.path, url.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temporary)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
}

/// What a digest is computed over: the request, never the result.
public enum MCPAuditQuery: Equatable, Sendable {
    case sql(String)
    case partitionQuery(table: String, indexName: String?, keyCondition: String, projection: [String])

    /// Domain-separated so a SQL text can never collide with a DynamoDB
    /// request. Every DynamoDB field is length-prefixed, and an absent index is
    /// marked apart from an empty name, so no two distinct requests encode to
    /// the same input whatever characters their names contain.
    fileprivate var canonicalInput: String {
        switch self {
        case .sql(let text):
            return "berrydb-mcp-audit/sql\n" + text
        case .partitionQuery(let table, let indexName, let keyCondition, let projection):
            var input = "berrydb-mcp-audit/dynamodb\n" + MCPAuditDigest.field(table)
            input += indexName.map { "i" + MCPAuditDigest.field($0) } ?? "-"
            input += MCPAuditDigest.field(keyCondition) + "\(projection.count):"
            for name in projection { input += MCPAuditDigest.field(name) }
            return input
        }
    }
}

/// Query identifiers for the audit file: an HMAC-SHA256 under a key the audit
/// file does not contain, so the file shows that two calls ran the same query
/// without storing what it said, and a holder of the file alone cannot confirm
/// a guessed query or key value.
public struct MCPAuditDigest {
    private let key: SymmetricKey

    public init(key: SymmetricKey) {
        self.key = key
    }

    /// First 16 bytes of the MAC, lowercase hex.
    public func digest(_ query: MCPAuditQuery) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data(query.canonicalInput.utf8), using: key)
        return Self.hex(code)
    }

    /// Unkeyed form, still used by the server's tools.
    public static func sql(_ text: String) -> String {
        hex(SHA256.hash(data: Data(MCPAuditQuery.sql(text).canonicalInput.utf8)))
    }

    /// Unkeyed form, still used by the server's tools.
    public static func partitionQuery(table: String, indexName: String?, keyCondition: String, projection: [String]) -> String {
        let query = MCPAuditQuery.partitionQuery(
            table: table, indexName: indexName, keyCondition: keyCondition, projection: projection)
        return hex(SHA256.hash(data: Data(query.canonicalInput.utf8)))
    }

    /// The UTF-8 byte count, a colon, then the text.
    static func field(_ text: String) -> String {
        "\(text.utf8.count):" + text
    }

    private static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
        bytes.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
