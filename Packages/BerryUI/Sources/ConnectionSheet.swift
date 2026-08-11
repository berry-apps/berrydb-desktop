import BerryCore
import BerryDriverKit
import BerryStore
import SwiftUI
import UniformTypeIdentifiers

/// Create/edit a connection profile (KN-01) with TLS mode (KN-04), SSH tunnel
/// (KN-03) and a test-connection action (KN-06). Secrets never touch the
/// profile struct — they travel separately as `ConnectionSecrets` so the
/// caller stores them in the Keychain (07 §2).
///
/// Sizing follows UD-07: the sheet grows with its content and never scrolls.
public struct ConnectionSheet: View {
    public enum TestState: Equatable {
        case idle
        case testing
        case done(ConnectionTestReport)
    }

    /// Two-step flow (KN-01): pick the connection type first, then configure
    /// it — replaces the old single-screen layout's top row of type buttons,
    /// which got cramped as the driver count grew past what a fixed-width
    /// row could show clearly. Editing an existing profile skips straight to
    /// `.configure` (the type is already set; re-picking it isn't the normal
    /// edit flow) — only a brand-new connection starts at `.chooseType`.
    private enum SheetStep {
        case chooseType
        case configure
    }

    /// Elasticsearch auth mode (docs/architecture/17 §3): self-hosted
    /// clusters default to Basic, Elastic Cloud/Serverless pushes/requires
    /// API keys — both real, not a v1-only placeholder.
    private enum ElasticsearchAuthMode {
        case basic, apiKey
    }

    @Environment(\.dismiss) private var dismiss

    @State private var driverID: DriverID
    @State private var name: String
    @State private var groupName: String
    @State private var isProduction: Bool
    @State private var historyEnabled: Bool
    @State private var filePath: String
    @State private var host: String
    @State private var port: String
    @State private var username: String
    @State private var password: String
    @State private var database: String
    @State private var tlsMode: TLSMode
    @State private var tlsCACertPath: String
    @State private var tlsClientCertPath: String
    @State private var tlsClientKeyPath: String
    /// Mongo-only replica-set seeds beyond Host/Port (docs/architecture/12
    /// §3, v1) — comma-separated "host:port" entries.
    @State private var mongoAdditionalHosts: String
    @State private var mongoReplicaSetName: String
    @State private var elasticsearchAuthMode: ElasticsearchAuthMode
    @State private var elasticsearchAPIKey: String
    @State private var sshEnabled: Bool
    @State private var sshHost: String
    @State private var sshPort: String
    @State private var sshUsername: String
    @State private var sshPassword: String
    @State private var sshKeyPath: String
    @State private var sshPassphrase: String
    @State private var testState: TestState = .idle
    @State private var step: SheetStep
    /// Mongo-only "paste a URI" convenience (task 3, `docs/draft/mongodb.md`)
    /// — unidirectional: parsing fills Host/Port/Username/Password/Database/TLS
    /// once, it doesn't keep syncing with them afterwards.
    @State private var mongoURIInput: String = ""
    @State private var mongoURIError: String?

    private let existing: ConnectionProfile?
    private let availableDrivers: [DriverID]
    private let onTest: (ConnectionConfig) async -> ConnectionTestReport
    private let onSave: (ConnectionProfile, ConnectionSecrets) -> Void

