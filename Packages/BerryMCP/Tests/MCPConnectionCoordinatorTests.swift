import BerryCredentials
import BerryDriverKit
import BerryDriverSQLite
import BerryMCP
import BerryStore
import Foundation
import Testing

@Suite("MCP connection coordinator")
struct MCPConnectionCoordinatorTests {
    @Test func cancellationDuringResolutionPreventsConnectionOpen() async throws {
        let gate = AsyncGate()
        let tracker = Tracker()
        let profileID = UUID()
        let resolver = MCPProjectResolver(
            loadProject: {
                await gate.wait()
                return MCPVerifiedProject(
                    project: MCPProject(
                        name: "P", isEnabled: true,
                        profiles: [MCPProfileAccess(profileID: profileID, liveRead: true)]
                    ),
                    liveReadProfileIDs: [profileID]
                )
            },
            profile: { _ in MCPConnectionProfile(id: profileID, driverID: .sqlite, config: .sqlite(path: ":memory:")) }
        )
        let coordinator = MCPConnectionCoordinator(
            resolver: resolver,
            sqlFactory: { _ in
                _ = await tracker.opened()
                return MCPSQLSession(connection: FakeSQLConnection(), lifecycle: MCPConnectionLifecycle(cancel: {}, closeConnection: {}))
            }
        )
        let request = Task { try await coordinator.withSQLSession(requestID: "resolving", profileID: profileID) { _ in () } }
        await gate.waitUntilBlocked()
        await coordinator.cancel(requestID: "resolving")
        await gate.open()
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(await tracker.opens == 0)
    }

