import BerryStore
import Foundation
import GRDB
import SQLite3
import Testing

/// The stdio contract of the built `berrydb-mcp` executable, exercised as a
/// subprocess the way a host runs it.
///
/// Every store here has no MCP projects, so selection never reaches project
/// verification and no test reads the Keychain.
@Suite(.serialized)
struct BerryMCPStdioTests {
    @Test
    func stdoutCarriesOnlyJSONRPC() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        let helper = try HelperProcess(arguments: ["--store-path", store.path], workingDirectory: store.directory)
        defer { helper.stop() }

        try helper.send(Self.initialize(id: 1, protocolVersion: "2025-11-25", client: "berrydb-tests"))
        let initialize = try await helper.response(id: 1)
        let result = try #require(initialize["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-11-25")
        let serverInfo = result["serverInfo"] as? [String: Any]
        #expect(serverInfo?["name"] as? String == "berrydb-mcp")
        // A build run from `.build` has no Info.plist to take a version from.
        #expect(serverInfo?["version"] as? String == "dev")

        try helper.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        try helper.send(["jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": [:]])
        #expect(try await Self.toolNames(helper.response(id: 2)) == ["berrydb_status"])

        try helper.send(Self.callStatus(id: 3))
        #expect(try await Self.statusReason(helper.response(id: 3)) == "no_matching_project")

