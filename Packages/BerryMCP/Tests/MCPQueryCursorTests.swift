import BerryDriverKit
import CryptoKit
import Foundation
import Testing

@testable import BerryMCP

@Suite("MCP query cursor")
struct MCPQueryCursorTests {
    private let lastKey: [String: DynamoDBAttributeValue] = [
        "pk": .string("user#1"),
        "sk": .number("42"),
        "blob": .binary(Data([1, 2, 3])),
    ]

    private func query(
        projection: [String]? = nil, limit: Int = 10,
        start: [String: DynamoDBAttributeValue]? = nil
    ) -> DynamoDBPartitionQuery {
        DynamoDBPartitionQuery(
            table: "Orders", indexName: nil, partitionKey: .string("user#1"),
            sortKey: .between(.number("1"), .number("9")), projection: projection,
            limit: limit, exclusiveStartKey: start)
    }

    private func scope(
        profile: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        table: String = "Orders", index: String? = nil, digest: Data = Data([9, 9])
    ) -> MCPQueryCursor.Scope {
        .init(profileID: profile, table: table, indexName: index, queryDigest: digest)
    }

    @Test func aCursorRoundTripsUnderTheSameScope() throws {
        let token = try MCPQueryCursor.seal(lastKey: lastKey, scope: scope())
        #expect(!token.isEmpty)
        #expect(!token.contains("=") && !token.contains("+") && !token.contains("/"))
        #expect(try MCPQueryCursor.open(token, scope: scope()) == lastKey)
    }

    @Test func aCursorFromAnotherProcessIsRefused() throws {
        let token = try MCPQueryCursor.seal(lastKey: lastKey, scope: scope(), key: SymmetricKey(size: .bits256))
        #expect(throws: MCPQueryCursorError.invalid) {
            try MCPQueryCursor.open(token, scope: scope(), key: SymmetricKey(size: .bits256))
        }
    }

    @Test func aTamperedCursorIsRefused() throws {
        let token = try MCPQueryCursor.seal(lastKey: lastKey, scope: scope())
        var base64 = token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        var bytes = try #require(Data(base64Encoded: base64))
        try #require(bytes.count > 28)
        // Past the 12-byte nonce and before the 16-byte tag: inside the ciphertext.
        let middle = 12 + (bytes.count - 28) / 2
        bytes[middle] ^= 0x01
        let tampered = bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        #expect(throws: MCPQueryCursorError.invalid) {
            try MCPQueryCursor.open(tampered, scope: scope())
        }
        #expect(throws: MCPQueryCursorError.invalid) {
            try MCPQueryCursor.open("not base64 !!", scope: scope())
        }
    }

    @Test func aCursorFromAnotherQueryIsRefused() throws {
        let token = try MCPQueryCursor.seal(lastKey: lastKey, scope: scope())
        let others = [
            scope(table: "Other"),
            scope(index: "byDate"),
            scope(profile: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!),
            scope(digest: Data([1])),
        ]
        for other in others {
            #expect(throws: MCPQueryCursorError.otherQuery) {
                try MCPQueryCursor.open(token, scope: other)
            }
        }
    }

    @Test func theDigestIgnoresLimitAndStartKey() throws {
        let base = MCPQueryCursor.digest(of: query())
        #expect(!base.isEmpty)
        #expect(base == MCPQueryCursor.digest(of: query(limit: 500, start: lastKey)))
        #expect(base != MCPQueryCursor.digest(of: query(projection: ["pk"])))
    }
}