    @Test func shutdownDuringOpenClosesLateResourceAndPreventsActivation() async throws {
        let gate = AsyncGate()
        let fixture = Fixture()
        let tracker = fixture.tracker
        let profileID = fixture.profile.id
        let resolver = MCPProjectResolver(
            loadProject: {
                MCPVerifiedProject(
                    project: MCPProject(
                        name: "P", isEnabled: true,
                        profiles: [MCPProfileAccess(profileID: profileID, liveRead: true)]
                    ),
                    liveReadProfileIDs: [profileID]
                )
            },
            profile: { _ in fixture.profile }
        )
        let coordinator = MCPConnectionCoordinator(
            resolver: resolver,
            sqlFactory: { _ in
                let number = await tracker.opened()
                await gate.wait()
                return MCPSQLSession(
                    connection: FakeSQLConnection(),
                    lifecycle: MCPConnectionLifecycle(
                        cancel: { await tracker.cancelled() },
                        closeConnection: { try await tracker.closed(number: number) },
                        closeTunnel: { await tracker.tunnelClosed() }
                    )
                )
            }
        )
        let operationRan = Flag()
        let request = Task {
            try await coordinator.withSQLSession(requestID: "opening", profileID: profileID) { _ in
                await operationRan.set()
            }
        }
        await gate.waitUntilBlocked()
        let shutdown = Task { _ = await coordinator.closeAll() }
        await Task.yield()
        #expect(await tracker.closes == 0)
        await gate.open()
        await shutdown.value
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(await operationRan.value == false)
        #expect(await tracker.closes == 1)
        #expect(await tracker.tunnelCloses == 1)
        await #expect(throws: MCPConnectionCoordinatorError.shuttingDown) {
            try await coordinator.withSQLSession(requestID: "late", profileID: profileID) { _ in () }
        }
    }

    @Test func connectionFailureClosesOpenedTunnel() async throws {
        let tracker = Tracker()
        let registries = MCPDriverRegistries(sql: { _ in SQLiteDriver.self })
        let factories = MCPConnectionFactories(registries: registries, openTunnel: { _ in
            MCPTunnelEndpoint(
                config: .sqlite(path: "/definitely/missing/berrydb-parent/database.sqlite"),
                close: { await tracker.tunnelClosed() }
            )
        })
        let profile = MCPConnectionProfile(
            id: UUID(), driverID: .sqlite,
            config: .sqlite(path: ":memory:")
        )
        await #expect(throws: (any Error).self) { try await factories.sql(profile) }
        #expect(await tracker.tunnelCloses == 1)
    }

    @Test func coordinatorFactoryEnforcesSQLiteQueryOnlyBeforeOperation() async throws {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "berrydb-mcp-readonly-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(FileManager.default.createFile(atPath: path, contents: nil))
        let setup = try SQLiteConnection(path: path)
        for try await _ in setup.execute("CREATE TABLE users(id INTEGER)") {}
        await setup.close()

        let profile = MCPConnectionProfile(id: UUID(), driverID: .sqlite, config: .sqlite(path: path))
        let resolver = MCPProjectResolver(
            loadProject: {
                MCPVerifiedProject(
                    project: MCPProject(
                        name: "P", isEnabled: true,
                        profiles: [MCPProfileAccess(profileID: profile.id, liveRead: true)]
                    ),
                    liveReadProfileIDs: [profile.id]
                )
            },
            profile: { _ in profile }
        )
        let registries = MCPDriverRegistries(sql: { _ in SQLiteDriver.self })
        let coordinator = MCPConnectionCoordinator(
            resolver: resolver,
            factories: MCPConnectionFactories(registries: registries)
        )

        try await coordinator.withSQLSession(requestID: "readonly", profileID: profile.id) { session in
            var observedRead = false
            for try await event in session.connection.execute("SELECT 42") {
                if case .rows = event { observedRead = true }
            }
            #expect(observedRead)
            do {
                for try await _ in session.connection.execute("INSERT INTO users VALUES (1)") {}
                Issue.record("Coordinator session unexpectedly permitted a SQLite write")
            } catch {
                #expect(String(describing: error).lowercased().contains("readonly"))
            }
        }
    }

    @Test func defaultFactoryRejectsUnsupportedSQLDriverAndCleansUpBeforeOperation() async throws {
        let tracker = Tracker()
        let token = UUID().uuidString
        await ReadOnlyConnectionRegistry.shared.register(tracker, for: token)
        let config = ConnectionConfig(driver: .postgres, name: token)
        let profile = MCPConnectionProfile(id: UUID(), driverID: .postgres, config: config)
        let resolver = MCPProjectResolver(
            loadProject: {
                MCPVerifiedProject(
                    project: MCPProject(
                        name: "P", isEnabled: true,
                        profiles: [MCPProfileAccess(profileID: profile.id, liveRead: true)]
                    ),
                    liveReadProfileIDs: [profile.id]
                )
            },
            profile: { _ in profile }
        )
        let registries = MCPDriverRegistries(sql: { _ in ReadOnlyTrackingSQLDriver.self })
        let coordinator = MCPConnectionCoordinator(
            resolver: resolver,
            factories: MCPConnectionFactories(
                registries: registries,
                openTunnel: { config in
                    MCPTunnelEndpoint(config: config, close: { await tracker.tunnelClosed() })
                }
            )
        )
        let operationRan = Flag()

        await #expect(throws: MCPConnectionCoordinatorError.sqlReadOnlyEnforcementUnavailable(.postgres)) {
            try await coordinator.withSQLSession(requestID: "unsupported", profileID: profile.id) { _ in
                await operationRan.set()
            }
        }
        #expect(await operationRan.value == false)
        #expect(await tracker.opens == 1)
        #expect(await tracker.closes == 1)
        #expect(await tracker.tunnelCloses == 1)
        await ReadOnlyConnectionRegistry.shared.remove(token)
    }

    @Test func injectedReadOnlyEnforcerRunsBeforeSessionEscapesFactory() async throws {
        let tracker = Tracker()
        let registries = MCPDriverRegistries(sql: { _ in FakeSQLDriver.self })
        let factories = MCPConnectionFactories(
            registries: registries,
            enforceSQLReadOnly: { _, _ in await tracker.enforcedReadOnly() }
        )
        let profile = MCPConnectionProfile(id: UUID(), driverID: .postgres, config: .sqlite(path: ":memory:"))
        let session = try await factories.sql(profile)
        #expect(await tracker.readOnlyEnforcements == 1)
        try await session.lifecycle.close()
    }

    @Test func unauthorizedProfileIsRejectedBeforeOpening() async throws {
        let fixture = Fixture(profileIsAuthorized: false)
        await #expect(throws: MCPProjectResolutionError.self) {
            try await fixture.coordinator.withSQLSession(requestID: "request", profileID: fixture.profile.id) { _ in 1 }
        }
        #expect(await fixture.tracker.opens == 0)
    }

    /// Equivalent of the pre-grant-removal `storeResolverEnforcesMembershipAndRevocation`:
    /// a profile's live read revoked between two calls is refused on the
    /// second call, and a profile never assigned to the project is refused
    /// the same way an unassigned one always is.
    @Test func liveReadRevocationAndUnassignedProfileAreBothRejected() async throws {
        let fixture = Fixture()
        try await fixture.coordinator.withSQLSession(requestID: "one", profileID: fixture.profile.id) { _ in () }
        await fixture.authorization.revoke()
        await #expect(throws: MCPProjectResolutionError.liveReadNotEnabled(fixture.profile.id)) {
            try await fixture.coordinator.withSQLSession(requestID: "two", profileID: fixture.profile.id) { _ in () }
        }
        #expect(await fixture.tracker.opens == 1)

        let unassigned = Fixture(profileIsAuthorized: false)
        await #expect(throws: MCPProjectResolutionError.unauthorizedProfile(unassigned.profile.id)) {
            try await unassigned.coordinator.withSQLSession(requestID: "unassigned", profileID: unassigned.profile.id) { _ in () }
        }
        #expect(await unassigned.tracker.opens == 0)
    }

    @Test func missingProfileIsRejectedBeforeOpening() async throws {
        let fixture = Fixture(profileExists: false)
        await #expect(throws: MCPProjectResolutionError.self) {
            try await fixture.coordinator.withSQLSession(requestID: "request", profileID: fixture.profile.id) { _ in () }
        }
        #expect(await fixture.tracker.opens == 0)
    }

    @Test func successErrorAndCloseFailureCloseExactlyOnce() async throws {
        let fixture = Fixture()
        _ = try await fixture.coordinator.withSQLSession(requestID: "success", profileID: fixture.profile.id) { session in
            #expect(session.recordsHistory == false)
            return 42
        }
        await #expect(throws: FixtureError.self) {
            try await fixture.coordinator.withSQLSession(requestID: "error", profileID: fixture.profile.id) { _ in throw FixtureError.operation }
        }
        await fixture.tracker.failCloseNumber(3)
        await #expect(throws: FixtureError.self) {
            try await fixture.coordinator.withSQLSession(requestID: "close", profileID: fixture.profile.id) { _ in () }
        }
        #expect(await fixture.tracker.opens == 3)
        #expect(await fixture.tracker.closes == 3)
        #expect(await fixture.tracker.tunnelCloses == 3)
    }

    @Test func concurrentRequestsDoNotReuseConnections() async throws {
        let fixture = Fixture()
        async let first: UUID = fixture.coordinator.withSQLSession(requestID: "a", profileID: fixture.profile.id) { $0.connection.id }
        async let second: UUID = fixture.coordinator.withSQLSession(requestID: "b", profileID: fixture.profile.id) { $0.connection.id }
        let ids = try await [first, second]
        #expect(Set(ids).count == 2)
        #expect(await fixture.tracker.opens == 2)
        #expect(await fixture.tracker.closes == 2)
    }

    @Test func cancellationCancelsAndClosesExactlyOnce() async throws {
        let fixture = Fixture()
        let task = Task {
            try await fixture.coordinator.withSQLSession(requestID: "slow", profileID: fixture.profile.id) { _ in
                try await Task.sleep(for: .seconds(30))
            }
        }
        await fixture.tracker.waitForOpen()
        await fixture.coordinator.cancel(requestID: "slow")
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await fixture.tracker.cancels == 1)
        #expect(await fixture.tracker.closes == 1)
        #expect(await fixture.tracker.tunnelCloses == 1)
    }

    @Test func closeAllCancelsInflightAndClosesEachExactlyOnce() async throws {
        let fixture = Fixture()
        let tasks = ["a", "b", "c"].map { id in
            Task {
                try await fixture.coordinator.withSQLSession(requestID: id, profileID: fixture.profile.id) { _ in
                    try await Task.sleep(for: .seconds(30))
                }
            }
        }
        await fixture.tracker.waitForOpens(3)
        #expect(await fixture.coordinator.closeAll() == MCPShutdownReport(abandonedRequestIDs: []))
        for task in tasks {
            await #expect(throws: CancellationError.self) { try await task.value }
        }
        #expect(await fixture.tracker.closes == 3)
        #expect(await fixture.tracker.tunnelCloses == 3)
    }

    @Test func concurrentLifecycleClosersAwaitOneSharedClose() async throws {
        let gate = AsyncGate()
        let tracker = Tracker()
        let lifecycle = MCPConnectionLifecycle(
            cancel: {},
            closeConnection: {
                try await tracker.closed(number: 1)
                await gate.wait()
            },
            closeTunnel: { await tracker.tunnelClosed() }
        )
        let first = Task { try await lifecycle.close() }
        await gate.waitUntilBlocked()
        let second = Task { try await lifecycle.close() }
        await Task.yield()
        #expect(await tracker.closes == 1)
        #expect(await tracker.tunnelCloses == 0)
        await gate.open()
        try await first.value
        try await second.value
        #expect(await tracker.closes == 1)
        #expect(await tracker.tunnelCloses == 1)
    }

    @Test func closeAllWaitsForPausedOperationAndItsCleanup() async throws {
        let fixture = Fixture()
        let gate = AsyncGate()
        let operation = Task {
            try await fixture.coordinator.withSQLSession(requestID: "paused", profileID: fixture.profile.id) { _ in
                await gate.wait() // deliberately ignores task cancellation
            }
        }
        await gate.waitUntilBlocked()
        let shutdownReturned = Flag()
        let shutdown = Task {
            _ = await fixture.coordinator.closeAll()
            await shutdownReturned.set()
        }
        await Task.yield()
        #expect(await shutdownReturned.value == false)
        await fixture.tracker.waitForCancels(1)
        await gate.open()
        _ = try? await operation.value
        await shutdown.value
        #expect(await fixture.tracker.cancels == 1)
        #expect(await fixture.tracker.closes == 1)
        #expect(await fixture.tracker.tunnelCloses == 1)
    }

    @Test func closeAllReturnsAtTheDeadlineWhenADriverIgnoresCancellation() async throws {
        let profileID = UUID()
        let started = AsyncStream<Void>.makeStream()
        let coordinator = MCPConnectionCoordinator(
            resolver: liveResolver(for: [profileID]),
            sqlFactory: { _ in
                MCPSQLSession(
                    connection: FakeSQLConnection(),
                    lifecycle: MCPConnectionLifecycle(cancel: {}, closeConnection: {})
                )
            },
            shutdownDeadline: .milliseconds(100)
        )
        let request = Task {
            try await coordinator.withSQLSession(requestID: "stuck", profileID: profileID) { _ in
                started.continuation.yield()
                // Ignores cancellation, modelling a driver call that never returns.
                await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
                return 0
            }
        }
        for await _ in started.stream { break }
        let clock = ContinuousClock()
        let begin = clock.now
        let report = await coordinator.closeAll()
        #expect(clock.now - begin < .seconds(1))
        #expect(report.abandonedRequestIDs == ["stuck"])
        request.cancel()
    }

    @Test func closeAllReportsNothingAbandonedWhenRequestsDrain() async throws {
        let profileID = UUID()
        let coordinator = MCPConnectionCoordinator(
            resolver: liveResolver(for: [profileID]),
            sqlFactory: { _ in
                MCPSQLSession(
                    connection: FakeSQLConnection(),
                    lifecycle: MCPConnectionLifecycle(cancel: {}, closeConnection: {})
                )
            },
            shutdownDeadline: .seconds(5)
        )
        _ = try await coordinator.withSQLSession(requestID: "quick", profileID: profileID) { _ in 1 }
        #expect(await coordinator.closeAll() == MCPShutdownReport(abandonedRequestIDs: []))
    }

    @Test func cancelAfterCloseStartedDoesNotRunTheCancelAction() async throws {
        let tracker = Tracker()
        let closed = MCPConnectionLifecycle(
            cancel: { await tracker.cancelled() },
            closeConnection: { try await tracker.closed(number: 1) }
        )
        try await closed.close()
        await closed.cancel()
        #expect(await tracker.cancels == 0)

        let gate = AsyncGate()
        let closing = MCPConnectionLifecycle(
            cancel: { await tracker.cancelled() },
            closeConnection: { await gate.wait() }
        )
        let close = Task { try await closing.close() }
        await gate.waitUntilBlocked()
        await closing.cancel()
        #expect(await tracker.cancels == 0)
        await gate.open()
        try await close.value
    }

    @Test func closeAllReturnsAtTheDeadlineWhenADriverCancelNeverReturns() async throws {
        let profileID = UUID()
        let started = AsyncStream<Void>.makeStream()
        let coordinator = MCPConnectionCoordinator(
            resolver: liveResolver(for: [profileID]),
            sqlFactory: { _ in
                MCPSQLSession(
                    connection: FakeSQLConnection(),
                    lifecycle: MCPConnectionLifecycle(
                        cancel: { await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in } },
                        closeConnection: {}
                    )
                )
            },
            shutdownDeadline: .milliseconds(100)
        )
        let request = Task {
            try await coordinator.withSQLSession(requestID: "stuck-cancel", profileID: profileID) { _ in
                started.continuation.yield()
                await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
                return 0
            }
        }
        for await _ in started.stream { break }
        let clock = ContinuousClock()
        let begin = clock.now
        let report = await coordinator.closeAll()
        #expect(clock.now - begin < .seconds(1))
        #expect(report.abandonedRequestIDs == ["stuck-cancel"])
        request.cancel()
    }

    @Test func closeFailureCleanupDoesNotTouchALaterRequestWithTheSameID() async throws {
        let profileID = UUID()
        let tracker = Tracker()
        let firstCloseGate = AsyncGate()
        let secondOperationGate = AsyncGate()
        let coordinator = MCPConnectionCoordinator(
            resolver: liveResolver(for: [profileID]),
            sqlFactory: { _ in
                let number = await tracker.opened()
                return MCPSQLSession(
                    connection: FakeSQLConnection(),
                    lifecycle: MCPConnectionLifecycle(
                        cancel: { await tracker.cancelled() },
                        closeConnection: {
                            try await tracker.closed(number: number)
                            if number == 1 {
                                await firstCloseGate.wait()
                                throw FixtureError.close
                            }
                        }
                    )
                )
            }
        )
        let first = Task {
            try await coordinator.withSQLSession(requestID: "reused", profileID: profileID) { _ in 1 }
        }
        await firstCloseGate.waitUntilBlocked()
        let second = Task {
            try await coordinator.withSQLSession(requestID: "reused", profileID: profileID) { _ in
                await secondOperationGate.wait()
                return 2
            }
        }
        await secondOperationGate.waitUntilBlocked()
        await firstCloseGate.open()
        await #expect(throws: FixtureError.close) { try await first.value }
        #expect(await tracker.closes == 1)
        #expect(await tracker.cancels == 0)
        await secondOperationGate.open()
        #expect(try await second.value == 2)
        #expect(await tracker.closes == 2)
        #expect(await tracker.cancels == 0)
    }

    @Test func closeWaitsForAnInFlightDriverCancel() async throws {
        let tracker = Tracker()
        let gate = AsyncGate()
        let lifecycle = MCPConnectionLifecycle(
            cancel: {
                await gate.wait()
                await tracker.cancelled()
            },
            closeConnection: { try await tracker.closed(number: 1) },
            closeTunnel: { await tracker.tunnelClosed() }
        )
        let cancel = Task { await lifecycle.cancel() }
        await gate.waitUntilBlocked()
        let close = Task { try await lifecycle.close() }
        // Gives an overlapping close time to run; a correct close stays parked on the cancel.
        try await Task.sleep(for: .milliseconds(100))
        #expect(await tracker.closes == 0)
        await gate.open()
        await cancel.value
        try await close.value
        #expect(await tracker.cancels == 1)
        #expect(await tracker.closes == 1)
        #expect(await tracker.tunnelCloses == 1)
        await lifecycle.cancel()
        #expect(await tracker.cancels == 1)
    }

    @Test func cancelByIDCancelsTheOperationEvenIfTheDriverCancelNeverReturns() async throws {
        let profileID = UUID()
        let started = AsyncStream<Void>.makeStream()
        let observed = AsyncStream<Bool>.makeStream()
        let coordinator = MCPConnectionCoordinator(
            resolver: liveResolver(for: [profileID]),
            sqlFactory: { _ in
                MCPSQLSession(
                    connection: FakeSQLConnection(),
                    lifecycle: MCPConnectionLifecycle(
                        cancel: { await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in } },
                        closeConnection: {}
                    )
                )
            }
        )
        _ = Task {
            try await coordinator.withSQLSession(requestID: "hung-driver-cancel", profileID: profileID) { _ in
                started.continuation.yield()
                do {
                    try await Task.sleep(for: .seconds(10))
                    observed.continuation.yield(false)
                } catch {
                    observed.continuation.yield(true)
                    throw error
                }
            }
        }
        for await _ in started.stream { break }
        _ = Task { await coordinator.cancel(requestID: "hung-driver-cancel") }
        var operationSawCancellation = false
        for await value in observed.stream {
            operationSawCancellation = value
            break
        }
        #expect(operationSawCancellation)
    }

    @Test func cancellingTheCallerCancelsTheDriverAndTheOperation() async throws {
        let fixture = Fixture()
        let started = AsyncStream<Void>.makeStream()
        let request = Task {
            try await fixture.coordinator.withSQLSession(requestID: "caller", profileID: fixture.profile.id) { _ in
                started.continuation.yield()
                try await Task.sleep(for: .seconds(30))
            }
        }
        for await _ in started.stream { break }
        request.cancel()
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(await fixture.tracker.cancels == 1)
        #expect(await fixture.tracker.closes == 1)
        #expect(await fixture.tracker.tunnelCloses == 1)
    }
}

