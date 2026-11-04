import BerryDriverTestKit
import Foundation

@testable import BerryDriverDynamoDB

/// Raw-API fixture helpers shared by the live suites.
struct DynamoDBLiveFixtures {
    let server: DynamoDBTestServer

    /// A string-keyed global secondary index projecting every attribute.
    struct GlobalSecondaryIndex {
        let name: String
        let partitionKey: String
        let sortKey: String?
    }

    /// Table creation is out of scope for the driver itself, so the live
    /// suites create and drop tables directly through the raw DynamoDB API,
    /// not through the driver.
    func createTable(
        name: String, partitionKey: String, sortKey: String? = nil,
        globalSecondaryIndex: GlobalSecondaryIndex? = nil
    ) async throws {
        var keySchema: [[String: Any]] = [["AttributeName": partitionKey, "KeyType": "HASH"]]
        var attributeDefs: [[String: Any]] = [["AttributeName": partitionKey, "AttributeType": "S"]]
        if let sortKey {
            keySchema.append(["AttributeName": sortKey, "KeyType": "RANGE"])
            attributeDefs.append(["AttributeName": sortKey, "AttributeType": "S"])
        }
        var body: [String: Any] = [
            "TableName": name, "KeySchema": keySchema, "AttributeDefinitions": attributeDefs,
            "BillingMode": "PAY_PER_REQUEST",
        ]
        if let index = globalSecondaryIndex {
            var indexKeySchema: [[String: Any]] = [["AttributeName": index.partitionKey, "KeyType": "HASH"]]
            for attribute in [index.partitionKey] + (index.sortKey.map { [$0] } ?? [])
            where !attributeDefs.contains(where: { $0["AttributeName"] as? String == attribute }) {
                attributeDefs.append(["AttributeName": attribute, "AttributeType": "S"])
            }
            if let sortKey = index.sortKey { indexKeySchema.append(["AttributeName": sortKey, "KeyType": "RANGE"]) }
            body["AttributeDefinitions"] = attributeDefs
            body["GlobalSecondaryIndexes"] = [[
                "IndexName": index.name, "KeySchema": indexKeySchema, "Projection": ["ProjectionType": "ALL"],
            ] as [String: Any]]
        }
        _ = try await rawCall(target: "CreateTable", body: body)
        // dynamodb-local creates synchronously, but poll briefly for ACTIVE to be safe.
        for _ in 0..<20 {
            let describe = try await rawCall(target: "DescribeTable", body: ["TableName": name])
            let status = ((describe["Table"] as? [String: Any])?["TableStatus"] as? String) ?? ""
            if status == "ACTIVE" { return }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    func deleteTable(name: String) async {
        _ = try? await rawCall(target: "DeleteTable", body: ["TableName": name])
    }

    /// Minimal hand-signed request — deliberately reuses `SigV4Signer` (the
    /// unit under test elsewhere) rather than a second signing path, since
    /// this helper exists only to set up/tear down fixtures, not to
    /// re-verify signing.
    @discardableResult
    func rawCall(target: String, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://\(server.host):\(server.port)/")!)
        request.httpMethod = "POST"
        request.setValue("application/x-amz-json-1.0", forHTTPHeaderField: "Content-Type")
        request.setValue("DynamoDB_20120810.\(target)", forHTTPHeaderField: "X-Amz-Target")
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        SigV4Signer.sign(
            &request, body: bodyData,
            credentials: .init(accessKeyID: "fakeAccessKeyId", secretAccessKey: "fakeSecretAccessKey"),
            region: "us-east-1", service: "dynamodb"
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw ConformanceFailure("\(target) failed: \(text)")
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func putItem(table: String, item: [String: Any]) async throws {
        _ = try await rawCall(target: "PutItem", body: ["TableName": table, "Item": item])
    }
}
