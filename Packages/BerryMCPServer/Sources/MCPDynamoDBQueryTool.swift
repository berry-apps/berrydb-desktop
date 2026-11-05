import BerryMCP
import Foundation
import MCP

/// Serves `berrydb_dynamodb_query`: checks the call, then hands one
/// partition query to the DynamoDB query service.
///
/// Invariants, as for `MCPLiveReadTool`: malformed arguments are
/// `MCPError.invalidParams` whose message never repeats a value, every other
/// failure is a one-line tool result, an unassigned and a deleted profile get
/// the same text, a SQL connection is pointed to the SQL tool before any
/// connection opens, and a cancelled call throws `CancellationError` so the
/// SDK sends no response to it.
struct MCPDynamoDBQueryTool: Sendable {
    let service: MCPPartitionQueryService

    func call(
        _ arguments: [String: Value]?, context: MCPProjectContext, metadata: MCPMetadataService
    ) async throws -> MCPToolReply {
        guard case let .selected(project, _, _) = context else {
            return .failure(MCPToolRouter.noProjectText, code: "no_project")
        }
        let arguments = try MCPToolArguments(arguments, allowing: MCPToolArguments.allowedKeys(for: .dynamodbQuery))
        let connectionID = try arguments.connectionID()
        let request = MCPPartitionQueryRequest(
            profileID: connectionID, table: try arguments.table(), indexName: try arguments.indexName(),
            partitionKey: try arguments.partitionKeyInput(), sortKey: try arguments.sortKeyInput(),
            projection: try arguments.projection(), limit: try arguments.itemLimit(), cursor: try arguments.cursor()
        )
        let detail = MCPAuditDetail(profileID: connectionID, digest: request.auditDigest)

        guard project.project.profiles.contains(where: { $0.profileID == connectionID }) else {
            return .failure(
                MCPPartitionQueryError.unknownConnection.description,
                code: MCPPartitionQueryError.unknownConnection.auditCode, audit: detail
            )
        }
        do {
            guard try metadata.isPartitionQueryable(connectionID) else {
                return .failure(
                    MCPPartitionQueryError.unsupportedDatabase.description, code: "wrong_tool", audit: detail
                )
            }
        } catch let error as MCPMetadataError {
            return .failure(error.description, code: "metadata", audit: detail)
        } catch {
            return .failure(MCPToolRouter.storeFailureText, code: "store", audit: detail)
        }

        do {
            let result = try await service.run(request)
            let response = try Self.respond(result)
            var audit = detail
            if MCPToolReply.isTooLargeRefusal(response) {
                audit.error = "result_too_large"
            } else {
                audit.rows = result.itemCount
                audit.truncated = result.truncated
                audit.redacted = !result.redactedAttributes.isEmpty
                audit.consumedCapacityUnits = result.consumedCapacityUnits
            }
            return MCPToolReply(result: response, audit: audit)
        } catch let error as MCPPartitionQueryError {
            return .failure(error.description, code: error.auditCode, audit: detail)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Neither the service nor the encoding of its result throws
            // anything else; the SDK would send another error's localized
            // description to the host.
            return .failure(
                MCPPartitionQueryError.queryFailed("unexpected error").description, code: "unexpected", audit: detail
            )
        }
    }

    /// The result as one JSON object: its metadata, whose keys the result
    /// spells in snake_case itself, plus `items` with attribute names as
    /// stored. This is the object `MCPPartitionQueryService` measured
    /// against its byte ceiling, so a result it returned fits.
    static func respond(_ result: MCPPartitionQueryResult) throws -> CallTool.Result {
        guard case var .object(fields) = try MCPStructuredEncoding.value(result) else {
            throw EncodingError.invalidValue(result, .init(codingPath: [], debugDescription: "Not a JSON object"))
        }
        fields["items"] = .array(result.items.map(MCPAttributeValueJSON.value))
        return try MCPToolRouter.respond(structured: .object(fields))
    }
}
