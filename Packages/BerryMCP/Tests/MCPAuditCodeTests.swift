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
}
