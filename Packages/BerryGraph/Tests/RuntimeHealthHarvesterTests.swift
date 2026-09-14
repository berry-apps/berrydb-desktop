import BerryCore
import BerryDriverKit
import BerryDriverMySQL
import BerryDriverPostgres
import BerryDriverSQLite
import BerryDriverTestKit
import Foundation
import Testing

@testable import BerryGraph

@Suite("RuntimeHealthHarvester on Postgres", .enabled(if: TestServer.postgres != nil))
struct RuntimeHealthHarvesterPostgresTests {
    private func openSession() async throws -> Session {
        DriverRegistry.register(PostgresDriver.self)
        let s = TestServer.postgres!
        return try await ConnectionManager().open(
            ConnectionConfig(driver: .postgres, name: "harvest", host: s.host, port: s.port,
                             username: s.username, password: s.password, database: s.database)
        )
    }

    @Test func harvestsPostgresMetrics() async throws {
        let session = try await openSession()
        defer { Task { await session.connection.close() } }

        let metrics = await RuntimeHealthHarvester.harvest(session: session)

        let hitRatio = try #require(metrics.first { $0.name == "cache_hit_ratio" })
        #expect(hitRatio.value >= 0.0 && hitRatio.value <= 1.0)

        let connCount = try #require(metrics.first { $0.name == "connection_count" })
        #expect(connCount.value >= 1.0)
    }
}

@Suite("RuntimeHealthHarvester on MySQL", .enabled(if: TestServer.mysql != nil))
struct RuntimeHealthHarvesterMySQLTests {
    private func openSession() async throws -> Session {
        DriverRegistry.register(MySQLDriver.self)
        let s = TestServer.mysql!
        return try await ConnectionManager().open(ConnectionConfig(
            driver: .mysql, name: "harvest", host: s.host, port: s.port,
            username: s.username, password: s.password, database: s.database
        ))
    }

    @Test func harvestsMySQLMetrics() async throws {
        let session = try await openSession()
        defer { Task { await session.connection.close() } }

        let metrics = await RuntimeHealthHarvester.harvest(session: session)

        let connCount = try #require(metrics.first { $0.name == "connection_count" })
        #expect(connCount.value >= 1.0)
    }
}

@Suite("RuntimeHealthHarvester on SQLite")
struct RuntimeHealthHarvesterSQLiteTests {
    @Test func returnsEmptyForSQLite() async throws {
        DriverRegistry.register(SQLiteDriver.self)
        let path = NSTemporaryDirectory() + "berrydb-runtime-\(UUID().uuidString).sqlite"
        FileManager.default.createFile(atPath: path, contents: nil)
        let session = try await ConnectionManager().open(.sqlite(path: path))
        defer { Task { await session.connection.close() } }

        let metrics = await RuntimeHealthHarvester.harvest(session: session)
        #expect(metrics.isEmpty)
    }
}
