import Dispatch
import Foundation
import MCP
import Synchronization

/// Turns SIGINT and SIGTERM into a stop of the server, at any point of the
/// helper's life: a signal that arrives before the server is serving is
/// remembered and applied as soon as it is.
///
/// Invariant: `server.stop()` is called once a signal has been received and
/// a server is being served, at whichever of the two happens later. Calling
/// it more than once is harmless, since a stopped server has no task or
/// connection left to stop.
final class HelperShutdown: Sendable {
    private struct State {
        var requested = false
        var server: Server?
    }

    private let state = Mutex(State())

    /// Installs a handler for each of `signals` and returns the dispatch
    /// sources, which must stay alive for the life of the process.
    ///
    /// The default action is replaced with `SIG_IGN` only from the
    /// registration handler, which dispatch runs once the source is
    /// installed; until then a signal still ends the process. Ignoring it
    /// earlier would drop a signal that arrives before the source exists. A
    /// kqueue signal filter observes a signal even when it is ignored, which
    /// is what lets a dispatch source handle it (kqueue(2), `EVFILT_SIGNAL`).
    ///
    /// Both handlers are `@Sendable` and so not isolated to an actor: dispatch
    /// runs them on a global queue, where the runtime's isolation check of a
    /// main-actor closure traps (observed as `EXC_BREAKPOINT` in
    /// `dispatch_assert_queue` when this was installed from top-level code).
    func handle(_ signals: [Int32]) -> [any DispatchSourceSignal] {
        signals.map { number in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { @Sendable [self] in
                request()
            }
            source.setRegistrationHandler { @Sendable in
                signal(number, SIG_IGN)
            }
            source.resume()
            return source
        }
    }

    /// Records the server once it is serving, and stops it at once if a
    /// signal arrived before. Call after the server has started: stopping a
    /// server that has not started does nothing, and its start would then
    /// serve regardless.
    func serving(_ server: Server) async {
        let requested = state.withLock { state in
            state.server = server
            return state.requested
        }
        if requested {
            await server.stop()
        }
    }

    private func request() {
        let server = state.withLock { state in
            state.requested = true
            return state.server
        }
        if let server {
            Task { await server.stop() }
        }
    }
}
