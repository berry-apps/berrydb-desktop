import Foundation
import Testing

@testable import BerryMCP
@testable import BerryStore
@testable import BerryUI

@Suite @MainActor struct MCPActivityTests {
    private static let projectA = UUID()
    private static let projectB = UUID()

    private func record(
        _ n: Int, project: UUID?, profile: UUID? = nil, tool: String = "berrydb_status",
        outcome: MCPAuditRecord.Outcome = .ok, error: String? = nil, truncated: Bool? = nil
    ) -> MCPAuditRecord {
        MCPAuditRecord(
            at: Date(timeIntervalSince1970: 1_000 + Double(n)), host: "codex", projectID: project, profileID: profile,
            tool: tool, outcome: outcome, error: error, durationMs: 1, rows: n, bytes: n, truncated: truncated)
    }

    @Test func rowsAreNewestFirstForTheProjectOnlyAndCapped() {
        var records: [MCPAuditRecord] = []
        for n in 0..<150 {
            records.append(record(n, project: Self.projectA))
            if n % 30 == 0 { records.append(record(n, project: Self.projectB)) }
        }
        let rows = MCPProjectsSettingsModel.activityRows(records, projectID: Self.projectA, profileNames: [:])
        #expect(rows.count == 100)
        #expect(rows[0].at == Date(timeIntervalSince1970: 1_149))
        #expect(rows.map(\.id) == Array(0..<100))
        #expect(rows.allSatisfy { $0.rows != nil })
        #expect(rows.last?.at == Date(timeIntervalSince1970: 1_050))
    }

    @Test func rowMapsNamesCodesAndFlags() {
        let orders = UUID()
        let gone = UUID()
        let records = [
            record(1, project: Self.projectA, profile: orders, tool: "berrydb_execute_read_query",
                   outcome: .error, error: "policy", truncated: true),
            record(2, project: Self.projectA, profile: gone),
            record(3, project: Self.projectA, tool: "unknown", outcome: .invalidParams),
            record(4, project: Self.projectA, outcome: .cancelled),
            record(5, project: Self.projectA, outcome: .error),
        ]
        let rows = MCPProjectsSettingsModel.activityRows(
            records, projectID: Self.projectA, profileNames: [orders: "Orders"])
        let byAt = Dictionary(uniqueKeysWithValues: rows.map { (Int($0.at.timeIntervalSince1970) - 1_000, $0) })
        #expect(byAt[1]?.tool == "execute_read_query")
        #expect(byAt[1]?.connection == "Orders")
        #expect(byAt[1]?.connectionRemoved == false)
        #expect(byAt[1]?.outcome == "policy")
        #expect(byAt[1]?.truncated == true)
        #expect(byAt[2]?.connection == nil)
        #expect(byAt[2]?.connectionRemoved == true)
        #expect(byAt[2]?.outcome == "ok")
        #expect(byAt[3]?.connection == nil)
        #expect(byAt[3]?.connectionRemoved == false)
        #expect(byAt[3]?.tool == "unknown")
        #expect(byAt[3]?.outcome == "invalid_params")
        #expect(byAt[4]?.outcome == "cancelled")
        #expect(byAt[5]?.outcome == "error")
    }

    @Test func loadActivityReadsAndPublishes() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(MCPAuditLog.fileName)
        let store = try BerryStore(path: ":memory:")
        let box = MCPProjectsSettingsModelTests.KeyBox()
        let model = MCPProjectsSettingsModel(
            store: store, keyStore: box.keyStore, helperURL: nil, auditLogURL: url)

        await model.loadActivity(for: Self.projectA)
        #expect(model.activity == [])
        #expect(!FileManager.default.fileExists(atPath: url.path))

        var data = Data()
        for n in 1...3 { data.append(try MCPAuditLog.line(record(n, project: Self.projectA))) }
        try data.write(to: url)
        await model.loadActivity(for: Self.projectA)
        #expect(model.activity.count == 3)
        #expect(model.activity.map(\.at) == [3, 2, 1].map { Date(timeIntervalSince1970: 1_000 + Double($0)) })
        #expect(try Data(contentsOf: url) == data)
    }

    private func row(
        outcome: String = "ok", rows: Int? = nil, bytes: Int = 0, truncated: Bool = false,
        redacted: Bool = false, capacity: Double? = nil
    ) -> MCPProjectsSettingsModel.ActivityRow {
        MCPProjectsSettingsModel.ActivityRow(
            id: 0, at: Date(timeIntervalSince1970: 1_000), host: "codex", tool: "status", connection: nil,
            connectionRemoved: false, outcome: outcome, rows: rows, bytes: bytes, truncated: truncated,
            redacted: redacted, consumedCapacityUnits: capacity)
    }

    @Test func activityLineListsOnlyWhatTheRecordHas() {
        #expect(
            MCPProjectsSettingsModel.activityLine(
                row(rows: 3, bytes: 1024, truncated: true, redacted: true, capacity: 1.5))
                == "ok · 3 rows · 1 KB · truncated · redacted · 1.5 RCU")
        #expect(MCPProjectsSettingsModel.activityLine(row(outcome: "policy", bytes: 90)) == "policy · 90 bytes")
        #expect(MCPProjectsSettingsModel.activityLine(row(rows: 1, bytes: 90, capacity: 2)) == "ok · 1 row · 90 bytes · 2 RCU")
    }
}
