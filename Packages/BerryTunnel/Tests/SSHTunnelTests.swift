import BerryDriverKit
import BerryDriverTestKit
import Foundation
import Testing

@testable import BerryDriverPostgres
@testable import BerryTunnel

/// Runs against the sshd bastion in Tests/docker/compose.yml
/// (`BERRYDB_TEST_SSH`, format host:port:user:pass) plus the Postgres
/// container reached THROUGH the tunnel via docker-network DNS.
/// Skipped when the env var is unset.
@Suite("SSH tunnel", .enabled(if: TestServer.ssh != nil && TestServer.postgres != nil))
struct SSHTunnelTests {
    private func makeSSHConfig() -> SSHConfig {
        let server = TestServer.ssh!
        return SSHConfig(
            host: server.host,
            port: server.port,
            username: server.username,
            password: server.password
        )
    }

    @Test func forwardsPostgresThroughTunnel() async throws {
        // Target uses the docker-network DNS name — reachable only from
        // INSIDE the bastion, which proves traffic really goes via SSH.
        let tunnel = try await SSHTunnel.open(
            makeSSHConfig(),
            targetHost: "postgres16",
            targetPort: 5432,
            knownHosts: makeIsolatedKnownHosts()
        )
        defer { Task { await tunnel.close() } }

        let pg = TestServer.postgres!
        let conn = try await PostgresDriverConnection(config: ConnectionConfig(
            driver: .postgres,
            name: "via-tunnel",
            host: "127.0.0.1",
            port: tunnel.localPort,
            username: pg.username,
            password: pg.password,
            database: pg.database
        ))
        let harness = DriverConformance { conn }
        let result = try await harness.drain(conn.execute("SELECT 1"))
        #expect(result.rows == [[.int(1)]])
        await conn.close()
    }

    @Test func streamsLargeResultThroughTunnel() async throws {
        // Bidirectional glue + backpressure under real load (10k rows).
        let tunnel = try await SSHTunnel.open(
            makeSSHConfig(),
            targetHost: "postgres16",
            targetPort: 5432,
            knownHosts: makeIsolatedKnownHosts()
        )
        defer { Task { await tunnel.close() } }

        let pg = TestServer.postgres!
        let harness = DriverConformance {
            try await PostgresDriverConnection(config: ConnectionConfig(
                driver: .postgres,
                name: "via-tunnel",
                host: "127.0.0.1",
                port: tunnel.localPort,
                username: pg.username,
                password: pg.password,
                database: pg.database
            ))
        }
        try await harness.checkStreaming(
            setup: [],
            select: "SELECT g, md5(g::text) FROM generate_series(1, 10000) g",
            expectedRows: 10_000
        )
    }

    @Test func failsCleanlyOnBadCredentials() async throws {
        let server = TestServer.ssh!
        let bad = SSHConfig(
            host: server.host, port: server.port,
            username: server.username, password: "sai-mat-khau"
        )
        await #expect(throws: DriverError.self) {
            _ = try await SSHTunnel.open(
                bad, targetHost: "postgres16", targetPort: 5432,
                knownHosts: makeIsolatedKnownHosts()
            )
        }
    }
}
