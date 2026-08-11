import BerryDataSourceKit
import BerryDriverKit
import Foundation
import Testing

@testable import BerryDriverMongo

@Suite("MongoWireClient — handshake, auth, command envelope")
struct MongoWireClientTests {
    private func makeConfig(username: String? = nil, password: String? = nil, database: String? = nil) -> ConnectionConfig {
        ConnectionConfig(driver: .mongodb, name: "test", host: "stub-host", port: 27017, username: username, password: password, database: database)
    }

    // MARK: - Handshake without auth

    @Test func connectWithoutUsernameOnlySendsHello() async throws {
        let transport = MongoStubTransport(handlers: [helloHandler])
        let client = try MongoWireClient(config: makeConfig(), transport: transport)
        try await client.connect()
        #expect(transport.sentCommands.count == 1)
        #expect(transport.sentCommands[0]["hello"] == .int(1))
    }

    @Test func everyCommandCarriesDollarDB() async throws {
        let transport = MongoStubTransport(handlers: [helloHandler])
        let client = try MongoWireClient(config: makeConfig(), transport: transport)
        try await client.connect()
        #expect(transport.sentCommands[0]["$db"] == .string("admin"))
    }

    @Test func requestIDsIncrementPerCommand() async throws {
        let transport = MongoStubTransport(handlers: [helloHandler, { _ in okReply() }])
        let client = try MongoWireClient(config: makeConfig(), transport: transport)
        try await client.connect()
        _ = try await client.runCommand(.object([("ping", .int(1))]), database: "admin")
        #expect(transport.sentCommands.count == 2)
    }

    // MARK: - SCRAM-SHA-256 handshake (full round trip through a fake server)

    private func parseClientFirstBare(_ payload: String) -> (username: String, nonce: String) {
        let bare = payload.hasPrefix("n,,") ? String(payload.dropFirst(3)) : payload
        var username = ""
        var nonce = ""
        for part in bare.split(separator: ",") {
            if part.hasPrefix("n=") { username = String(part.dropFirst(2)) }
            if part.hasPrefix("r=") { nonce = String(part.dropFirst(2)) }
        }
        return (username, nonce)
    }

    /// Builds a fake-but-self-consistent SCRAM server: it reuses `SCRAM`'s
    /// own (RFC-verified, see `SCRAMTests`) math from "the server's side" to
    /// compute the `v=` signature it hands back, rather than duplicating
    /// PBKDF2/HMAC in test code. This exercises `MongoWireClient`'s wire
    /// plumbing (saslStart/saslContinue field shapes, conversationId
    /// threading, the "done" loop) independently from the crypto itself.
    @Test func connectPerformsFullSCRAMHandshakeAgainstAFakeServer() async throws {
        let username = "berry"
        let password = "s3cret"
        let salt = Data([1, 2, 3, 4, 5, 6, 7, 8])
        let iterations = 10
        final class Captured: @unchecked Sendable {
            var clientFirst: SCRAM.ClientFirst?
            var serverFirst: SCRAM.ServerFirst?
        }
        let captured = Captured()

        let transport = MongoStubTransport(handlers: [
            helloHandler,
            { [self] request in
                guard case .binary(let payloadBytes)? = request["payload"] else {
                    Issue.record("expected binary payload on saslStart")
                    return okReply()
                }
                let (parsedUsername, clientNonce) = parseClientFirstBare(String(decoding: payloadBytes, as: UTF8.self))
                #expect(parsedUsername == username)
                captured.clientFirst = SCRAM.clientFirst(username: parsedUsername, nonce: clientNonce)
                let serverFirstMessage = "r=\(clientNonce)SERVERSUFFIX,s=\(salt.base64EncodedString()),i=\(iterations)"
                captured.serverFirst = try! SCRAM.parseServerFirst(serverFirstMessage)
                return okReply([
                    ("conversationId", .int(1)),
                    ("payload", .binary(Data(serverFirstMessage.utf8))),
                    ("done", .bool(false)),
                ])
            },
            { request in
                guard let clientFirst = captured.clientFirst, let serverFirst = captured.serverFirst else {
                    Issue.record("missing captured SCRAM state")
                    return okReply()
                }
                #expect(request["conversationId"] == .int(1))
                let expected = try! SCRAM.clientFinal(password: password, clientFirst: clientFirst, serverFirst: serverFirst)
                let serverFinalMessage = "v=\(expected.serverSignatureExpected.base64EncodedString())"
                return okReply([
                    ("conversationId", .int(1)),
                    ("payload", .binary(Data(serverFinalMessage.utf8))),
                    ("done", .bool(true)),
                ])
            },
        ])

        let client = try MongoWireClient(
            config: makeConfig(username: username, password: password, database: "berrydb"), transport: transport
        )
        try await client.connect() // must not throw — full handshake succeeds
        #expect(transport.sentCommands.count == 3) // hello, saslStart, saslContinue
        #expect(transport.sentCommands[1]["$db"] == .string("berrydb")) // authSource defaults to config.database
    }

