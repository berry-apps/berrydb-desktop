import BerryDriverKit
import Foundation
import Testing

@testable import BerryDriverDynamoDB

@Suite("DynamoDBIntrospector — ListTables/DescribeTable mapping")
struct DynamoDBIntrospectorTests {
    private func makeIntrospector(
        host: String, handler: @escaping DynamoDBStubURLProtocol.Handler
    ) throws -> DynamoDBIntrospector {
        let session = DynamoDBStubURLProtocol.session(host: host, handler: handler)
        let config = ConnectionConfig(
            driver: .dynamodb, name: "test", host: host, port: 8000, tlsMode: .disable,
            awsAccessKeyID: "fake", awsSecretAccessKey: "fake", awsRegion: "us-east-1"
        )
        let client = try DynamoDBHTTPClient(config: config, session: session)
        return DynamoDBIntrospector(client: client)
    }

    @Test func databasesReturnsOneSyntheticEntry() async throws {
        let host = "dynamo-\(UUID().uuidString)".lowercased()
        let introspector = try makeIntrospector(host: host) { request, _ in
            (dynamoStubResponse(request.url!, status: 200), dynamoStubJSON([:]))
        }
        let databases = try await introspector.databases()
        #expect(databases.count == 1)
    }

    @Test func objectsMapsListTablesToTableKindSchemaObjects() async throws {
        let host = "dynamo-\(UUID().uuidString)".lowercased()
        let introspector = try makeIntrospector(host: host) { request, _ in
            (dynamoStubResponse(request.url!, status: 200), dynamoStubJSON(["TableNames": ["Music", "Users"]]))
        }
        let objects = try await introspector.objects(in: nil)
        #expect(objects == [
            SchemaObject(kind: .table, name: "Music", database: nil),
            SchemaObject(kind: .table, name: "Users", database: nil),
        ])
    }

    /// Both partition AND sort key must come back `isPrimaryKey: true` —
    /// this is what makes ChangeSet's generated UPDATE/DELETE WHERE clause
    /// (which ANDs every `isPrimaryKey` column) satisfy DynamoDB's "WHERE
    /// must equate the full primary key" requirement, verified against
    /// dynamodb-local (docs/architecture/12 §4).
    @Test func tableDetailMarksBothPartitionAndSortKeyAsPrimaryKey() async throws {
        let host = "dynamo-\(UUID().uuidString)".lowercased()
        let introspector = try makeIntrospector(host: host) { request, _ in
            let table: [String: Any] = [
                "TableName": "Music",
                "KeySchema": [
                    ["AttributeName": "Artist", "KeyType": "HASH"],
                    ["AttributeName": "SongTitle", "KeyType": "RANGE"],
                ],
                "AttributeDefinitions": [
                    ["AttributeName": "Artist", "AttributeType": "S"],
                    ["AttributeName": "SongTitle", "AttributeType": "S"],
                ],
            ]
            return (dynamoStubResponse(request.url!, status: 200), dynamoStubJSON(["Table": table]))
        }
        let detail = try await introspector.tableDetail(TableRef(name: "Music"))
        #expect(detail.columns.count == 2)
        #expect(detail.columns.allSatisfy { $0.isPrimaryKey })
        #expect(detail.columns.map(\.name) == ["Artist", "SongTitle"])
        #expect(detail.columns.map(\.declaredType) == ["String (S)", "String (S)"])
    }

    @Test func tableDetailMapsGSIsAndLSIsToIndexInfo() async throws {
        let host = "dynamo-\(UUID().uuidString)".lowercased()
        let introspector = try makeIntrospector(host: host) { request, _ in
            let table: [String: Any] = [
                "TableName": "Music",
                "KeySchema": [["AttributeName": "Artist", "KeyType": "HASH"]],
                "AttributeDefinitions": [["AttributeName": "Artist", "AttributeType": "S"]],
                "GlobalSecondaryIndexes": [
                    ["IndexName": "ByGenre", "KeySchema": [["AttributeName": "Genre", "KeyType": "HASH"]]],
                ],
            ]
            return (dynamoStubResponse(request.url!, status: 200), dynamoStubJSON(["Table": table]))
        }
        let detail = try await introspector.tableDetail(TableRef(name: "Music"))
        #expect(detail.indexes == [IndexInfo(name: "ByGenre", isUnique: false, columns: ["Genre"])])
    }

    // ItemCount/TableSizeBytes come back as JSON numbers in the real
    // DescribeTable response — verifying the NSNumber bridge reads them
    // correctly (TR-04), not just that the keys are looked up.
    @Test func tableStatsReadsItemCountAndSizeFromDescribeTable() async throws {
        let host = "dynamo-\(UUID().uuidString)".lowercased()
        let introspector = try makeIntrospector(host: host) { request, _ in
            let table: [String: Any] = [
                "TableName": "Music",
                "ItemCount": 42,
                "TableSizeBytes": 123456,
            ]
            return (dynamoStubResponse(request.url!, status: 200), dynamoStubJSON(["Table": table]))
        }
        let stats = try await introspector.tableStats(TableRef(name: "Music"))
        #expect(stats.estimatedRowCount == 42)
        #expect(stats.sizeBytes == 123456)
        #expect(stats.engine == nil)
        #expect(stats.comment == nil)
    }

    @Test func tableStatsIsNilWhenFieldsAreAbsent() async throws {
        let host = "dynamo-\(UUID().uuidString)".lowercased()
        let introspector = try makeIntrospector(host: host) { request, _ in
            (dynamoStubResponse(request.url!, status: 200), dynamoStubJSON(["Table": ["TableName": "Music"]]))
        }
        let stats = try await introspector.tableStats(TableRef(name: "Music"))
        #expect(stats.estimatedRowCount == nil)
        #expect(stats.sizeBytes == nil)
    }

    @Test func ddlSynthesizesPseudoCreateTableFromKeySchema() async throws {
        let host = "dynamo-\(UUID().uuidString)".lowercased()
        let introspector = try makeIntrospector(host: host) { request, _ in
            let table: [String: Any] = [
                "TableName": "Music",
                "KeySchema": [
                    ["AttributeName": "Artist", "KeyType": "HASH"],
                    ["AttributeName": "SongTitle", "KeyType": "RANGE"],
                ],
                "AttributeDefinitions": [
                    ["AttributeName": "Artist", "AttributeType": "S"],
                    ["AttributeName": "SongTitle", "AttributeType": "S"],
                ],
            ]
            return (dynamoStubResponse(request.url!, status: 200), dynamoStubJSON(["Table": table]))
        }
        let ddl = try await introspector.ddl(of: SchemaObject(kind: .table, name: "Music"))
        #expect(ddl.contains("PARTITION KEY"))
        #expect(ddl.contains("SORT KEY"))
        #expect(ddl.contains(#""Artist""#))
        #expect(ddl.contains(#""SongTitle""#))
        // Clearly marked as synthesized, not authoritative (TR-03, 05 §5).
        #expect(ddl.contains("NOT authoritative"))
    }
}
