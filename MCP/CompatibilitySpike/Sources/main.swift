import MCP

let server = await CompatibilityServer.makeServer()
let transport = HostCompatibleStdioTransport()
try await server.start(transport: transport)
await server.waitUntilCompleted()
