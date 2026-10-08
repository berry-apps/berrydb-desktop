import BerryGraph
import BerryMCP
import Foundation
import MCP

/// Resources the server offers: the selected project and the harvested graph
/// summary of each connection assigned to it.
///
/// Invariant: an unconfigured session has no resources, and a URI that is
/// unknown, malformed or names a connection outside the project is rejected
/// with one identical message, so a read cannot probe for connections the
/// project does not expose.
public enum MCPResourceCatalog {
    static let projectURI = "berrydb://project"
    static let unknownResourceText = "Unknown resource"
    private static let graphPrefix = "berrydb://connections/"
    private static let graphSuffix = "/graph"
    private static let mimeType = "application/json"

    /// The resources of a context; none when no project is selected. A
    /// connection's graph is listed only once it has been harvested.
    public static func resources(for context: MCPProjectContext, metadata: MCPMetadataService) throws -> [Resource] {
        guard case let .selected(project, _) = context else { return [] }
        let connections = try mapping { try metadata.listConnections(in: project) }
        let projectResource = Resource(
            name: "project", uri: projectURI, title: "BerryDB project",
            description: "The selected project and the connections it exposes.", mimeType: mimeType
        )
        let graphs = connections.filter { $0.graphHarvestedAt != nil }.map { connection in
            Resource(
                name: "graph-\(connection.id.uuidString)", uri: graphURI(connection.id),
                title: "\(connection.name) schema graph",
                description: "Harvested table and index statistics of one connection.", mimeType: mimeType
            )
        }
        return [projectResource] + graphs
    }

    /// The JSON content of one resource.
    public static func read(uri: String, context: MCPProjectContext, metadata: MCPMetadataService) throws -> [Resource.Content] {
        guard case let .selected(project, _) = context else { throw unknownResource() }
        if uri == projectURI {
            let connections = try mapping { try metadata.listConnections(in: project) }
            let payload = ProjectPayload(
                project: .init(id: project.project.id, name: project.project.name), connections: connections
            )
            return [try content(payload, uri: uri)]
        }
        guard let id = connectionID(fromGraphURI: uri) else { throw unknownResource() }
        let connections = try mapping { try metadata.listConnections(in: project) }
        guard let connection = connections.first(where: { $0.id == id }) else { throw unknownResource() }
        let stats = try mapping { try metadata.graphStats(in: project, connectionID: id, object: nil) }
        guard case let .summary(summary) = stats else { throw unknownResource() }
        let payload = GraphPayload(
            harvestedAt: connection.graphHarvestedAt, tables: summary.tables, unusedIndexes: summary.unusedIndexes
        )
        return [try content(payload, uri: uri)]
    }

    private struct ProjectPayload: Encodable {
        struct Identity: Encodable {
            let id: UUID
            let name: String
        }

        let project: Identity
        let connections: [MCPConnectionDescriptor]
    }

    private struct GraphPayload: Encodable {
        let harvestedAt: Date?
        let tables: [BerryGraphQueryService.NodeStatistics]
        let unusedIndexes: [String]
    }

    private static func graphURI(_ id: UUID) -> String {
        graphPrefix + id.uuidString + graphSuffix
    }

    private static func connectionID(fromGraphURI uri: String) -> UUID? {
        guard uri.hasPrefix(graphPrefix), uri.hasSuffix(graphSuffix),
              uri.count > graphPrefix.count + graphSuffix.count
        else { return nil }
        return UUID(uuidString: String(uri.dropFirst(graphPrefix.count).dropLast(graphSuffix.count)))
    }

    private static func content<T: Encodable>(_ payload: T, uri: String) throws -> Resource.Content {
        let data = try mapping { try MCPStructuredEncoding.data(payload) }
        return .text(String(decoding: data, as: UTF8.self), uri: uri, mimeType: mimeType)
    }

    private static func unknownResource() -> MCPError {
        .invalidParams(unknownResourceText)
    }

    /// Passes protocol errors through, shows metadata errors (written for the
    /// agent) and hides any other failure behind a fixed text, since a store
    /// error can carry a file path.
    private static func mapping<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as MCPError {
            throw error
        } catch let error as MCPMetadataError {
            throw MCPError.invalidParams(error.description)
        } catch {
            throw MCPError.internalError(MCPToolRouter.storeFailureText)
        }
    }
}
