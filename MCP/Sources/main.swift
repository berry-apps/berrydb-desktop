import BerryMCPServer
import BerryStore
import Dispatch
import Foundation
import MCP

// Standard output belongs to the JSON-RPC transport from the first byte;
// every failure before the server starts is reported on standard error.

BerryDBMCPComposition.registerDrivers()

let arguments: HelperArguments
do {
    arguments = try HelperArguments.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    BerryDBMCPComposition.diagnose("\(error)")
    exit(2)
}

let store: BerryStore
do {
    store = try BerryStore.openReadOnly(path: arguments.storePath ?? BerryDBMCPComposition.defaultStorePath())
} catch {
    BerryDBMCPComposition.diagnose(
        "cannot open the BerryDB store (\(BerryDBMCPComposition.openFailureReason(error)))"
    )
    exit(1)
}

let (server, start) = await BerryMCPServerFactory.makeServer(
    BerryDBMCPComposition.dependencies(
        store: store,
        explicitProject: arguments.project,
        workingDirectory: FileManager.default.currentDirectoryPath
    )
)

do {
    try await start(HostCompatibleStdioTransport())
} catch {
    BerryDBMCPComposition.diagnose("cannot start the stdio transport")
    exit(1)
}

// A host ends a session by closing standard input or by signalling the
// process. The default action of SIGINT and SIGTERM terminates the process
// at once; ignoring them and stopping the server from a dispatch source lets
// the receive loop finish and the process exit 0, as it does on end of input.
// The handler is `@Sendable` so it is not main-actor isolated like other
// closures written at top level: dispatch runs it on a global queue, where
// the runtime's isolation check of a main-actor closure traps (observed as
// EXC_BREAKPOINT in `dispatch_assert_queue` on the first signal).
let signalSources = [SIGINT, SIGTERM].map { signalNumber in
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
    source.setEventHandler { @Sendable [server] in
        Task { await server.stop() }
    }
    source.resume()
    return source
}

await server.waitUntilCompleted()
exit(0)
