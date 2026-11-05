import Foundation
import Testing

@testable import BerryMCP

@Suite("MCP audit codes and request digests")
struct MCPAuditCodeTests {
    @Test func liveReadCodesAreSnakeCaseCaseNames() {
        #expect(MCPLiveReadError.policy("x").auditCode == "policy")
        #expect(MCPLiveReadError.openTimedOut(seconds: 1).auditCode == "open_timed_out")
        #expect(MCPLiveReadError.tooManyConcurrentReads(limit: 4).auditCode == "too_many_concurrent_reads")
        #expect(MCPLiveReadError.queryFailed("secret text").auditCode == "query_failed")
    }

    @Test func partitionQueryCodesAreSnakeCaseCaseNames() {
        #expect(MCPPartitionQueryError.tunnelUnsupported.auditCode == "tunnel_unsupported")
        #expect(MCPPartitionQueryError.invalidRequest("x").auditCode == "invalid_request")
        #expect(MCPPartitionQueryError.openStillPending(retryAfterSeconds: 3).auditCode == "open_still_pending")
    }

    @Test func partitionRequestDigestIgnoresLimitAndCursorAndSeesTheKey() {
        let id = UUID()
        func request(sort: String, limit: Int?, cursor: String?) -> MCPPartitionQueryRequest {
            MCPPartitionQueryRequest(
                profileID: id, table: "orders", indexName: nil, partitionKey: .string("c-1"),
                sortKey: MCPSortKeyInput(op: .beginsWith, value: .string(sort), value2: nil),
                projection: ["total"], limit: limit, cursor: cursor
            )
        }
        let base = request(sort: "2026-", limit: nil, cursor: nil)
        #expect(base.auditDigest == request(sort: "2026-", limit: 5, cursor: "abc").auditDigest)
        #expect(base.auditDigest != request(sort: "2027-", limit: nil, cursor: nil).auditDigest)
        #expect(base.auditDigest.count == 32)
    }

    @Test func partitionRequestDigestKeepsKeyValuesApartFromTheConditionSyntax() {
        let id = UUID()
        let packed = MCPPartitionQueryRequest(
            profileID: id, table: "orders", partitionKey: .string("c-1;sk=eq:s:x")
        )
        let split = MCPPartitionQueryRequest(
            profileID: id, table: "orders", partitionKey: .string("c-1"),
            sortKey: MCPSortKeyInput(op: .eq, value: .string("x"))
        )
        #expect(packed.auditDigest != split.auditDigest)
    }

    @Test func partitionRequestAuditQueryIgnoresLimitAndCursorAndSeesTheKey() {
        func request(sort: String, limit: Int?, cursor: String?) -> MCPPartitionQueryRequest {
            MCPPartitionQueryRequest(
                profileID: UUID(), table: "orders", indexName: nil, partitionKey: .string("c-1"),
                sortKey: MCPSortKeyInput(op: .beginsWith, value: .string(sort), value2: nil),
                projection: ["total"], limit: limit, cursor: cursor
            )
        }
        let base = request(sort: "2026-", limit: nil, cursor: nil)
        let op = MCPSortKeyOperator.beginsWith.rawValue
        #expect(base.auditQuery == request(sort: "2026-", limit: 5, cursor: "abc").auditQuery)
        #expect(base.auditQuery != request(sort: "2027-", limit: nil, cursor: nil).auditQuery)
        #expect(base.auditQuery == .partitionQuery(
            table: "orders", indexName: nil, keyCondition: "pk=s3:c-1;sk=\(op):s5:2026-", projection: ["total"]))
    }

    @Test func partitionRequestAuditQueryKeepsKeyValuesApartFromTheConditionSyntax() {
        let id = UUID()
        let packed = MCPPartitionQueryRequest(
            profileID: id, table: "orders", partitionKey: .string("c-1;sk=eq:s:x")
        )
        let split = MCPPartitionQueryRequest(
            profileID: id, table: "orders", partitionKey: .string("c-1"),
            sortKey: MCPSortKeyInput(op: .eq, value: .string("x"))
        )
        #expect(packed.auditQuery != split.auditQuery)
    }
}