        try helper.closeInput()
        let termination = try await helper.termination()
        #expect(termination.reason == .exit)
        #expect(termination.status == 0)
        try await helper.outputFinished()
        Self.expectOnlyJSONRPC(helper.stdout, messages: 3)
    }

    @Test
    func codexInitializeShapeIsAccepted() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        let helper = try HelperProcess(arguments: ["--store-path", store.path], workingDirectory: store.directory)
        defer { helper.stop() }

        // Captured from Codex 0.154.0: the object-valued experimental entry
        // does not decode in the pinned SDK unless the transport drops it.
        try helper.send([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": [
                "protocolVersion": "2025-06-18",
                "capabilities": [
                    "experimental": ["codex/auth-change": [:]],
                    "elicitation": ["form": [:], "url": [:]],
                ],
                "clientInfo": ["name": "codex-mcp-client", "version": "0.154.0"],
            ],
        ])
        let initialize = try await helper.response(id: 1)
        #expect((initialize["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-06-18")

        try helper.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        try helper.send(["jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": [:]])
        #expect(try await Self.toolNames(helper.response(id: 2)) == ["berrydb_status"])

        try helper.send(Self.callStatus(id: 3))
        #expect(try await Self.statusReason(helper.response(id: 3)) == "no_matching_project")

        try helper.closeInput()
        #expect(try await helper.termination().status == 0)
        try await helper.outputFinished()
        Self.expectOnlyJSONRPC(helper.stdout, messages: 3)
    }

    @Test
    func serverDiscoverFallsBackToInitialize() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        let helper = try HelperProcess(arguments: ["--store-path", store.path], workingDirectory: store.directory)
        defer { helper.stop() }

        // Captured from Antigravity CLI 1.2.11, which probes with the
        // 2026-07-28 `server/discover` request and falls back to initialize
        // only on Method not found.
        try helper.send([
            "jsonrpc": "2.0", "id": 1, "method": "server/discover",
            "params": [
                "_meta": [
                    "io.modelcontextprotocol/clientCapabilities": [
                        "elicitation": ["form": [:], "url": [:]],
                        "roots": ["listChanged": true],
                    ],
                    "io.modelcontextprotocol/clientInfo": [
                        "name": "antigravity-client", "version": "v1.0.0",
                    ],
                    "io.modelcontextprotocol/protocolVersion": "2026-07-28",
                ],
            ],
        ])
        let discovery = try await helper.response(id: 1)
        #expect((discovery["error"] as? [String: Any])?["code"] as? Int == -32601)

        try helper.send(
            Self.initialize(id: 2, protocolVersion: "2025-11-25", client: "antigravity-client", version: "v1.0.0")
        )
        let initialize = try await helper.response(id: 2)
        #expect((initialize["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-11-25")

        try helper.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        try helper.send(["jsonrpc": "2.0", "id": 3, "method": "tools/list", "params": [:]])
        #expect(try await Self.toolNames(helper.response(id: 3)) == ["berrydb_status"])

        try helper.closeInput()
        #expect(try await helper.termination().status == 0)
        try await helper.outputFinished()
        Self.expectOnlyJSONRPC(helper.stdout, messages: 3)
    }

    /// `--project` with a name no project has selects nothing, and an
    /// explicit project keeps the helper from asking for the host's roots
    /// even though the host declared the capability.
    @Test
    func unknownProjectNameIsReportedWithoutAskingForRoots() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        let helper = try HelperProcess(
            arguments: ["--store-path", store.path, "--project", "No Such Project"], workingDirectory: store.directory
        )
        defer { helper.stop() }

        try helper.send(
            Self.initialize(id: 1, protocolVersion: "2025-11-25", client: "berrydb-tests", capabilities: ["roots": [:]])
        )
        _ = try await helper.response(id: 1)
        try helper.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        try helper.send(Self.callStatus(id: 2))

        let next = try await helper.message("roots/list or JSON-RPC response 2") {
            $0["method"] as? String == "roots/list" || (($0["id"] as? Int) == 2 && $0["method"] == nil)
        }
        #expect(next["method"] as? String != "roots/list", "the host's roots were requested")
        let status = try await Self.status(helper.response(id: 2))
        #expect(status["reason"] as? String == "explicit_project_not_found")
        #expect(status["selected_by"] is NSNull)
        #expect(status["workspace"] is NSNull)
        try helper.send(["jsonrpc": "2.0", "id": 3, "method": "tools/list", "params": [:]])
        #expect(try await Self.toolNames(helper.response(id: 3)) == ["berrydb_status"])

        try helper.closeInput()
        #expect(try await helper.termination().status == 0)
        try await helper.outputFinished()
        Self.expectOnlyJSONRPC(helper.stdout, messages: 3)
    }

    /// A request sent before `initialize` is answered from the working
    /// directory, and that selection is not kept: once the host has
    /// initialized with the roots capability, its roots decide. Both link
    /// files name projects the store does not have, so the status names the
    /// deciding folder and link without verifying any project.
    @Test
    func selectionBeforeInitializeGivesWayToRoots() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        let workingDirectory = try store.folder("working", linkedTo: "Alpha")
        let root = try store.folder("root", linkedTo: "Beta")
        let helper = try HelperProcess(
            arguments: ["--store-path", store.path], workingDirectory: URL(fileURLWithPath: workingDirectory)
        )
        defer { helper.stop() }

        try helper.send(Self.callStatus(id: 1))
        let early = try await Self.status(helper.response(id: 1))
        #expect(early["reason"] as? String == "linked_project_not_found")
        #expect(early["linked_project"] as? String == "Alpha")
        #expect(early["workspace"] as? String == workingDirectory)

        try helper.send(
            Self.initialize(id: 2, protocolVersion: "2025-11-25", client: "berrydb-tests", capabilities: ["roots": [:]])
        )
        _ = try await helper.response(id: 2)
        try helper.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        try helper.send(Self.callStatus(id: 3))

        // A selection kept from the first request answers without asking for
        // roots, so whichever message comes first tells the two apart.
        let next = try await helper.message("roots/list or JSON-RPC response 3") {
            $0["method"] as? String == "roots/list" || (($0["id"] as? Int) == 3 && $0["method"] == nil)
        }
        #expect(next["method"] as? String == "roots/list", "the host's roots were never requested")
        if next["method"] as? String == "roots/list", let request = next["id"] {
            let uri = URL(fileURLWithPath: root, isDirectory: true).absoluteString
            try helper.send(["jsonrpc": "2.0", "id": request, "result": ["roots": [["uri": uri, "name": "root"]]]])
        }
        let late = try await Self.status(helper.response(id: 3))
        #expect(late["reason"] as? String == "linked_project_not_found")
        #expect(late["linked_project"] as? String == "Beta")
        #expect(late["workspace"] as? String == root)

        try helper.closeInput()
        #expect(try await helper.termination().status == 0)
        try await helper.outputFinished()
        Self.expectOnlyJSONRPC(helper.stdout, messages: 4)
    }

    @Test
    func missingStoreExitsWithStderrOnly() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        let missing = store.directory.appendingPathComponent("absent", isDirectory: true)
            .appendingPathComponent("store.sqlite").path
        let helper = try HelperProcess(arguments: ["--store-path", missing], workingDirectory: store.directory)
        defer { helper.stop() }

        let termination = try await helper.termination()
        try await helper.outputFinished()

        #expect(termination.reason == .exit)
        #expect(termination.status == 1)
        #expect(helper.stdout.lines.isEmpty)
        #expect(helper.stdout.unterminated.isEmpty)
        let stderr = helper.stderr.text
        #expect(stderr.hasPrefix("berrydb-mcp: cannot open the BerryDB store ("))
        #expect(!stderr.contains(missing))
        #expect(!stderr.contains(store.directory.path))
        #expect(!FileManager.default.fileExists(atPath: missing))
    }

    @Test
    func unknownArgumentExitsTwo() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        let helper = try HelperProcess(
            arguments: ["--store-path", store.path, "--verbose"], workingDirectory: store.directory
        )
        defer { helper.stop() }

        let termination = try await helper.termination()
        try await helper.outputFinished()

        #expect(termination.reason == .exit)
        #expect(termination.status == 2)
        #expect(helper.stdout.lines.isEmpty)
        #expect(helper.stdout.unterminated.isEmpty)
        #expect(helper.stderr.text == "berrydb-mcp: unknown argument '--verbose'\n")
    }

    @Test
    func rejectedStorePathArgumentStaysOffStderr() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        let helper = try HelperProcess(arguments: ["--store-path=\(store.path)"], workingDirectory: store.directory)
        defer { helper.stop() }

        let termination = try await helper.termination()
        try await helper.outputFinished()

        #expect(termination.reason == .exit)
        #expect(termination.status == 2)
        #expect(helper.stdout.lines.isEmpty)
        #expect(helper.stderr.text == "berrydb-mcp: unknown argument '--store-path='\n")
        #expect(!helper.stderr.text.contains(store.directory.path))
    }

    @Test
    func storeFromNewerAppExitsWithStderrOnly() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        try store.overwriteWithNewerStore()
        let helper = try HelperProcess(arguments: ["--store-path", store.path], workingDirectory: store.directory)
        defer { helper.stop() }

        let termination = try await helper.termination()
        try await helper.outputFinished()

        #expect(termination.reason == .exit)
        #expect(termination.status == 1)
        #expect(helper.stdout.lines.isEmpty)
        #expect(helper.stdout.unterminated.isEmpty)
        #expect(
            helper.stderr.text
                == "berrydb-mcp: cannot open the BerryDB store (it was written by a different version of BerryDB)\n"
        )
        #expect(!helper.stderr.text.contains(store.directory.path))
    }

    /// The exit must be the handler's clean exit: the default action of
    /// either signal would end the process with `.uncaughtSignal`.
    @Test(arguments: [SIGTERM, SIGINT])
    func signalStopsCleanly(signal: Int32) async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        let helper = try HelperProcess(arguments: ["--store-path", store.path], workingDirectory: store.directory)
        defer { helper.stop() }

        try helper.send(Self.initialize(id: 1, protocolVersion: "2025-11-25", client: "berrydb-tests"))
        _ = try await helper.response(id: 1)
        // The handler is installed before serving starts, but its
        // registration runs on a dispatch queue; until it has, the signal
        // would still take its default action.
        try await helper.ignoring(signal)
        helper.send(signal: signal)

        let termination = try await helper.termination()
        #expect(termination.reason == .exit)
        #expect(termination.status == 0)
    }

    /// A signal that arrives while the helper is still starting is handled,
    /// not left to the default action, and ends the server as soon as it
    /// starts. An exclusive lock on the store holds the helper inside its
    /// store open, so the signal deterministically arrives before serving.
    @Test
    func signalBeforeServingStopsCleanly() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        let lock = try StoreLock(path: store.path)
        let helper = try HelperProcess(arguments: ["--store-path", store.path], workingDirectory: store.directory)
        defer { helper.stop() }

        try await helper.ignoring(SIGTERM)
        helper.send(signal: SIGTERM)
        try lock.release()

        let termination = try await helper.termination()
        try await helper.outputFinished()
        #expect(termination.reason == .exit)
        // The helper waits at most five seconds for the store lock. Released
        // later than that on a stalled runner, the open fails and the helper
        // exits 1; the signal was still handled rather than fatal.
        if termination.status != 0 {
            #expect(termination.status == 1)
            #expect(helper.stderr.text.hasPrefix("berrydb-mcp: cannot open the BerryDB store ("))
        }
        #expect(helper.stdout.lines.isEmpty)
    }

    /// The store is validated once, at open; a file replaced underneath the
    /// running helper, here by one carrying a migration this build does not
    /// know, must still produce an answer and never end the process.
    @Test
    func storeReplacedAfterStartDoesNotCrash() async throws {
        let store = try TemporaryStore()
        defer { store.remove() }
        let helper = try HelperProcess(arguments: ["--store-path", store.path], workingDirectory: store.directory)
        defer { helper.stop() }

        try helper.send(Self.initialize(id: 1, protocolVersion: "2025-11-25", client: "berrydb-tests"))
        _ = try await helper.response(id: 1)
        try helper.send(["jsonrpc": "2.0", "method": "notifications/initialized"])

        try store.overwriteWithNewerStore()

        try helper.send(Self.callStatus(id: 2))
        #expect(try await Self.statusReason(helper.response(id: 2)) == "no_matching_project")
        try helper.send(["jsonrpc": "2.0", "id": 3, "method": "tools/list", "params": [:]])
        _ = try await helper.response(id: 3)

        try helper.closeInput()
        let termination = try await helper.termination()
        #expect(termination.reason == .exit)
        #expect(termination.status == 0)
    }

    // MARK: Messages

    private static func initialize(
        id: Int, protocolVersion: String, client: String, version: String = "1.0",
        capabilities: [String: Any] = [:]
    ) -> [String: Any] {
        [
            "jsonrpc": "2.0", "id": id, "method": "initialize",
            "params": [
                "protocolVersion": protocolVersion,
                "capabilities": capabilities,
                "clientInfo": ["name": client, "version": version],
            ],
        ]
    }

    private static func callStatus(id: Int) -> [String: Any] {
        [
            "jsonrpc": "2.0", "id": id, "method": "tools/call",
            "params": ["name": "berrydb_status", "arguments": [:]],
        ]
    }

    private static func toolNames(_ response: [String: Any]) throws -> [String] {
        let result = try #require(response["result"] as? [String: Any])
        let tools = try #require(result["tools"] as? [[String: Any]])
        return tools.compactMap { $0["name"] as? String }
    }

    private static func statusReason(_ response: [String: Any]) throws -> String? {
        try status(response)["reason"] as? String
    }

    /// The structured result of a `berrydb_status` call.
    private static func status(_ response: [String: Any]) throws -> [String: Any] {
        let result = try #require(response["result"] as? [String: Any])
        #expect(result["isError"] as? Bool != true)
        return try #require(result["structuredContent"] as? [String: Any])
    }

    /// Every stdout line is one JSON-RPC 2.0 object, the last line is
    /// terminated, and the helper wrote exactly `messages` of them.
    private static func expectOnlyJSONRPC(_ stdout: LineRecorder, messages: Int) {
        let lines = stdout.lines
        #expect(lines.count == messages)
        for line in lines {
            let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            #expect(object?["jsonrpc"] as? String == "2.0", "not a JSON-RPC line: \(String(decoding: line, as: UTF8.self))")
        }
        #expect(stdout.unterminated.isEmpty)
    }
}

