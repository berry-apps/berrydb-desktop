import BerryDriverKit
import Foundation
import NIOSSL
import Testing

@testable import BerryDriverPostgres

/// TLS verification modes — pure config, no server needed.
@Suite("Postgres TLS config")
struct PostgresTLSConfigTests {
    @Test func verifyFullChecksTheHostname() {
        let tls = PostgresDriverConnection.verifyingTLS(mode: .verifyFull, caCertPath: nil)
        #expect(tls.certificateVerification == .fullVerification)
    }

    @Test func verifyCASkipsTheHostname() {
        let tls = PostgresDriverConnection.verifyingTLS(mode: .verifyCA, caCertPath: nil)
        #expect(tls.certificateVerification == .noHostnameVerification)
    }

    @Test func customCASetsAFileTrustRoot() {
        let custom = PostgresDriverConnection.verifyingTLS(mode: .verifyFull, caCertPath: "/tmp/ca.pem")
        if case .file(let path)? = custom.trustRoots {
            #expect(path == "/tmp/ca.pem")
        } else {
            Issue.record("a custom CA path should set a .file trust root")
        }
    }

 // mutual TLS: a real (openssl-generated) client cert + key load into
    // the certificate chain and private key.
    @Test func clientIdentityLoadsFromPEM() throws {
        let dir = NSTemporaryDirectory() + "berry_mtls_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let gen = Process()
        gen.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        gen.arguments = [
            "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
            "-keyout", dir + "/client.key", "-out", dir + "/client.pem",
            "-subj", "/CN=berry-test",
        ]
        gen.standardOutput = FileHandle.nullDevice
        gen.standardError = FileHandle.nullDevice
        try gen.run()
        gen.waitUntilExit()
        try #require(gen.terminationStatus == 0)

        var tls = PostgresDriverConnection.verifyingTLS(mode: .verifyFull, caCertPath: nil)
        let config = ConnectionConfig(
            driver: .postgres, name: "t", host: "db",
            clientCertPath: dir + "/client.pem", clientKeyPath: dir + "/client.key"
        )
        try PostgresDriverConnection.applyClientIdentity(&tls, config: config)
        #expect(!tls.certificateChain.isEmpty)
        #expect(tls.privateKey != nil)
    }
}
