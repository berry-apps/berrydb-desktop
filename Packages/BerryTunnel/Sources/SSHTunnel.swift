import BerryDriverKit
// Citadel's SSHClient predates strict concurrency; it is thread-safe in
// practice (NIO event-loop bound) — treat its Sendable gaps as warnings.
@preconcurrency import Citadel
import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// Dev-only tracing, enabled with BERRYDB_TUNNEL_DEBUG=1.
@inline(__always)
func tunnelTrace(_ message: @autoclosure () -> String) {
    if ProcessInfo.processInfo.environment["BERRYDB_TUNNEL_DEBUG"] != nil {
        FileHandle.standardError.write(Data("[tunnel] \(message())\n".utf8))
    }
}

/// SSH tunnel (KN-03, docs/architecture/06 · L1): connects to a bastion via
/// Citadel and exposes a local 127.0.0.1 port; every accepted local socket is
/// piped through an SSH direct-tcpip channel to the target host.
///
/// Host keys are pinned trust-on-first-use (docs/architecture/07 §4): the first
/// key seen for a bastion is recorded; a later mismatch hard-fails the connect
/// (`DriverError.sshHostKeyChanged`) as MITM protection.
public final class SSHTunnel: Sendable {
    private let client: SSHClient
    private let serverChannel: Channel

    /// Local endpoint drivers should connect to.
    public let localPort: Int

    private init(client: SSHClient, serverChannel: Channel, localPort: Int) {
        self.client = client
        self.serverChannel = serverChannel
        self.localPort = localPort
    }

    public static func open(
        _ ssh: SSHConfig,
        targetHost: String,
        targetPort: Int,
        knownHosts: KnownHostsStore = .standard()
    ) async throws -> SSHTunnel {
        let validator = TOFUHostKeyValidator(store: knownHosts, host: ssh.host, port: ssh.port)
        let client: SSHClient
        do {
            client = try await SSHClient.connect(
                host: ssh.host,
                port: ssh.port,
                authenticationMethod: try authMethod(for: ssh),
                hostKeyValidator: .custom(validator),
                reconnect: .never
            )
        } catch let error as DriverError {
            throw error
        } catch {
            // A host-key mismatch surfaces as a generic handshake failure; turn
            // it into the precise, actionable error (07 §4).
            if let mismatch = validator.mismatch {
                throw DriverError.sshHostKeyChanged(
                    host: ssh.host, port: ssh.port,
                    stored: mismatch.stored, presented: mismatch.presented
                )
            }
            throw DriverError.connectionFailed("SSH: \(error)")
        }

        // Local listener on an ephemeral port; each accepted connection gets
        // its own direct-tcpip channel glued to it. The local glue attaches
        // SYNCHRONOUSLY on accept (no autoRead games — early bytes are
        // buffered by the SSH-side glue until its channel opens).
        let bootstrap = ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { localChannel in
                tunnelTrace("accepted local connection, opening direct-tcpip…")
                let (localGlue, remoteGlue) = GlueHandler.matchedPair()
                localGlue.label = "local"
                remoteGlue.label = "ssh"
                do {
                    try localChannel.pipeline.syncOperations.addHandler(localGlue)
                } catch {
                    return localChannel.eventLoop.makeFailedFuture(error)
                }

                Task {
                    do {
                        let originator = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
                        _ = try await client.createDirectTCPIPChannel(
                            using: SSHChannelType.DirectTCPIP(
                                targetHost: targetHost,
                                targetPort: targetPort,
                                originatorAddress: originator
                            )
                        ) { channel in
                            // Citadel already installs its DataToBufferCodec on
                            // direct-tcpip channels — the child speaks raw
                            // ByteBuffer, so the glue attaches directly.
                            channel.pipeline.addHandler(remoteGlue)
                        }
                        tunnelTrace("direct-tcpip open, glue complete")
                    } catch {
                        tunnelTrace("direct-tcpip FAILED: \(error)")
                        localChannel.close(promise: nil)
                    }
                }
                return localChannel.eventLoop.makeSucceededVoidFuture()
            }

        let serverChannel: Channel
        do {
            serverChannel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        } catch {
            try? await client.close()
            throw DriverError.connectionFailed("SSH tunnel bind failed: \(error)")
        }
        guard let localPort = serverChannel.localAddress?.port else {
            try? await client.close()
            throw DriverError.connectionFailed("SSH tunnel has no local port")
        }
        return SSHTunnel(client: client, serverChannel: serverChannel, localPort: localPort)
    }

    public func close() async {
        try? await serverChannel.close()
        try? await client.close()
    }

    // MARK: - Authentication

    static func authMethod(for ssh: SSHConfig) throws -> SSHAuthenticationMethod {
        if let keyPath = ssh.privateKeyPath, !keyPath.isEmpty {
            let pem: String
            do {
                pem = try String(contentsOfFile: (keyPath as NSString).expandingTildeInPath, encoding: .utf8)
            } catch {
                throw DriverError.connectionFailed("SSH: cannot read private key at \(keyPath)")
            }
            return try keyAuth(pem: pem, ssh: ssh)
        }
        guard let password = ssh.password else {
            throw DriverError.connectionFailed("SSH: missing password or private key")
        }
        return .passwordBased(username: ssh.username, password: password)
    }

