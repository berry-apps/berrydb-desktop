import BerryDataSourceKit
import BerryDriverKit
import Foundation

/// One page of a PIT + `search_after` scroll. Marked
/// `@unchecked Sendable` because the underlying JSON dictionary contains `Any`
/// values that cross the actor boundary.
struct ElasticsearchScrollPage: @unchecked Sendable {
    let hits: [[String: Any]]
    /// nil once the PIT has been closed (last page reached).
    let nextPageToken: String?
}

/// Thin REST/JSON client over `URLSession` — zero vendored dependency, same
/// pattern as `QdrantHTTPClient` (no maintained
/// Swift Elasticsearch client exists either). Every method maps failures to
/// `DataSourceError` so the actor above never touches HTTP/JSON details
/// directly.
struct ElasticsearchHTTPClient: Sendable {
    let baseURL: URL
    private let authHeader: (name: String, value: String)?
    let session: URLSession

    init(config: ConnectionConfig, session: URLSession) throws {
        guard let host = config.host, !host.isEmpty else {
            throw DataSourceError.connectionFailed("Missing host")
        }
        var components = URLComponents()
        components.scheme = config.tlsMode == .disable ? "http" : "https"
        components.host = host
        components.port = config.port ?? 9200
        guard let url = components.url else {
            throw DataSourceError.connectionFailed("Invalid host/port")
        }
        self.baseURL = url
        self.authHeader = Self.authHeader(config: config)
        self.session = session
    }

    /// API key wins over Basic auth when both are set — self-hosted clusters
    /// default to Basic (`username`/`password`), Elastic Cloud/Serverless
 /// pushes/requires API keys. `elasticsearchAPIKey`
    /// is expected already `base64(id:api_key)`-encoded, the same "encoded"
    /// value ES's own `POST /_security/api_key` response returns — BerryDB
    /// does not mint keys itself in v1, only consumes an existing one.
    private static func authHeader(config: ConnectionConfig) -> (name: String, value: String)? {
        if let apiKey = config.elasticsearchAPIKey, !apiKey.isEmpty {
            return ("Authorization", "ApiKey \(apiKey)")
        }
        if let username = config.username, !username.isEmpty {
            let raw = "\(username):\(config.password ?? "")"
            return ("Authorization", "Basic \(Data(raw.utf8).base64EncodedString())")
        }
        return nil
    }

    // MARK: Request plumbing

