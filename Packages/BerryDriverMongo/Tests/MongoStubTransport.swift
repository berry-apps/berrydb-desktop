import BerryDataSourceKit
import Foundation

@testable import BerryDriverMongo

/// In-process fake `MongoTransport` — no real socket, no Docker
/// (docs/architecture/12 §10 task scope: "pure unit tests, no network"). Same
/// role as `QdrantStubURLProtocol`, adapted to the wire-protocol shape:
/// `MongoOpMsg.decodeReply` happens to parse a REQUEST just as well as a
/// reply (identical header+section framing either direction), so `send`
/// decodes the outgoing command straight into a `BerryDocument` instead of
/// scripting raw bytes by hand.
///
/// Safe as a plain class (not an actor): `MongoWireClient` is itself an
/// actor and only ever has one `send`/`receive` round trip in flight at a
/// time, so the lock only guards against the test's own assertions reading
/// `sentCommands` concurrently with the actor.
final class MongoStubTransport: MongoTransport, @unchecked Sendable {
    typealias Handler = @Sendable (BerryDocument) throws -> BerryDocument

    private let lock = NSLock()
    private let handlers: [Handler]
    private var handlerIndex = 0
    private var replyBuffer: [UInt8] = []
    private var _sentCommands: [BerryDocument] = []
    var connectError: Error?

    /// One handler per expected round trip, consumed in order; the last
    /// handler repeats for any further calls (handy for a trailing `ping`).
    init(handlers: [Handler]) {
        self.handlers = handlers
    }

    var sentCommands: [BerryDocument] {
        lock.lock(); defer { lock.unlock() }
        return _sentCommands
    }

    func connect() async throws {
        if let connectError { throw connectError }
    }

    func send(_ data: Data) async throws {
        let requestBody = try MongoOpMsg.decodeReply([UInt8](data))
        let handler = recordSent(requestBody)
        let replyBody = try handler(requestBody)
        let replyBytes = [UInt8](MongoOpMsg.encodeRequest(requestID: 1, body: replyBody))
        appendReply(replyBytes)
    }

    func receive(exactly count: Int) async throws -> Data {
        try takeReply(count)
    }

    func close() async {}

    // MARK: - Locked sections split into plain (non-async) methods — NSLock's
    // lock()/unlock() are flagged as unavailable directly inside an `async`
    // function body under Swift 6 strict concurrency, even though the actual
    // hold time here is a few array operations.

    private func recordSent(_ doc: BerryDocument) -> Handler {
        lock.lock(); defer { lock.unlock() }
        _sentCommands.append(doc)
        let handler = handlers[min(handlerIndex, handlers.count - 1)]
        handlerIndex += 1
        return handler
    }

    private func appendReply(_ bytes: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        replyBuffer.append(contentsOf: bytes)
    }

    private func takeReply(_ count: Int) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard replyBuffer.count >= count else {
            throw DataSourceError.connectionLost("stub underflow: wanted \(count) bytes, had \(replyBuffer.count)")
        }
        let chunk = Data(replyBuffer.prefix(count))
        replyBuffer.removeFirst(count)
        return chunk
    }
}

/// Builds a minimal `{ok: 1, ...}` command reply — every stub handler starts
/// from this and adds command-specific fields.
func okReply(_ extra: [(String, BerryDocument)] = []) -> BerryDocument {
    .object([("ok", .double(1))] + extra)
}

/// A `hello` handshake reply — the first thing every `MongoWireClient.connect()`
/// sends, regardless of the test's actual focus.
let helloHandler: MongoStubTransport.Handler = { _ in okReply() }