/// An exclusive SQLite lock on a store file, which keeps every other
/// connection from reading it until `release()`. Uses the C API because GRDB
/// refuses to leave a transaction open between database accesses.
private final class StoreLock {
    struct Failure: Error {
        let code: Int32
    }

    private var connection: OpaquePointer?

    init(path: String) throws {
        var connection: OpaquePointer?
        let opened = sqlite3_open_v2(path, &connection, SQLITE_OPEN_READWRITE, nil)
        self.connection = connection
        guard opened == SQLITE_OK else { throw Failure(code: opened) }
        let locked = sqlite3_exec(connection, "BEGIN EXCLUSIVE", nil, nil, nil)
        guard locked == SQLITE_OK else { throw Failure(code: locked) }
    }

    func release() throws {
        let committed = sqlite3_exec(connection, "COMMIT", nil, nil, nil)
        guard committed == SQLITE_OK else { throw Failure(code: committed) }
    }

    deinit {
        sqlite3_close(connection)
    }
}

/// A store file created by this build's `BerryStore` in its own temporary
/// directory, with no MCP projects.
private struct TemporaryStore {
    let directory: URL
    let path: String

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("berrydb-mcp-stdio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appendingPathComponent("store.sqlite").path
        _ = try BerryStore(path: path)
    }

    /// Rewrites the store file in place, keeping its inode, with the bytes of
    /// a fresh store whose migration table lists one extra migration.
    func overwriteWithNewerStore() throws {
        let replacement = directory.appendingPathComponent("replacement.sqlite").path
        _ = try BerryStore(path: replacement)
        try DatabaseQueue(path: replacement).write { db in
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v999-from-a-newer-app')")
        }
        let bytes = try Data(contentsOf: URL(fileURLWithPath: replacement))
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: bytes)
    }

    /// Creates the folder `name` beside the store with a `.berrydb.json`
    /// naming `project`, and returns its path with symbolic links resolved,
    /// the form the helper reports a link's folder in.
    func folder(_ name: String, linkedTo project: String) throws -> String {
        let folder = directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let link = try JSONSerialization.data(withJSONObject: ["project": project])
        try link.write(to: folder.appendingPathComponent(".berrydb.json"))
        guard let resolved = realpath(folder.path, nil) else { throw CocoaError(.fileNoSuchFile) }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
