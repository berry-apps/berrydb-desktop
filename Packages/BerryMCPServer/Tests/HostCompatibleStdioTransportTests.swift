import Foundation
import Testing
@testable import BerryMCPServer

@Suite("Host-compatible stdio transport")
struct HostCompatibleStdioTransportTests {
    @Test("Codex compatibility sanitizer changes only experimental initialize capabilities")
    func codexSanitizerScope() throws {
        let nonInitialize = Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{"experimental":{"keep":{}}}}"#.utf8)
        #expect(HostCompatibleStdioTransport.sanitizeIncomingMessage(nonInitialize) == nonInitialize)

        let initializeWithoutExperimental = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"elicitation":{"form":{},"url":{}}},"clientInfo":{"name":"codex-mcp-client","version":"0.154.0"}}}"#.utf8)
        #expect(
            HostCompatibleStdioTransport.sanitizeIncomingMessage(initializeWithoutExperimental)
                == initializeWithoutExperimental
        )

        let codexInitialize = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"experimental":{"codex/auth-change":{}},"elicitation":{"form":{},"url":{}}},"clientInfo":{"name":"codex-mcp-client","version":"0.154.0"}}}"#.utf8)
        let sanitized = HostCompatibleStdioTransport.sanitizeIncomingMessage(codexInitialize)
        let envelope = try #require(
            JSONSerialization.jsonObject(with: sanitized) as? [String: Any]
        )
        #expect(envelope["jsonrpc"] as? String == "2.0")
        #expect(envelope["id"] as? Int == 1)
        #expect(envelope["method"] as? String == "initialize")
        let params = try #require(envelope["params"] as? [String: Any])
        #expect(params["protocolVersion"] as? String == "2025-06-18")
        #expect(params["clientInfo"] as? [String: String] == [
            "name": "codex-mcp-client", "version": "0.154.0",
        ])
        let capabilities = try #require(params["capabilities"] as? [String: Any])
        #expect(capabilities["experimental"] == nil)
        let elicitation = try #require(capabilities["elicitation"] as? [String: Any])
        #expect((elicitation["form"] as? [String: Any])?.isEmpty == true)
        #expect((elicitation["url"] as? [String: Any])?.isEmpty == true)
    }

    @Test("Codex compatibility sanitizer preserves supported experimental entries")
    func codexSanitizerPreservesStrings() throws {
        let stringOnly = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"experimental":{"berry/mode":"safe","berry/version":"1"},"elicitation":{"form":{},"url":{}}},"clientInfo":{"name":"test","version":"1"}}}"#.utf8)
        #expect(HostCompatibleStdioTransport.sanitizeIncomingMessage(stringOnly) == stringOnly)

        let mixed = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"experimental":{"keep":"supported","object":{},"array":[],"null":null,"number":1,"boolean":true},"elicitation":{"form":{},"url":{}}},"clientInfo":{"name":"test","version":"1"}}}"#.utf8)
        let sanitized = HostCompatibleStdioTransport.sanitizeIncomingMessage(mixed)
        let envelope = try #require(
            JSONSerialization.jsonObject(with: sanitized) as? [String: Any]
        )
        let params = try #require(envelope["params"] as? [String: Any])
        let capabilities = try #require(params["capabilities"] as? [String: Any])
        let experimental = try #require(capabilities["experimental"] as? [String: Any])
        #expect(experimental.count == 1)
        #expect(experimental["keep"] as? String == "supported")
        let elicitation = try #require(capabilities["elicitation"] as? [String: Any])
        #expect((elicitation["form"] as? [String: Any])?.isEmpty == true)
        #expect((elicitation["url"] as? [String: Any])?.isEmpty == true)
    }

    @Test("legacy discovery fallback is narrow and preserves request identifiers")
    func legacyDiscoveryFallbackScope() throws {
        let list = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}"#.utf8)
        #expect(HostCompatibleStdioTransport.legacyDiscoveryFallbackResponse(for: list) == nil)

        let notification = Data(#"{"jsonrpc":"2.0","method":"server/discover","params":{}}"#.utf8)
        #expect(HostCompatibleStdioTransport.legacyDiscoveryFallbackResponse(for: notification) == nil)

        let invalidRequests = [
            #"{"id":1,"method":"server/discover","params":{}}"#,
            #"{"jsonrpc":"1.0","id":1,"method":"server/discover","params":{}}"#,
            #"{"jsonrpc":"2.0","id":null,"method":"server/discover","params":{}}"#,
            #"{"jsonrpc":"2.0","id":true,"method":"server/discover","params":{}}"#,
            #"{"jsonrpc":"2.0","id":{},"method":"server/discover","params":{}}"#,
            #"{"jsonrpc":"2.0","id":[],"method":"server/discover","params":{}}"#,
        ]
        for invalid in invalidRequests {
            #expect(
                HostCompatibleStdioTransport.legacyDiscoveryFallbackResponse(
                    for: Data(invalid.utf8)
                ) == nil
            )
        }

        let request = Data(#"{"jsonrpc":"2.0","id":"discover-1","method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}"#.utf8)
        let responseData = try #require(
            HostCompatibleStdioTransport.legacyDiscoveryFallbackResponse(for: request)
        )
        let response = try #require(
            JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        )
        #expect(response["jsonrpc"] as? String == "2.0")
        #expect(response["id"] as? String == "discover-1")
        let error = try #require(response["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32601)
        #expect(error["message"] as? String == "Method not found")

        let numericRequest = Data(#"{"jsonrpc":"2.0","id":7.5,"method":"server/discover","params":{}}"#.utf8)
        let numericResponseData = try #require(
            HostCompatibleStdioTransport.legacyDiscoveryFallbackResponse(for: numericRequest)
        )
        let numericResponse = try #require(
            JSONSerialization.jsonObject(with: numericResponseData) as? [String: Any]
        )
        #expect(numericResponse["id"] as? Double == 7.5)
    }
}
