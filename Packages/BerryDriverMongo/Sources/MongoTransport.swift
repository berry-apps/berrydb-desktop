import BerryDataSourceKit
import Foundation
import Network

/// Byte-level transport for the MongoDB wire protocol — abstracted so tests
/// can substitute a scripted fake instead of a real socket (mirrors how
/// `QdrantStubURLProtocol` substitutes for `URLSession`,
/// `MongoWireClient` is the only caller; it owns all framing.
protocol MongoTransport: Sendable {
    func connect() async throws
    func send(_ data: Data) async throws
    /// Reads exactly `count` bytes, waiting for them to arrive; throws if the
    /// connection closes or errors before `count` bytes are available.
    func receive(exactly count: Int) async throws -> Data
    func close() async
}

/// `NWConnection`-backed TCP transport (`Network.framework` — an Apple
/// platform framework, not a new SwiftPM dependency; same zero-vendored-
/// dependency shape as `BerryDriverQdrant`'s `URLSession` client). No
/// SwiftNIO here on purpose, even though Postgres/MySQL already pull it in
/// transitively — keeping this driver's own dependency footprint independent
/// of that.
///
/// TLS is a plain on/off switch (`config.tlsMode != .disable`), not the full
/// prefer/require/verify-CA/verify-full spectrum `TLSMode` models for the SQL
/// drivers: MongoDB's wire protocol has no in-band "try TLS, fall back to
/// plaintext on the same connection" negotiation the way Postgres's
/// `SSLRequest` byte does, so "prefer" cannot be honored as designed —
/// documented deviation.
/// Custom CA / client cert are not wired in yet, same not-yet-done
/// bucket as SRV DNS lookup and x.509 client-cert auth.
final class MongoSocketTransport: MongoTransport, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "berrydb.mongo.transport")

    init(host: String, port: Int, useTLS: Bool) {
        let params: NWParameters = useTLS ? .tls : .tcp
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? 27017,
            using: params
        )
    }

    func connect() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = ResumeOnce(continuation)
            connection.stateUpdateHandler = { [connection] state in
                switch state {
                case .ready:
                    box.resume(.success(()))
                case .failed(let error):
                    box.resume(.failure(error))
                case .waiting(let error):
                    // `Network.framework` treats a refused/unreachable TCP
                    // connection as "waiting for the network path to become
                    // viable" (it will keep silently retrying forever), not
                    // `.failed` — Wi-Fi/cellular-switch resilience that makes
                    // sense for a long-lived app, but not for a one-shot
                    // "connect now" driver call. Empirically found: a bad
                    // host/port otherwise hung indefinitely instead of
 // failing fast ("Test connection" expectation, same
                    // as every other driver). Treat it as a hard failure and
                    // stop retrying.
                    connection.cancel()
                    box.resume(.failure(error))
                case .cancelled:
                    box.resume(.failure(DataSourceError.connectionFailed("Connection cancelled")))
                default:
                    break // .setup/.preparing — keep waiting for a terminal state
                }
            }
            connection.start(queue: queue)
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }

    func receive(exactly count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            // min == max forces the completion to wait for exactly `count`
            // bytes rather than returning early with a short read.
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data, data.count == count else {
                    let detail = isComplete ? "connection closed" : "short read"
                    continuation.resume(throwing: DataSourceError.connectionLost(
                        "\(detail) while reading \(count) bytes"
                    ))
                    return
                }
                continuation.resume(returning: data)
            }
        }
    }

    func close() async {
        connection.cancel()
    }
}

/// `CheckedContinuation` may only resume once — `NWConnection.stateUpdateHandler`
/// can fire multiple times (`.preparing`, `.waiting`, ...) before a terminal
/// state, so this guards against a double-resume crash.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<Void, Error>) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        guard let c else { return }
        switch result {
        case .success: c.resume()
        case .failure(let error): c.resume(throwing: error)
        }
    }
}
