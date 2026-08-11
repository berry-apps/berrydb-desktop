import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import Testing

@testable import BerryTunnel

private final class ReceivedBox: @unchecked Sendable {
    private let box = NIOLockedValueBox("")
    var received: String { box.withLockedValue { $0 } }
    func append(_ s: String) { box.withLockedValue { $0 += s } }
}

private final class CaptureHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private let box: ReceivedBox
    init(box: ReceivedBox) { self.box = box }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        box.append(buffer.readString(length: buffer.readableBytes) ?? "")
    }
}

/// GlueHandler pumps bytes between two channels that "usually live on
/// DIFFERENT event loops" (GlueHandler.swift's own doc comment). This wires
/// exactly that topology — local side on one single-threaded group, remote
/// side on another — so every partner* hop is a genuine cross-loop call,
/// reproducing KN-03's `NIOLoopBound` precondition crash deterministically
/// rather than depending on MultiThreadedEventLoopGroup's thread assignment.
@Suite("GlueHandler cross-event-loop pump")
struct GlueHandlerTests {
    @Test func forwardsDataWhenTheTwoSidesLiveOnDifferentEventLoops() async throws {
        let localGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let remoteGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        let (localGlue, remoteGlue) = GlueHandler.matchedPair()
        let received = ReceivedBox()

        let remoteServer = try await ServerBootstrap(group: remoteGroup)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(remoteGlue)
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()

        // remoteGlue.partnerWrite() writes OUT through its own (server-side
        // accepted) channel, over the socket, to whatever's on the other
        // end — so the observer belongs on remotePeer, not remoteServer's
        // child channel.
        let remotePeer = try await ClientBootstrap(group: remoteGroup)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(CaptureHandler(box: received))
                }
            }
            .connect(host: "127.0.0.1", port: remoteServer.localAddress!.port!).get()

        let localServer = try await ServerBootstrap(group: localGroup)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(localGlue)
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()

        let localPeer = try await ClientBootstrap(group: localGroup)
            .connect(host: "127.0.0.1", port: localServer.localAddress!.port!).get()

        // Written on localGroup's thread; localGlue.channelRead forwards via
        // remoteGlue.partnerWrite, which must hop onto remoteGroup's thread.
        var buffer = localPeer.allocator.buffer(capacity: 5)
        buffer.writeString("hello")
        try await localPeer.writeAndFlush(buffer).get()

        for _ in 0..<200 where received.received != "hello" {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(received.received == "hello")

        // Best-effort: closing localPeer cascades through GlueHandler's
        // channelInactive → partnerCloseFull to remoteServer's accepted
        // child, which in turn closes remotePeer over the wire — so these
        // may already be closed by the time we get here.
        try? await localPeer.close()
        try? await localServer.close()
        try? await remotePeer.close()
        try? await remoteServer.close()
        try await localGroup.shutdownGracefully()
        try await remoteGroup.shutdownGracefully()
    }
}
