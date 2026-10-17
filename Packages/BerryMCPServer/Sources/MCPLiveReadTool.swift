import BerryMCP
import Foundation
import MCP

/// Serves `berrydb_execute_read_query`: checks the call, then hands the
/// statement to the live read service.
///
/// Invariants, as for the metadata tools: malformed arguments are
/// `MCPError.invalidParams` whose message never repeats a value, and every
/// other failure is a one-line tool result. An unassigned and a deleted
/// profile get the same text, and a statement is checked against the read
/// policy of the profile's dialect before any connection opens. A cancelled
/// call throws `CancellationError`, so the SDK sends no response to it
/// (`handleRequest` in Server.swift of swift-sdk 0.12.1), as the protocol
/// asks: https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/cancellation
struct MCPLiveReadTool: Sendable {
    let service: MCPLiveReadService

    func call(
        _ arguments: [String: Value]?, context: MCPProjectContext, metadata: MCPMetadataService
    ) async throws -> CallTool.Result {
        guard case let .selected(project, _, _) = context else {
            return MCPToolRouter.failure(MCPToolRouter.noProjectText)
        }
        let arguments = try MCPToolArguments(arguments, allowing: MCPToolArguments.allowedKeys(for: .executeReadQuery))
        let connectionID = try arguments.connectionID()
        let sql = try arguments.sql()
        let parameters = try arguments.parameters()
        let rowLimit = try arguments.rowLimit()

        guard project.project.profiles.contains(where: { $0.profileID == connectionID }) else {
            return MCPToolRouter.failure(MCPLiveReadError.unknownConnection.description)
        }
        let dialect: MCPSQLDialect?
        do {
            dialect = try metadata.dialect(of: connectionID)
        } catch let error as MCPMetadataError {
            return MCPToolRouter.failure(error.description)
        } catch {
            return MCPToolRouter.failure(MCPToolRouter.storeFailureText)
        }
        guard let dialect else { return MCPToolRouter.failure(MCPLiveReadError.unsupportedDatabase.description) }

        do {
            let result = try await service.run(MCPLiveReadRequest(
                profileID: connectionID, dialect: dialect, sql: sql, parameters: parameters, rowLimit: rowLimit
            ))
            return try MCPToolRouter.respond(result)
        } catch let error as MCPLiveReadError {
            return MCPToolRouter.failure(error.description)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Neither the service nor the encoding of its result throws
            // anything else. The SDK would send any other error's localized
            // description to the host, so it gets the service's own text for
            // an unexpected failure instead.
            return MCPToolRouter.failure(MCPLiveReadError.queryFailed("unexpected error").description)
        }
    }
}
