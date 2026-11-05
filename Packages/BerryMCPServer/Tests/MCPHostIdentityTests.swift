import Testing

@testable import BerryMCPServer

@Suite("MCP host identity")
struct MCPHostIdentityTests {
    @Test func sanitizedStripsControlCharactersTrimsAndCaps() {
        #expect(MCPHostIdentity.sanitized("  Codex\u{0}\n CLI ") == "Codex CLI")
        #expect(MCPHostIdentity.sanitized("") == "unknown")
        #expect(MCPHostIdentity.sanitized(String(repeating: "a", count: 100)).count == 64)
    }

    @Test func combiningMarksCannotInflateTheName() {
        let name = MCPHostIdentity.sanitized("a" + String(repeating: "\u{0301}", count: 100))
        #expect(name.unicodeScalars.count <= 64)
        #expect(name.unicodeScalars.first == "a")
    }

    @Test func nameIsUnknownUntilSet() {
        let host = MCPHostIdentity()
        #expect(host.name == "unknown")
        host.set(clientName: "x")
        #expect(host.name == "x")
    }
}