    /// Public-key auth from an OpenSSH private key (KN-04, 07 §4). ed25519 (the
    /// modern default) and RSA are supported; ECDSA can't be parsed by the SSH
    /// library yet, so it gets a clear message rather than a cryptic failure.
    static func keyAuth(pem: String, ssh: SSHConfig) throws -> SSHAuthenticationMethod {
        let passphrase = ssh.keyPassphrase.flatMap { $0.isEmpty ? nil : Data($0.utf8) }
        let pem = try normalizeToOpenSSH(pem, passphrase: ssh.keyPassphrase)

        let keyType: SSHKeyType
        do {
            keyType = try SSHKeyDetection.detectPrivateKeyType(from: pem)
        } catch {
            throw DriverError.connectionFailed(
                "SSH: unreadable private key — expected an OpenSSH key "
                    + "(begins with “-----BEGIN OPENSSH PRIVATE KEY-----”)"
            )
        }

        do {
            if keyType == .ed25519 {
                let key = try Curve25519.Signing.PrivateKey(sshEd25519: pem, decryptionKey: passphrase)
                return .ed25519(username: ssh.username, privateKey: key)
            } else if keyType == .rsa {
                let key = try Insecure.RSA.PrivateKey(sshRsa: pem, decryptionKey: passphrase)
                // rsa-sha2-512/256 (RFC 8332) first, falling back to legacy
                // ssh-rsa (SHA-1) — OpenSSH 8.8+ rejects ssh-rsa by default, so
                // plain .rsa(...) fails against any stock modern server (KN-03).
                return .rsaSHA2(username: ssh.username, privateKey: key)
            } else if keyType == .ecdsaP256 || keyType == .ecdsaP384 || keyType == .ecdsaP521 {
                // Citadel can't parse OpenSSH ECDSA keys — our own parser
                // (unencrypted only) feeds its p256/p384/p521 auth methods.
                switch try OpenSSHECDSAKey.parse(pem: pem) {
                case .p256(let key): return .p256(username: ssh.username, privateKey: key)
                case .p384(let key): return .p384(username: ssh.username, privateKey: key)
                case .p521(let key): return .p521(username: ssh.username, privateKey: key)
                }
            } else {
                throw DriverError.connectionFailed(
                    "SSH: \(keyType) keys aren't supported yet — use an ed25519, RSA, or ECDSA key"
                )
            }
        } catch let error as DriverError {
            throw error
        } catch OpenSSHECDSAKey.ParseError.encrypted {
            throw DriverError.connectionFailed(
                "SSH: passphrase-protected ECDSA keys aren't supported yet — remove the passphrase or use ed25519/RSA"
            )
        } catch {
            // Usually a wrong/missing passphrase for an encrypted key.
            throw DriverError.connectionFailed(
                "SSH: could not load the \(keyType) private key — check the passphrase"
            )
        }
    }

    /// Citadel's key loader only reads the OpenSSH private key format — a
    /// classic PKCS1/PKCS8 PEM key (e.g. the .key file Oracle Cloud VPS
    /// downloads give you) fails with an "unreadable private key" error even
    /// though it's perfectly valid. Rather than re-implementing ASN.1/PKCS1
    /// parsing in-app (a real memory-safety and correctness risk for very
    /// little benefit), shell out to the system's own `ssh-keygen` — already
    /// on every Mac, and the canonical tool for exactly this conversion.
    ///
    /// Works on a private temp copy only; the user's original file is never
    /// read-modified-written. The copy is force-permissioned 0600 in a 0700
    /// temp directory and removed immediately after, success or failure.
    /// Re-encrypts with the SAME passphrase (empty if none) so the key's
    /// security posture is unchanged — only the container format changes.
    private static func normalizeToOpenSSH(_ pem: String, passphrase: String?) throws -> String {
        guard !pem.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----") else { return pem }
        // Not a PEM private key at all (empty file, public key pasted by
        // mistake, etc.) — let the existing detector produce its normal error.
        guard pem.contains("PRIVATE KEY-----") else { return pem }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("berrydb-sshkey-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let keyFile = tempDir.appendingPathComponent("key")
        try pem.write(to: keyFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)

        let pass = passphrase ?? ""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        // -p rewrite in place, -o force new OpenSSH format, -N/-P new/old
        // passphrase (same value both ways — this only changes the format).
        process.arguments = ["-p", "-o", "-f", keyFile.path, "-N", pass, "-P", pass]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()
        do {
            try process.run()
        } catch {
            // No ssh-keygen at the expected path — fall back to the original
            // PEM so the caller's existing "unreadable private key" error fires.
            return pem
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw DriverError.connectionFailed(
                "SSH: couldn't convert this key to OpenSSH format"
                    + (stderr.isEmpty ? "" : " (\(stderr))")
            )
        }
        return try String(contentsOf: keyFile, encoding: .utf8)
    }
}