    private func request(
        method: String, path: String, query: [URLQueryItem] = [], jsonBody: [String: Any]? = nil
    ) throws -> URLRequest {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false
        ) else {
            throw DataSourceError.connectionFailed("Invalid request URL")
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else {
            throw DataSourceError.connectionFailed("Invalid request URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let authHeader {
            req.setValue(authHeader.value, forHTTPHeaderField: authHeader.name)
        }
        if let jsonBody {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do {
                req.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
            } catch {
                throw DataSourceError.queryFailed("Could not encode request body: \(error.localizedDescription)")
            }
        }
        return req
    }

    private func send(_ request: URLRequest) async throws -> [String: Any] {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw DataSourceError.cancelled
        } catch {
            throw DataSourceError.connectionFailed(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw DataSourceError.connectionFailed("Non-HTTP response from Elasticsearch")
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(http.statusCode) else {
            throw DataSourceError.queryFailed(Self.errorMessage(status: http.statusCode, json: json))
        }
        guard let json else {
            throw DataSourceError.queryFailed("Elasticsearch returned a non-JSON response (HTTP \(http.statusCode))")
        }
        return json
    }

    private static func errorMessage(status: Int, json: [String: Any]?) -> String {
        if let error = json?["error"] as? [String: Any], let reason = error["reason"] as? String {
            return "HTTP \(status): \(reason)"
        }
        if let error = json?["error"] as? String {
            return "HTTP \(status): \(error)"
        }
        return "HTTP \(status)"
    }

 // MARK: Indices

    /// `GET /_resolve/index/*` — NOT `_cat/indices`, which Elastic's own docs
    /// scope to human/CLI consumption rather than application use. The
    /// default wildcard excludes hidden/dot-prefixed system indices, same
    /// "user's own objects only" scope as Postgres excluding system schemas.
    func listIndices() async throws -> [CollectionRef] {
        let req = try request(method: "GET", path: "_resolve/index/*")
        let json = try await send(req)
        let indices = (json["indices"] as? [[String: Any]]) ?? []
        return indices.compactMap { entry in
            (entry["name"] as? String).map { CollectionRef(name: $0) }
        }
    }

    /// `PUT /{name}` with an empty body — dynamic mapping infers field types
    /// from the first document indexed, so no upfront mapping is required.
    func createIndex(name: String) async throws {
        let req = try request(method: "PUT", path: name)
        _ = try await send(req)
    }

    func dropIndex(name: String) async throws {
        let req = try request(method: "DELETE", path: name)
        _ = try await send(req)
    }

    /// `GET /{name}/_mapping` — a real, authoritative field/type catalog
    /// (unlike Mongo's sample-based inference), flattened to dot-path keys.
    func mapping(index: String) async throws -> [String: String] {
        let req = try request(method: "GET", path: "\(index)/_mapping")
        let json = try await send(req)
        guard let indexEntry = json[index] as? [String: Any],
              let mappings = indexEntry["mappings"] as? [String: Any],
              let properties = mappings["properties"] as? [String: Any]
        else { return [:] }
        return ElasticsearchWire.flattenMapping(properties)
    }

 // MARK: Query

    /// `refresh=true` on every write below, same read-after-write reasoning
    /// as `QdrantHTTPClient.waitForResult`: ES's default 1s refresh interval
    /// means a query issued right after an unwaited write can miss it, and
 /// BerryDB always previews-then-applies expecting the change
    /// visible immediately afterward.
    private static let refreshTrue = [URLQueryItem(name: "refresh", value: "true")]

    /// Search hits from Elasticsearch. Marked `@unchecked Sendable` because the
    /// underlying JSON dictionary contains `Any` values that cross the actor boundary.
    struct ElasticsearchSearchResults: @unchecked Sendable, RandomAccessCollection {
        typealias Element = [String: Any]
        typealias Index = Int

        let hits: [[String: Any]]

        init(hits: [[String: Any]]) {
            self.hits = hits
        }

        var startIndex: Int { hits.startIndex }
        var endIndex: Int { hits.endIndex }
        subscript(position: Int) -> [String: Any] { hits[position] }
    }

    func search(index: String, query: BerryDocument, from: Int, size: Int) async throws -> ElasticsearchSearchResults {
        let body: [String: Any] = ["query": ElasticsearchWire.queryDSLBody(query), "from": from, "size": size]
        let req = try request(method: "POST", path: "\(index)/_search", jsonBody: body)
        let json = try await send(req)
        let hitsWrapper = json["hits"] as? [String: Any]
        return ElasticsearchSearchResults(hits: (hitsWrapper?["hits"] as? [[String: Any]]) ?? [])
    }

    /// One page per call, `pageToken` opaquely carrying `(pit_id,
    /// search_after)` forward — `nil` `pageToken` opens a fresh PIT.
    /// `_doc` order is the tiebreaker sort: cheapest to compute, and the
    /// standard choice for deep pagination when relevance ranking doesn't
    /// matter (Elastic's own deep-pagination guidance).
    func scroll(index: String, query: BerryDocument, pageToken: String?, size: Int) async throws -> ElasticsearchScrollPage {
        let pitID: String
        var searchAfter: [Any]?
        if let pageToken, let decoded = Self.decodePageToken(pageToken) {
            pitID = decoded.pitID
            searchAfter = decoded.searchAfter
        } else {
            pitID = try await openPIT(index: index)
        }

        var body: [String: Any] = [
            "query": ElasticsearchWire.queryDSLBody(query),
            "size": size,
            "sort": [["_doc": "asc"]],
            "pit": ["id": pitID, "keep_alive": Self.pitKeepAlive],
        ]
        if let searchAfter { body["search_after"] = searchAfter }
        let req = try request(method: "POST", path: "_search", jsonBody: body)
        let json = try await send(req)
        let hitsWrapper = json["hits"] as? [String: Any]
        let hits = (hitsWrapper?["hits"] as? [[String: Any]]) ?? []

        guard hits.count >= size, let lastSort = hits.last.flatMap(ElasticsearchWire.sortValues(fromHitJSON:)) else {
            await closePIT(pitID)
            return ElasticsearchScrollPage(hits: hits, nextPageToken: nil)
        }
        return ElasticsearchScrollPage(hits: hits, nextPageToken: Self.encodePageToken(pitID: pitID, searchAfter: lastSort))
    }

    private static let pitKeepAlive = "1m"

    private func openPIT(index: String) async throws -> String {
        let req = try request(method: "POST", path: "\(index)/_pit", query: [URLQueryItem(name: "keep_alive", value: Self.pitKeepAlive)])
        let json = try await send(req)
        guard let id = json["id"] as? String else {
            throw DataSourceError.queryFailed("Elasticsearch did not return a point-in-time id")
        }
        return id
    }

    private func closePIT(_ id: String) async {
        guard let req = try? request(method: "DELETE", path: "_pit", jsonBody: ["id": id]) else { return }
        _ = try? await send(req)
    }

    private static func encodePageToken(pitID: String, searchAfter: [Any]) -> String {
        let payload: [String: Any] = ["pit_id": pitID, "search_after": searchAfter]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return "" }
        return data.base64EncodedString()
    }

    private static func decodePageToken(_ token: String) -> (pitID: String, searchAfter: [Any])? {
        guard let data = Data(base64Encoded: token),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pitID = json["pit_id"] as? String,
              let searchAfter = json["search_after"] as? [Any]
        else { return nil }
        return (pitID, searchAfter)
    }

 // MARK: Write

    /// `id` nil lets Elasticsearch auto-generate one; the response's `_id`
    /// becomes the caller's `insertedID`.
    func indexDocument(index: String, id: String?, source: [String: Any]) async throws -> String {
        let path = id.map { "\(index)/_doc/\($0)" } ?? "\(index)/_doc"
        let req = try request(method: id == nil ? "POST" : "PUT", path: path, query: Self.refreshTrue, jsonBody: source)
        let json = try await send(req)
        guard let insertedID = json["_id"] as? String else {
            throw DataSourceError.queryFailed("Elasticsearch did not return an _id for the indexed document")
        }
        return insertedID
    }

    /// `POST /{index}/_update/{id}` with `{"doc": patch}` — a partial merge,
    /// matching `DataSourceChangeSet.update`'s "leaves every field not in
    /// patch untouched" contract.
    func updateDocument(index: String, id: String, patch: [String: Any]) async throws {
        let req = try request(
            method: "POST", path: "\(index)/_update/\(id)", query: Self.refreshTrue, jsonBody: ["doc": patch]
        )
        _ = try await send(req)
    }

    func deleteDocument(index: String, id: String) async throws {
        let req = try request(method: "DELETE", path: "\(index)/_doc/\(id)", query: Self.refreshTrue)
        _ = try await send(req)
    }

    /// `POST /{index}/_delete_by_query` — an empty/`match_all` query is the
 /// "no id, no filter" whole-index delete case (-equivalent).
    func deleteByQuery(index: String, query: BerryDocument) async throws -> Int {
        let body: [String: Any] = ["query": ElasticsearchWire.queryDSLBody(query)]
        let req = try request(method: "POST", path: "\(index)/_delete_by_query", query: Self.refreshTrue, jsonBody: body)
        let json = try await send(req)
        return (json["deleted"] as? NSNumber)?.intValue ?? 0
    }

    func ping() async -> Bool {
        guard let req = try? request(method: "GET", path: "_cluster/health") else { return false }
        return (try? await send(req)) != nil
    }
}
