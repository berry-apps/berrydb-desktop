import BerryDriverKit
import Foundation
import Testing

@testable import BerryTunnel

/// Public-key auth from OpenSSH private keys. Uses ssh-keygen to make
/// real keys of each type — no server needed, just key parsing.
@Suite("SSH key auth")
struct SSHKeyAuthTests {
    private func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "berry_ssh_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func generateKey(type: String, passphrase: String = "", into dir: String) throws -> String {
        let path = dir + "/" + type
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-t", type, "-N", passphrase, "-f", path, "-q"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return path
    }

    private func config(keyPath: String, passphrase: String? = nil) -> SSHConfig {
        SSHConfig(host: "bastion.example", port: 22, username: "deploy",
                  privateKeyPath: keyPath, keyPassphrase: passphrase)
    }

    @Test func acceptsEd25519RSAAndECDSAKeys() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

 // ECDSA parsing is our own — all three curves must load.
        for type in ["ed25519", "rsa", "ecdsa"] {
            let path = try generateKey(type: type, into: dir)
            #expect(throws: Never.self) {
                _ = try SSHTunnel.authMethod(for: config(keyPath: path))
            }
        }
    }

    @Test func ecdsaCurves384And521Parse() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        for bits in ["384", "521"] {
            let path = dir + "/ecdsa\(bits)"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
            process.arguments = ["-t", "ecdsa", "-b", bits, "-N", "", "-f", path, "-q"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            #expect(throws: Never.self) {
                _ = try SSHTunnel.authMethod(for: config(keyPath: path))
            }
        }
    }

    @Test func encryptedECDSAFailsWithAClearMessage() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = try generateKey(type: "ecdsa", passphrase: "s3cret", into: dir)

        var thrown: Error?
        do { _ = try SSHTunnel.authMethod(for: config(keyPath: path, passphrase: "s3cret")) }
        catch { thrown = error }

        let message = (thrown as? DriverError)?.errorDescription ?? ""
        #expect(message.contains("ECDSA"))
    }

    @Test func decryptsEncryptedKeyOnlyWithTheRightPassphrase() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = try generateKey(type: "ed25519", passphrase: "s3cret", into: dir)

        #expect(throws: Never.self) {
            _ = try SSHTunnel.authMethod(for: config(keyPath: path, passphrase: "s3cret"))
        }
        #expect(throws: (any Error).self) {
            _ = try SSHTunnel.authMethod(for: config(keyPath: path, passphrase: "wrong"))
        }
    }

    /// A classic PKCS1/PKCS8 PEM key (e.g. Oracle Cloud's downloadable .key
    /// file) — `-m PEM` forces ssh-keygen's old output format instead of the
    /// OpenSSH-format default, reproducing exactly what Citadel can't read.
    private func generatePEMKey(type: String, passphrase: String = "", into dir: String) throws -> String {
        let path = dir + "/" + type + "-pem"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-t", type, "-m", "PEM", "-N", passphrase, "-f", path, "-q"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return path
    }

    @Test func autoConvertsAClassicPEMRSAKeyToOpenSSHFormat() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = try generatePEMKey(type: "rsa", into: dir)

        let original = try String(contentsOfFile: path, encoding: .utf8)
        #expect(original.hasPrefix("-----BEGIN RSA PRIVATE KEY-----"), "test setup must actually produce the old PEM format")

        #expect(throws: Never.self) {
            _ = try SSHTunnel.authMethod(for: config(keyPath: path))
        }

        // The user's original file on disk must never be touched — only a
        // private temp copy is converted.
        let after = try String(contentsOfFile: path, encoding: .utf8)
        #expect(after == original, "the original key file on disk must not be modified")
    }

    @Test func autoConvertsAPassphraseProtectedPEMKeyAndPreservesThePassphrase() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = try generatePEMKey(type: "rsa", passphrase: "s3cret", into: dir)

        #expect(throws: Never.self) {
            _ = try SSHTunnel.authMethod(for: config(keyPath: path, passphrase: "s3cret"))
        }
        #expect(throws: (any Error).self) {
            _ = try SSHTunnel.authMethod(for: config(keyPath: path, passphrase: "wrong"))
        }
    }

    /// The key-format conversion shells out to ssh-keygen. Command-line arguments
    /// are readable by any process running as the same user, so a passphrase there
    /// is scrapeable with a `ps` loop — which would undo the Keychain protecting
    /// it everywhere else. It must travel through the environment instead, which
    /// `ps` does not expose.
    @Test func theConversionKeepsThePassphraseOffTheCommandLine() {
        let args = SSHTunnel.conversionArguments(keyPath: "/tmp/berry-test-key")

        #expect(args == ["-p", "-o", "-f", "/tmp/berry-test-key"])
        // -N and -P are the flags that carry a passphrase. Their absence is the
        // whole point; this is what fails if someone folds them back in.
        #expect(!args.contains("-N"), "-N puts the new passphrase in argv")
        #expect(!args.contains("-P"), "-P puts the old passphrase in argv")

        let env = SSHTunnel.conversionEnvironment(askpassPath: "/tmp/askpass.sh", passphrase: "s3cret")
        #expect(env[SSHTunnel.passphraseEnvKey] == "s3cret", "the passphrase must reach ssh-keygen somehow")
        #expect(env["SSH_ASKPASS"] == "/tmp/askpass.sh")
        #expect(env["SSH_ASKPASS_REQUIRE"] == "force", "without force, ssh-keygen ignores the helper when a TTY exists")
        #expect(!args.joined(separator: " ").contains("s3cret"))
    }
}
