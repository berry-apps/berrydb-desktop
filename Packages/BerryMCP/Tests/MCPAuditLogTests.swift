import CryptoKit
import Foundation
import Testing

@testable import BerryMCP

@Suite struct MCPAuditLogTests {
    static let project = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let profile = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    // 2026-11-05T01:02:03.5Z; a half second is exact in a Double, so the pinned text cannot drift by rounding.
    static func sample(at: Date = Date(timeIntervalSince1970: 1_793_840_523.5)) -> MCPAuditRecord {
        MCPAuditRecord(at: at, host: "codex", projectID: project, profileID: profile,
                       tool: "berrydb_execute_read_query", outcome: .ok,
                       digest: "00112233445566778899aabbccddeeff", durationMs: 12, rows: 3, bytes: 120,
                       truncated: false, redacted: false)
    }

    @Test func lineIsOneSortedSnakeCaseObject() throws {
        let line = String(decoding: try MCPAuditLog.line(Self.sample()), as: UTF8.self)
        #expect(line == #"{"at":"2026-11-05T01:02:03.500Z","bytes":120,"digest":"00112233445566778899aabbccddeeff","duration_ms":12,"host":"codex","outcome":"ok","profile_id":"22222222-2222-2222-2222-222222222222","project_id":"11111111-1111-1111-1111-111111111111","redacted":false,"rows":3,"tool":"berrydb_execute_read_query","truncated":false,"v":2}"# + "\n")
    }
    @Test func nilFieldsAreOmitted() throws {
        let record = MCPAuditRecord(at: Date(timeIntervalSince1970: 0), host: "unknown", projectID: nil, profileID: nil,
                                    tool: "berrydb_status", outcome: .invalidParams, durationMs: 0, bytes: 0)
        let line = String(decoding: try MCPAuditLog.line(record), as: UTF8.self)
        #expect(line == #"{"at":"1970-01-01T00:00:00.000Z","bytes":0,"duration_ms":0,"host":"unknown","outcome":"invalid_params","tool":"berrydb_status","v":2}"# + "\n")
    }
    @Test func lineRoundTrips() throws {
        let record = Self.sample()
        #expect(MCPAuditLog.record(from: try MCPAuditLog.line(record)) == record)
    }
    @Test func unknownVersionAndGarbageAreNil() throws {
        #expect(MCPAuditLog.record(from: Data("not json\n".utf8)) == nil)
        var other = try JSONSerialization.jsonObject(with: try MCPAuditLog.line(Self.sample())) as! [String: Any]
        for version in [1, 3] {
            other["v"] = version
            #expect(MCPAuditLog.record(from: try JSONSerialization.data(withJSONObject: other)) == nil)
        }
    }
    @Test func readSkipsBrokenAndOversizedLinesAndKeepsOrder() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(MCPAuditLog.fileName)
        var data = Data()
        data += try MCPAuditLog.line(Self.sample(at: Date(timeIntervalSince1970: 1)))
        data += Data("{\"v\":1,\"at\":\"edited by hand\"}\n".utf8)
        data += Data((String(repeating: "x", count: MCPAuditLog.maximumLineBytes + 1) + "\n").utf8)
        data += try MCPAuditLog.line(Self.sample(at: Date(timeIntervalSince1970: 2)))
        try data.write(to: url)
        let records = MCPAuditLog.read(from: url)
        #expect(records.map { $0.at.timeIntervalSince1970 } == [1, 2])
        #expect(MCPAuditLog.read(from: dir.appendingPathComponent("missing.jsonl")) == [])
    }
    @Test func capKeepsNewestWholeLinesUnderTheLimit() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(MCPAuditLog.fileName)
        var data = Data()
        for i in 0..<200 { data += try MCPAuditLog.line(Self.sample(at: Date(timeIntervalSince1970: Double(i)))) }
        try data.write(to: url)
        let lineBytes = try MCPAuditLog.line(Self.sample()).count
        try MCPAuditLog.cap(at: url, thresholdBytes: lineBytes * 100, keepBytes: lineBytes * 10)
        let kept = MCPAuditLog.read(from: url)
        #expect(kept.count == 10)
        #expect(kept.first?.at.timeIntervalSince1970 == 190)
        #expect(kept.last?.at.timeIntervalSince1970 == 199)
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int
        #expect(size <= lineBytes * 10)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! Int
        #expect(mode == 0o600)
    }
    @Test func capSkipsAnOversizedNewestLineAndKeepsTheNewestValidLines() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(MCPAuditLog.fileName)
        var data = Data()
        for i in 0..<20 { data += try MCPAuditLog.line(Self.sample(at: Date(timeIntervalSince1970: Double(i)))) }
        data += Data((String(repeating: "x", count: MCPAuditLog.maximumLineBytes + 1) + "\n").utf8)
        try data.write(to: url)
        let lineBytes = try MCPAuditLog.line(Self.sample()).count
        try MCPAuditLog.cap(at: url, thresholdBytes: lineBytes * 10, keepBytes: lineBytes * 5)
        #expect(MCPAuditLog.read(from: url).map { Int($0.at.timeIntervalSince1970) } == Array(15..<20))
        #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("xxxx"))
    }
    @Test func capDropsLinesOfAnotherVersionAndGarbage() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(MCPAuditLog.fileName)
        var current: [Data] = []
        for i in 0..<3 { current.append(try MCPAuditLog.line(Self.sample(at: Date(timeIntervalSince1970: Double(i))))) }
        var other = try JSONSerialization.jsonObject(with: try MCPAuditLog.line(Self.sample())) as! [String: Any]
        other["v"] = 1
        let older = try JSONSerialization.data(withJSONObject: other, options: [.sortedKeys]) + Data([0x0A])
        var data = Data()
        data += current[0]; data += older; data += current[1]; data += Data("not json\n".utf8); data += current[2]
        try data.write(to: url)
        try MCPAuditLog.cap(at: url, thresholdBytes: data.count - 1, keepBytes: data.count * 2)
        #expect(try Data(contentsOf: url) == current.reduce(Data(), +))
    }
    @Test func capKeepsTheNewestLineEvenWhenItAloneExceedsTheKeepSize() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(MCPAuditLog.fileName)
        var data = Data()
        for i in 0..<20 { data += try MCPAuditLog.line(Self.sample(at: Date(timeIntervalSince1970: Double(i)))) }
        try data.write(to: url)
        try MCPAuditLog.cap(at: url, thresholdBytes: 100, keepBytes: 10)
        #expect(MCPAuditLog.read(from: url).map { Int($0.at.timeIntervalSince1970) } == [19])
    }
    @Test func capLeavesAFileExactlyAtTheThresholdAlone() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(MCPAuditLog.fileName)
        var data = Data()
        for i in 0..<20 { data += try MCPAuditLog.line(Self.sample(at: Date(timeIntervalSince1970: Double(i)))) }
        try data.write(to: url)
        try MCPAuditLog.cap(at: url, thresholdBytes: data.count, keepBytes: 10)
        #expect(try Data(contentsOf: url) == data)
    }
    @Test func capLeavesASmallFileAlone() throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(MCPAuditLog.fileName)
        try MCPAuditLog.line(Self.sample()).write(to: url)
        let before = try Data(contentsOf: url)
        try MCPAuditLog.cap(at: url)
        #expect(try Data(contentsOf: url) == before)
        try MCPAuditLog.cap(at: dir.appendingPathComponent("missing.jsonl"))   // no throw, no file
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("missing.jsonl").path))
    }
    static let testKey = SymmetricKey(data: Data(repeating: 0x42, count: 32))

    @Test func keyedDigestsArePinned() {
        let digest = MCPAuditDigest(key: Self.testKey)
        #expect(digest.digest(.sql("select 1")) == "802e6de50cda3d2fa5eedf68b713e62e")
        #expect(digest.digest(.partitionQuery(table: "orders", indexName: nil, keyCondition: "pk=s3:c-1", projection: ["total"]))
                == "a30178dd6d633b4507a0bbc20875380b")
    }
    @Test func anotherKeyGivesAnotherDigest() {
        let other = MCPAuditDigest(key: SymmetricKey(data: Data(repeating: 0x43, count: 32)))
        #expect(other.digest(.sql("select 1")) == "e58b3e3a3359048dfe3d8e4ac248cb34")
    }
    @Test func keyedDigestIsNotTheUnkeyedHash() {
        // SHA-256 of the same input, the previous record format. Pinned because
        // a digest that ignores its key would still pass every other test.
        #expect(MCPAuditDigest(key: Self.testKey).digest(.sql("select 1")) != "d085ef13d4e6e4c8e01a0e86b57d36d4")
    }
    @Test func digestsAreDomainSeparated() {
        let digest = MCPAuditDigest(key: Self.testKey)
        func pq(_ table: String, _ index: String?, _ condition: String, _ projection: [String]) -> String {
            digest.digest(.partitionQuery(table: table, indexName: index, keyCondition: condition, projection: projection))
        }
        let sql = digest.digest(.sql("select 1"))
        #expect(sql.count == 32)
        #expect(sql.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(sql != digest.digest(.sql("select 2")))
        #expect(sql != pq("select 1", nil, "", []))
        #expect(pq("t", nil, "pk=a", ["x"]) != pq("t", "gsi", "pk=a", ["x"]))
        #expect(pq("t", nil, "pk=a", []) != pq("t", "", "pk=a", []))
        #expect(pq("t", nil, "pk=a", ["a\u{1F}b"]) != pq("t", nil, "pk=a", ["a", "b"]))
        #expect(pq("a\nb", "", "pk=a", []) != pq("a", "b\n", "pk=a", []))
    }
    @Test func urlsSitBesideTheStore() {
        #expect(MCPAuditLog.url(besideStore: "/tmp/x/store.sqlite").path == "/tmp/x/mcp-audit.jsonl")
        #expect(MCPAuditLog.defaultURL().path.hasSuffix("/BerryDB/mcp-audit.jsonl"))
    }
}

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("audit-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