    public init(
        profile: ConnectionProfile? = nil,
        availableDrivers: [DriverID],
        onTest: @escaping (ConnectionConfig) async -> ConnectionTestReport,
        onSave: @escaping (ConnectionProfile, ConnectionSecrets) -> Void
    ) {
        self.existing = profile
        let preferredOrder: [DriverID] = [.mysql, .postgres]
        let sorted = availableDrivers.sorted { a, b in
            let aIndex = preferredOrder.firstIndex(of: a) ?? 999
            let bIndex = preferredOrder.firstIndex(of: b) ?? 999
            if aIndex != bIndex { return aIndex < bIndex }
            return a.rawValue < b.rawValue
        }
        self.availableDrivers = sorted
        self.onTest = onTest
        self.onSave = onSave
        _driverID = State(initialValue: profile?.driver ?? sorted.first ?? .mysql)
        _name = State(initialValue: profile?.name ?? "")
        _groupName = State(initialValue: profile?.groupName ?? "")
        _isProduction = State(initialValue: profile?.envColor == "production")
        _historyEnabled = State(initialValue: profile?.historyEnabled ?? true)
        _filePath = State(initialValue: profile?.filePath ?? "")
        _host = State(initialValue: profile?.host ?? "localhost")
        _port = State(initialValue: profile?.port.map(String.init) ?? "")
        _username = State(initialValue: profile?.username ?? "")
        _password = State(initialValue: "")
        _database = State(initialValue: profile?.database ?? "")
        _tlsMode = State(initialValue: profile.flatMap { TLSMode(rawValue: $0.tlsMode) } ?? .prefer)
        _tlsCACertPath = State(initialValue: profile?.tlsCACertPath ?? "")
        _tlsClientCertPath = State(initialValue: profile?.tlsClientCertPath ?? "")
        _tlsClientKeyPath = State(initialValue: profile?.tlsClientKeyPath ?? "")
        _mongoAdditionalHosts = State(initialValue: profile?.mongoAdditionalHosts ?? "")
        _mongoReplicaSetName = State(initialValue: profile?.mongoReplicaSet ?? "")
        // Never pre-filled (like `password` above) — "empty means keep
        // stored". The MODE, unlike the secret, is a real persisted profile
        // field (`elasticsearchAPIKeyEnabled`, same pattern as `sshEnabled`),
        // so editing an existing API-key connection opens on the right tab.
        _elasticsearchAPIKey = State(initialValue: "")
        _elasticsearchAuthMode = State(initialValue: (profile?.elasticsearchAPIKeyEnabled ?? false) ? .apiKey : .basic)
        _sshEnabled = State(initialValue: profile?.sshEnabled ?? false)
        _sshHost = State(initialValue: profile?.sshHost ?? "")
        _sshPort = State(initialValue: profile?.sshPort.map(String.init) ?? "")
        _sshUsername = State(initialValue: profile?.sshUsername ?? "")
        _sshPassword = State(initialValue: "")
        _sshKeyPath = State(initialValue: profile?.sshKeyPath ?? "")
        _sshPassphrase = State(initialValue: "")
        _step = State(initialValue: profile == nil ? .chooseType : .configure)
    }

    private var isFileBased: Bool { driverID == .sqlite }

    private var defaultPort: Int {
        switch driverID {
        case .postgres: 5432
        case .mysql: 3306
        case .redis: 6379
        case .sqlserver: 1433
        case .mongodb: 27017
        case .qdrant: 6333
        case .elasticsearch: 9200
        case .dynamodb: 443
        case .sqlite: 0
        }
    }


    public var body: some View {
        Group {
            switch step {
            case .chooseType:
                typeSelectionStep
            case .configure:
                configureStep
            }
        }
        .frame(width: 540, height: 660)
        .animation(.default, value: sshEnabled)
        .animation(.default, value: step)
    }

