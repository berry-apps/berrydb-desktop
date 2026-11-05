import Foundation
import MCP

/// What the audit log records about one tool call beyond its name and
/// outcome. Never holds statement text, key values or database error text:
/// `digest` identifies a request and `error` is a fixed code.
public struct MCPAuditDetail: Equatable, Sendable {
    public var profileID: UUID?
    public var digest: String?
    public var error: String?
    public var rows: Int?
    public var truncated: Bool?
    public var redacted: Bool?
    public var consumedCapacityUnits: Double?

    public init(
        profileID: UUID? = nil, digest: String? = nil, error: String? = nil, rows: Int? = nil,
        truncated: Bool? = nil, redacted: Bool? = nil, consumedCapacityUnits: Double? = nil
    ) {
        self.profileID = profileID
        self.digest = digest
        self.error = error
        self.rows = rows
        self.truncated = truncated
        self.redacted = redacted
        self.consumedCapacityUnits = consumedCapacityUnits
    }
}

/// A tool's result together with the detail the audit log records for it.
public struct MCPToolReply: Sendable {
    public let result: CallTool.Result
    public let audit: MCPAuditDetail

    public init(result: CallTool.Result, audit: MCPAuditDetail) {
        self.result = result
        self.audit = audit
    }

    /// An error result with its audit code.
    static func failure(_ text: String, code: String, audit: MCPAuditDetail = MCPAuditDetail()) -> MCPToolReply {
        var audit = audit
        audit.error = code
        return MCPToolReply(result: MCPToolRouter.failure(text), audit: audit)
    }

    /// Whether `respond` replaced a payload with the refusal for a result
    /// over the size ceiling. Compared against that refusal rather than
    /// re-encoding the payload, so the check costs nothing per row.
    static func isTooLargeRefusal(_ result: CallTool.Result) -> Bool {
        let refusal = MCPToolRouter.failure(MCPToolRouter.tooLargeText)
        guard result.isError == true, result.content.count == refusal.content.count else { return false }
        for (left, right) in zip(result.content, refusal.content) {
            guard case let .text(a, _, _) = left, case let .text(b, _, _) = right, a == b else { return false }
        }
        return true
    }
}
