import NIOConcurrencyHelpers
import NIOCore

/// Carries a non-`Sendable` value across a `context.eventLoop.execute` hop
/// to a foreign loop. `NIOLoopBound` can't do this: it asserts on
/// construction (not just on access) that the current thread is already on
/// the target loop, which by definition isn't true at the point we're
/// hopping FROM. The safety proof here instead comes from `execute`
/// guaranteeing its closure runs on `eventLoop` — `.value` is only ever
/// read there.
private struct CrossLoopTransfer<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Bidirectional byte pump between two channels (local socket ↔ SSH
/// direct-tcpip channel), with backpressure in both directions.
///
/// The two sides attach at DIFFERENT times: the local side is installed
/// synchronously on accept, while the SSH side only exists after the
/// direct-tcpip channel opens (~ms later). Writes forwarded to a side whose
/// context is not attached yet are buffered and drained on attach — this is
/// what lets the listener run with plain autoRead instead of fragile
/// read-gating during setup.
///
/// The channels usually live on DIFFERENT event loops: all cross-channel
/// state lives in lock-protected boxes and every channel operation hops onto
/// that channel's own loop.
final class GlueHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = NIOAny
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny

    private var partner: GlueHandler?
    private let contextBox = NIOLockedValueBox<ChannelHandlerContext?>(nil)
    private let writableCache = NIOLockedValueBox(true)
    /// Writes that arrived before our context attached.
    private let pendingWrites = NIOLockedValueBox<[NIOAny]>([])
    private var pendingRead = false

    /// Dev-only label for tracing.
    var label: String = "?"

    private init() {}

    /// Two handlers wired to forward into each other.
    static func matchedPair() -> (GlueHandler, GlueHandler) {
        let (first, second) = (GlueHandler(), GlueHandler())
        first.partner = second
        second.partner = first
        return (first, second)
    }

    // MARK: Partner-facing operations (thread-safe; hop to our own loop)

    private func partnerWrite(_ data: NIOAny) {
        guard let context = contextBox.withLockedValue({ $0 }) else {
            // Our channel is not ready yet — buffer until handlerAdded drains.
            pendingWrites.withLockedValue { $0.append(data) }
            return
        }
        if context.eventLoop.inEventLoop {
            context.writeAndFlush(data, promise: nil)
        } else {
            // NIOLoopBound/`.loopBound` assert on CONSTRUCTION that we're
            // already on the target loop — the opposite of true here, since
            // we're in this branch precisely because we're on a different
            // one. CrossLoopTransfer defers that proof to where it's
            // actually true: inside the `execute` closure, once hopped.
            let transfer = CrossLoopTransfer((context, data))
            context.eventLoop.execute {
                let (context, data) = transfer.value
                context.writeAndFlush(data, promise: nil)
            }
        }
    }

    private func partnerFlush() {
        guard let context = contextBox.withLockedValue({ $0 }) else { return }
        if context.eventLoop.inEventLoop {
            context.flush()
        } else {
            let transfer = CrossLoopTransfer(context)
            context.eventLoop.execute { transfer.value.flush() }
        }
    }

    private func partnerCloseFull() {
        guard let context = contextBox.withLockedValue({ $0 }) else { return }
        if context.eventLoop.inEventLoop {
            context.close(promise: nil)
        } else {
            let transfer = CrossLoopTransfer(context)
            context.eventLoop.execute { transfer.value.close(promise: nil) }
        }
    }

    private func partnerBecameWritable() {
        guard let context = contextBox.withLockedValue({ $0 }) else { return }
        let transfer = CrossLoopTransfer(context)
        context.eventLoop.execute { [self] in
            if pendingRead {
                pendingRead = false
                transfer.value.read()
            }
        }
    }

    /// Safe to call from any thread — backed by the cache, not the channel.
    private var isWritableCached: Bool {
        writableCache.withLockedValue { $0 }
    }

    // MARK: ChannelDuplexHandler (all on our own event loop)

    func handlerAdded(context: ChannelHandlerContext) {
        contextBox.withLockedValue { $0 = context }
        writableCache.withLockedValue { $0 = context.channel.isWritable }
        let buffered = pendingWrites.withLockedValue { queue in
            let copy = queue
            queue.removeAll()
            return copy
        }
        if !buffered.isEmpty {
            tunnelTrace("glue[\(label)] draining \(buffered.count) buffered write(s)")
            for data in buffered {
                context.write(data, promise: nil)
            }
            context.flush()
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        contextBox.withLockedValue { $0 = nil }
        partner = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        tunnelTrace("glue[\(label)] read → forward")
        partner?.partnerWrite(data)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        partner?.partnerFlush()
    }

    func channelInactive(context: ChannelHandlerContext) {
        partner?.partnerCloseFull()
        partner = nil
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        partner?.partnerCloseFull()
        context.close(promise: nil)
    }

    func read(context: ChannelHandlerContext) {
        // Backpressure: only keep reading while the partner can absorb writes.
        if let partner, partner.isWritableCached == false {
            pendingRead = true
        } else {
            context.read()
        }
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        let writable = context.channel.isWritable
        writableCache.withLockedValue { $0 = writable }
        if writable {
            partner?.partnerBecameWritable()
        }
        context.fireChannelWritabilityChanged()
    }
}