    /// Step 1 (new connections only, see `SheetStep`): a type grid instead
    /// of the old cramped top row — `.adaptive` reflows automatically as
    /// more driver types are added, no hardcoded column count to revisit.
    private var typeSelectionStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("New Connection")).font(.title2).fontWeight(.semibold)
            Text(L("Choose a connection type to continue.")).font(.callout).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                ForEach(availableDrivers, id: \.self) { id in
                    Button {
                        driverID = id
                        // The Database field becomes a 0-15 Picker for
                        // Redis (below) — seed a valid selection so it
                        // doesn't render on an unmatched "" tag.
                        if id == .redis && database.isEmpty { database = "0" }
                        step = .configure
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: systemImage(for: id))
                                .font(.title2)
                                .frame(height: 26)
                            Text(displayName(for: id))
                                .font(.callout)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .padding(.horizontal, 8)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                }
            }
            Spacer()
            HStack {
                Spacer()
                Button(L("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
    }

    /// Step 2: today's config form, prefixed with a small header showing the
    /// chosen type — a back chevron only when creating new (`existing ==
    /// nil`); editing never shows it, since re-picking the type mid-edit
    /// isn't the normal flow (see `SheetStep`).
    private var typeHeader: some View {
        HStack(spacing: 8) {
            if existing == nil {
                Button {
                    step = .chooseType
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help(L("Change connection type"))
            }
            Image(systemName: systemImage(for: driverID))
                .foregroundStyle(.secondary)
            Text(displayName(for: driverID)).fontWeight(.medium)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var configureStep: some View {
        VStack(spacing: 0) {
            typeHeader
            Divider()
            TabView {
                Form {
                    Section {
                        TextField(L("Connection name"), text: $name, prompt: Text(placeholderName))
                        TextField(L("Group (optional)"), text: $groupName, prompt: Text(L("e.g. Production, Staging")))
                    }

                if isFileBased {
                    Section(L("File")) {
                        HStack {
                            TextField(L("File path"), text: $filePath)
                                .truncationMode(.middle)
                            Button(L("Choose…")) { pickFile(into: $filePath, updateName: true) }
                        }
                    }
                } else {
                    Section(L("Server")) {
                        // Navicat-inspired convenience (docs/draft/mongodb.md):
                        // paste a mongodb:// URI to fill the fields below in
                        // one shot — unidirectional, not a live sync.
                        if driverID == .mongodb {
                            HStack {
                                TextField(
                                    L("Connection URI"), text: $mongoURIInput,
                                    prompt: Text(verbatim: "mongodb://user:pass@host:port/database")
                                )
                                Button(L("Parse")) { parseMongoURI() }
                                    .disabled(mongoURIInput.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                            if let mongoURIError {
                                Label(mongoURIError, systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                        TextField(L("Host"), text: $host)
                        TextField(L("Port"), text: $port, prompt: Text(verbatim: "\(defaultPort)"))
                        // Elasticsearch genuinely needs a mode switch, not a
                        // password-reuse hack: self-hosted defaults to Basic,
                        // Elastic Cloud/Serverless pushes/requires API keys
                        // (docs/architecture/17 §3).
                        if driverID == .elasticsearch {
                            Picker(L("Authentication"), selection: $elasticsearchAuthMode) {
                                Text(L("Username & Password")).tag(ElasticsearchAuthMode.basic)
                                Text(L("API Key")).tag(ElasticsearchAuthMode.apiKey)
                            }
                            .pickerStyle(.segmented)
                        }
                        if driverID == .elasticsearch && elasticsearchAuthMode == .apiKey {
                            SecureField(
                                L("API Key"), text: $elasticsearchAPIKey,
                                prompt: existing == nil ? nil : Text(L("(keep saved API key)"))
                            )
                            Label(
                                L("An already-encoded key, e.g. the \"encoded\" field from Elastic's Create API key response — sent as \"Authorization: ApiKey <value>\"."),
                                systemImage: "info.circle"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        } else {
                            // DynamoDB has no username/password/database — reuses these
                            // same three fields (relabeled) for AWS SigV4 credentials
                            // instead of adding a parallel set of Keychain/profile
                            // columns just for one driver (docs/architecture/12 §4,
                            // ConnectionProfile.makeConfig does the field mapping).
                            TextField(driverID == .dynamodb ? L("Access Key ID") : L("Username"), text: $username)
                            // Qdrant auth is a single API-key header, not a
                            // user/password pair — reuses the Password field
                            // (relabeled) rather than adding a parallel secret
                            // shape for one driver (docs/architecture/12 §5,
                            // `QdrantHTTPClient` reads `config.password` as the key).
                            SecureField(
                                driverID == .dynamodb ? L("Secret Access Key")
                                    : (driverID == .qdrant ? L("API Key") : L("Password")),
                                text: $password,
                                prompt: existing == nil ? nil : Text(L("(keep saved password)"))
                            )
                        }
                        // Redis has no free-text database name — a numbered
                        // index 0-15 (docs/architecture/15 §3). Still just the
                        // `database` String field underneath (`RedisConnection`
                        // already parses it as `Int`) — only the control
                        // differs, matching the relabel-not-duplicate pattern
                        // this file already uses for DynamoDB/Qdrant.
                        if driverID == .redis {
                            Picker(L("Database"), selection: $database) {
                                ForEach(0..<16, id: \.self) { index in
                                    Text(verbatim: "\(index)").tag(String(index))
                                }
                            }
                        } else {
                            TextField(driverID == .dynamodb ? L("Region (optional, default us-east-1)") : L("Database"), text: $database)
                        }
                        if driverID == .dynamodb {
                            Label(
                                L("For dynamodb-local or a self-hosted endpoint, set Host/Port (any non-empty access key/secret works). For real AWS, leave Host empty and set Region."),
                                systemImage: "info.circle"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        if driverID == .redis {
                            Label(
                                L("Username/Password are optional ACL credentials (Redis 6+). Leave both empty for a server with no auth."),
                                systemImage: "info.circle"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        // Replica set v1 (docs/architecture/12 §3): Host/Port
                        // above stay the primary seed; these add seed members
                        // 2+. All reads/writes still go to the primary the
                        // driver finds at connect time — no secondary routing.
                        if driverID == .mongodb {
                            TextField(
                                L("Additional hosts (comma-separated host:port, optional)"),
                                text: $mongoAdditionalHosts,
                                prompt: Text(verbatim: "host2:27017, host3:27017")
                            )
                            TextField(L("Replica Set name (optional)"), text: $mongoReplicaSetName)
                        }
                    }
                    }

                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 10) {
                                Button(L("Test Connection")) {
                                    guard testState != .testing else { return }
                                    testState = .testing
                                    Task { await runTest() }
                                }
                                .disabled(testState == .testing)
                                if testState == .testing {
                                    ProgressView().controlSize(.small)
                                }
                                Spacer()
                            }
                            if case .done(let report) = testState {
                                testBreakdown(report)
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                .tabItem { Text(L("General")) }
                Form {
                    Section(L("Behavior")) {
                        Toggle(L("Production environment (warn on writes)"), isOn: $isProduction)
                        Toggle(L("Log queries to history"), isOn: $historyEnabled)
                    }
                }
                .formStyle(.grouped)
                .tabItem { Text(L("Advanced")) }

                if !isFileBased {
                    // Split out of General (UD-07: sheets never scroll) — the
                    // TLS block alone can run to 7 rows once Verify
                    // Certificate is picked (mode + warning + CA row + CA
                    // info + client cert row + client key row), which was
                    // pushing General past the fixed 600pt sheet height.
                    // Mirrors the existing SSH Tunnel tab's own split.
                    Form {
                        Section {
                            Picker(L("TLS"), selection: $tlsMode) {
                                Text(L("Off")).tag(TLSMode.disable)
                                Text(L("Prefer (no verify)")).tag(TLSMode.prefer)
                                Text(L("Require (no verify)")).tag(TLSMode.require)
                                Text(L("Verify CA (skip hostname)")).tag(TLSMode.verifyCA)
                                Text(L("Verify certificate")).tag(TLSMode.verifyFull)
                            }
                            // 07 §4: prefer/require encrypt but don't authenticate
                            // the server — spell that out so it isn't mistaken
                            // for "secure".
                            if tlsMode == .prefer || tlsMode == .require {
                                Label(
                                    L("Encrypted, but the server's certificate isn't checked. Use “Verify certificate” for production."),
                                    systemImage: "exclamationmark.shield"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            // KN-04: a custom CA is optional — empty means the
                            // system trust store; a PEM file covers
                            // self-signed/private CAs.
                            if tlsMode.verifiesCertificate {
                                HStack {
                                    TextField(L("CA certificate (optional)"), text: $tlsCACertPath)
                                        .truncationMode(.middle)
                                    Button(L("Choose…")) { pickCACert() }
                                }
                                Label(
                                    L("Leave empty to use the system trust store, or pick a PEM file for a self-signed or private-CA server."),
                                    systemImage: "info.circle"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            // KN-04 mutual TLS: optional client certificate + key
                            // (PEM paths; both required to take effect).
                            if tlsMode != .disable {
                                HStack {
                                    TextField(L("Client certificate (optional)"), text: $tlsClientCertPath)
                                        .truncationMode(.middle)
                                    Button(L("Choose…")) { pickPEM(into: $tlsClientCertPath) }
                                }
                                if !tlsClientCertPath.isEmpty {
                                    HStack {
                                        TextField(L("Client key"), text: $tlsClientKeyPath)
                                            .truncationMode(.middle)
                                        Button(L("Choose…")) { pickPEM(into: $tlsClientKeyPath) }
                                    }
                                }
                            }
                        }
                    }
                    .formStyle(.grouped)
                    .tabItem { Text(L("TLS")) }

                    Form {
                        Section(L("SSH Configuration")) {
                            Toggle(L("Connect through SSH tunnel"), isOn: $sshEnabled)
                            TextField(L("SSH host"), text: $sshHost)
                                .onChange(of: sshHost) { _, newValue in
                                    if !newValue.isEmpty && !sshEnabled {
                                        sshEnabled = true
                                    }
                                }
                            TextField(L("SSH port"), text: $sshPort, prompt: Text(verbatim: "22"))
                            TextField(L("SSH username"), text: $sshUsername)
                            SecureField(L("SSH password"), text: $sshPassword,
                                        prompt: existing == nil ? nil : Text(L("(keep saved password)")))
                            HStack {
                                TextField(L("Private key (optional)"), text: $sshKeyPath)
                                    .truncationMode(.middle)
                                Button(L("Choose…")) { pickKeyFile() }
                            }
                            if !sshKeyPath.isEmpty {
                                SecureField(L("Key passphrase"), text: $sshPassphrase)
                            }
                        }
                    }
                    .formStyle(.grouped)
                    .tabItem { Text(L("SSH Tunnel")) }
                }
            }
            .focusable(false)
            .focusEffectDisabled()
            // docs/ui/02 §6: bordered fields so it's obvious where to type
            .textFieldStyle(.roundedBorder)

            Divider()
            HStack {
                Spacer()
                Button(L("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(existing == nil ? L("Save Connection") : L("Update")) {
                    onSave(builtProfile(), typedSecrets())
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
            .padding(12)
        }
        // Fixed size on the outer `body` (UD-07: sheets never scroll) — even
        // after splitting TLS into its own tab, General's tallest driver
        // variants (Redis: Database picker + ACL info label; Mongo: URI
        // paste row + Additional hosts + Replica Set) still overflowed 600
        // by roughly a row, confirmed visually rather than assumed.
    }

    private var isValid: Bool {
        if isFileBased { return !filePath.isEmpty }
        if host.isEmpty { return false }
        if sshEnabled && (sshHost.isEmpty || sshUsername.isEmpty) { return false }
        return true
    }

    private var placeholderName: String {
        if isFileBased {
            return filePath.isEmpty ? L("New connection") : (filePath as NSString).lastPathComponent
        }
        return host.isEmpty ? L("New connection") : "\(username.isEmpty ? "" : "\(username)@")\(host)"
    }

    private func displayName(for id: DriverID) -> String {
        switch id {
        case .sqlite: "SQLite"
        case .postgres: "PostgreSQL"
        case .mysql: "MySQL / MariaDB"
        case .redis: "Redis"
        case .sqlserver: "SQL Server"
        case .mongodb: "MongoDB"
        case .qdrant: "Qdrant"
        case .elasticsearch: "Elasticsearch"
        case .dynamodb: "DynamoDB"
        }
    }

    private func shortName(for id: DriverID) -> String {
        switch id {
        case .sqlite: "SQLite"
        case .postgres: "PostgreSQL"
        case .mysql: "MySQL"
        case .redis: "Redis"
        case .sqlserver: "SQL Server"
        case .mongodb: "MongoDB"
        case .qdrant: "Qdrant"
        case .elasticsearch: "Elasticsearch"
        case .dynamodb: "DynamoDB"
        }
    }

    private func systemImage(for id: DriverID) -> String {
        switch id {
        case .sqlite: "internaldrive"
        case .postgres: "cylinder.split.1x2"
        case .mysql: "cylinder"
        case .redis: "memorychip"
        case .sqlserver: "server.rack"
        case .mongodb: "leaf"
        case .qdrant: "point.3.filled.connected.trianglepath.dotted"
        case .elasticsearch: "magnifyingglass"
        case .dynamodb: "bolt.horizontal"
        }
    }

    /// Splits "host:port" apart when the Host field's suffix after its LAST
    /// colon is purely numeric — always a port, never a valid hostname/IPv4
    /// octet. Doesn't attempt to handle bracket-less IPv6 literals (also not
    /// otherwise supported by the HTTP-based drivers' plain `host` field).
    static func splitHostPort(_ raw: String) -> (host: String, port: Int?) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let colonIndex = trimmed.lastIndex(of: ":") else { return (trimmed, nil) }
        let hostPart = String(trimmed[trimmed.startIndex..<colonIndex])
        let portPart = String(trimmed[trimmed.index(after: colonIndex)...])
        guard !hostPart.isEmpty, let port = Int(portPart) else { return (trimmed, nil) }
        return (hostPart, port)
    }

    /// Fills Host/Port/Username/Password/Database/TLS from `mongoURIInput`
    /// (task 3, `docs/draft/mongodb.md`). Only overwrites a field the URI
    /// actually specified — e.g. an auth-less URI leaves a previously typed
    /// Username/Password alone rather than clearing it.
    private func parseMongoURI() {
        switch MongoConnectionURI.parse(mongoURIInput) {
        case .success(let fields):
            host = fields.host
            port = String(fields.port)
            if let parsedUsername = fields.username { username = parsedUsername }
            if let parsedPassword = fields.password { password = parsedPassword }
            if let parsedDatabase = fields.database { database = parsedDatabase }
            if let parsedTLSMode = fields.tlsMode { tlsMode = parsedTLSMode }
            if !fields.additionalHosts.isEmpty { mongoAdditionalHosts = fields.additionalHosts.joined(separator: ", ") }
            if let parsedReplicaSet = fields.replicaSet { mongoReplicaSetName = parsedReplicaSet }
            mongoURIError = nil
        case .failure(let error):
            mongoURIError = error.message
        }
    }

    private func builtProfile() -> ConnectionProfile {
        var profile = existing ?? ConnectionProfile(driverID: driverID.rawValue, name: "")
        profile.driverID = driverID.rawValue
        profile.name = name.isEmpty ? placeholderName : name
        profile.groupName = groupName.trimmingCharacters(in: .whitespaces).isEmpty
            ? nil : groupName.trimmingCharacters(in: .whitespaces)
        profile.envColor = isProduction ? "production" : nil
        profile.historyEnabled = historyEnabled
        profile.filePath = isFileBased ? filePath : nil
        // A combined "host:port" pasted into Host (e.g. copied from a
        // BERRYDB_TEST_* env var / Tests/docker/compose.yml, which uses that
        // format) isn't a valid hostname — it breaks URL construction in the
        // HTTP-based drivers (Dynamo/Qdrant) with an opaque "Invalid
        // host/port". Split it apart here so that mistake just works.
        let (normalizedHost, embeddedPort) = Self.splitHostPort(host)
        profile.host = isFileBased ? nil : normalizedHost
        profile.port = isFileBased ? nil : (Int(port.trimmingCharacters(in: .whitespaces)) ?? embeddedPort ?? defaultPort)
        // Trimmed: these are structural fields (identifiers/region), never
        // meaningfully whitespace-sensitive — unlike password/secret below,
        // which is left as-typed since a real secret could contain spaces.
        let trimmedUsername = username.trimmingCharacters(in: .whitespaces)
        let trimmedDatabase = database.trimmingCharacters(in: .whitespaces)
        profile.username = isFileBased ? nil : (trimmedUsername.isEmpty ? nil : trimmedUsername)
        profile.database = isFileBased ? nil : (trimmedDatabase.isEmpty ? nil : trimmedDatabase)
        profile.tlsMode = tlsMode.rawValue
        profile.tlsCACertPath = (tlsMode.verifiesCertificate && !tlsCACertPath.isEmpty)
            ? tlsCACertPath : nil
        profile.tlsClientCertPath = (tlsMode != .disable && !tlsClientCertPath.isEmpty)
            ? tlsClientCertPath : nil
        profile.tlsClientKeyPath = (tlsMode != .disable && !tlsClientKeyPath.isEmpty)
            ? tlsClientKeyPath : nil
        let trimmedAdditionalHosts = mongoAdditionalHosts.trimmingCharacters(in: .whitespaces)
        let trimmedReplicaSet = mongoReplicaSetName.trimmingCharacters(in: .whitespaces)
        profile.mongoAdditionalHosts = (driverID == .mongodb && !trimmedAdditionalHosts.isEmpty) ? trimmedAdditionalHosts : nil
        profile.mongoReplicaSet = (driverID == .mongodb && !trimmedReplicaSet.isEmpty) ? trimmedReplicaSet : nil
        profile.elasticsearchAPIKeyEnabled = driverID == .elasticsearch && elasticsearchAuthMode == .apiKey
        profile.sshEnabled = !isFileBased && sshEnabled
        profile.sshHost = sshEnabled ? sshHost : nil
        profile.sshPort = sshEnabled ? (Int(sshPort) ?? 22) : nil
        profile.sshUsername = sshEnabled ? sshUsername : nil
        profile.sshKeyPath = sshEnabled && !sshKeyPath.isEmpty ? sshKeyPath : nil
        return profile
    }

    private func typedSecrets() -> ConnectionSecrets {
        ConnectionSecrets(
            dbPassword: password.isEmpty ? nil : password,
            sshPassword: sshPassword.isEmpty ? nil : sshPassword,
            sshPassphrase: sshPassphrase.isEmpty ? nil : sshPassphrase,
            elasticsearchAPIKey: elasticsearchAPIKey.isEmpty ? nil : elasticsearchAPIKey
        )
    }

    private func builtConfig() -> ConnectionConfig {
        // Prefer freshly typed secrets; fall back to stored ones when editing
        // (Keychain stays the single access point — docs/architecture/07 §2).
        func effective(_ typed: String, _ kind: KeychainService.SecretKind) -> String? {
            if !typed.isEmpty { return typed }
            guard let existing else { return nil }
            return KeychainService.readPassword(kind: kind, profileID: existing.id)
        }
        // `makeConfig` itself gates on `elasticsearchAPIKeyEnabled` (set by
        // `builtProfile()` above from the current mode), same as it gates
        // `SSHConfig` on `sshEnabled` — switching back to Basic actually
        // stops sending a previously stored key, not just hiding the field.
        return builtProfile().makeConfig(
            password: effective(password, .database),
            sshPassword: effective(sshPassword, .ssh),
            sshPassphrase: effective(sshPassphrase, .sshPassphrase),
            elasticsearchAPIKey: effective(elasticsearchAPIKey, .elasticsearchAPIKey)
        )
    }

    private func runTest() async {
        testState = .done(await onTest(builtConfig()))
    }

    /// Per-step result list for the last test (KN-06).
    @ViewBuilder
    private func testBreakdown(_ report: ConnectionTestReport) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(report.steps) { result in
                HStack(spacing: 6) {
                    Image(systemName: result.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(result.passed ? .green : .red)
                    Text(stepLabel(result.step))
                    Spacer()
                    Text(verbatim: String(format: "%.0f ms", result.seconds * 1000))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.caption)
            }
            if let error = report.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .textSelection(.enabled)
            } else {
                Label(L("Connection successful"), systemImage: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
    }

    private func stepLabel(_ step: ConnectionTestReport.Step) -> String {
        switch step {
        case .tunnel: L("SSH tunnel")
        case .connect: L("Connect")
        case .ping: L("Ping")
        }
    }

    @MainActor
    private func pickFile(into binding: Binding<String>, updateName: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "sqlite"), UTType(filenameExtension: "db"),
            UTType(filenameExtension: "sqlite3"), UTType(filenameExtension: "db3"),
        ].compactMap(\.self)
        if panel.runModal() == .OK, let url = panel.url {
            binding.wrappedValue = url.path
            if updateName && name.isEmpty { name = url.lastPathComponent }
        }
    }

    @MainActor
    private func pickKeyFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            sshKeyPath = url.path
            if !sshEnabled { sshEnabled = true }
        }
    }

    @MainActor
    private func pickPEM(into binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            binding.wrappedValue = url.path
        }
    }

    @MainActor
    private func pickCACert() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.allowedContentTypes = [
            UTType(filenameExtension: "pem"), UTType(filenameExtension: "crt"),
            UTType(filenameExtension: "cer"), UTType(filenameExtension: "der"),
            .x509Certificate, .data,
        ].compactMap(\.self)
        if panel.runModal() == .OK, let url = panel.url {
            tlsCACertPath = url.path
        }
    }
}
