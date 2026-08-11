import BerryCore
import BerryDriverKit
import BerryDriverMySQL
import BerryDriverPostgres
import BerryDriverTestKit
import BerryStore
import Foundation
import Testing

@testable import BerryGraph

/// Harvests the DSG from a real schema on the Docker matrix (DI-01). Skips
/// cleanly when the server env var is unset.
@Suite("SchemaHarvester on Postgres (DI-01)", .enabled(if: TestServer.postgres != nil))
struct SchemaHarvesterPostgresTests {
    private func openSession(isProduction: Bool = false) async throws -> Session {
        DriverRegistry.register(PostgresDriver.self)
        let s = TestServer.postgres!
        return try await ConnectionManager().open(
            ConnectionConfig(driver: .postgres, name: "harvest", host: s.host, port: s.port,
                             username: s.username, password: s.password, database: s.database),
            isProduction: isProduction
        )
    }

    private func exec(_ sql: String, on session: Session) async throws {
        for try await _ in session.connection.execute(sql) {}
    }

    private func tableID(_ graph: SchemaGraph, _ name: String) -> String? {
        graph.nodes.values.first { $0.kind == .table && $0.name == name }?.id
    }

    @Test func harvestsTablesColumnsAndForeignKeys() async throws {
        let session = try await openSession()
        // Close unconditionally — a mid-test throw must not leak the connection
        // (PostgresNIO asserts on deinit-before-close).
        defer { Task { await session.connection.close() } }
        try await exec("DROP TABLE IF EXISTS bd_dsg_orders", on: session)
        try await exec("DROP TABLE IF EXISTS bd_dsg_customers", on: session)
        try await exec("CREATE TABLE bd_dsg_customers (id int PRIMARY KEY, name text)", on: session)
        try await exec("""
            CREATE TABLE bd_dsg_orders (
                id int PRIMARY KEY,
                customer_id int REFERENCES bd_dsg_customers(id)
            )
            """, on: session)

        let graph = try await SchemaHarvester.buildGraph(session: session, catalog: SchemaCatalog(session: session))

        let orders = try #require(tableID(graph, "bd_dsg_orders"))
        let customers = try #require(tableID(graph, "bd_dsg_customers"))
        #expect(graph.neighbors(of: orders, direction: .outgoing, kinds: [.references]).contains(customers))
        #expect(graph.blastRadius(of: customers).contains(orders))
        #expect(graph.neighbors(of: orders, direction: .outgoing, kinds: [.hasColumn]).count == 2)

        try await exec("DROP TABLE IF EXISTS bd_dsg_orders", on: session)
        try await exec("DROP TABLE IF EXISTS bd_dsg_customers", on: session)
    }

    @Test func refusesProductionByDefault() async throws {
        let session = try await openSession(isProduction: true)
        defer { Task { await session.connection.close() } }
        let catalog = SchemaCatalog(session: session)
        await #expect(throws: SchemaHarvester.HarvestError.productionDisabled) {
            _ = try await SchemaHarvester.buildGraph(session: session, catalog: catalog)
        }
        // ...but an explicit opt-in proceeds.
        let graph = try await SchemaHarvester.buildGraph(session: session, catalog: catalog, allowProduction: true)
        #expect(graph.nodeCount >= 0)
    }

    @Test func enrichesTableAndIndexStats() async throws {
        let session = try await openSession()
        defer { Task { await session.connection.close() } }
        try await exec("DROP TABLE IF EXISTS bd_stats_t", on: session)
        try await exec("CREATE TABLE bd_stats_t (id int PRIMARY KEY, v int)", on: session)
        try await exec("CREATE INDEX bd_stats_idx ON bd_stats_t (v)", on: session)
        try await exec("INSERT INTO bd_stats_t (id, v) VALUES (1, 10), (2, 20), (3, 30)", on: session)
        try await exec("ANALYZE bd_stats_t", on: session)

        let structural = try await SchemaHarvester.buildGraph(session: session, catalog: SchemaCatalog(session: session))
        let enriched = await StatsHarvester.enrich(structural, session: session)

        let table = try #require(enriched.nodes.values.first { $0.kind == .table && $0.name == "bd_stats_t" })
        #expect((table.attrs["size_bytes"].flatMap(Int.init) ?? 0) > 0)
        #expect(table.attrs["rows"] != nil)
        #expect(table.attrs["seq_scan"] != nil)
        let index = try #require(enriched.nodes.values.first { $0.kind == .index && $0.name == "bd_stats_idx" })
        #expect(index.attrs["idx_scan"] != nil)

        try await exec("DROP TABLE IF EXISTS bd_stats_t", on: session)
    }

    @Test func harvestPersistsAndReloadsSnapshot() async throws {
        let session = try await openSession()
        defer { Task { await session.connection.close() } }
        try await exec("DROP TABLE IF EXISTS bd_dsg_solo", on: session)
        try await exec("CREATE TABLE bd_dsg_solo (id int PRIMARY KEY)", on: session)

        let store = GraphStore(store: try BerryStore(path: ":memory:"))
        let profile = UUID()
        _ = try await SchemaHarvester.harvest(
            session: session, catalog: SchemaCatalog(session: session),
            into: store, profileID: profile, now: Date(timeIntervalSince1970: 1000)
        )
        #expect(try store.snapshots(profileID: profile).count == 1)
        let loaded = try store.loadGraph(profileID: profile)
        #expect(loaded.nodes.values.contains { $0.kind == .table && $0.name == "bd_dsg_solo" })

        try await exec("DROP TABLE IF EXISTS bd_dsg_solo", on: session)
    }
}

