import BerryDataSourceKit
import BerryDriverKit
import Foundation
import Testing

@testable import BerryDriverMongo

@Suite("MongoIntrospector — inferred schema")
struct MongoIntrospectorTests {
    private func makeIntrospector(handlers: [MongoStubTransport.Handler]) async throws -> MongoIntrospector {
        let transport = MongoStubTransport(handlers: [helloHandler] + handlers)
        let client = try MongoWireClient(
            config: ConnectionConfig(driver: .mongodb, name: "test", host: "stub-host", port: 27017, database: "berrydb"),
            transport: transport
        )
        try await client.connect()
        return MongoIntrospector(client: client, database: "berrydb")
    }

    @Test func collectionsDelegatesToListCollections() async throws {
        let introspector = try await makeIntrospector(handlers: [
            { _ in
                okReply([("cursor", .object([
                    ("firstBatch", .array([.object([("name", .string("users"))])])),
                    ("id", .int(0)),
                ]))])
            },
        ])
        let collections = try await introspector.collections()
        #expect(collections.map(\.name) == ["users"])
    }

    @Test func inferredSchemaUnionsFieldTypesAcrossSampleAndSortsMostRecentFirst() async throws {
        let introspector = try await makeIntrospector(handlers: [
            { request in
                #expect(request["find"] == .string("users"))
                #expect(request["sort"] == .object([("_id", .int(-1))]))
                return okReply([("cursor", .object([
                    ("firstBatch", .array([
                        .object([("name", .string("Alice")), ("age", .int(30))]),
                        .object([("name", .string("Bob")), ("age", .double(31.5))]),
                        .object([("name", .string("Carol")), ("tags", .array([.string("a")]))]),
                    ])),
                    ("id", .int(0)),
                ]))])
            },
        ])
        let schema = try await introspector.inferredSchema(of: CollectionRef(database: "berrydb", name: "users"), sampleSize: 10)
        #expect(schema["name"] == "string")
        #expect(schema["age"] == "double|int") // union across the sample, sorted
        #expect(schema["tags"] == "array")
    }

    @Test func inferredSchemaClampsSampleSizeToAtLeastOne() async throws {
        let introspector = try await makeIntrospector(handlers: [
            { request in
                #expect(request["limit"] == .int(1))
                return okReply([("cursor", .object([("firstBatch", .array([])), ("id", .int(0))]))])
            },
        ])
        let schema = try await introspector.inferredSchema(of: CollectionRef(database: "berrydb", name: "users"), sampleSize: 0)
        #expect(schema.isEmpty)
    }
}
