import BerryDataSourceKit
import BerryDriverKit
import Foundation

/// Drives one MongoDB wire-protocol connection: handshake (`hello`), optional
/// SCRAM-SHA-256 auth, and command round trips over OP_MSG — plus the
/// command-builder helpers (find/aggregate/getMore/insert/update/delete/
/// listCollections) that turn driver-level requests into wire commands.
/// Everything above this (query routing, write model, introspection) talks
/// to this actor, not the transport directly — same layering as
/// `QdrantHTTPClient` sitting under `QdrantConnection`
/// just over a socket instead of REST. An actor (not a plain struct
/// like `QdrantHTTPClient`) because a raw TCP connection can only run one
/// request/response round trip at a time — concurrent `runCommand` calls
/// would interleave bytes and corrupt framing.
actor MongoWireClient {
    private var transport: MongoTransport
    /// Seed members to try, in order — `config.host`/`.port` first, then
 /// `config.additionalHosts` (replica-set v1).
    private let seeds: [(host: String, port: Int)]
    private let useTLS: Bool
    /// `replicaSet=<name>`, verified against each candidate's `hello`
    /// `setName` — `nil` skips the check.
    private let replicaSetName: String?
    /// Test-only hook for connecting to a *second* host during primary
    /// discovery (e.g. "seed reports it isn't primary, reconnect to the host
    /// it names") without a real socket — mirrors the `transport:` param's
    /// existing role for the first seed. `nil` in production, where
    /// `MongoSocketTransport` is created directly.
    private let transportFactory: (@Sendable (String, Int, Bool) -> MongoTransport)?
    /// Auth source database — Mongo convention: defaults to `config.database`
    /// when given, else `"admin"` (deliberately different default from the
    /// *working* database used for find/collections, which defaults to
    /// `"test"` — see `MongoConnection.database`).
    private let authDatabase: String
    private let username: String?
    private let password: String?
    private var requestIDCounter: Int32 = 0
    private var isConnected = false
    private var objectIDCounter = UInt32.random(in: 0...0xFFFFFF)

    init(
        config: ConnectionConfig, transport: MongoTransport? = nil,
        transportFactory: (@Sendable (String, Int, Bool) -> MongoTransport)? = nil
    ) throws {
        guard let host = config.host, !host.isEmpty else {
            throw DataSourceError.connectionFailed("Missing host")
        }
        let port = config.port ?? 27017
        var seedList: [(host: String, port: Int)] = [(host, port)]
        for entry in config.additionalHosts ?? [] {
            let (extraHost, extraPort) = Self.splitHostPort(entry)
            guard !extraHost.isEmpty else { continue }
            seedList.append((extraHost, extraPort ?? 27017))
        }
        let resolvedUseTLS = config.tlsMode != .disable
        self.transport = transport ?? MongoSocketTransport(host: host, port: port, useTLS: resolvedUseTLS)
        self.seeds = seedList
        self.useTLS = resolvedUseTLS
        self.replicaSetName = config.mongoReplicaSet
        self.transportFactory = transportFactory
        self.authDatabase = (config.database?.isEmpty == false) ? config.database! : "admin"
        self.username = config.username
        self.password = config.password
    }

    func connect() async throws {
        try await connectToPrimary()
        isConnected = true
        if let username, !username.isEmpty {
            try await authenticateSCRAM(username: username, password: password ?? "")
        }
    }

 // MARK: - Seeds -> primary (replica-set v1)

    /// Tries each seed in order for a TCP-reachable host, reads its `hello`
    /// response, and — if that node reports it isn't the primary — reconnects
    /// once to whatever host:port its `primary` field names. `hello` also
    /// confirms the server speaks OP_MSG correctly; beyond `isWritablePrimary`
    /// /`primary`/`setName` this driver still does not gate on
    /// `maxWireVersion` or any other capability field (documented scope
 /// narrowing).
    ///
    /// v1 boundary, deliberate: no background topology monitoring/heartbeats,
    /// no automatic reconnect if the primary steps down mid-session (a
    /// dropped primary hits the existing connection-lost handling, same as
    /// any other driver) — a session-level reconnect is a separate, larger
    /// feature. All reads AND writes go to whatever node this function lands
    /// on; there is no secondary read routing.
    private func connectToPrimary() async throws {
        var lastError: Error?
        for (index, seed) in seeds.enumerated() {
            let candidate = index == 0 ? transport : makeTransport(host: seed.host, port: seed.port)
            do {
                try await candidate.connect()
            } catch {
                lastError = error
                continue
            }
            transport = candidate

            let info: MongoHelloResponse
            do {
                info = MongoHelloResponse(try await runCommand(.object([("hello", .int(1))]), database: "admin"))
            } catch {
                await transport.close()
                lastError = error
                continue
            }
            // A replica-set-name mismatch is a real misconfiguration (wrong
            // deployment/cluster) — surface it immediately rather than
            // quietly trying the next seed, which would just report the
            // less-useful "could not find a primary" (task scope point 6).
            try checkReplicaSetName(info, reportedBy: "\(seed.host):\(seed.port)")

            if info.isWritablePrimary != false {
                return // primary, a standalone server, or one that didn't opine — proceed as before
            }
            guard let primaryAddress = info.primary else {
                await transport.close()
                lastError = DataSourceError.connectionFailed(
                    "\(seed.host):\(seed.port) reported it is not the primary, and named no primary to retry"
                )
                continue
            }
            await transport.close()

            let (primaryHost, primaryPort) = Self.splitHostPort(primaryAddress)
            guard !primaryHost.isEmpty else {
                lastError = DataSourceError.connectionFailed("Malformed primary address \"\(primaryAddress)\" reported by \(seed.host):\(seed.port)")
                continue
            }
            let primaryTransport = makeTransport(host: primaryHost, port: primaryPort ?? 27017)
            do {
                try await primaryTransport.connect()
            } catch {
                lastError = error
                continue
            }
            transport = primaryTransport

            let primaryInfo: MongoHelloResponse
            do {
                primaryInfo = MongoHelloResponse(try await runCommand(.object([("hello", .int(1))]), database: "admin"))
            } catch {
                await transport.close()
                lastError = error
                continue
            }
            try checkReplicaSetName(primaryInfo, reportedBy: primaryAddress)
            guard primaryInfo.isWritablePrimary == true else {
                await transport.close()
                lastError = DataSourceError.connectionFailed(
                    "\(primaryAddress) (reported as primary by \(seed.host):\(seed.port)) did not confirm isWritablePrimary"
                )
                continue
            }
            return
        }
        throw DataSourceError.connectionFailed(
            "Could not find a primary among seed hosts (\(seeds.map { "\($0.host):\($0.port)" }.joined(separator: ", "))): "
                + (lastError?.localizedDescription ?? "unknown error")
        )
    }

    private func makeTransport(host: String, port: Int) -> MongoTransport {
        if let transportFactory { return transportFactory(host, port, useTLS) }
        return MongoSocketTransport(host: host, port: port, useTLS: useTLS)
    }

    private func checkReplicaSetName(_ info: MongoHelloResponse, reportedBy source: String) throws {
        guard let expected = replicaSetName else { return }
        guard let actual = info.setName else {
            throw DataSourceError.connectionFailed(
                "Replica set name mismatch: expected \"\(expected)\", but \(source) is not part of any replica set"
            )
        }
        guard actual == expected else {
            throw DataSourceError.connectionFailed(
                "Replica set name mismatch: expected \"\(expected)\", but \(source) reported setName \"\(actual)\""
            )
        }
    }

    /// Same "split on the last colon when the suffix is purely numeric" rule
    /// as `MongoConnectionURI.splitHostPort`/`ConnectionSheet.splitHostPort` —
    /// duplicated rather than shared so `BerryDriverMongo` doesn't gain a
    /// dependency on `BerryUI` just for this helper.
    private static func splitHostPort(_ raw: String) -> (host: String, port: Int?) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let colonIndex = trimmed.lastIndex(of: ":") else { return (trimmed, nil) }
        let hostPart = String(trimmed[trimmed.startIndex..<colonIndex])
        let portPart = String(trimmed[trimmed.index(after: colonIndex)...])
        guard !hostPart.isEmpty, let port = Int(portPart) else { return (trimmed, nil) }
        return (hostPart, port)
    }

    func close() async {
        isConnected = false
        await transport.close()
    }

    func ping() async -> Bool {
        guard isConnected else { return false }
        return (try? await runCommand(.object([("ping", .int(1))]), database: "admin")) != nil
    }

 // MARK: - SCRAM-SHA-256 auth

    private func authenticateSCRAM(username: String, password: String) async throws {
        let nonce = SCRAM.generateNonce()
        let clientFirst = SCRAM.clientFirst(username: username, nonce: nonce)

        let startReply = try await runCommand(.object([
            ("saslStart", .int(1)),
            ("mechanism", .string("SCRAM-SHA-256")),
            ("payload", .binary(Data(clientFirst.message.utf8))),
        ]), database: authDatabase)

        guard case .int(let conversationId)? = startReply["conversationId"],
              case .binary(let payload1)? = startReply["payload"] else {
            throw DataSourceError.connectionFailed("Malformed saslStart reply")
        }
        let serverFirst = try SCRAM.parseServerFirst(String(decoding: payload1, as: UTF8.self))
        let clientFinal = try SCRAM.clientFinal(password: password, clientFirst: clientFirst, serverFirst: serverFirst)

        var continueReply = try await runCommand(.object([
            ("saslContinue", .int(1)),
            ("conversationId", .int(conversationId)),
            ("payload", .binary(Data(clientFinal.message.utf8))),
        ]), database: authDatabase)

        guard case .binary(let payload2)? = continueReply["payload"] else {
            throw DataSourceError.connectionFailed("Malformed saslContinue reply")
        }
        try SCRAM.verifyServerFinal(String(decoding: payload2, as: UTF8.self), expected: clientFinal.serverSignatureExpected)

        // MongoDB's SCRAM conversation needs one more empty saslContinue to
        // reach `done: true` when the server didn't set it on the message
        // carrying `v=` — the standard SASL "client acknowledges success"
        // step. Bounded to 2 extra round trips so a server that never sets
        // `done` can't spin this forever.
        var guardCount = 0
        while case .bool(false)? = continueReply["done"], guardCount < 2 {
            continueReply = try await runCommand(.object([
                ("saslContinue", .int(1)),
                ("conversationId", .int(conversationId)),
                ("payload", .binary(Data())),
            ]), database: authDatabase)
            guardCount += 1
        }
        guard case .bool(true)? = continueReply["done"] else {
            throw DataSourceError.connectionFailed("SCRAM conversation did not reach done:true")
        }
    }

    // MARK: - Command round trip

    func runCommand(_ body: BerryDocument, database: String) async throws -> BerryDocument {
        guard case .object(let fields) = body else {
            throw DataSourceError.queryFailed("Command body must be a document")
        }
        requestIDCounter += 1
        let requestID = requestIDCounter
        let requestData = MongoOpMsg.encodeRequest(requestID: requestID, body: .object(fields + [("$db", .string(database))]))

        do {
            try await transport.send(requestData)
            let headerBytes = [UInt8](try await transport.receive(exactly: 16))
            let header = try MongoOpMsg.decodeHeader(headerBytes)
            guard header.messageLength >= 16 else {
                throw DataSourceError.connectionLost("Malformed message length")
            }
            let rest = try await transport.receive(exactly: Int(header.messageLength) - 16)
            let reply = try MongoOpMsg.decodeReply(headerBytes + [UInt8](rest))
            try Self.checkOK(reply)
            return reply
        } catch let error as DataSourceError {
            throw error
        } catch is CancellationError {
            throw DataSourceError.cancelled
        } catch {
            throw DataSourceError.connectionLost(error.localizedDescription)
        }
    }

    private static func checkOK(_ reply: BerryDocument) throws {
        let ok: Double?
        switch reply["ok"] {
        case .double(let d)?: ok = d
        case .int(let i)?: ok = Double(i)
        default: ok = nil
        }
        guard ok == 1.0 else {
            var message = "Command failed"
            if case .string(let s)? = reply["errmsg"] { message = s }
            throw DataSourceError.queryFailed(message)
        }
    }

    // MARK: - Collections

    func listCollections(database: String) async throws -> [CollectionRef] {
        let reply = try await runCommand(.object([("listCollections", .int(1))]), database: database)
        guard case .object(let cursorFields)? = reply["cursor"],
              case .array(let batch)? = BerryDocument.object(cursorFields)["firstBatch"] else { return [] }
        return batch.compactMap { doc in
            guard case .string(let name)? = doc["name"] else { return nil }
            return CollectionRef(database: database, name: name)
        }
    }

 // MARK: - Explicit collection creation

    /// The `create` admin command — explicit collection creation, matching
    /// what a real Mongo admin UI would do rather than relying on Mongo's
    /// implicit creation-via-insert. `options` from the protocol layer is
    /// ignored for v1 (see `DataSourceConnection.createCollection`).
    func createCollection(database: String, collection: String) async throws {
        _ = try await runCommand(.object([("create", .string(collection))]), database: database)
    }

    // MARK: - find / aggregate (cursor iteration, N3 batching)

    struct CursorPage: Sendable {
        let documents: [BerryDocument]
        let cursorID: Int64
    }

    func find(
        database: String, collection: String, filter: BerryDocument, projection: BerryDocument?,
        sort: BerryDocument? = nil, limit: Int?, batchSize: Int
    ) async throws -> CursorPage {
        var fields: [(String, BerryDocument)] = [
            ("find", .string(collection)),
            ("filter", filter),
            ("batchSize", .int(Int64(batchSize))),
        ]
        if let projection { fields.append(("projection", projection)) }
        if let sort { fields.append(("sort", sort)) }
        if let limit { fields.append(("limit", .int(Int64(limit)))) }
        let reply = try await runCommand(.object(fields), database: database)
        return try Self.cursorPage(from: reply)
    }

    func aggregate(database: String, collection: String, pipeline: [BerryDocument], batchSize: Int) async throws -> CursorPage {
        let fields: [(String, BerryDocument)] = [
            ("aggregate", .string(collection)),
            ("pipeline", .array(pipeline)),
            ("cursor", .object([("batchSize", .int(Int64(batchSize)))])),
        ]
        let reply = try await runCommand(.object(fields), database: database)
        return try Self.cursorPage(from: reply)
    }

    func listIndexes(database: String, collection: String, batchSize: Int) async throws -> CursorPage {
        let fields: [(String, BerryDocument)] = [
            ("listIndexes", .string(collection)),
            ("cursor", .object([("batchSize", .int(Int64(batchSize)))])),
        ]
        let reply = try await runCommand(.object(fields), database: database)
        return try Self.cursorPage(from: reply)
    }

    func getMore(database: String, collection: String, cursorID: Int64, batchSize: Int) async throws -> CursorPage {
        let fields: [(String, BerryDocument)] = [
            ("getMore", .int(cursorID)),
            ("collection", .string(collection)),
            ("batchSize", .int(Int64(batchSize))),
        ]
        let reply = try await runCommand(.object(fields), database: database)
        return try Self.cursorPage(from: reply)
    }

    private static func cursorPage(from reply: BerryDocument) throws -> CursorPage {
        guard case .object(let cursorFields)? = reply["cursor"] else {
            throw DataSourceError.queryFailed("Reply had no cursor field")
        }
        let cursor = BerryDocument.object(cursorFields)
        let batchDocs: [BerryDocument]
        if case .array(let batch)? = cursor["firstBatch"] {
            batchDocs = batch
        } else if case .array(let batch)? = cursor["nextBatch"] {
            batchDocs = batch
        } else {
            batchDocs = []
        }
        var cursorID: Int64 = 0
        if case .int(let id)? = cursor["id"] { cursorID = id }
        return CursorPage(documents: batchDocs, cursorID: cursorID)
    }

 // MARK: - Write

    /// `document` is the Mongo document itself (unlike Qdrant's
    /// id/vector/payload wrapper — Mongo has no such split). A missing `_id`
    /// gets a client-generated ObjectId so the caller always learns the
    /// inserted id back, matching `DataSourceWriteResult.insertedID`'s
    /// contract.
    func insert(database: String, collection: String, document: BerryDocument) async throws -> (insertedCount: Int, insertedID: BerryDocument) {
        var docFields: [(String, BerryDocument)] = []
        if case .object(let f) = document { docFields = f }
        let insertedID: BerryDocument
        if let existing = document["_id"] {
            insertedID = existing
        } else {
            let generated = BerryDocument.objectID(generateObjectIDHex())
            docFields.append(("_id", generated))
            insertedID = generated
        }
        let reply = try await runCommand(.object([
            ("insert", .string(collection)),
            ("documents", .array([.object(docFields)])),
        ]), database: database)
        var n = 0
        if case .int(let count)? = reply["n"] { n = Int(count) }
        return (n, insertedID)
    }

    func update(database: String, collection: String, filter: BerryDocument, update: BerryDocument, multi: Bool) async throws -> Int {
        let reply = try await runCommand(.object([
            ("update", .string(collection)),
            ("updates", .array([.object([("q", filter), ("u", update), ("multi", .bool(multi))])])),
        ]), database: database)
        if case .int(let n)? = reply["n"] { return Int(n) }
        return 0
    }

    func delete(database: String, collection: String, filter: BerryDocument, multi: Bool) async throws -> Int {
        let reply = try await runCommand(.object([
            ("delete", .string(collection)),
            ("deletes", .array([.object([("q", filter), ("limit", .int(multi ? 0 : 1))])])),
        ]), database: database)
        if case .int(let n)? = reply["n"] { return Int(n) }
        return 0
    }

    func drop(database: String, collection: String) async throws {
        _ = try await runCommand(.object([("drop", .string(collection))]), database: database)
    }

    /// MongoDB's wire protocol requires each index spec to carry an explicit
    /// `name` — real drivers derive one from the keys when the caller
    /// doesn't supply one (e.g. `{email: 1, age: -1}` → `"email_1_age_-1"`);
    /// `options` may override it with its own `"name"` field.
    func createIndex(database: String, collection: String, keys: BerryDocument, options: BerryDocument?) async throws {
        var indexSpec: [(String, BerryDocument)] = [("key", keys)]
        var explicitName: String?
        if case .object(let optFields)? = options, case .string(let n)? = BerryDocument.object(optFields)["name"] {
            explicitName = n
        }
        indexSpec.append(("name", .string(explicitName ?? Self.defaultIndexName(for: keys))))
        if case .object(let optFields)? = options {
            indexSpec.append(contentsOf: optFields.filter { $0.0 != "name" })
        }
        _ = try await runCommand(.object([
            ("createIndexes", .string(collection)),
            ("indexes", .array([.object(indexSpec)])),
        ]), database: database)
    }

    func dropIndex(database: String, collection: String, indexName: String) async throws {
        _ = try await runCommand(.object([
            ("dropIndexes", .string(collection)),
            ("index", .string(indexName)),
        ]), database: database)
    }

    /// `renameCollection` is an admin-level command — it must run against
    /// the `admin` database (not `database`) using fully-qualified names,
    /// per MongoDB's wire protocol, regardless of which database the
    /// collection actually lives in. `dropTarget: false` always, so a name
    /// collision fails loudly instead of silently destroying a pre-existing
    /// target (this is what keeps the operation classifiable as `.safe` at
    /// the danger-guard layer).
    func renameCollection(database: String, collection: String, newName: String) async throws {
        _ = try await runCommand(.object([
            ("renameCollection", .string("\(database).\(collection)")),
            ("to", .string("\(database).\(newName)")),
            ("dropTarget", .bool(false)),
        ]), database: "admin")
    }

 // MARK: - User management (Phase C)

    /// `usersInfo: 1` lists every user scoped to `database` — real MongoDB
    /// admin command, roles come back as `{role, db}` pairs; role names only
    /// are kept (v1: every role is scoped to the connection's own working
 /// database).
    func usersInfo(database: String) async throws -> [DataSourceUserInfo] {
        let reply = try await runCommand(.object([("usersInfo", .int(1))]), database: database)
        guard case .array(let users)? = reply["users"] else { return [] }
        return users.compactMap { doc -> DataSourceUserInfo? in
            guard case .string(let username)? = doc["user"] else { return nil }
            var roles: [String] = []
            if case .array(let roleDocs)? = doc["roles"] {
                roles = roleDocs.compactMap { roleDoc -> String? in
                    guard case .string(let role)? = roleDoc["role"] else { return nil }
                    return role
                }
            }
            return DataSourceUserInfo(username: username, roles: roles)
        }
    }

    /// `roles` are plain role-name strings — MongoDB defaults each role's
    /// `db` to the command's own database when given this shape, so no
    /// `{role, db}` document wrapping is needed for the v1 single-database
    /// scope.
    func createUser(database: String, username: String, password: String, roles: [String]) async throws {
        _ = try await runCommand(.object([
            ("createUser", .string(username)),
            ("pwd", .string(password)),
            ("roles", .array(roles.map { .string($0) })),
        ]), database: database)
    }

    func dropUser(database: String, username: String) async throws {
        _ = try await runCommand(.object([("dropUser", .string(username))]), database: database)
    }

    private static func defaultIndexName(for keys: BerryDocument) -> String {
        guard case .object(let fields) = keys else { return "index" }
        return fields.map { key, value in
            let direction: String
            switch value {
            case .int(let n): direction = String(n)
            case .double(let d): direction = String(d)
            case .string(let s): direction = s
            default: direction = "1"
            }
            return "\(key)_\(direction)"
        }.joined(separator: "_")
    }

    // MARK: - ObjectId generation (insert without a caller-supplied `_id`)

    /// A best-effort 12-byte ObjectId (4-byte unix-seconds timestamp + 5
    /// random bytes + 3-byte rolling counter) — not the exact MongoDB
    /// driver-spec algorithm (which also mixes in a process identifier), but
    /// globally-unique enough for a client-generated `_id`; same pragmatic
 /// bar as Qdrant's UUID-when-missing.
    /// `objectIDCounter` is actor-isolated state, so no separate lock is
    /// needed for the rolling counter.
    private func generateObjectIDHex() -> String {
        var bytes = [UInt8]()
        bytes.reserveCapacity(12)
        let seconds = UInt32(Date().timeIntervalSince1970)
        bytes.append(contentsOf: withUnsafeBytes(of: seconds.bigEndian) { Array($0) })
        for _ in 0..<5 { bytes.append(UInt8.random(in: 0...255)) }
        objectIDCounter = (objectIDCounter + 1) & 0xFFFFFF
        bytes.append(UInt8((objectIDCounter >> 16) & 0xFF))
        bytes.append(UInt8((objectIDCounter >> 8) & 0xFF))
        bytes.append(UInt8(objectIDCounter & 0xFF))
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
