import Foundation
import Synchronization
import Testing

@testable import BerryMCP

/// The paths a reader was asked for, in order.
private final class ReadLog: Sendable {
    private let paths = Mutex([String]())

    var all: [String] {
        paths.withLock { $0 }
    }

    func append(_ path: String) {
        paths.withLock { $0.append(path) }
    }
}

/// Resumes a continuation with the first answer only; later answers are dropped.
private final class FirstAnswer<T: Sendable>: Sendable {
    private let pending: Mutex<CheckedContinuation<T?, Never>?>

    init(_ continuation: CheckedContinuation<T?, Never>) {
        pending = Mutex(continuation)
    }

    func resume(_ value: T?) {
        let continuation = pending.withLock { slot in
            let taken = slot
            slot = nil
            return taken
        }
        continuation?.resume(returning: value)
    }
}

/// The result of `body`, run on its own thread so a call that blocks never
/// holds a Swift concurrency thread, or nil once `timeout` has passed. On
/// timeout the thread is left blocked; the test fails instead of hanging.
private func onDedicatedThread<T: Sendable>(
    within timeout: Duration, _ body: @escaping @Sendable () -> T
) async -> T? {
    await withCheckedContinuation { continuation in
        let answer = FirstAnswer(continuation)
        let timer = Task {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            answer.resume(nil)
        }
        Thread {
            answer.resume(body())
            timer.cancel()
        }.start()
    }
}

@Suite("MCP repository link")
struct MCPRepositoryLinkTests {
    /// A synthetic workspace that does not exist, so canonicalization leaves it unchanged.
    static let base = "/berrydb-link-test-\(UUID().uuidString)"

    func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func writeLink(_ content: String, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(content.utf8).write(to: directory.appendingPathComponent(MCPRepositoryLink.fileName))
    }

    /// Finds a link from `workspace` where only `directory` holds a file with `content`.
    func lookup(_ content: String, in directory: String, from workspace: String) -> MCPRepositoryLink.Lookup {
        let file = directory + "/" + MCPRepositoryLink.fileName
        return MCPRepositoryLink.find(from: workspace) { $0 == file ? Data(content.utf8) : nil }
    }

    // MARK: Walk

