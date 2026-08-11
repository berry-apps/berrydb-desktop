import Foundation

/// TLS behaviour for network drivers (KN-04, docs/architecture/07 §4).
public enum TLSMode: String, Sendable, CaseIterable, Codable {
    /// Plaintext only.
    case disable
    /// Try TLS without certificate verification; fall back to plaintext
    /// when the server has no TLS (libpq sslmode=prefer semantics). Default.
    case prefer
    /// TLS required, certificate NOT verified.
    case require
    /// TLS required and the certificate chain verified (against the system trust
    /// store, or a custom CA file), but the server hostname is NOT checked — for
    /// cloud databases reached by IP (libpq sslmode=verify-ca).
    case verifyCA
    /// TLS required and the certificate chain + hostname fully verified.
    case verifyFull

    /// Whether this mode validates the server certificate (and therefore honors
    /// a custom CA file). `prefer`/`require` encrypt without verifying.
    public var verifiesCertificate: Bool {
        self == .verifyCA || self == .verifyFull
    }
}

/// SSH tunnel parameters (KN-03). Secrets (password/passphrase) live in RAM
/// only, same rule as the database password (docs/architecture/07 §2).
public struct SSHConfig: Sendable {
    public let host: String
    public let port: Int
    public let username: String
    public let password: String?
    /// OpenSSH private key file path; when set it wins over password auth.
    public let privateKeyPath: String?
    public let keyPassphrase: String?

    public init(
        host: String,
        port: Int = 22,
        username: String,
        password: String? = nil,
        privateKeyPath: String? = nil,
        keyPassphrase: String? = nil
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.privateKeyPath = privateKeyPath
        self.keyPassphrase = keyPassphrase
    }
}

/// Configuration for one connection. Secrets (password/passphrase) live in RAM
/// only — never persist this struct with secrets (docs/architecture/07 §2).
public struct ConnectionConfig: Sendable {
    public let driver: DriverID
    public let name: String

    /// SQLite: file path.
    public let filePath: String?

    /// Network drivers (M1+).
    public let host: String?
    public let port: Int?
    public let username: String?
    public let password: String?
    public let database: String?
    public let tlsMode: TLSMode
    /// Custom CA certificate (PEM) used to verify the server when `tlsMode`
    /// verifies the certificate — for self-signed or private-CA servers (KN-04).
    public let caCertPath: String?
    /// Client certificate + key (PEM) for mutual TLS (KN-04). Paths, not
    /// secrets; encrypted client keys aren't supported yet.
    public let clientCertPath: String?
    public let clientKeyPath: String?
    public let ssh: SSHConfig?

    /// AWS SigV4 credentials — DynamoDB only (docs/architecture/12 §4). A new
    /// secret shape (not user/password): access key + secret key + optional
    /// session token, scoped to a region instead of host:port.
    public let awsAccessKeyID: String?
    public let awsSecretAccessKey: String?
    public let awsSessionToken: String?
    public let awsRegion: String?

    /// Mongo replica-set seed members beyond the first (`host`/`port` stay
    /// the primary seed for backward compat — every other driver keeps
    /// reading only those two fields and ignores this one). Each entry is
    /// `"host:port"`. v1 scope: seeds are tried in order to find the
    /// primary at connect time; no background topology monitoring, no
    /// automatic reconnect if the primary changes mid-session
    /// (docs/architecture/12 §3).
    public let additionalHosts: [String]?
    /// `replicaSet=<name>` — verified defensively against the connected
    /// primary's own `hello` `setName` at connect time (mismatch is a hard
    /// connect error, docs/architecture/12 §3). `nil` skips the check.
    public let mongoReplicaSet: String?

    /// Elasticsearch only — a real auth-mode field, not another
    /// `password`-reuse hack like Qdrant's API key (docs/architecture/17 §2):
    /// self-hosted clusters default to Basic auth (`username`/`password`,
    /// already above), while Elastic Cloud/Serverless recommends or requires
    /// API keys. When set, this wins over `username`/`password` for the
    /// `Authorization` header; when `nil`, `username`/`password` are used.
    public let elasticsearchAPIKey: String?

    public init(
        driver: DriverID,
        name: String,
        filePath: String? = nil,
        host: String? = nil,
        port: Int? = nil,
        username: String? = nil,
        password: String? = nil,
        database: String? = nil,
        tlsMode: TLSMode = .prefer,
        caCertPath: String? = nil,
        clientCertPath: String? = nil,
        clientKeyPath: String? = nil,
        ssh: SSHConfig? = nil,
        awsAccessKeyID: String? = nil,
        awsSecretAccessKey: String? = nil,
        awsSessionToken: String? = nil,
        awsRegion: String? = nil,
        additionalHosts: [String]? = nil,
        mongoReplicaSet: String? = nil,
        elasticsearchAPIKey: String? = nil
    ) {
        self.driver = driver
        self.name = name
        self.filePath = filePath
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.database = database
        self.tlsMode = tlsMode
        self.caCertPath = caCertPath
        self.clientCertPath = clientCertPath
        self.clientKeyPath = clientKeyPath
        self.ssh = ssh
        self.awsAccessKeyID = awsAccessKeyID
        self.awsSecretAccessKey = awsSecretAccessKey
        self.awsSessionToken = awsSessionToken
        self.awsRegion = awsRegion
        self.additionalHosts = additionalHosts
        self.mongoReplicaSet = mongoReplicaSet
        self.elasticsearchAPIKey = elasticsearchAPIKey
    }

    public static func sqlite(path: String, name: String? = nil) -> ConnectionConfig {
        ConnectionConfig(
            driver: .sqlite,
            name: name ?? (path as NSString).lastPathComponent,
            filePath: path
        )
    }

    /// Copy of this config pointing at a different endpoint — used to swap in
    /// the local end of an SSH tunnel (docs/architecture/06 · L1).
    public func replacingEndpoint(host: String, port: Int) -> ConnectionConfig {
        ConnectionConfig(
            driver: driver, name: name, filePath: filePath,
            host: host, port: port,
            username: username, password: password, database: database,
            tlsMode: tlsMode, caCertPath: caCertPath,
            clientCertPath: clientCertPath, clientKeyPath: clientKeyPath, ssh: nil,
            elasticsearchAPIKey: elasticsearchAPIKey
        )
    }
}