/// A resolver whose enabled project assigns `profileIDs` with live reads on.
private func liveResolver(for profileIDs: Set<UUID>) -> MCPProjectResolver {
    MCPProjectResolver(
        loadProject: {
            MCPVerifiedProject(
                project: MCPProject(
                    name: "P", isEnabled: true,
                    profiles: profileIDs.map { MCPProfileAccess(profileID: $0, liveRead: true) }
                ),
                liveReadProfileIDs: profileIDs
            )
        },
        profile: { id in MCPConnectionProfile(id: id, driverID: .sqlite, config: .sqlite(path: ":memory:")) }
    )
}

private enum FixtureError: Error { case operation, close }

private actor Authorization {
    var liveReadEnabled = true
    func revoke() { liveReadEnabled = false }
    func check() -> Bool { liveReadEnabled }
}

private actor Flag {
    var value = false
    func set() { value = true }
}

private actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var blockedContinuation: CheckedContinuation<Void, Never>?
    private var isBlocked = false
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        isBlocked = true
        blockedContinuation?.resume()
        blockedContinuation = nil
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilBlocked() async {
        if isBlocked { return }
        await withCheckedContinuation { blockedContinuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private actor Tracker {
    var opens = 0
    var closes = 0
    var cancels = 0
    var tunnelCloses = 0
    var failedClose: Int?
    var readOnlyEnforcements = 0
    func opened() -> Int {
        opens += 1
        return opens
    }
    func closed(number: Int) throws {
        closes += 1
        if failedClose == number { throw FixtureError.close }
    }
    func cancelled() { cancels += 1 }
    func tunnelClosed() { tunnelCloses += 1 }
    func failCloseNumber(_ number: Int) { failedClose = number }
    func enforcedReadOnly() { readOnlyEnforcements += 1 }
    func waitForOpen() async { await waitForOpens(1) }
    func waitForOpens(_ count: Int) async {
        while opens < count { await Task.yield() }
    }
    func waitForCancels(_ count: Int) async {
        while cancels < count { await Task.yield() }
    }
}

private struct FakeSQLDriver: DatabaseDriver {
    static let id = DriverID.postgres
    static let displayName = "Fake"
    static let capabilities = Capabilities()
    static let dialect: any SQLDialect = SQLiteDialect()
    init() {}
    func connect(_ config: ConnectionConfig) async throws -> any DriverConnection { FakeSQLConnection() }
}

private actor ReadOnlyConnectionRegistry {
    static let shared = ReadOnlyConnectionRegistry()
    private var trackers: [String: Tracker] = [:]

    func register(_ tracker: Tracker, for token: String) { trackers[token] = tracker }
    func remove(_ token: String) { trackers[token] = nil }
    func tracker(for token: String) -> Tracker? { trackers[token] }
}

private struct ReadOnlyTrackingSQLDriver: DatabaseDriver {
    static let id = DriverID.postgres
    static let displayName = "Read-only tracking SQL driver"
    static let capabilities = Capabilities()
    static let dialect: any SQLDialect = SQLiteDialect()
    init() {}

    func connect(_ config: ConnectionConfig) async throws -> any DriverConnection {
        guard let tracker = await ReadOnlyConnectionRegistry.shared.tracker(for: config.name) else {
            throw DriverError.connectionFailed("Missing test tracker")
        }
        let number = await tracker.opened()
        return TrackingSQLConnection(tracker: tracker, number: number)
    }
}

private actor TrackingSQLConnection: DriverConnection {
    nonisolated let id = UUID()
    private let tracker: Tracker
    private let number: Int

    init(tracker: Tracker, number: Int) {
        self.tracker = tracker
        self.number = number
    }

    nonisolated func execute(_ sql: String) -> AsyncThrowingStream<ResultEvent, Error> {
        .init { $0.finish() }
    }
    nonisolated func cancelCurrentQuery() {}
    func setDatabase(_ name: String) async throws {}
    nonisolated var introspector: any Introspector { fatalError("unused") }
    func ping() async -> Bool { true }
    func close() async { try? await tracker.closed(number: number) }
}

private actor FakeSQLConnection: DriverConnection {
    nonisolated let id = UUID()
    nonisolated func execute(_ sql: String) -> AsyncThrowingStream<ResultEvent, Error> { .init { $0.finish() } }
    nonisolated func cancelCurrentQuery() {}
    func setDatabase(_ name: String) async throws {}
    nonisolated var introspector: any Introspector { fatalError("unused") }
    func ping() async -> Bool { true }
    func close() async {}
}

private struct Fixture {
    let profile: MCPConnectionProfile
    let tracker: Tracker
    let authorization: Authorization
    let coordinator: MCPConnectionCoordinator

    init(profileIsAuthorized: Bool = true, profileExists: Bool = true) {
        let id = UUID()
        let tracker = Tracker()
        let authorization = Authorization()
        profile = MCPConnectionProfile(id: id, driverID: .sqlite, config: .sqlite(path: ":memory:"))
        self.tracker = tracker
        self.authorization = authorization
        let project = MCPProject(
            name: "P", isEnabled: true,
            profiles: profileIsAuthorized ? [MCPProfileAccess(profileID: id, liveRead: true)] : []
        )
        let resolver = MCPProjectResolver(
            loadProject: {
                let liveReadEnabled = await authorization.check()
                return MCPVerifiedProject(project: project, liveReadProfileIDs: liveReadEnabled ? [id] : [])
            },
            profile: { requested in profileExists && requested == id ? MCPConnectionProfile(id: id, driverID: .sqlite, config: .sqlite(path: ":memory:")) : nil }
        )
        let lifecycle: @Sendable () async -> MCPConnectionLifecycle = {
            let number = await tracker.opened()
            return MCPConnectionLifecycle(
                cancel: { await tracker.cancelled() },
                closeConnection: { try await tracker.closed(number: number) },
                closeTunnel: { await tracker.tunnelClosed() }
            )
        }
        coordinator = MCPConnectionCoordinator(
            resolver: resolver,
            sqlFactory: { _ in MCPSQLSession(connection: FakeSQLConnection(), recordsHistory: false, lifecycle: await lifecycle()) }
        )
    }
}
