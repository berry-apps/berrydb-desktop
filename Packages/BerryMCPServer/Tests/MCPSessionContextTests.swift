import BerryMCP
import BerryStore
import Foundation
import Synchronization
import Testing

@testable import BerryMCPServer

/// Counts calls and records diagnostic lines shared with `@Sendable` closures.
private final class Recorder: Sendable {
    private let state = Mutex((calls: 0, lines: [String]()))

    var calls: Int {
        state.withLock { $0.calls }
    }

    var lines: [String] {
        state.withLock { $0.lines }
    }

    func call() {
        state.withLock { $0.calls += 1 }
    }

    func write(_ line: String) {
        state.withLock { $0.lines.append(line) }
    }
}

/// A switch shared with `@Sendable` closures, off until turned on.
private final class Switch: Sendable {
    private let state = Mutex(false)

    var isOn: Bool {
        state.withLock { $0 }
    }

    func turnOn() {
        state.withLock { $0 = true }
    }
}

@Suite("MCP session context")
struct MCPSessionContextTests {
    let projectA = MCPProject(name: "A", isEnabled: true, workspaceRoots: ["/work/a"])
    let projectB = MCPProject(name: "B", isEnabled: true, workspaceRoots: ["/work/b"])

    /// - Parameter selections: Counts the selections made; each one reads the
    ///   stored projects once, and verifying a selection never does.
    fileprivate func resolver(selections: Recorder = Recorder()) -> MCPProjectContextResolver {
        let projects = [projectA, projectB]
        return MCPProjectContextResolver(
            loadProjects: {
                selections.call()
                return projects
            },
            verify: { id in
                projects.first { $0.id == id }.map { MCPVerifiedProject(project: $0, liveReadProfileIDs: []) }
            },
            selector: MCPProjectSelector(canonicalize: { $0 })
        )
    }

    func selectedID(_ context: MCPProjectContext, by expected: MCPSelectionSource) -> UUID? {
        guard case let .selected(verified, source, _) = context, source == expected else { return nil }
        return verified.project.id
    }

    @Test func unansweredRootsRequestFallsBackToWorkingDirectory() async throws {
        let (never, release) = AsyncStream<Void>.makeStream()
        let recorder = Recorder()
        let session = MCPSessionContext(
            resolver: resolver(), explicitProject: nil, workingDirectory: "/work/a",
            listRoots: {
                for await _ in never {}
                return ["file:///work/b"]
            },
            diagnostics: { recorder.write($0) },
            rootsTimeout: .milliseconds(20)
        )
        let context: MCPProjectContext
        do {
            context = try await withDeadline(.seconds(10)) { await session.context() }
        } catch {
            release.finish()
            throw error
        }
        release.finish()
        #expect(selectedID(context, by: .workingDirectory) == projectA.id)
        #expect(recorder.lines.isEmpty)
    }

    @Test func concurrentFirstRequestsShareOneRootsRequest() async throws {
        let (started, signalStarted) = AsyncStream<Void>.makeStream()
        let (gate, open) = AsyncStream<Void>.makeStream()
        let recorder = Recorder()
        let session = MCPSessionContext(
            resolver: resolver(), explicitProject: nil, workingDirectory: "/work/a",
            listRoots: {
                recorder.call()
                signalStarted.yield()
                for await _ in gate {}
                return ["file:///work/b"]
            },
            diagnostics: { recorder.write($0) }
        )
        let first = Task { await session.context() }
        do {
            try await withDeadline(.seconds(10)) {
                var startedEvents = started.makeAsyncIterator()
                _ = await startedEvents.next()
            }
        } catch {
            open.finish()
            signalStarted.finish()
            throw error
        }
        let second = Task { await session.context() }
        // An allowance for the second request to reach the actor and wait on
        // the shared roots request. Should it arrive later instead, it finds
        // the selection already made, and the test still passes; it cannot
        // fail spuriously.
        try await Task.sleep(for: .milliseconds(100))
        open.finish()

        let results = try await withDeadline(.seconds(10)) { [await first.value, await second.value] }
        signalStarted.finish()
        #expect(recorder.calls == 1)
        #expect(results.map { selectedID($0, by: .roots) } == [projectB.id, projectB.id])
    }

    @Test func requestsBeforeInitializeAreSelectedWithoutRootsAndNotKept() async throws {
        let selections = Recorder()
        let rootsRequests = Recorder()
        let initialized = Switch()
        let session = MCPSessionContext(
            resolver: resolver(selections: selections), explicitProject: nil, workingDirectory: "/work/a",
            listRoots: {
                rootsRequests.call()
                return ["file:///work/b"]
            },
            initialized: { initialized.isOn }
        )

        let early = [await session.context(), await session.context()]
        #expect(early.map { selectedID($0, by: .workingDirectory) } == [projectA.id, projectA.id])
        #expect(rootsRequests.calls == 0)
        #expect(selections.calls == 2, "a selection made before initialize was kept")

        initialized.turnOn()
        let late = try await withDeadline(.seconds(10)) { [await session.context(), await session.context()] }
        #expect(late.map { selectedID($0, by: .roots) } == [projectB.id, projectB.id])
        #expect(rootsRequests.calls == 1)
        #expect(selections.calls == 3)
    }
}