@Suite("SchemaHarvester on MySQL (DI-01)", .enabled(if: TestServer.mysql != nil))
struct SchemaHarvesterMySQLTests {
    private func exec(_ sql: String, on session: Session) async throws {
        for try await _ in session.connection.execute(sql) {}
    }

    @Test func harvestsForeignKeys() async throws {
        DriverRegistry.register(MySQLDriver.self)
        let s = TestServer.mysql!
        let session = try await ConnectionManager().open(ConnectionConfig(
            driver: .mysql, name: "harvest", host: s.host, port: s.port,
            username: s.username, password: s.password, database: s.database
        ))
        defer { Task { await session.connection.close() } }
        try await exec("DROP TABLE IF EXISTS bd_dsg_orders", on: session)
        try await exec("DROP TABLE IF EXISTS bd_dsg_customers", on: session)
        try await exec("CREATE TABLE bd_dsg_customers (id int PRIMARY KEY, name text) ENGINE=InnoDB", on: session)
        try await exec("""
            CREATE TABLE bd_dsg_orders (
                id int PRIMARY KEY, customer_id int,
                FOREIGN KEY (customer_id) REFERENCES bd_dsg_customers(id)
            ) ENGINE=InnoDB
            """, on: session)

        let graph = try await SchemaHarvester.buildGraph(session: session, catalog: SchemaCatalog(session: session))
        let orders = graph.nodes.values.first { $0.kind == .table && $0.name == "bd_dsg_orders" }?.id
        let customers = graph.nodes.values.first { $0.kind == .table && $0.name == "bd_dsg_customers" }?.id
        let ordersID = try #require(orders)
        let customersID = try #require(customers)
        #expect(graph.blastRadius(of: customersID).contains(ordersID))

        try await exec("DROP TABLE IF EXISTS bd_dsg_orders", on: session)
        try await exec("DROP TABLE IF EXISTS bd_dsg_customers", on: session)
    }

    @Test func enrichesTableSize() async throws {
        DriverRegistry.register(MySQLDriver.self)
        let s = TestServer.mysql!
        let session = try await ConnectionManager().open(ConnectionConfig(
            driver: .mysql, name: "stats", host: s.host, port: s.port,
            username: s.username, password: s.password, database: s.database
        ))
        defer { Task { await session.connection.close() } }
        try await exec("DROP TABLE IF EXISTS bd_stats_t", on: session)
        try await exec("CREATE TABLE bd_stats_t (id int PRIMARY KEY, v int) ENGINE=InnoDB", on: session)
        try await exec("INSERT INTO bd_stats_t (id, v) VALUES (1, 10), (2, 20)", on: session)
        try await exec("ANALYZE TABLE bd_stats_t", on: session)

        let structural = try await SchemaHarvester.buildGraph(session: session, catalog: SchemaCatalog(session: session))
        let enriched = await StatsHarvester.enrich(structural, session: session)

        let table = try #require(enriched.nodes.values.first { $0.kind == .table && $0.name == "bd_stats_t" })
        #expect(table.attrs["size_bytes"] != nil)

        try await exec("DROP TABLE IF EXISTS bd_stats_t", on: session)
    }
}
