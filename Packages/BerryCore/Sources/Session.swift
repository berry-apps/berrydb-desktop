import BerryDriverKit
import BerryTunnel
import Foundation

/// One logical connection — decoupled from the physical connection so it can
/// later reconnect without losing tab state (docs/architecture/04 §3).
public struct Session: Sendable, Identifiable {
    public let id: UUID
    /// Saved profile this session was opened from (nil for quick-open) —
    /// used by history (ED-06) and snapshots (DI-08).
    public let profileID: UUID?
    /// Production label (KN-07) — tightens DangerGuard (07 §6).
    public let isProduction: Bool
    public let config: ConnectionConfig
    public let connection: any DriverConnection
    public let capabilities: Capabilities
    public let dialect: any SQLDialect
    public let driverDisplayName: String
    /// Non-nil when the connection runs through an SSH tunnel (KN-03);
    /// closed together with the session (docs/architecture/06 · L1).
    public let tunnel: SSHTunnel?
    /// Whether statements run in this session are logged to history (ED-06) —
    /// off when the profile disables it.
    public let recordHistory: Bool

    public var displayName: String { config.name }
}

/// Per-step outcome of a connection test (KN-06). `steps` holds every stage
/// that was attempted, in order; `errorMessage` is nil on full success.
public struct ConnectionTestReport: Sendable, Equatable {
    public enum Step: String, Sendable, CaseIterable {
        case tunnel
        case connect
        case ping
    }

    public struct StepResult: Sendable, Equatable, Identifiable {
        public let step: Step
        public let passed: Bool
        public let seconds: Double
        public var id: String { step.rawValue }

        public init(step: Step, passed: Bool, seconds: Double) {
            self.step = step
            self.passed = passed
            self.seconds = seconds
        }
    }

    public let steps: [StepResult]
    public let errorMessage: String?

    public var succeeded: Bool { errorMessage == nil }

    public init(steps: [StepResult], errorMessage: String?) {
        self.steps = steps
        self.errorMessage = errorMessage
    }
}

/// Connection lifecycle (docs/architecture/04 §2). M1: open/close + test;
/// automatic reconnect comes with M2 session restore.
public actor ConnectionManager {
    public static let shared = ConnectionManager()

    private var sessions: [UUID: Session] = [:]

    public init() {}

    /// Test connection (KN-06): tunnel (if any) → connect → ping → close;
    /// reports the first failing step through the thrown DriverError.
    public func test(_ config: ConnectionConfig) async throws {
        let report = await testReport(config)
        if let error = report.errorMessage {
            throw DriverError.connectionFailed(error)
        }
    }

    /// Test connection with a per-step breakdown (KN-06). Runs the same
    /// tunnel → connect → ping sequence as `test`, but records the outcome and
    /// timing of each attempted step and stops at the first failure instead of
    /// throwing, so the UI can show exactly where a connection breaks.
    public func testReport(_ config: ConnectionConfig) async -> ConnectionTestReport {
        guard let driverType = DriverRegistry.driverType(for: config.driver) else {
            return ConnectionTestReport(
                steps: [],
                errorMessage: "Driver \(config.driver.rawValue) is not registered"
            )
        }
        let clock = ContinuousClock()
        var steps: [ConnectionTestReport.StepResult] = []

        // 1. SSH tunnel — only when the connection is configured to use one.
        let effectiveConfig: ConnectionConfig
        let tunnel: SSHTunnel?
        if config.ssh != nil {
            let started = clock.now
            do {
                (effectiveConfig, tunnel) = try await prepareEndpoint(config)
                steps.append(.init(step: .tunnel, passed: true, seconds: Self.seconds(clock.now - started)))
            } catch {
                steps.append(.init(step: .tunnel, passed: false, seconds: Self.seconds(clock.now - started)))
                return ConnectionTestReport(steps: steps, errorMessage: error.localizedDescription)
            }
        } else {
            (effectiveConfig, tunnel) = (config, nil)
        }

        // 2. Connect (TCP + TLS handshake + authentication, as one driver call).
        let connection: any DriverConnection
        let connectStarted = clock.now
        do {
            connection = try await driverType.init().connect(effectiveConfig)
            steps.append(.init(step: .connect, passed: true, seconds: Self.seconds(clock.now - connectStarted)))
        } catch {
            steps.append(.init(step: .connect, passed: false, seconds: Self.seconds(clock.now - connectStarted)))
            await tunnel?.close()
            return ConnectionTestReport(steps: steps, errorMessage: error.localizedDescription)
        }

        // 3. Ping.
        let pingStarted = clock.now
        let alive = await connection.ping()
        steps.append(.init(step: .ping, passed: alive, seconds: Self.seconds(clock.now - pingStarted)))
        await connection.close()
        await tunnel?.close()
        return ConnectionTestReport(
            steps: steps,
            errorMessage: alive ? nil : "Connection opened but ping failed"
        )
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    public func open(
        _ config: ConnectionConfig,
        profileID: UUID? = nil,
        isProduction: Bool = false,
        recordHistory: Bool = true
    ) async throws -> Session {
        guard let driverType = DriverRegistry.driverType(for: config.driver) else {
            throw DriverError.unsupported("Driver \(config.driver.rawValue) is not registered")
        }
        let (effectiveConfig, tunnel) = try await prepareEndpoint(config)

        let connection: any DriverConnection
        do {
            connection = try await driverType.init().connect(effectiveConfig)
        } catch {
            await tunnel?.close()
            throw error
        }

        let session = Session(
            id: UUID(),
            profileID: profileID,
            isProduction: isProduction,
            config: config,
            connection: connection,
            capabilities: driverType.capabilities,
            dialect: driverType.dialect,
            driverDisplayName: driverType.displayName,
            tunnel: tunnel,
            recordHistory: recordHistory
        )
        sessions[session.id] = session
        return session
    }

    public func close(_ sessionID: UUID) async {
        guard let session = sessions.removeValue(forKey: sessionID) else { return }
        await session.connection.close()
        await session.tunnel?.close()
    }

    public func closeAll() async {
        for session in sessions.values {
            await session.connection.close()
            await session.tunnel?.close()
        }
        sessions.removeAll()
    }

    /// SSH first, then swap the endpoint to the tunnel's local port
    /// (docs/architecture/06 · L1).
    private func prepareEndpoint(
        _ config: ConnectionConfig
    ) async throws -> (ConnectionConfig, SSHTunnel?) {
        guard let ssh = config.ssh else { return (config, nil) }
        guard let targetHost = config.host else {
            throw DriverError.connectionFailed("Missing host")
        }
        let targetPort = config.port ?? defaultPort(for: config.driver)
        let tunnel = try await SSHTunnel.open(ssh, targetHost: targetHost, targetPort: targetPort)
        return (config.replacingEndpoint(host: "127.0.0.1", port: tunnel.localPort), tunnel)
    }

    private func defaultPort(for driver: DriverID) -> Int {
        switch driver {
        case .postgres: 5432
        case .mysql: 3306
        case .redis: 6379
        case .sqlserver: 1433
        case .mongodb: 27017
        case .qdrant: 6333
        case .elasticsearch: 9200
        case .dynamodb: 443
        case .sqlite: 0
        }
    }
}
