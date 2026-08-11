import BerryDriverKit
import Foundation
import Testing

@testable import BerryStore

@Suite("BerryStore profiles")
struct BerryStoreTests {
    private func makeStore() throws -> BerryStore {
        try BerryStore(path: ":memory:")
    }

    @Test func savesAndFetchesProfiles() throws {
        let store = try makeStore()
        let profile = ConnectionProfile(
            driverID: "postgres", name: "Local PG",
            host: "localhost", port: 5432, username: "dev", database: "app"
        )
        try store.save(profile)

        let all = try store.allProfiles()
        #expect(all.count == 1)
        #expect(all[0].name == "Local PG")
        #expect(all[0].driver == .postgres)
        #expect(all[0].port == 5432)
    }

    @Test func persistsTLSCACertPath() throws {
        let store = try makeStore()
        let profile = ConnectionProfile(
            driverID: "postgres", name: "PG TLS",
            host: "db.internal", port: 5432, username: "dev",
            tlsMode: TLSMode.verifyCA.rawValue,
            tlsCACertPath: "/etc/ssl/certs/internal-ca.pem"
        )
        try store.save(profile)

        let loaded = try #require(try store.allProfiles().first)
        #expect(loaded.tlsMode == TLSMode.verifyCA.rawValue)
        #expect(loaded.tlsCACertPath == "/etc/ssl/certs/internal-ca.pem")
        // KN-04: the CA path flows into the runtime config.
        #expect(loaded.makeConfig(password: nil).caCertPath == "/etc/ssl/certs/internal-ca.pem")
    }

    @Test func persistsClientCertPaths() throws {
        let store = try makeStore()
        let profile = ConnectionProfile(
            driverID: "mysql", name: "mTLS",
            host: "db", port: 3306,
            tlsClientCertPath: "/certs/client.pem",
            tlsClientKeyPath: "/certs/client.key"
        )
        try store.save(profile)
        let config = try #require(try store.allProfiles().first).makeConfig(password: nil)
        #expect(config.clientCertPath == "/certs/client.pem")
        #expect(config.clientKeyPath == "/certs/client.key")
    }

    @Test func persistsMongoReplicaSetFields() throws {
        // Replica-set v1 (docs/architecture/12 §3) — additive Mongo-only
        // fields, same pattern as tlsCACertPath.
        let store = try makeStore()
        let profile = ConnectionProfile(
            driverID: "mongodb", name: "RS",
            host: "seed0", port: 27017, database: "admin",
            mongoAdditionalHosts: "seed1:27017, seed2:27017",
            mongoReplicaSet: "berryrs"
        )
        try store.save(profile)

        let loaded = try #require(try store.allProfiles().first)
        #expect(loaded.mongoAdditionalHosts == "seed1:27017, seed2:27017")
        #expect(loaded.mongoReplicaSet == "berryrs")

        let config = loaded.makeConfig(password: nil)
        #expect(config.additionalHosts == ["seed1:27017", "seed2:27017"])
        #expect(config.mongoReplicaSet == "berryrs")
    }

    @Test func mongoReplicaSetFieldsAreNilForOtherDrivers() throws {
        // Only Mongo reads additionalHosts/mongoReplicaSet into the runtime
        // config — every other driver must stay unaffected even if the
        // profile row happens to carry stale values (e.g. after a driver
        // switch in the sheet).
        let store = try makeStore()
        let profile = ConnectionProfile(
            driverID: "postgres", name: "PG",
            host: "localhost", port: 5432,
            mongoAdditionalHosts: "seed1:27017",
            mongoReplicaSet: "berryrs"
        )
        try store.save(profile)
        let config = try #require(try store.allProfiles().first).makeConfig(password: nil)
        #expect(config.additionalHosts == nil)
        #expect(config.mongoReplicaSet == nil)
    }

    @Test func blankMongoAdditionalHostsBecomesNilInConfig() throws {
        let store = try makeStore()
        let profile = ConnectionProfile(
            driverID: "mongodb", name: "RS", host: "seed0", port: 27017,
            mongoAdditionalHosts: "  ,  "
        )
        try store.save(profile)
        let config = try #require(try store.allProfiles().first).makeConfig(password: nil)
        #expect(config.additionalHosts == nil)
    }

    @Test func persistsElasticsearchAPIKeyModeAndGatesTheSecret() throws {
        // Auth mode (docs/architecture/17 §3) is a persisted flag, same
        // pattern as `sshEnabled` gating `SSHConfig` — the secret itself
        // never lives on the profile (07 §2), only whether to use it.
        let store = try makeStore()
        let profile = ConnectionProfile(
            driverID: "elasticsearch", name: "ES Cloud",
            host: "my-cluster.es.io", port: 9243,
            elasticsearchAPIKeyEnabled: true
        )
        try store.save(profile)

        let loaded = try #require(try store.allProfiles().first)
        #expect(loaded.elasticsearchAPIKeyEnabled)

        let config = loaded.makeConfig(password: nil, elasticsearchAPIKey: "id:secret")
        #expect(config.elasticsearchAPIKey == "id:secret")
    }

