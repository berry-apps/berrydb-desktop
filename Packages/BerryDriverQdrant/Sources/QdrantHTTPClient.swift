import BerryDataSourceKit
import BerryDriverKit
import Foundation

/// Best-effort collection metadata from `GET /collections/{name}` — vector
/// size/distance feed `inferredSchema` (docs/architecture/12 §3).
struct QdrantCollectionInfo: Sendable {
    let pointsCount: Int?
    let vectorSize: Int?
    let distance: String?
}

/// Thin REST/JSON client over `URLSession` — zero vendored dependency, same
/// pattern as the AI client (docs/architecture/03 §2, 12 §5). Every method
/// maps failures to `DataSourceError` so the actor above never touches
/// HTTP/JSON details directly.
struct QdrantHTTPClient: Sendable {
    let baseURL: URL
    /// Pragmatic reuse of `ConnectionConfig.password` as the Qdrant API key:
    /// Qdrant auth is a single header value, not a user/password pair, but
    /// `ConnectionConfig` (docs/architecture/07 §2) has no dedicated "API key"
    /// secret shape yet. Growing it for one driver isn't worth it for v1 —
    /// revisit if a second header-only-auth driver shows up.
    let apiKey: String?
    let session: URLSession

    init(config: ConnectionConfig, session: URLSession) throws {
        guard let host = config.host, !host.isEmpty else {
            throw DataSourceError.connectionFailed("Missing host")
        }
        var components = URLComponents()
        components.scheme = config.tlsMode == .disable ? "http" : "https"
        components.host = host
        components.port = config.port ?? 6333
        guard let url = components.url else {
            throw DataSourceError.connectionFailed("Invalid host/port")
        }
        self.baseURL = url
        self.apiKey = config.password
        self.session = session
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
        if let apiKey, !apiKey.isEmpty {
            req.setValue(apiKey, forHTTPHeaderField: "api-key")
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
            throw DataSourceError.connectionFailed("Non-HTTP response from Qdrant")
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(http.statusCode) else {
            throw DataSourceError.queryFailed(Self.errorMessage(status: http.statusCode, json: json))
        }
        guard let json else {
            throw DataSourceError.queryFailed("Qdrant returned a non-JSON response (HTTP \(http.statusCode))")
        }
        return json
    }

    private static func errorMessage(status: Int, json: [String: Any]?) -> String {
        if let statusField = json?["status"] as? [String: Any], let error = statusField["error"] as? String {
            return "HTTP \(status): \(error)"
        }
        if let statusField = json?["status"] as? String {
            return "HTTP \(status): \(statusField)"
        }
        return "HTTP \(status)"
    }

    // MARK: Collections

    func listCollections() async throws -> [CollectionRef] {
        let req = try request(method: "GET", path: "collections")
        let json = try await send(req)
        let result = json["result"] as? [String: Any]
        let collections = result?["collections"] as? [[String: Any]] ?? []
        return collections.compactMap { entry in
            (entry["name"] as? String).map { CollectionRef(name: $0) }
        }
    }

    /// `PUT /collections/{name}` — explicit collection creation
    /// (docs/architecture/12 §5); Qdrant has no implicit-creation-on-insert
    /// equivalent to Mongo's, so this is the only path into an existing
    /// collection. Caller (`QdrantConnection.createCollection`) has already
    /// validated `vectorSize`/`distance`.
    func createCollection(name: String, vectorSize: Int, distance: String) async throws {
        let body: [String: Any] = ["vectors": ["size": vectorSize, "distance": distance]]
        let req = try request(method: "PUT", path: "collections/\(name)", jsonBody: body)
        _ = try await send(req)
    }

    func collectionInfo(name: String) async throws -> QdrantCollectionInfo {
        let req = try request(method: "GET", path: "collections/\(name)")
        let json = try await send(req)
        let result = json["result"] as? [String: Any]
        let pointsCount = (result?["points_count"] as? NSNumber)?.intValue
        let params = (result?["config"] as? [String: Any])?["params"] as? [String: Any]

        var size: Int?
        var distance: String?
        if let vectors = params?["vectors"] as? [String: Any] {
            if let s = (vectors["size"] as? NSNumber)?.intValue {
                size = s
                distance = vectors["distance"] as? String
            } else {
                // Named-vector collection — best-effort: report the first one
                // (docs/architecture/12 §5 scopes to a single default vector).
                for (_, value) in vectors {
                    guard let dict = value as? [String: Any] else { continue }
                    size = (dict["size"] as? NSNumber)?.intValue
                    distance = dict["distance"] as? String
                    break
                }
            }
        }
        return QdrantCollectionInfo(pointsCount: pointsCount, vectorSize: size, distance: distance)
    }

    // MARK: Query (NS-06/07)

    func search(
        collection: String, vector: [Float], filter: BerryDocument?, topK: Int, scoreThreshold: Double?
    ) async throws -> [[String: Any]] {
        var body: [String: Any] = [
            "vector": vector.map(Double.init),
            "limit": topK,
            "with_payload": true,
            "with_vector": false,
        ]
        if let filter { body["filter"] = filter.jsonObject }
        if let scoreThreshold { body["score_threshold"] = scoreThreshold }
        let req = try request(method: "POST", path: "collections/\(collection)/points/search", jsonBody: body)
        let json = try await send(req)
        return (json["result"] as? [[String: Any]]) ?? []
    }

    /// One page per call — `nextPageToken` drives the next `scroll` the same
    /// way DynamoDB's `LastEvaluatedKey` drives sequential paging
    /// (docs/architecture/12 §4/§5): no seek, caller passes the token back in.
    func scroll(
        collection: String, filter: BerryDocument?, pageToken: String?, limit: Int, withVector: Bool
    ) async throws -> (points: [[String: Any]], nextPageToken: String?) {
        var body: [String: Any] = [
            "limit": limit,
            "with_payload": true,
            "with_vector": withVector,
        ]
        if let filter { body["filter"] = filter.jsonObject }
        if let pageToken { body["offset"] = Self.decodeOffset(pageToken) }
        let req = try request(method: "POST", path: "collections/\(collection)/points/scroll", jsonBody: body)
        let json = try await send(req)
        let result = json["result"] as? [String: Any]
        let points = (result?["points"] as? [[String: Any]]) ?? []
        let nextOffset = result?["next_page_offset"]
        let nextToken: String? =
            if nextOffset == nil || nextOffset is NSNull { nil } else { Self.encodeOffset(nextOffset!) }
        return (points, nextToken)
    }

    // MARK: Write (docs/architecture/12 §6)

    /// `wait=true` on every write below: Qdrant applies writes asynchronously
    /// by default, so a query issued right after an unwaited write can miss
    /// it. BerryDB always previews-then-applies (DL-03/04) and the UI expects
    /// the change visible immediately afterward, so this trades a little
    /// latency for read-after-write consistency — not in the doc's endpoint
    /// list verbatim, called out in docs/architecture/12 §5 "Trạng thái hiện thực".
    private static let waitForResult = [URLQueryItem(name: "wait", value: "true")]

    func upsertPoint(collection: String, id: Any, vector: [Double], payload: [String: Any]?) async throws {
        var point: [String: Any] = ["id": id, "vector": vector]
        if let payload { point["payload"] = payload }
        let req = try request(
            method: "PUT", path: "collections/\(collection)/points",
            query: Self.waitForResult, jsonBody: ["points": [point]]
        )
        _ = try await send(req)
    }

    /// Merges into the existing payload without touching the vector — used
    /// for a payload-only `.update` so a partial patch never wipes the vector
    /// (deliberate deviation from the doc's plain "upsert" description; see
    /// docs/architecture/12 §5 "Trạng thái hiện thực").
    func setPayload(collection: String, id: Any, payload: [String: Any]) async throws {
        let body: [String: Any] = ["payload": payload, "points": [id]]
        let req = try request(
            method: "POST", path: "collections/\(collection)/points/payload",
            query: Self.waitForResult, jsonBody: body
        )
        _ = try await send(req)
    }

    func deleteByIDs(collection: String, ids: [Any]) async throws {
        let req = try request(
            method: "POST", path: "collections/\(collection)/points/delete",
            query: Self.waitForResult, jsonBody: ["points": ids]
        )
        _ = try await send(req)
    }

    /// Empty filter `{}` matches every point — the "no id" delete case
    /// (`DataSourceDangerGuard.deleteWithoutFilter`, docs/architecture/12 §6).
    func deleteByFilter(collection: String, filter: [String: Any]) async throws {
        let req = try request(
            method: "POST", path: "collections/\(collection)/points/delete",
            query: Self.waitForResult, jsonBody: ["filter": filter]
        )
        _ = try await send(req)
    }

    func ping() async -> Bool {
        guard let req = try? request(method: "GET", path: "collections") else { return false }
        return (try? await send(req)) != nil
    }

    // MARK: Page token encoding

    /// `next_page_offset` is a number or a string ID depending on the
    /// collection's ID type — tag it so the opaque `String`
    /// `DataSourceStats.nextPageToken` round-trips either shape intact.
    private static func encodeOffset(_ value: Any) -> String {
        if let s = value as? String { return "s:" + s }
        if let n = value as? NSNumber { return "n:" + n.stringValue }
        return "s:" + String(describing: value)
    }

    private static func decodeOffset(_ token: String) -> Any {
        if token.hasPrefix("n:"), let n = Int64(token.dropFirst(2)) { return n }
        if token.hasPrefix("s:") { return String(token.dropFirst(2)) }
        return token
    }
}
