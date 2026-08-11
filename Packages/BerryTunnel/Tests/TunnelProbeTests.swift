import BerryDriverKit
import BerryDriverTestKit
import Foundation
import Testing

@testable import BerryTunnel

/// Byte-level probe that isolates the tunnel from any driver: sends a
/// Postgres SSLRequest through the forwarded port and expects the 1-byte
/// 'S'/'N' answer. Uses blocking POSIX sockets with SO_RCVTIMEO so a broken
/// tunnel fails fast instead of hanging the suite.
@Suite("SSH tunnel byte probe", .enabled(if: TestServer.ssh != nil))
struct TunnelProbeTests {
    @Test func rawRoundTripThroughTunnel() async throws {
        let server = TestServer.ssh!
        let tunnel = try await SSHTunnel.open(
            SSHConfig(host: server.host, port: server.port,
                      username: server.username, password: server.password),
            targetHost: "postgres16",
            targetPort: 5432,
            knownHosts: makeIsolatedKnownHosts()
        )
        defer { Task { await tunnel.close() } }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #expect(fd >= 0)
        defer { close(fd) }

        var timeout = timeval(tv_sec: 8, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(tunnel.localPort)).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        #expect(connected == 0, "TCP connect to tunnel local port failed: errno \(errno)")

        // Postgres SSLRequest: length 8, code 80877103.
        let sslRequest: [UInt8] = [0x00, 0x00, 0x00, 0x08, 0x04, 0xD2, 0x16, 0x2F]
        let written = sslRequest.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
        #expect(written == 8, "write through tunnel failed: errno \(errno)")

        var answer: UInt8 = 0
        let received = read(fd, &answer, 1)
        #expect(received == 1, "no answer through tunnel (errno \(errno)) — bytes not flowing")
        #expect(answer == UInt8(ascii: "S") || answer == UInt8(ascii: "N"),
                "unexpected SSLRequest answer: \(answer)")
    }
}