    @Test func elasticsearchAPIKeyIsNilWhenModeIsBasicEvenIfAKeyIsSupplied() throws {
        // Switching back to Basic must actually stop sending a previously
        // stored key, not just hide the field — `elasticsearchAPIKeyEnabled`
        // gates it regardless of what the caller passes in.
        let store = try makeStore()
        let profile = ConnectionProfile(
            driverID: "elasticsearch", name: "ES Basic",
            host: "localhost", port: 9200, username: "elastic"
        )
        try store.save(profile)

        let loaded = try #require(try store.allProfiles().first)
        #expect(loaded.elasticsearchAPIKeyEnabled == false)

        let config = loaded.makeConfig(password: "changeme", elasticsearchAPIKey: "stale:key")
        #expect(config.elasticsearchAPIKey == nil)
        #expect(config.username == "elastic")
        #expect(config.password == "changeme")
    }

    @Test func elasticsearchAPIKeyIsNilForOtherDrivers() throws {
        let store = try makeStore()
        let profile = ConnectionProfile(
            driverID: "postgres", name: "PG",
            host: "localhost", port: 5432,
            elasticsearchAPIKeyEnabled: true
        )
        try store.save(profile)
        let config = try #require(try store.allProfiles().first)
            .makeConfig(password: nil, elasticsearchAPIKey: "id:secret")
        #expect(config.elasticsearchAPIKey == nil)
    }

    @Test func updatesInPlace() throws {
        let store = try makeStore()
        var profile = ConnectionProfile(driverID: "sqlite", name: "Demo", filePath: "/tmp/a.sqlite")
        try store.save(profile)
        profile.name = "Demo đổi tên"
        try store.save(profile)

        let all = try store.allProfiles()
        #expect(all.count == 1)
        #expect(all[0].name == "Demo đổi tên")
    }

    @Test func deletesProfile() throws {
        let store = try makeStore()
        let profile = ConnectionProfile(driverID: "sqlite", name: "Xóa tôi", filePath: "/tmp/x.sqlite")
        try store.save(profile)
        try store.deleteProfile(id: profile.id)
        #expect(try store.allProfiles().isEmpty)
    }

    @Test func ordersBySortOrderThenCreation() throws {
        let store = try makeStore()
        try store.save(ConnectionProfile(driverID: "sqlite", name: "B", sortOrder: 1, filePath: "/b"))
        try store.save(ConnectionProfile(driverID: "sqlite", name: "A", sortOrder: 0, filePath: "/a"))
        #expect(try store.allProfiles().map(\.name) == ["A", "B"])
    }

    @Test func savedQueryScopingByProfile() throws {
        let store = try makeStore()
        let profileA = UUID()
        let profileB = UUID()
        try store.saveSavedQuery(SavedQuery(profileID: profileA, name: "A count", sql: "SELECT count(*) FROM a"))
        try store.saveSavedQuery(SavedQuery(profileID: profileB, name: "B count", sql: "SELECT count(*) FROM b"))
        try store.saveSavedQuery(SavedQuery(profileID: nil, name: "Now", sql: "SELECT now()"))

        // Profile A sees its own + the global one, not B's.
        let forA = try store.savedQueries(profileID: profileA).map(\.name).sorted()
        #expect(forA == ["A count", "Now"])

        // Global-only scope hides both profile-scoped snippets.
        #expect(try store.savedQueries(profileID: nil).map(\.name) == ["Now"])
    }

    @Test func savedQueryUpdateAndDelete() throws {
        let store = try makeStore()
        var query = SavedQuery(profileID: nil, name: "Draft", sql: "SELECT 1")
        try store.saveSavedQuery(query)
        query.name = "Final"
        query.sql = "SELECT 2"
        try store.saveSavedQuery(query)

        let all = try store.savedQueries(profileID: nil)
        #expect(all.count == 1)
        #expect(all[0].name == "Final")
        #expect(all[0].sql == "SELECT 2")

        try store.deleteSavedQuery(id: query.id)
        #expect(try store.savedQueries(profileID: nil).isEmpty)
    }

    @Test func aiSettingRoundTripsAndUpdatesInPlace() throws {
        let store = try makeStore()
        let profileID = UUID()
        #expect(try store.aiSetting(profileID: profileID) == nil)

        try store.saveAISetting(AIConnectionSetting(
            profileID: profileID, aiEnabled: true, allowSampleRows: false,
            autoApproveSelects: true, consentGiven: true
        ))
        let loaded = try store.aiSetting(profileID: profileID)
        #expect(loaded?.aiEnabled == true)
        #expect(loaded?.consentGiven == true)
        #expect(loaded?.allowSampleRows == false)

        // Same profile key updates in place (one row per profile).
        try store.saveAISetting(AIConnectionSetting(
            profileID: profileID, aiEnabled: false, allowSampleRows: true,
            autoApproveSelects: false, consentGiven: true
        ))
        let updated = try store.aiSetting(profileID: profileID)
        #expect(updated?.aiEnabled == false)
        #expect(updated?.allowSampleRows == true)
    }

    @Test func configNeverContainsStoredPassword() throws {
        // Guarantees design 07 §2: the profile has nowhere to hold a password;
        // the config only receives a password via the runtime parameter.
        let profile = ConnectionProfile(
            driverID: "mysql", name: "m", host: "h", port: 3306, username: "u"
        )
        let config = profile.makeConfig(password: "bí-mật")
        #expect(config.password == "bí-mật")
        let mirror = Mirror(reflecting: profile)
        #expect(!mirror.children.contains { "\($0.label ?? "")".lowercased().contains("password") })
    }
}
