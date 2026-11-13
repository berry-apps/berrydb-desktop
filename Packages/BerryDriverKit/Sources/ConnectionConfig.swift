import Foundation

/// TLS behaviour for network drivers.
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

/// SSH tunnel parameters. Secrets (password/passphrase) live in RAM
/// only, same rule as the database password.
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
/// only — never persist this struct with secrets.
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
 /// verifies the certificate — for self-signed or private-CA servers.
    public let caCertPath: String?
 /// Client certificate + key (PEM) for mutual TLS. Paths, not
    /// secrets; encrypted client keys aren't supported yet.
    public let clientCertPath: String?
    public let clientKeyPath: String?
    public let ssh: SSHConfig?

 /// AWS SigV4 credentials — DynamoDB only. A new
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
 ///
    public let additionalHosts: [String]?
    /// `replicaSet=<name>` — verified defensively against the connected
    /// primary's own `hello` `setName` at connect time (mismatch is a hard
 /// connect error). `nil` skips the check.
    public let mongoReplicaSet: String?

    /// Elasticsearch only — a real auth-mode field, not another
 /// `password`-reuse hack like Qdrant's API key:
    /// self-hosted clusters default to Basic auth (`username`/`password`,
    /// already above), while Elastic Cloud/Serverless recommends or requires
    /// API keys. When set, this wins over `username`/`password` for the
    /// `Authorization` header; when `nil`, `username`/`password` are used.
    public let elasticsearchAPIKey: String?
    /// The name the server lists the connection under, sent at connect where
    /// the driver can: Postgres takes it as the `application_name` startup
    /// parameter and shows it in `pg_stat_activity`
    /// (https://www.postgresql.org/docs/current/runtime-config-logging.html#GUC-APPLICATION-NAME).
    /// Nil leaves the driver's default. Other drivers ignore it.
    public let applicationName: String?

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
        elasticsearchAPIKey: String? = nil,
        applicationName: String? = nil
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
        self.applicationName = applicationName
    }

    /// Copy of this config whose connection the server lists under `name`.
    public func withApplicationName(_ name: String) -> ConnectionConfig {
        ConnectionConfig(
            driver: driver, name: self.name, filePath: filePath,
            host: host, port: port,
            username: username, password: password, database: database,
            tlsMode: tlsMode, caCertPath: caCertPath,
            clientCertPath: clientCertPath, clientKeyPath: clientKeyPath, ssh: ssh,
            awsAccessKeyID: awsAccessKeyID, awsSecretAccessKey: awsSecretAccessKey,
            awsSessionToken: awsSessionToken, awsRegion: awsRegion,
            additionalHosts: additionalHosts, mongoReplicaSet: mongoReplicaSet,
            elasticsearchAPIKey: elasticsearchAPIKey, applicationName: name
        )
    }

    public static func sqlite(path: String, name: String? = nil) -> ConnectionConfig {
        ConnectionConfig(
            driver: .sqlite,
            name: name ?? (path as NSString).lastPathComponent,
            filePath: path
        )
    }

    public struct LibSQLEndpoint: Sendable, Equatable {
        public let baseURL: URL
        public let host: String
        public let port: Int
        public let useTLS: Bool

        public init(baseURL: URL, host: String, port: Int, useTLS: Bool) {
            self.baseURL = baseURL
            self.host = host
            self.port = port
            self.useTLS = useTLS
        }
    }

    /// Parses a libSQL endpoint from a URL (`libsql://`, `https://`, `http://`)
    /// or bare hostname, applying `port` and `tlsMode` when not already pinned
    /// by an explicit HTTP(S) scheme.
    public static func parseLibSQLEndpoint(
        host rawHost: String?,
        port explicitPort: Int? = nil,
        tlsMode: TLSMode = .require
    ) -> LibSQLEndpoint? {
        let trimmed = (rawHost ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate: String
        let explicitScheme: String?
        if let range = trimmed.range(of: "://") {
            let scheme = String(trimmed[..<range.lowerBound]).lowercased()
            guard scheme == "libsql" || scheme == "https" || scheme == "http" else {
                return nil
            }
            explicitScheme = scheme
            let rest = String(trimmed[range.upperBound...])
            let httpScheme: String
            switch scheme {
            case "http":
                httpScheme = "http"
            case "https":
                httpScheme = "https"
            default:
                httpScheme = tlsMode == .disable ? "http" : "https"
            }
            candidate = "\(httpScheme)://\(rest)"
        } else {
            explicitScheme = nil
            let httpScheme = tlsMode == .disable ? "http" : "https"
            candidate = "\(httpScheme)://\(trimmed)"
        }

        guard var components = URLComponents(string: candidate),
              let parsedHost = components.host, !parsedHost.isEmpty
        else {
            return nil
        }

        let useTLS: Bool
        switch explicitScheme {
        case "http":
            useTLS = false
        case "https":
            useTLS = true
        default:
            useTLS = tlsMode != .disable
        }

        let resolvedPort: Int
        if let urlPort = components.port {
            resolvedPort = urlPort
        } else if let explicitPort, explicitPort > 0 {
            resolvedPort = explicitPort
            let defaultPort = useTLS ? 443 : 80
            if explicitPort != defaultPort {
                components.port = explicitPort
            }
        } else {
            resolvedPort = useTLS ? 443 : 80
        }

        // Normalize trailing slash on path while preserving any custom subpath.
        if components.path == "/" {
            components.path = ""
        } else if components.path.hasSuffix("/") {
            components.path = String(components.path.dropLast())
        }
        components.query = nil
        components.fragment = nil

        guard let baseURL = components.url else { return nil }
        return LibSQLEndpoint(
            baseURL: baseURL,
            host: parsedHost,
            port: resolvedPort,
            useTLS: useTLS
        )
    }

    public static func libsql(
        host: String,
        port: Int? = nil,
        authToken: String? = nil,
        tlsMode: TLSMode = .require,
        name: String? = nil
    ) -> ConnectionConfig {
        let parsed = parseLibSQLEndpoint(host: host, port: port, tlsMode: tlsMode)
        return ConnectionConfig(
            driver: .libsql,
            name: name ?? parsed?.host ?? host,
            host: host,
            port: port ?? parsed?.port ?? (tlsMode == .disable ? 80 : 443),
            password: authToken,
            tlsMode: parsed.map { $0.useTLS ? (tlsMode == .disable ? .require : tlsMode) : .disable } ?? tlsMode
        )
    }

    /// Copy of this config pointing at a different endpoint — used to swap in
    /// the local end of an SSH tunnel. Credentials travel with it, the AWS
    /// SigV4 key, token and region included; `additionalHosts` and
    /// `mongoReplicaSet` do not, because the tunnel reaches exactly one host.
    public func replacingEndpoint(host: String, port: Int) -> ConnectionConfig {
        ConnectionConfig(
            driver: driver, name: name, filePath: filePath,
            host: host, port: port,
            username: username, password: password, database: database,
            tlsMode: tlsMode, caCertPath: caCertPath,
            clientCertPath: clientCertPath, clientKeyPath: clientKeyPath, ssh: nil,
            awsAccessKeyID: awsAccessKeyID, awsSecretAccessKey: awsSecretAccessKey,
            awsSessionToken: awsSessionToken, awsRegion: awsRegion,
            elasticsearchAPIKey: elasticsearchAPIKey, applicationName: applicationName
        )
    }
}
