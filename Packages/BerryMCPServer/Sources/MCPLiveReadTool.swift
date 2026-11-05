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
/// policy of the profile's dialect before any connection opens; a DynamoDB
/// connection is pointed to `berrydb_dynamodb_query` instead. A cancelled
/// call throws `CancellationError`, so the SDK sends no response to it
/// (`handleRequest` in Server.swift of swift-sdk 0.12.1), as the protocol
/// asks: https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/cancellation
struct MCPLiveReadTool: Sendable {
    static let dynamoDBConnectionText = "This is a DynamoDB connection; use berrydb_dynamodb_query."

    let service: MCPLiveReadService

    func call(
        _ arguments: [String: Value]?, context: MCPProjectContext, metadata: MCPMetadataService
    ) async throws -> MCPToolReply {
        guard case let .selected(project, _, _) = context else {
            return .failure(MCPToolRouter.noProjectText, code: "no_project")
        }
        let arguments = try MCPToolArguments(arguments, allowing: MCPToolArguments.allowedKeys(for: .executeReadQuery))
        let connectionID = try arguments.connectionID()
        let sql = try arguments.sql()
        let parameters = try arguments.parameters()
        let rowLimit = try arguments.rowLimit()
        let detail = MCPAuditDetail(profileID: connectionID, query: .sql(sql))

        guard project.project.profiles.contains(where: { $0.profileID == connectionID }) else {
            return .failure(
                MCPLiveReadError.unknownConnection.description, code: MCPLiveReadError.unknownConnection.auditCode,
                audit: detail
            )
        }
        let dialect: MCPSQLDialect?
        let isDynamoDB: Bool
        do {
            dialect = try metadata.dialect(of: connectionID)
            isDynamoDB = try dialect == nil && metadata.isPartitionQueryable(connectionID)
        } catch let error as MCPMetadataError {
            return .failure(error.description, code: "metadata", audit: detail)
        } catch {
            return .failure(MCPToolRouter.storeFailureText, code: "store", audit: detail)
        }
        if isDynamoDB { return .failure(Self.dynamoDBConnectionText, code: "wrong_tool", audit: detail) }
        guard let dialect else {
            return .failure(
                MCPLiveReadError.unsupportedDatabase.description,
                code: MCPLiveReadError.unsupportedDatabase.auditCode, audit: detail
            )
        }

        do {
            let result = try await service.run(MCPLiveReadRequest(
                profileID: connectionID, dialect: dialect, sql: sql, parameters: parameters, rowLimit: rowLimit
            ))
            let response = try MCPToolRouter.respond(result)
            var audit = detail
            if MCPToolReply.isTooLargeRefusal(response) {
                audit.error = "result_too_large"
            } else {
                audit.rows = result.rowCount
                audit.truncated = result.truncated
                audit.redacted = !result.redactedColumns.isEmpty
            }
            return MCPToolReply(result: response, audit: audit)
        } catch let error as MCPLiveReadError {
            return .failure(error.description, code: error.auditCode, audit: detail)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Neither the service nor the encoding of its result throws
            // anything else. The SDK would send any other error's localized
            // description to the host, so it gets the service's own text for
            // an unexpected failure instead.
            return .failure(MCPLiveReadError.queryFailed("unexpected error").description, code: "unexpected", audit: detail)
        }
    }
}
