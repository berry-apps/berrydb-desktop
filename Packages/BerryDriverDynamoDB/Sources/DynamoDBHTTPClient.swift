import BerryDriverKit
import Foundation

/// Signed REST/JSON client for the DynamoDB HTTP API — zero vendored
/// dependency, same shape as `QdrantHTTPClient` (docs/architecture/12 §5)
/// but with AWS SigV4 signing (§4) instead of a bearer header. Every method
/// maps failures to `DriverError` so `DynamoDBConnection` never touches
/// HTTP/JSON details directly.
struct DynamoDBHTTPClient: Sendable {
    let baseURL: URL
    let region: String
    let credentials: SigV4Signer.Credentials
    let session: URLSession

    /// `config.host` set (non-empty) → explicit endpoint, the shape used for
    /// dynamodb-local (docs/architecture/12 §10) and for self-hosted-behind-
    /// SSH-tunnel setups. Otherwise the endpoint is derived from
    /// `awsRegion` — the normal shape for real AWS, where DynamoDB is always
    /// reached at `dynamodb.{region}.amazonaws.com`, not a user-chosen host.
    init(config: ConnectionConfig, session: URLSession) throws {
        guard let accessKey = config.awsAccessKeyID, !accessKey.isEmpty,
              let secretKey = config.awsSecretAccessKey, !secretKey.isEmpty else {
            throw DriverError.connectionFailed("Missing AWS access key / secret access key")
        }
        let region = (config.awsRegion?.isEmpty == false) ? config.awsRegion! : "us-east-1"
        self.region = region
        self.credentials = SigV4Signer.Credentials(
            accessKeyID: accessKey, secretAccessKey: secretKey, sessionToken: config.awsSessionToken
        )

        if let host = config.host, !host.isEmpty {
            var components = URLComponents()
            components.scheme = config.tlsMode == .disable ? "http" : "https"
            components.host = host
            components.port = config.port ?? 8000
            guard let url = components.url else {
                throw DriverError.connectionFailed("Invalid host/port")
            }
            self.baseURL = url
        } else {
            guard let url = URL(string: "https://dynamodb.\(region).amazonaws.com") else {
                throw DriverError.connectionFailed("Invalid AWS region: \(region)")
            }
            self.baseURL = url
        }
        self.session = session
    }

    // MARK: - Request plumbing

    private func send(target: String, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("application/x-amz-json-1.0", forHTTPHeaderField: "Content-Type")
        request.setValue(target, forHTTPHeaderField: "X-Amz-Target")

        let bodyData: Data
        do {
            bodyData = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw DriverError.queryFailed(message: "Could not encode request body: \(error.localizedDescription)", code: nil)
        }
        request.httpBody = bodyData
        SigV4Signer.sign(&request, body: bodyData, credentials: credentials, region: region, service: "dynamodb")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw DriverError.cancelled
        } catch {
            throw DriverError.connectionFailed(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw DriverError.connectionFailed("Non-HTTP response from DynamoDB")
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(http.statusCode) else {
            throw Self.mapError(status: http.statusCode, json: json)
        }
        return json ?? [:]
    }

    /// DynamoDB's JSON-protocol error shape (verified against dynamodb-local):
    /// `{"__type": "com.amazonaws.dynamodb.v20120810#ResourceNotFoundException", "Message": "..."}`
    /// — `Message` is capitalized (unlike Qdrant's lowercase `status.error`).
    private static func mapError(status: Int, json: [String: Any]?) -> DriverError {
        let exceptionType = (json?["__type"] as? String)?.split(separator: "#").last.map(String.init)
        let message = (json?["Message"] as? String) ?? (json?["message"] as? String) ?? "HTTP \(status)"
        let label = exceptionType ?? "HTTP \(status)"
        return .queryFailed(message: "\(label): \(message)", code: Int32(status))
    }

    // MARK: - ExecuteStatement (docs/architecture/12 §4)

    /// One page. `limit` is the API's page-size cap ("max items to
    /// evaluate", distinct from a SQL LIMIT — see `PartiQLDialect.limitClause`);
    /// `nextToken` continues a previous page. Tuple return (not a named
    /// `Sendable` struct) — same reasoning as `QdrantHTTPClient.scroll`:
    /// `[String: Any]` can't provably conform to `Sendable`, and Swift 6
    /// strict concurrency only flags that when it's a stored property of an
    /// explicitly `Sendable`-declared type, not a bare tuple crossing the
    /// actor boundary.
    func executeStatement(
        _ statement: String, nextToken: String?, limit: Int?
    ) async throws -> (items: [[String: Any]], nextToken: String?) {
        var body: [String: Any] = ["Statement": statement]
        if let nextToken { body["NextToken"] = nextToken }
        if let limit { body["Limit"] = limit }
        let json = try await send(target: "DynamoDB_20120810.ExecuteStatement", body: body)
        return ((json["Items"] as? [[String: Any]]) ?? [], json["NextToken"] as? String)
    }

    // MARK: - Introspection (05 §5)

    func listTables() async throws -> [String] {
        var names: [String] = []
        var start: String?
        repeat {
            var body: [String: Any] = [:]
            if let start { body["ExclusiveStartTableName"] = start }
            let json = try await send(target: "DynamoDB_20120810.ListTables", body: body)
            names += (json["TableNames"] as? [String]) ?? []
            start = json["LastEvaluatedTableName"] as? String
        } while start != nil
        return names
    }

    func describeTable(name: String) async throws -> [String: Any] {
        let json = try await send(target: "DynamoDB_20120810.DescribeTable", body: ["TableName": name])
        guard let table = json["Table"] as? [String: Any] else {
            throw DriverError.queryFailed(message: "DescribeTable returned no Table for \(name)", code: nil)
        }
        return table
    }

    /// Fail-fast check for `connect()` (KN-06 "Test connection" expectation,
    /// same reasoning as `QdrantDriver.connect()`) — an HTTP client has no
    /// TCP-handshake-time failure the way Postgres/MySQL do, so a cheap real
    /// call is the only way to catch a bad host/region/credential early.
    func ping() async -> Bool {
        (try? await listTables()) != nil
    }
}
