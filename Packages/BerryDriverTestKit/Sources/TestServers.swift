import Foundation

/// Test server coordinates parsed from env vars so conformance suites can run
/// against real servers locally and in CI, and skip cleanly when absent
/// (docs/architecture/08 §5).
///
/// Format: `HOST:PORT:USER:PASSWORD[:DATABASE]`
public struct TestServer: Sendable {
    public let host: String
    public let port: Int
    public let username: String
    public let password: String
    public let database: String?

    public static func fromEnv(_ variable: String) -> TestServer? {
        guard let raw = ProcessInfo.processInfo.environment[variable] else { return nil }
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 4, let port = Int(parts[1]) else { return nil }
        return TestServer(
            host: parts[0],
            port: port,
            username: parts[2],
            password: parts[3],
            database: parts.count >= 5 ? parts[4] : nil
        )
    }

    public static let postgres = fromEnv("BERRYDB_TEST_POSTGRES")
    public static let mysql = fromEnv("BERRYDB_TEST_MYSQL")
    public static let sqlServer = fromEnv("BERRYDB_TEST_SQLSERVER")
    public static let ssh = fromEnv("BERRYDB_TEST_SSH")
    /// Mongo has real user/password SCRAM auth (unlike Qdrant's API-key-only
    /// shape), so it reuses this general `host:port:user:pass:database`
    /// shape rather than a narrower type — same as Postgres/MySQL
    /// (docs/architecture/12 §3/§10). `database` doubles as the SCRAM
    /// authSource (see `Tests/docker/compose.yml`'s `mongo` service comment).
    public static let mongo = fromEnv("BERRYDB_TEST_MONGO")
}

/// Replica-set seed(s) for the v1 multi-seed/primary-discovery conformance
/// suite (docs/architecture/12 §3) — separate from `TestServer.mongo`
/// because this target has no auth (`Tests/docker/compose.yml`'s `mongo-rs`
/// service) and needs a *list* of seeds rather than one host/port.
///
/// Format: `host1:port1[,host2:port2...]`
public struct MongoReplicaSetTestServer: Sendable {
    /// "host:port" entries — the first is the primary seed.
    public let hosts: [String]

    public static func fromEnv(_ variable: String) -> MongoReplicaSetTestServer? {
        guard let raw = ProcessInfo.processInfo.environment[variable] else { return nil }
        let hosts = raw.split(separator: ",").map(String.init).filter { !$0.isEmpty }
        guard !hosts.isEmpty else { return nil }
        return MongoReplicaSetTestServer(hosts: hosts)
    }

    /// Fixed to match the replica set name `mongo-rs` self-initiates with in
    /// `Tests/docker/compose.yml` — no reason to also thread this through the
    /// env var.
    public static let replicaSetName = "berryrs"

    public static let mongoReplicaSet = fromEnv("BERRYDB_TEST_MONGO_RS")
}

/// Qdrant has no user/password — API key only (docs/architecture/12 §5) — so
/// it gets its own narrower coordinate shape instead of reusing `TestServer`.
///
/// Format: `HOST:PORT`
public struct QdrantTestServer: Sendable {
    public let host: String
    public let port: Int

    public static func fromEnv(_ variable: String) -> QdrantTestServer? {
        guard let raw = ProcessInfo.processInfo.environment[variable] else { return nil }
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, let port = Int(parts[1]) else { return nil }
        return QdrantTestServer(host: parts[0], port: port)
    }

    public static let qdrant = fromEnv("BERRYDB_TEST_QDRANT")
}

/// dynamodb-local accepts any non-empty SigV4 access key/secret (no real AWS
/// account needed, docs/architecture/12 §10) — same narrower shape as
/// `QdrantTestServer`, just `host:port`.
///
/// Format: `HOST:PORT`
public struct DynamoDBTestServer: Sendable {
    public let host: String
    public let port: Int

    public static func fromEnv(_ variable: String) -> DynamoDBTestServer? {
        guard let raw = ProcessInfo.processInfo.environment[variable] else { return nil }
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, let port = Int(parts[1]) else { return nil }
        return DynamoDBTestServer(host: parts[0], port: port)
    }

    public static let dynamodb = fromEnv("BERRYDB_TEST_DYNAMODB")
}

/// Redis/Valkey conformance target (docs/architecture/15, Phase 0 spike) — no
/// auth needed for a local conformance container, same narrower shape as
/// `QdrantTestServer`/`DynamoDBTestServer`.
///
/// Format: `HOST:PORT`
public struct RedisTestServer: Sendable {
    public let host: String
    public let port: Int

    public static func fromEnv(_ variable: String) -> RedisTestServer? {
        guard let raw = ProcessInfo.processInfo.environment[variable] else { return nil }
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, let port = Int(parts[1]) else { return nil }
        return RedisTestServer(host: parts[0], port: port)
    }

    public static let redis = fromEnv("BERRYDB_TEST_REDIS")
}

/// Elasticsearch conformance target (docs/architecture/17) — no auth needed
/// for a local conformance container (`xpack.security.enabled=false`, same
/// as the `qdrant`/`mongo` no-auth conformance containers), same narrower
/// shape as `QdrantTestServer`/`DynamoDBTestServer`/`RedisTestServer`.
///
/// Format: `HOST:PORT`
public struct ElasticsearchTestServer: Sendable {
    public let host: String
    public let port: Int

    public static func fromEnv(_ variable: String) -> ElasticsearchTestServer? {
        guard let raw = ProcessInfo.processInfo.environment[variable] else { return nil }
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, let port = Int(parts[1]) else { return nil }
        return ElasticsearchTestServer(host: parts[0], port: port)
    }

    public static let elasticsearch = fromEnv("BERRYDB_TEST_ELASTICSEARCH")
}
