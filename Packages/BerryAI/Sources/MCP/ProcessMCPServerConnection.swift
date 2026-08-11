import Foundation

/// Drives one MCP server subprocess over stdio JSON-RPC (docs/agents/architecture/08 §4):
/// `initialize` + `tools/list` at start, `tools/call` per invocation. An actor so the
/// pending-request map and pipe writes are race-free.
///
/// Not covered by unit tests — it needs a live server binary; the JSON-RPC codec
/// and LineFramer it builds on ARE tested. Verify against a real allowlisted
/// server before shipping (doc 08 §8).
public actor ProcessMCPServerConnection: MCPServerConnection {
    public nonisolated let serverID: String
    private let manifest: MCPServerManifest
    private let process = Process()
    private let inPipe = Pipe()
    private let outPipe = Pipe()
    private let framer = LineFramer()
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<JSONRPC.Response, Error>] = [:]
    private var timeoutTasks: [Int: Task<Void, Never>] = [:]
    private var started = false

    public init(manifest: MCPServerManifest) {
        serverID = manifest.id
        self.manifest = manifest
    }

    deinit {
        // If callers drop this connection without calling shutdown(), any pending
        // continuations must still be resumed. An un-resumed CheckedContinuation
        // that gets deallocated is a fatal Swift Concurrency error (aborts the
        // process via swift_task_dealloc) — this is what showed up in the crash
        // report (docs/tests/crash.md), surfaced from inside Task.sleep's cleanup
        // once the actor (and its in-flight timeout tasks) went away.
        for (_, continuation) in pending {
            continuation.resume(throwing: MCPError.notRunning)
        }
        for (_, task) in timeoutTasks {
            task.cancel()
        }
        if process.isRunning {
            process.terminate()
        }
    }

    public enum MCPError: Error, Equatable {
        case launchFailed(String)
        case serverError(String)
        case timedOut
        case notRunning
    }

    /// Spawns the subprocess, does the MCP handshake, and returns its tools.
    public func start() async throws -> [MCPToolSpec] {
        guard !started else { return [] }
        started = true

        // /usr/bin/env resolves the command on PATH (npm/pip-installed servers).
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [manifest.command] + manifest.args
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { await self?.ingest(text) }
        }

        do {
            try process.run()
        } catch {
            started = false
            throw MCPError.launchFailed(error.localizedDescription)
        }

        _ = try await request(method: "initialize", params: [
            "protocolVersion": "2024-11-05",
            "capabilities": [:],
            "clientInfo": ["name": "BerryDB", "version": "1.0"],
        ])
        notify(method: "notifications/initialized")
        let listed = try await request(method: "tools/list", params: [:])
        return Self.parseTools(listed.result)
    }

    public func callTool(name: String, argumentsJSON: String) async throws -> String {
        guard started, process.isRunning else { throw MCPError.notRunning }
        let arguments = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        let response = try await request(method: "tools/call", params: ["name": name, "arguments": arguments])
        if let error = response.error { throw MCPError.serverError(error) }
        return response.result ?? "{}"
    }

    public func shutdown() {
        outPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        for (_, continuation) in pending { continuation.resume(throwing: MCPError.notRunning) }
        pending.removeAll()
        for (_, task) in timeoutTasks { task.cancel() }
        timeoutTasks.removeAll()
        started = false
    }

    // MARK: - JSON-RPC plumbing

    private func ingest(_ text: String) {
        for line in framer.feed(text) {
            guard let response = JSONRPC.decodeResponse(line), let id = response.id,
                  let continuation = pending.removeValue(forKey: id) else { continue }
            timeoutTasks.removeValue(forKey: id)?.cancel()
            continuation.resume(returning: response)
        }
    }

    private func request(method: String, params: [String: Any], timeout: Duration = .seconds(30)) async throws -> JSONRPC.Response {
        nextID += 1
        let id = nextID
        let line = JSONRPC.encodeRequest(id: id, method: method, params: params) + "\n"
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try inPipe.fileHandleForWriting.write(contentsOf: Data(line.utf8))
            } catch {
                // A response (or shutdown) may have already resumed and removed this
                // continuation concurrently with the write failing. Only resume here
                // if we're the ones who still own it — resuming twice is a fatal
                // Swift Concurrency error (aborts the process).
                guard pending.removeValue(forKey: id) != nil else { return }
                timeoutTasks.removeValue(forKey: id)?.cancel()
                continuation.resume(throwing: error)
                return
            }
            // Resolve whichever comes first: a matching response (ingest) or timeout.
            timeoutTasks[id] = Task { [weak self] in
                // nanoseconds, not Task.sleep(for:) — see AISession.swift's
                // Duration.berryNanoseconds doc comment for why.
                try? await Task.sleep(nanoseconds: timeout.berryNanoseconds)
                guard !Task.isCancelled else { return }
                await self?.fail(id: id, with: MCPError.timedOut)
            }
        }
    }

    private func fail(id: Int, with error: Error) {
        timeoutTasks.removeValue(forKey: id)?.cancel()
        if let continuation = pending.removeValue(forKey: id) {
            continuation.resume(throwing: error)
        }
    }

    private func notify(method: String, params: [String: Any] = [:]) {
        var object: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if !params.isEmpty { object["params"] = params }
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A) // newline
        try? inPipe.fileHandleForWriting.write(contentsOf: data)
    }

    /// Parses a `tools/list` result into MCPToolSpecs.
    static func parseTools(_ resultJSON: String?) -> [MCPToolSpec] {
        guard let resultJSON, let data = resultJSON.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tools = object["tools"] as? [[String: Any]] else { return [] }
        return tools.compactMap { tool in
            guard let name = tool["name"] as? String else { return nil }
            let description = tool["description"] as? String ?? ""
            var schema = #"{"type":"object"}"#
            if let inputSchema = tool["inputSchema"],
               let schemaData = try? JSONSerialization.data(withJSONObject: inputSchema),
               let schemaString = String(data: schemaData, encoding: .utf8) {
                schema = schemaString
            }
            return MCPToolSpec(name: name, description: description, inputSchemaJSON: schema)
        }
    }
}
