import BerryMCPServer
import BerryStore
import Foundation

// Standard output belongs to the JSON-RPC transport from the first byte;
// every failure before the server starts is reported on standard error.

// A host ends a session by closing standard input or by sending SIGINT or
// SIGTERM. The default action of either signal terminates the process at
// once; handled, it stops the server so the receive loop finishes and the
// process exits 0, as on end of input. The handlers are installed first so
// a signal during startup is handled too, and applied once serving begins.
let shutdown = HelperShutdown()
let signalSources = shutdown.handle([SIGINT, SIGTERM])

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
await shutdown.serving(server)

// The receive loop ends on end of input or after a stop. The process then
// exits without waiting for requests still being handled: a host that closed
// standard input or signalled the helper has ended the session and reads no
// further responses.
await server.waitUntilCompleted()
exit(0)
