import BerryDataSourceKit
import Foundation
import Testing

@testable import BerryDriverMongo

/// `MongoHelloResponse` field extraction — replica-set primary discovery v1
/// (docs/architecture/12 §3). Fixtures below are real `hello` JSON captured
/// from a live `mongod` this session (both a standalone and a single-node
/// replica set, via `docker exec ... mongosh --eval "EJSON.stringify(db.hello())"`),
/// not assumed from memory — trimmed to the fields relevant here, with the
/// rest of the real payload's shape preserved so this exercises the same
/// `JSONSerialization` → `BerryDocument(jsonObject:)` decoding path the
/// pipeline-mode query UI already relies on (docs/architecture/12 §7).
@Suite("MongoHelloResponse — hello field extraction")
struct MongoHelloResponseTests {
    private func decode(_ json: String) -> BerryDocument {
        let object = try! JSONSerialization.jsonObject(with: Data(json.utf8))
        return BerryDocument(jsonObject: object)
    }

    /// Captured from `docker-mongo-1` (the standalone `mongo:7` test
    /// service) — a standalone reports `isWritablePrimary: true` and has
    /// neither `primary` nor `setName`.
    @Test func standaloneServerIsWritablePrimaryTrueNoReplicaSetFields() {
        let json = """
        {"isWritablePrimary":true,"maxBsonObjectSize":16777216,"maxWireVersion":21,"readOnly":false,"ok":1}
        """
        let info = MongoHelloResponse(decode(json))
        #expect(info.isWritablePrimary == true)
        #expect(info.primary == nil)
        #expect(info.setName == nil)
    }

    /// Captured from a throwaway `mongod --replSet berryrs --bind_ip_all`
    /// before `rs.initiate()` ran — `isWritablePrimary: false`, no `primary`/
    /// `setName` yet (the node has no replica-set config at all).
    @Test func uninitiatedReplicaSetMemberIsNotWritablePrimaryAndHasNoSetName() {
        let json = """
        {"topologyVersion":{"counter":0},"isWritablePrimary":false,"secondary":false,"info":"Does not have a valid replica set config","isreplicaset":true,"maxWireVersion":21,"ok":1}
        """
        let info = MongoHelloResponse(decode(json))
        #expect(info.isWritablePrimary == false)
        #expect(info.primary == nil)
        #expect(info.setName == nil)
    }

    /// Captured from the same node immediately after `rs.initiate()` — now
    /// the (single-member) primary: `setName`/`primary` present, `primary`
    /// is a "host:port" string (the container's own Docker hostname, here
    /// "11f6c51a7abc:27017" — kept verbatim as evidence of the real shape).
    @Test func electedPrimaryReportsSetNameAndItsOwnAddressAsPrimary() {
        let json = """
        {"hosts":["11f6c51a7abc:27017"],"setName":"berryrs","setVersion":1,"isWritablePrimary":true,"secondary":false,"primary":"11f6c51a7abc:27017","me":"11f6c51a7abc:27017","maxWireVersion":21,"ok":1}
        """
        let info = MongoHelloResponse(decode(json))
        #expect(info.isWritablePrimary == true)
        #expect(info.primary == "11f6c51a7abc:27017")
        #expect(info.setName == "berryrs")
    }

    /// A secondary member's `hello` (documented MongoDB shape — this exact
    /// combination wasn't independently captured live this session, since
    /// the Docker conformance target is a single-node replica set that is
    /// always its own primary; the individual fields/types above were each
    /// verified live). This is what drives the "reconnect to the named
    /// primary" branch in `MongoWireClientTests`.
    @Test func secondaryReportsIsWritablePrimaryFalseAndNamesTheRealPrimary() {
        let json = """
        {"setName":"berryrs","setVersion":1,"isWritablePrimary":false,"secondary":true,"primary":"mongo-rs0.internal:27017","me":"mongo-rs1.internal:27017","maxWireVersion":21,"ok":1}
        """
        let info = MongoHelloResponse(decode(json))
        #expect(info.isWritablePrimary == false)
        #expect(info.primary == "mongo-rs0.internal:27017")
        #expect(info.setName == "berryrs")
    }

    /// A bare `{ok: 1}` reply (what every pre-existing stub in
    /// `MongoWireClientTests` sends) — every field absent, not an error.
    @Test func fieldsAreNilWhenAbsentEntirely() {
        let info = MongoHelloResponse(.object([("ok", .double(1))]))
        #expect(info.isWritablePrimary == nil)
        #expect(info.primary == nil)
        #expect(info.setName == nil)
    }
}
