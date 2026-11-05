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
    @Test func fifoAtThePathWarnsOnceAndNeverBlocks() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(MCPAuditLog.fileName)
        #expect(mkfifo(url.path, 0o600) == 0)
        let lines = LineBox()
        let writer = MCPAuditWriter(url: url, diagnostics: { lines.append($0) })
        let finished = await completes(within: .seconds(5)) {
            await writer.record(MCPAuditLogTests.sample())
            await writer.record(MCPAuditLogTests.sample())
        }
        if !finished {
            // Opening the read end releases a writer blocked in open(2), so
            // the failing run does not leave a pool thread stuck behind it.
            // Its write then meets a closed pipe, which must fail with EPIPE
            // rather than end the test process with SIGPIPE.
            signal(SIGPIPE, SIG_IGN)
            let reader = open(url.path, O_RDONLY | O_NONBLOCK)
            if reader >= 0 { close(reader) }
        }
        #expect(finished)
        #expect(lines.all.count == 1)
    }
    @Test func symlinkAtThePathIsRefusedAndItsTargetUntouched() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(MCPAuditLog.fileName)
        let target = dir.appendingPathComponent("elsewhere")
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        let lines = LineBox()
        let writer = MCPAuditWriter(url: url, diagnostics: { lines.append($0) })
        let finished = await completes(within: .seconds(5)) {
            await writer.record(MCPAuditLogTests.sample())
            await writer.record(MCPAuditLogTests.sample())
        }
        #expect(finished)
        #expect(lines.all.count == 1)
        #expect(try Data(contentsOf: target).isEmpty)
    }
}

/// Whether `operation` returns within `limit`. The operation runs in an
/// unstructured task, so a call stuck in a blocking system call cannot hold
/// the test past the limit.
private func completes(within limit: Duration, _ operation: @escaping @Sendable () async -> Void) async -> Bool {
    let resumed = Mutex(false)
    return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
        let finish: @Sendable (Bool) -> Void = { value in
            let first = resumed.withLock { done in
                defer { done = true }
                return !done
            }
            if first { continuation.resume(returning: value) }
        }
        Task.detached {
            await operation()
            finish(true)
        }
        Task.detached {
            try? await Task.sleep(for: limit)
            finish(false)
        }
    }
}