    @Test func nearestFileWinsOverAParentFile() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appendingPathComponent("repo")
        let service = repository.appendingPathComponent("service")
        let web = repository.appendingPathComponent("web")
        try writeLink(#"{"project":"Outer"}"#, in: repository)
        try writeLink(#"{"project":"Inner"}"#, in: service)
        try FileManager.default.createDirectory(at: service.appendingPathComponent("src"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)

        let inner = MCPProjectSelector.canonicalPath(service.path)
        let outer = MCPProjectSelector.canonicalPath(repository.path)
        #expect(MCPRepositoryLink.find(from: service.appendingPathComponent("src").path)
            == .found(directory: inner, projectName: "Inner"))
        #expect(MCPRepositoryLink.find(from: service.path) == .found(directory: inner, projectName: "Inner"))
        #expect(MCPRepositoryLink.find(from: web.path) == .found(directory: outer, projectName: "Outer"))
    }

    @Test func walkVisitsEachAncestorNearestFirstAndStopsBeforeRoot() {
        let log = ReadLog()
        let result = MCPRepositoryLink.find(from: Self.base + "/repo/src") { path in
            log.append(path)
            return nil
        }
        #expect(result == .none)
        #expect(log.all == [
            Self.base + "/repo/src/.berrydb.json",
            Self.base + "/repo/.berrydb.json",
            Self.base + "/.berrydb.json",
        ])
    }

    @Test func fileAtTheFileSystemRootIsNeverConsulted() {
        let valid = Data(#"{"project":"Everything"}"#.utf8)
        #expect(MCPRepositoryLink.find(from: Self.base + "/repo") { $0 == "/.berrydb.json" ? valid : nil } == .none)
        #expect(MCPRepositoryLink.find(from: "/") { _ in valid } == .none)
    }

    @Test func invalidNearerFileIsNotSkippedForAValidParent() {
        let files = [
            Self.base + "/repo/sub/.berrydb.json": Data("{".utf8),
            Self.base + "/repo/.berrydb.json": Data(#"{"project":"Shop"}"#.utf8),
        ]
        #expect(MCPRepositoryLink.find(from: Self.base + "/repo/sub") { files[$0] }
            == .invalid(directory: Self.base + "/repo/sub"))
    }

    // MARK: Content

    @Test(arguments: [
        "",
        "not json",
        "{",
        "[]",
        #"["Shop"]"#,
        #""Shop""#,
        "{}",
        #"{"Project":"Shop"}"#,
        #"{"project":1}"#,
        #"{"project":true}"#,
        #"{"project":null}"#,
        #"{"project":["Shop"]}"#,
        #"{"project":{"name":"Shop"}}"#,
        #"{"project":"   "}"#,
    ])
    func unusableContentIsInvalid(_ content: String) {
        let directory = Self.base + "/repo"
        #expect(lookup(content, in: directory, from: directory) == .invalid(directory: directory))
    }

    @Test func unknownKeysAreIgnoredAndTheNameIsTrimmed() {
        let directory = Self.base + "/repo"
        let content = #"{"comment":"shared by the team","project":"  Shop Ops \n","version":2,"extra":{"a":[1]}}"#
        #expect(lookup(content, in: directory, from: directory + "/src")
            == .found(directory: directory, projectName: "Shop Ops"))
    }

    @Test func writtenContentsNameTheProjectAndReadBack() {
        let data = MCPRepositoryLink.contents(projectName: "Shop / Ops")
        #expect(String(decoding: data, as: UTF8.self) == "{\"project\":\"Shop / Ops\"}\n")

        let directory = Self.base + "/repo"
        for name in ["Shop / Ops", #"Shop "EU" \ west"#, "Café Zürich"] {
            let written = MCPRepositoryLink.contents(projectName: name)
            #expect(MCPRepositoryLink.find(from: directory) { _ in written }
                == .found(directory: directory, projectName: name))
        }
    }

    // MARK: File system

    @Test func fileLargerThanTheLimitIsInvalid() throws {
        #expect(MCPRepositoryLink.maximumBytes == 4096)
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let body = #"{"project":"Shop"}"#
        let atLimit = body + String(repeating: " ", count: MCPRepositoryLink.maximumBytes - body.utf8.count)
        let canonical = MCPProjectSelector.canonicalPath(root.path)

        try writeLink(atLimit, in: root)
        #expect(MCPRepositoryLink.find(from: root.path) == .found(directory: canonical, projectName: "Shop"))
        try writeLink(atLimit + " ", in: root)
        #expect(MCPRepositoryLink.find(from: root.path) == .invalid(directory: canonical))
    }

    @Test func boundedReadStopsOneByteAfterTheLimit() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(MCPRepositoryLink.fileName)
        try Data(count: 1_048_576).write(to: file)
        #expect(MCPRepositoryLink.readBounded(file.path)?.count == MCPRepositoryLink.maximumBytes + 1)
    }

    @Test func absentFileReadsAsNil() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(MCPRepositoryLink.readBounded(root.appendingPathComponent(MCPRepositoryLink.fileName).path) == nil)
        #expect(MCPRepositoryLink.readBounded(root.appendingPathComponent("missing/" + MCPRepositoryLink.fileName).path) == nil)
    }

    @Test func entryThatIsNotAReadableFileIsInvalid() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileManager.default

        let directoryEntry = root.appendingPathComponent("directory")
        try manager.createDirectory(
            at: directoryEntry.appendingPathComponent(MCPRepositoryLink.fileName), withIntermediateDirectories: true
        )

        let unreadable = root.appendingPathComponent("unreadable")
        try writeLink(#"{"project":"Shop"}"#, in: unreadable)
        let unreadableFile = unreadable.appendingPathComponent(MCPRepositoryLink.fileName)
        try manager.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadableFile.path)

        let dangling = root.appendingPathComponent("dangling")
        try manager.createDirectory(at: dangling, withIntermediateDirectories: true)
        try manager.createSymbolicLink(
            atPath: dangling.appendingPathComponent(MCPRepositoryLink.fileName).path,
            withDestinationPath: root.appendingPathComponent("missing.json").path
        )

        for directory in [directoryEntry, unreadable, dangling] {
            #expect(MCPRepositoryLink.find(from: directory.path)
                == .invalid(directory: MCPProjectSelector.canonicalPath(directory.path)))
        }
    }

    @Test func fifoIsInvalidWithoutWaitingForAWriter() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(mkfifo(root.appendingPathComponent(MCPRepositoryLink.fileName).path, 0o600) == 0)
        let workspace = root.path
        let lookup = await onDedicatedThread(within: .seconds(10)) { MCPRepositoryLink.find(from: workspace) }
        #expect(lookup == .invalid(directory: MCPProjectSelector.canonicalPath(root.path)))
    }
}
