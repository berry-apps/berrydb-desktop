import Foundation
import Testing

@testable import BerryDriverKit

@Suite("Read-only connection contract")
struct ReadOnlyContractTests {
    /// The card that replaces an automatic run shows this text, so it has to
    /// carry the server's own reason.
    @Test func readOnlyUnavailableCarriesTheReason() {
        let error = DriverError.readOnlyUnavailable("BEGIN refused by the pooler")
        let text = error.localizedDescription
        #expect(text.contains("BEGIN refused by the pooler"))
        #expect(text.contains("Read-only"))
    }

    /// Every shipped language has the wrapper; a missing entry would show the
    /// English key inside a Vietnamese card.
    @Test func readOnlyUnavailableIsTranslated() throws {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Resources")
        for language in ["en", "vi"] {
            let strings = try String(
                contentsOf: resources.appendingPathComponent("\(language).lproj/Localizable.strings"), encoding: .utf8
            )
            #expect(strings.contains("\"Read-only mode unavailable: %@\" = "), "\(language).lproj has no entry")
        }
    }

    /// A connection opened through a session's SSH tunnel keeps the name it
    /// was given, so the server still lists it as the read-only connection.
    @Test func theApplicationNameSurvivesTheTunnelEndpoint() {
        let config = ConnectionConfig(
            driver: .postgres, name: "prod", host: "db.internal", port: 5432,
            username: "app", password: "secret", database: "shop", tlsMode: .verifyFull
        )
        let named = config.withApplicationName("BerryDB AI (read-only)")
        let tunneled = named.replacingEndpoint(host: "127.0.0.1", port: 61_000)

        #expect(config.applicationName == nil)
        #expect(named.applicationName == "BerryDB AI (read-only)")
        #expect(tunneled.applicationName == "BerryDB AI (read-only)")
        #expect(tunneled.host == "127.0.0.1")
        #expect(tunneled.port == 61_000)
    }

    @Test func namingAConnectionKeepsEveryOtherSetting() {
        let ssh = SSHConfig(host: "bastion", username: "ops")
        let config = ConnectionConfig(
            driver: .postgres, name: "prod", filePath: nil, host: "db", port: 6432,
            username: "app", password: "secret", database: "shop", tlsMode: .verifyCA,
            caCertPath: "/ca.pem", clientCertPath: "/client.pem", clientKeyPath: "/client.key", ssh: ssh,
            awsAccessKeyID: "AK", awsSecretAccessKey: "SK", awsSessionToken: "ST", awsRegion: "eu-west-1",
            additionalHosts: ["db2:6432"], mongoReplicaSet: "rs0", elasticsearchAPIKey: "key"
        )

        let named = config.withApplicationName("BerryDB AI (read-only)")

        #expect(named.driver == config.driver && named.name == config.name && named.filePath == config.filePath)
        #expect(named.host == "db" && named.port == 6432 && named.username == "app")
        #expect(named.password == "secret" && named.database == "shop" && named.tlsMode == .verifyCA)
        #expect(named.caCertPath == "/ca.pem" && named.clientCertPath == "/client.pem" && named.clientKeyPath == "/client.key")
        #expect(named.ssh?.host == "bastion" && named.ssh?.username == "ops")
        #expect(named.awsAccessKeyID == "AK" && named.awsSecretAccessKey == "SK")
        #expect(named.awsSessionToken == "ST" && named.awsRegion == "eu-west-1")
        #expect(named.additionalHosts == ["db2:6432"] && named.mongoReplicaSet == "rs0")
        #expect(named.elasticsearchAPIKey == "key")
    }
}

/// A connection with only the unparameterized read-only call, as several
/// test doubles are.
private actor UnparameterizedConnection: ReadOnlyExecuting {
    nonisolated let id = UUID()
    private(set) var ran: [String] = []

    func prepareReadOnly() async throws {}

    nonisolated func executeReadOnly(_ sql: String, timeout: Duration) -> AsyncThrowingStream<ResultEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await self.record(sql)
                continuation.yield(.complete(QueryStats(rowsAffected: nil, duration: .zero)))
                continuation.finish()
            }
        }
    }

    private func record(_ sql: String) { ran.append(sql) }
    nonisolated func execute(_ sql: String) -> AsyncThrowingStream<ResultEvent, Error> { .init { $0.finish() } }
    nonisolated func cancelCurrentQuery() {}
    func setDatabase(_ name: String) async throws {}
    nonisolated var introspector: any Introspector { fatalError("unused") }
    func ping() async -> Bool { true }
    func close() async {}
}

extension ReadOnlyContractTests {
    @Test func noParametersForwardToTheUnparameterizedRun() async throws {
        let connection = UnparameterizedConnection()
        for try await _ in connection.executeReadOnly("SELECT 1", parameters: [], timeout: .seconds(1)) {}
        #expect(await connection.ran == ["SELECT 1"])
    }

    /// A connection that cannot bind must never run the text with its
    /// placeholders unbound, which SQLite reads as NULL
    /// (https://www.sqlite.org/c3ref/bind_blob.html).
    @Test func parametersOnAConnectionThatCannotBindRunNothing() async {
        let connection = UnparameterizedConnection()
        let error = await #expect(throws: DriverError.self) {
            for try await _ in connection.executeReadOnly("SELECT ?", parameters: [.int(1)], timeout: .seconds(1)) {}
        }
        guard case .unsupported? = error else {
            Issue.record("expected unsupported, got \(String(describing: error))")
            return
        }
        #expect(await connection.ran.isEmpty)
    }
}
