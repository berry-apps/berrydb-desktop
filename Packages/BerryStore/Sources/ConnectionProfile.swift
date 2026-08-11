import BerryDriverKit
import Foundation
import GRDB

/// Persisted connection profile — must NEVER contain a password/secret
/// (docs/architecture/07 §2: secrets live only in the Keychain, looked up by UUID).
public struct ConnectionProfile: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var driverID: String
    public var name: String
    public var groupName: String?
    /// Environment label (KN-07): "production" triggers a stricter DangerGuard.
    public var envColor: String?
    public var sortOrder: Int

    // SQLite
    public var filePath: String?

    // Network drivers
    public var host: String?
    public var port: Int?
    public var username: String?
    public var database: String?
    /// KN-04 — raw value of `TLSMode`; defaults to `prefer`.
    public var tlsMode: String
    /// KN-04 — path to a custom CA certificate (PEM) for verifying servers.
    /// A file path, not a secret, so it lives in the profile (07 §2).
    public var tlsCACertPath: String?
    /// KN-04 — client certificate + key paths for mutual TLS.
    public var tlsClientCertPath: String?
    public var tlsClientKeyPath: String?

    /// Mongo replica-set seed members beyond `host`/`port` — comma-separated
    /// `"host:port"` entries, Mongo-only field (docs/architecture/12 §3).
    /// Not a secret, so it lives in the profile like `tlsCACertPath`.
    public var mongoAdditionalHosts: String?
    /// Mongo `replicaSet=<name>` — verified against the connected primary's
    /// own `hello` `setName` at connect time.
    public var mongoReplicaSet: String?

    /// Elasticsearch auth mode (docs/architecture/17 §3): `true` = API key
    /// (Keychain `.elasticsearchAPIKey`), `false` = Basic (`username`/the
    /// Keychain `.database` password). A persisted flag, not an implicit
    /// "is a key stored" check — same reasoning as `sshEnabled` gating
    /// `SSHConfig`: switching back to Basic must actually stop sending a
    /// previously stored key, not silently keep using it.
    public var elasticsearchAPIKeyEnabled: Bool

    // SSH tunnel (KN-03) — secrets (password/passphrase) live in the Keychain.
    public var sshEnabled: Bool
    public var sshHost: String?
    public var sshPort: Int?
    public var sshUsername: String?
    public var sshKeyPath: String?

    public var createdAt: Date
    /// Whether executed statements are logged to query history (ED-06).
    public var historyEnabled: Bool

    public init(
        id: UUID = UUID(),
        driverID: String,
        name: String,
        groupName: String? = nil,
        envColor: String? = nil,
        sortOrder: Int = 0,
        filePath: String? = nil,
        host: String? = nil,
        port: Int? = nil,
        username: String? = nil,
        database: String? = nil,
        tlsMode: String = TLSMode.prefer.rawValue,
        tlsCACertPath: String? = nil,
        tlsClientCertPath: String? = nil,
        tlsClientKeyPath: String? = nil,
        mongoAdditionalHosts: String? = nil,
        mongoReplicaSet: String? = nil,
        elasticsearchAPIKeyEnabled: Bool = false,
        sshEnabled: Bool = false,
        sshHost: String? = nil,
        sshPort: Int? = nil,
        sshUsername: String? = nil,
        sshKeyPath: String? = nil,
        createdAt: Date = Date(),
        historyEnabled: Bool = true
    ) {
        self.id = id
        self.driverID = driverID
        self.name = name
        self.groupName = groupName
        self.envColor = envColor
        self.sortOrder = sortOrder
        self.filePath = filePath
        self.host = host
        self.port = port
        self.username = username
        self.database = database
        self.tlsMode = tlsMode
        self.tlsCACertPath = tlsCACertPath
        self.tlsClientCertPath = tlsClientCertPath
        self.tlsClientKeyPath = tlsClientKeyPath
        self.mongoAdditionalHosts = mongoAdditionalHosts
        self.mongoReplicaSet = mongoReplicaSet
        self.elasticsearchAPIKeyEnabled = elasticsearchAPIKeyEnabled
        self.sshEnabled = sshEnabled
        self.sshHost = sshHost
        self.sshPort = sshPort
        self.sshUsername = sshUsername
        self.sshKeyPath = sshKeyPath
        self.createdAt = createdAt
        self.historyEnabled = historyEnabled
    }

    public var driver: DriverID? { DriverID(rawValue: driverID) }

    /// Assemble the runtime config — secrets are passed separately from the
    /// Keychain, in RAM (docs/architecture/07 §2).
    public func makeConfig(
        password: String?,
        sshPassword: String? = nil,
        sshPassphrase: String? = nil,
        elasticsearchAPIKey: String? = nil
    ) -> ConnectionConfig {
        var ssh: SSHConfig?
        if sshEnabled, let sshHost, let sshUsername {
            ssh = SSHConfig(
                host: sshHost,
                port: sshPort ?? 22,
                username: sshUsername,
                password: sshPassword,
                privateKeyPath: sshKeyPath,
                keyPassphrase: sshPassphrase
            )
        }
        // DynamoDB has no username/password/database — the connection sheet
        // reuses those three fields (relabeled) for AWS SigV4 credentials
        // rather than adding a parallel set of profile columns/Keychain kind
        // for one driver (docs/architecture/12 §4 "AWS credentials" secret
        // type, simplified: Access Key ID/Secret/Region instead of a new
        // ConnectionProfile field + KeychainService.SecretKind).
        let isDynamoDB = driver == .dynamodb
        // "host:port, host:port" -> ["host:port", "host:port"] — empty/blank
        // entries dropped, nil (not []) when nothing usable remains so
        // `ConnectionConfig.additionalHosts == nil` stays the "single seed"
        // steady state every non-Mongo driver already expects.
        let parsedAdditionalHosts: [String]? = mongoAdditionalHosts.flatMap { raw in
            let hosts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return hosts.isEmpty ? nil : hosts
        }
        return ConnectionConfig(
            driver: driver ?? .sqlite,
            name: name,
            filePath: filePath,
            host: host,
            port: port,
            username: isDynamoDB ? nil : username,
            password: isDynamoDB ? nil : password,
            database: isDynamoDB ? nil : database,
            tlsMode: TLSMode(rawValue: tlsMode) ?? .prefer,
            caCertPath: tlsCACertPath,
            clientCertPath: tlsClientCertPath,
            clientKeyPath: tlsClientKeyPath,
            ssh: ssh,
            awsAccessKeyID: isDynamoDB ? username : nil,
            awsSecretAccessKey: isDynamoDB ? password : nil,
            awsRegion: isDynamoDB ? database : nil,
            additionalHosts: driver == .mongodb ? parsedAdditionalHosts : nil,
            mongoReplicaSet: driver == .mongodb ? mongoReplicaSet : nil,
            elasticsearchAPIKey: (driver == .elasticsearch && elasticsearchAPIKeyEnabled) ? elasticsearchAPIKey : nil
        )
    }
}

extension ConnectionProfile: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "connection_profile"
}
