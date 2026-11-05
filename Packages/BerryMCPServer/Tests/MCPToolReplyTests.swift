import BerryDriverKit
import BerryGraph
import BerryStore
import Foundation
import MCP
import Testing

@testable import BerryMCP
@testable import BerryMCPServer

@Suite("MCP tool replies carry audit detail")
struct MCPToolReplyTests {
    let billing = ConnectionProfile(driverID: "sqlite", name: "Billing", filePath: "/data/billing.db")
    let orders = ConnectionProfile(driverID: "dynamodb", name: "Orders")

    func metadata() throws -> MCPMetadataService {
        let profiles = [billing, orders]
        let reader = GraphReader(store: try BerryStore(path: ":memory:"))
        return MCPMetadataService(profiles: { profiles }, reader: reader, graph: BerryGraphQueryService(reader: reader))
    }

    func context(redacting: [String] = []) -> MCPProjectContext {
        let project = MCPProject(
            id: UUID(), name: "P", isEnabled: true, workspaceRoots: [],
            profiles: [
                MCPProfileAccess(profileID: billing.id, liveRead: true, redactedColumns: redacting),
                MCPProfileAccess(profileID: orders.id, liveRead: true),
            ]
        )
        return .selected(
            MCPVerifiedProject(project: project, liveReadProfileIDs: [billing.id, orders.id]),
            source: .explicit, workspace: nil
        )
    }

    @Test func sqlReplyCarriesQueryRowsAndFlagsWithoutTheText() async throws {
        let connection = ScriptedReadOnlyConnection(events: [
            .columns([ColumnMeta(name: "id", declaredType: "INTEGER"), ColumnMeta(name: "email", declaredType: "TEXT")]),
            .rows([[.int(1), .text("a@x")], [.int(2), .text("b@x")], [.int(3), .text("c@x")]]),
            .complete(QueryStats(rowsAffected: nil, duration: .zero)),
        ])
        let live = LiveReadHarness(connection: connection)
        let context = context(redacting: ["email"])
        live.liveReads.projectSource.bind { context }
        let sql = "SELECT id, email FROM users"
        let reply = try await MCPLiveReadTool(service: live.liveReads.service).call(
            ["connection_id": .string(billing.id.uuidString), "sql": .string(sql)],
            context: context, metadata: try metadata()
        )
        #expect(reply.result.isError != true)
        #expect(reply.audit == MCPAuditDetail(
            profileID: billing.id, query: .sql(sql), error: nil, rows: 3, truncated: false,
            redacted: true, consumedCapacityUnits: nil
        ))
    }

    @Test func sqlRefusalCarriesTheCodeAndTheQuery() async throws {
        let live = LiveReadHarness(connection: ScriptedReadOnlyConnection(events: []))
        let context = context()
        live.liveReads.projectSource.bind { context }
        let sql = "DELETE FROM users"
        let reply = try await MCPLiveReadTool(service: live.liveReads.service).call(
            ["connection_id": .string(billing.id.uuidString), "sql": .string(sql)],
            context: context, metadata: try metadata()
        )
        #expect(reply.result.isError == true)
        #expect(reply.audit.error == "policy")
        #expect(reply.audit.query == .sql(sql))
        #expect(reply.audit.profileID == billing.id)
    }

    @Test func dynamoReplyCarriesConsumedCapacityAndItemCount() async throws {
        let items: [[String: DynamoDBAttributeValue]] = [
            ["customer": .string("c1"), "placed": .string("2026-11-01")],
            ["customer": .string("c1"), "placed": .string("2026-11-02")],
        ]
        let connection = ScriptedPartitionConnection(pages: [
            DynamoDBQueryPage(items: items, lastEvaluatedKey: nil, consumedCapacityUnits: 1.5, scannedCount: 2),
        ])
        let live = PartitionHarness(connection: connection, dynamoID: orders.id)
        let context = context()
        live.liveReads.projectSource.bind { context }
        let reply = try await MCPDynamoDBQueryTool(service: try #require(live.liveReads.partition)).call(
            ["connection_id": .string(orders.id.uuidString), "table": "orders", "partition_key": "c1"],
            context: context, metadata: try metadata()
        )
        #expect(reply.result.isError != true)
        let request = MCPPartitionQueryRequest(profileID: orders.id, table: "orders", partitionKey: .string("c1"))
        #expect(reply.audit.rows == 2)
        #expect(reply.audit.consumedCapacityUnits == 1.5)
        #expect(reply.audit.query == request.auditQuery)
        #expect(reply.audit.profileID == orders.id)
        #expect(reply.audit.error == nil)
    }

    @Test func unknownConnectionIsCodedBeforeAnyConnection() async throws {
        let live = LiveReadHarness(connection: ScriptedReadOnlyConnection(events: []))
        let context = context()
        let stranger = UUID()
        let reply = try await MCPLiveReadTool(service: live.liveReads.service).call(
            ["connection_id": .string(stranger.uuidString), "sql": "SELECT 1"],
            context: context, metadata: try metadata()
        )
        #expect(reply.audit.error == "unknown_connection")
        #expect(reply.audit.profileID == stranger)
        #expect(await live.tracker.opens == 0)
    }
}
