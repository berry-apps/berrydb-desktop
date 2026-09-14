import BerryDataSourceKit
import BerryDriverKit
import BerryDriverTestKit
import Foundation
import Testing

@testable import BerryDriverMongo

/// Runs against a real single-node replica set from `BERRYDB_TEST_MONGO_RS`
/// (`host:port[,host:port...]`, see `Tests/docker/compose.yml`'s `mongo-rs`
/// service); skipped when the env var is unset
/// see Tests/docker/compose.yml). Ground truth for the v1 seeds->primary
/// discovery code path — confirms the driver actually lands on a node the
/// SERVER ITSELF reports as primary (re-queried independently after
/// connect), not just "it connected to something".
///
/// A single-node replica set is always its own primary, so the "connected
/// seed isn't primary, reconnect to the host it names" branch never fires
/// against this container — that LOGIC is unit-tested instead
/// (`MongoWireClientTests`, stub transports). See the `mongo-rs` compose
/// comment for why a multi-node topology isn't used here.
@Suite("Mongo replica-set conformance (v1)", .enabled(if: MongoReplicaSetTestServer.mongoReplicaSet != nil))
struct MongoReplicaSetConformanceTests {
    private var server: MongoReplicaSetTestServer { MongoReplicaSetTestServer.mongoReplicaSet! }

    private func splitHostPort(_ raw: String) -> (host: String, port: Int) {
        let parts = raw.split(separator: ":")
        return (String(parts.first ?? ""), parts.count > 1 ? (Int(parts[1]) ?? 27017) : 27017)
    }

    private func makeConfig(
        additionalHosts: [String]? = nil, replicaSet: String? = MongoReplicaSetTestServer.replicaSetName
    ) -> ConnectionConfig {
        let (host, port) = splitHostPort(server.hosts[0])
        let extras = additionalHosts ?? Array(server.hosts.dropFirst())
        return ConnectionConfig(
            driver: .mongodb, name: "test-rs", host: host, port: port,
            database: "berry_rs_test", tlsMode: .disable,
            additionalHosts: extras.isEmpty ? nil : extras,
            mongoReplicaSet: replicaSet
        )
    }

    @Test func driverConnectsAndLandsOnANodeTheServerConfirmsIsPrimary() async throws {
        let client = try MongoWireClient(config: makeConfig())
        try await client.connect() // exercises the real seeds -> primary flow end to end

        // Ground truth: re-query hello independently, straight from the
        // server, right after connect — not inferring success just from
        // "connect() didn't throw".
        let hello = try await client.runCommand(.object([("hello", .int(1))]), database: "admin")
        let info = MongoHelloResponse(hello)
        #expect(info.isWritablePrimary == true)
        #expect(info.setName == MongoReplicaSetTestServer.replicaSetName)
        await client.close()
    }

    @Test func findInsertRoundTripAgainstTheReplicaSetPrimary() async throws {
        let config = makeConfig()
        let connection = try MongoConnection(config: config)
        try await connection.open()
        defer { Task { await connection.close() } }

        let name = "berry_rs_conf_\(UUID().uuidString.prefix(8))"
        defer {
            Task {
                let cleanupClient = try? MongoWireClient(config: config)
                try? await cleanupClient?.connect()
                _ = try? await cleanupClient?.runCommand(.object([("drop", .string(name))]), database: "berry_rs_test")
                await cleanupClient?.close()
            }
        }

        let result = try await connection.write(.insert(collection: name, document: .object([("label", .string("rs-write"))])))
        #expect(result.affectedCount == 1)

        var items: [BerryDocument] = []
        for try await event in connection.query(.mongoFind(collection: name, filter: .object([]), projection: nil, limit: nil)) {
            if case .items(let batch) = event { items += batch }
        }
        #expect(items.count == 1)
        #expect(items.first?["label"] == .string("rs-write"))
    }

    /// Task scope point 6: a `replicaSet=` that doesn't match the server's
    /// real `setName` is a configuration error, surfaced as a connect failure.
    @Test func replicaSetNameMismatchIsRejected() async throws {
        let client = try MongoWireClient(config: makeConfig(replicaSet: "definitely-not-\(MongoReplicaSetTestServer.replicaSetName)"))
        await #expect(throws: (any Error).self) {
            try await client.connect()
        }
    }

    @Test func driverConnectSucceedsThroughTheDataSourceDriverEntryPoint() async throws {
        let driver = MongoDriver()
        let connection = try await driver.connect(makeConfig())
        defer { Task { await connection.close() } }
        #expect(await connection.ping())
    }
}