    @Test func connectThrowsWhenServerSignatureIsWrong() async throws {
        let transport = MongoStubTransport(handlers: [
            helloHandler,
            { _ in
                let serverFirstMessage = "r=whatever-nonceSUFFIX,s=AQIDBA==,i=10"
                return okReply([
                    ("conversationId", .int(1)),
                    ("payload", .binary(Data(serverFirstMessage.utf8))),
                    ("done", .bool(false)),
                ])
            },
            { _ in
                // Bogus server signature — does not match what the client independently computed.
                okReply([
                    ("conversationId", .int(1)),
                    ("payload", .binary(Data("v=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=".utf8))),
                    ("done", .bool(true)),
                ])
            },
        ])
        let client = try MongoWireClient(
            config: makeConfig(username: "u", password: "p", database: "db"), transport: transport
        )
        await #expect(throws: (any Error).self) {
            try await client.connect()
        }
    }

    // MARK: - Command failures

    @Test func runCommandThrowsOnNonOKReply() async throws {
        let transport = MongoStubTransport(handlers: [
            helloHandler,
            { _ in .object([("ok", .double(0)), ("errmsg", .string("no such collection"))]) },
        ])
        let client = try MongoWireClient(config: makeConfig(), transport: transport)
        try await client.connect()
        await #expect(throws: DataSourceError.self) {
            _ = try await client.runCommand(.object([("find", .string("x"))]), database: "test")
        }
    }

    // MARK: - Collections / find / aggregate / getMore / write command shapes

    @Test func listCollectionsParsesFirstBatchNames() async throws {
        let transport = MongoStubTransport(handlers: [
            helloHandler,
            { _ in
                okReply([
                    ("cursor", .object([
                        ("firstBatch", .array([
                            .object([("name", .string("users"))]),
                            .object([("name", .string("orders"))]),
                        ])),
                        ("id", .int(0)),
                    ])),
                ])
            },
        ])
        let client = try MongoWireClient(config: makeConfig(), transport: transport)
        try await client.connect()
        let collections = try await client.listCollections(database: "berrydb")
        #expect(collections.map(\.name) == ["users", "orders"])
        #expect(collections.allSatisfy { $0.database == "berrydb" })
    }

    @Test func findSendsFilterProjectionLimitAndParsesCursor() async throws {
        let transport = MongoStubTransport(handlers: [
            helloHandler,
            { request in
                #expect(request["find"] == .string("users"))
                #expect(request["filter"] == .object([("age", .int(30))]))
                #expect(request["projection"] == .object([("name", .int(1))]))
                #expect(request["limit"] == .int(5))
                #expect(request["batchSize"] == .int(1000))
                return okReply([
                    ("cursor", .object([
                        ("firstBatch", .array([.object([("_id", .int(1))])])),
                        ("id", .int(42)),
                    ])),
                ])
            },
        ])
        let client = try MongoWireClient(config: makeConfig(), transport: transport)
        try await client.connect()
        let page = try await client.find(
            database: "berrydb", collection: "users", filter: .object([("age", .int(30))]),
            projection: .object([("name", .int(1))]), limit: 5, batchSize: 1000
        )
        #expect(page.documents.count == 1)
        #expect(page.cursorID == 42)
    }

    @Test func aggregateSendsPipelineAndParsesFirstBatch() async throws {
        let transport = MongoStubTransport(handlers: [
            helloHandler,
            { request in
                #expect(request["aggregate"] == .string("orders"))
                #expect(request["pipeline"] == .array([.object([("$match", .object([]))])]))
                return okReply([("cursor", .object([("firstBatch", .array([])), ("id", .int(0))]))])
            },
        ])
        let client = try MongoWireClient(config: makeConfig(), transport: transport)
        try await client.connect()
        let page = try await client.aggregate(
            database: "berrydb", collection: "orders", pipeline: [.object([("$match", .object([]))])], batchSize: 1000
        )
        #expect(page.documents.isEmpty)
        #expect(page.cursorID == 0)
    }

    @Test func getMoreUsesNextBatchAndCarriesCursorID() async throws {
        let transport = MongoStubTransport(handlers: [
            helloHandler,
            { request in
                #expect(request["getMore"] == .int(42))
                #expect(request["collection"] == .string("users"))
                return okReply([
                    ("cursor", .object([("nextBatch", .array([.object([("_id", .int(2))])])), ("id", .int(0))])),
                ])
            },
        ])
        let client = try MongoWireClient(config: makeConfig(), transport: transport)
        try await client.connect()
        let page = try await client.getMore(database: "berrydb", collection: "users", cursorID: 42, batchSize: 1000)
        #expect(page.documents.count == 1)
        #expect(page.cursorID == 0)
    }

    // MARK: - Explicit collection creation (docs/architecture/12 §3)

    @Test func createCollectionSendsCreateCommand() async throws {
        let transport = MongoStubTransport(handlers: [
            helloHandler,
            { request in
                #expect(request["create"] == .string("docs"))
                #expect(request["$db"] == .string("berrydb"))
                return okReply()
            },
        ])
        let client = try MongoWireClient(config: makeConfig(), transport: transport)
        try await client.connect()
        try await client.createCollection(database: "berrydb", collection: "docs")
    }

    @Test func createCollectionOnExistingNameThrows() async throws {
        let transport = MongoStubTransport(handlers: [
            helloHandler,
            { _ in .object([("ok", .double(0)), ("errmsg", .string("collection already exists"))]) },
        ])
        let client = try MongoWireClient(config: makeConfig(), transport: transport)
        try await client.connect()
        await #expect(throws: DataSourceError.self) {
            try await client.createCollection(database: "berrydb", collection: "docs")
        }
    }

    // MARK: - Write

    @Test func insertGeneratesObjectIDWhenMissing() async throws {
        let transport = MongoStubTransport(handlers: [
            helloHandler,
            { request in
                #expect(request["insert"] == .string("users"))
                guard case .array(let docs)? = request["documents"], docs.count == 1 else {
                    Issue.record("expected exactly one document")
                    return okReply([("n", .int(0))])
                }
                #expect(docs[0]["_id"] != nil)
                return okReply([("n", .int(1))])
            },
        ])
        let client = try MongoWireClient(config: makeConfig(), transport: transport)
        try await client.connect()
        let (count, insertedID) = try await client.insert(
            database: "berrydb", collection: "users", document: .object([("name", .string("Alice"))])
        )
        #expect(count == 1)
        guard case .objectID(let hex) = insertedID else {
            Issue.record("expected a generated ObjectId")
            return
        }
        #expect(hex.count == 24)
    }

    @Test func insertPreservesACallerSuppliedID() async throws {
        let transport = MongoStubTransport(handlers: [helloHandler, { _ in okReply([("n", .int(1))]) }])
        let client = try MongoWireClient(config: makeConfig(), transport: transport)
        try await client.connect()
        let (_, insertedID) = try await client.insert(
            database: "berrydb", collection: "users", document: .object([("_id", .int(7)), ("name", .string("Bob"))])
        )
        #expect(insertedID == .int(7))
    }

    @Test func updateSendsQAndUAndMultiFlag() async throws {
        let transport = MongoStubTransport(handlers: [
            helloHandler,
            { request in
                guard case .array(let updates)? = request["updates"], updates.count == 1 else {
                    Issue.record("expected exactly one update spec")
                    return okReply([("n", .int(0))])
                }
                #expect(updates[0]["q"] == .object([("_id", .int(1))]))
                #expect(updates[0]["multi"] == .bool(false))
                return okReply([("n", .int(1))])
            },
        ])
        let client = try MongoWireClient(config: makeConfig(), transport: transport)
        try await client.connect()
        let n = try await client.update(
            database: "berrydb", collection: "users", filter: .object([("_id", .int(1))]),
            update: .object([("$set", .object([("name", .string("X"))]))]), multi: false
        )
        #expect(n == 1)
    }

    @Test func deleteSendsQAndLimit() async throws {
        let transport = MongoStubTransport(handlers: [
            helloHandler,
            { request in
                guard case .array(let deletes)? = request["deletes"], deletes.count == 1 else {
                    Issue.record("expected exactly one delete spec")
                    return okReply([("n", .int(0))])
                }
                #expect(deletes[0]["limit"] == .int(0)) // multi: true -> limit 0 (unbounded)
                return okReply([("n", .int(3))])
            },
        ])
        let client = try MongoWireClient(config: makeConfig(), transport: transport)
        try await client.connect()
        let n = try await client.delete(database: "berrydb", collection: "users", filter: .object([]), multi: true)
        #expect(n == 3)
    }

    // MARK: - Replica-set v1: seeds -> primary discovery (docs/architecture/12 §3)
    //
    // Field names/values (isWritablePrimary/primary/setName) verified live
    // against `docker-mongo-1` (standalone) and a throwaway `mongod --replSet
    // ... --bind_ip_all` this session — see `MongoHelloResponseTests` for the
    // captured JSON. These tests exercise the seed-iteration/reconnect LOGIC
    // (which Docker can't: a single-node replica set is always its own
    // primary, so the real container never takes the reconnect branch — see
    // `Tests/docker/compose.yml`'s `mongo-rs` comment).

    private func makeSeedConfig(
        additionalHosts: [String] = [], replicaSet: String? = nil
    ) -> ConnectionConfig {
        ConnectionConfig(
            driver: .mongodb, name: "test", host: "seed0", port: 27017,
            additionalHosts: additionalHosts.isEmpty ? nil : additionalHosts,
            mongoReplicaSet: replicaSet
        )
    }

    private func primaryHello(setName: String? = nil, primary: String? = nil) -> MongoStubTransport.Handler {
        { _ in
            var extra: [(String, BerryDocument)] = [("isWritablePrimary", .bool(true))]
            if let setName { extra.append(("setName", .string(setName))) }
            if let primary { extra.append(("primary", .string(primary))) }
            return okReply(extra)
        }
    }

    private func secondaryHello(setName: String?, primary: String?) -> MongoStubTransport.Handler {
        { _ in
            var extra: [(String, BerryDocument)] = [("isWritablePrimary", .bool(false))]
            if let setName { extra.append(("setName", .string(setName))) }
            if let primary { extra.append(("primary", .string(primary))) }
            return okReply(extra)
        }
    }

    @Test func connectStaysOnSeedWhenItIsAlreadyThePrimary() async throws {
        let transport = MongoStubTransport(handlers: [primaryHello(setName: "berryrs", primary: "seed0:27017")])
        let client = try MongoWireClient(config: makeSeedConfig(), transport: transport)
        try await client.connect() // must not throw
        #expect(transport.sentCommands.count == 1) // just hello — no reconnect needed
    }

    /// A bare `{ok: 1}` hello (no `isWritablePrimary` at all — every
    /// pre-existing stub before this feature) must keep working exactly as
    /// before: treated as "usable", no reconnect attempted.
    @Test func connectTreatsAMissingIsWritablePrimaryFieldAsUsable() async throws {
        let transport = MongoStubTransport(handlers: [helloHandler])
        let client = try MongoWireClient(config: makeSeedConfig(), transport: transport)
        try await client.connect()
        #expect(transport.sentCommands.count == 1)
    }

    @Test func connectReconnectsToTheReportedPrimaryWhenTheSeedIsSecondary() async throws {
        let seedTransport = MongoStubTransport(handlers: [
            secondaryHello(setName: "berryrs", primary: "primary-host:27018"),
        ])
        let primaryTransport = MongoStubTransport(handlers: [
            primaryHello(setName: "berryrs", primary: "primary-host:27018"),
            { _ in okReply() }, // trailing ping below
        ])
        final class Requested: @unchecked Sendable {
            var host: String?
            var port: Int?
        }
        let requested = Requested()
        let client = try MongoWireClient(
            config: makeSeedConfig(additionalHosts: ["backup-seed:27017"], replicaSet: "berryrs"),
            transport: seedTransport,
            transportFactory: { host, port, _ in
                requested.host = host
                requested.port = port
                return primaryTransport
            }
        )
        try await client.connect() // must not throw
        #expect(requested.host == "primary-host")
        #expect(requested.port == 27018)
        #expect(seedTransport.sentCommands.count == 1) // hello only, then abandoned
        #expect(primaryTransport.sentCommands.count == 1) // hello — subsequent commands go here
        _ = try await client.runCommand(.object([("ping", .int(1))]), database: "admin")
        #expect(primaryTransport.sentCommands.count == 2) // confirms the client stayed on the primary transport
    }

    @Test func connectFallsBackToTheNextSeedWhenTheFirstIsUnreachable() async throws {
        let unreachableTransport = MongoStubTransport(handlers: [helloHandler])
        unreachableTransport.connectError = DataSourceError.connectionFailed("refused")
        let secondSeedTransport = MongoStubTransport(handlers: [primaryHello(setName: "berryrs")])
        let client = try MongoWireClient(
            config: makeSeedConfig(additionalHosts: ["seed1:27017"], replicaSet: "berryrs"),
            transport: unreachableTransport,
            transportFactory: { _, _, _ in secondSeedTransport }
        )
        try await client.connect() // must not throw — falls through to seed1
        #expect(secondSeedTransport.sentCommands.count == 1)
    }

    @Test func connectThrowsWhenNoSeedIsReachable() async throws {
        let transport = MongoStubTransport(handlers: [helloHandler])
        transport.connectError = DataSourceError.connectionFailed("refused")
        let client = try MongoWireClient(config: makeSeedConfig(), transport: transport)
        await #expect(throws: (any Error).self) {
            try await client.connect()
        }
    }

    @Test func connectThrowsWhenSeedIsNotPrimaryAndNamesNoOne() async throws {
        let transport = MongoStubTransport(handlers: [secondaryHello(setName: "berryrs", primary: nil)])
        let client = try MongoWireClient(config: makeSeedConfig(replicaSet: "berryrs"), transport: transport)
        await #expect(throws: (any Error).self) {
            try await client.connect()
        }
    }

    @Test func connectThrowsWhenTheReportedPrimaryDoesNotConfirmItself() async throws {
        let seedTransport = MongoStubTransport(handlers: [secondaryHello(setName: "berryrs", primary: "flaky:27017")])
        // "flaky" itself still says it's not primary (e.g. a stale report).
        let flakyTransport = MongoStubTransport(handlers: [secondaryHello(setName: "berryrs", primary: nil)])
        let client = try MongoWireClient(
            config: makeSeedConfig(replicaSet: "berryrs"), transport: seedTransport,
            transportFactory: { _, _, _ in flakyTransport }
        )
        await #expect(throws: (any Error).self) {
            try await client.connect()
        }
    }

    /// Task scope point 6: `replicaSet=` mismatch is a real configuration
    /// error, surfaced immediately — not silently ignored or retried against
    /// another seed.
    @Test func connectThrowsImmediatelyOnReplicaSetNameMismatch() async throws {
        let transport = MongoStubTransport(handlers: [primaryHello(setName: "some-other-rs", primary: "seed0:27017")])
        let client = try MongoWireClient(
            config: makeSeedConfig(replicaSet: "berryrs"), transport: transport
        )
        await #expect(throws: (any Error).self) {
            try await client.connect()
        }
    }

    @Test func connectThrowsWhenReplicaSetIsExpectedButNodeReportsNone() async throws {
        // Standalone `mongod` (no setName at all) but the profile set replicaSet=.
        let transport = MongoStubTransport(handlers: [helloHandler2WithPrimaryTrueNoSetName])
        let client = try MongoWireClient(
            config: makeSeedConfig(replicaSet: "berryrs"), transport: transport
        )
        await #expect(throws: (any Error).self) {
            try await client.connect()
        }
    }
}

/// A standalone-shaped `hello` reply: `isWritablePrimary: true`, no `setName`
/// — used to test the `replicaSet=` mismatch case against a node that isn't
/// part of any replica set at all.
private let helloHandler2WithPrimaryTrueNoSetName: MongoStubTransport.Handler = { _ in
    okReply([("isWritablePrimary", .bool(true))])
}
