import Foundation
import Synchronization
import Testing

@testable import BerryMCP

private final class LineBox: Sendable {
    private let lines = Mutex<[String]>([])

    var all: [String] {
        lines.withLock { $0 }
    }

    func append(_ line: String) {
        lines.withLock { $0.append(line) }
    }
}

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-audit-writer-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite struct MCPAuditWriterTests {
    @Test func appendsOneLinePerRecordWithPrivateMode() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(MCPAuditLog.fileName)
        let writer = MCPAuditWriter(url: url, diagnostics: { _ in Issue.record("no diagnostic expected") })
        await writer.record(MCPAuditLogTests.sample(at: Date(timeIntervalSince1970: 1)))
        await writer.record(MCPAuditLogTests.sample(at: Date(timeIntervalSince1970: 2)))
        #expect(MCPAuditLog.read(from: url).map { $0.at.timeIntervalSince1970 } == [1, 2])
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! Int
        #expect(mode == 0o600)
    }
    @Test func fiftyConcurrentWritersLeaveOnlyWholeLines() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(MCPAuditLog.fileName)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask {
                    let writer = MCPAuditWriter(url: url, diagnostics: { _ in })
                    await writer.record(MCPAuditLogTests.sample(at: Date(timeIntervalSince1970: Double(i))))
                }
            }
        }
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        #expect(lines.count == 50)
        #expect(MCPAuditLog.read(from: url).count == 50)
        #expect(Set(MCPAuditLog.read(from: url).map { Int($0.at.timeIntervalSince1970) }) == Set(0..<50))
    }
    @Test func unwritableLocationWarnsOnceAndNeverThrows() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("missing").appendingPathComponent(MCPAuditLog.fileName)
        let lines = LineBox()
        let writer = MCPAuditWriter(url: url, diagnostics: { lines.append($0) })
        await writer.record(MCPAuditLogTests.sample())
        await writer.record(MCPAuditLogTests.sample())
        #expect(lines.all.count == 1)
        #expect(lines.all.first?.hasPrefix("audit log unavailable: ") == true)
        #expect(lines.all.first?.contains(dir.path) == false)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("missing").path))
    }
}
