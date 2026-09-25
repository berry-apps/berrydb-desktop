import MCP

let server = await CompatibilityServer.makeServer()
let transport = StdioTransport()
try await server.start(transport: transport)
await server.waitUntilCompleted()
