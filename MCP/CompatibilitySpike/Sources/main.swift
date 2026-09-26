import MCP

let server = await CompatibilityServer.makeServer()
let transport = CodexCompatibleStdioTransport()
try await server.start(transport: transport)
await server.waitUntilCompleted()
