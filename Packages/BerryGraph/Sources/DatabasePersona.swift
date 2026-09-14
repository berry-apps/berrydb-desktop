import BerryDriverKit
import Foundation

/// A rule set that judges a DSG for one workload persona
/// Relational rules (missing PK, unused index…)
/// are correct for Postgres/MySQL/SQLite/SQL Server but meaningless or wrong
/// for document/key-value/vector engines — this protocol lets `InsightEngine`
/// dispatch to the right rule set instead of running one rule set on every
/// dialect.
public protocol PersonaAnalyzer: Sendable {
    func analyze(_ graph: SchemaGraph, dialect: DriverID) -> [Insight]
}

struct RelationalSchemaAnalyzer: PersonaAnalyzer {
    func analyze(_ graph: SchemaGraph, dialect: DriverID) -> [Insight] {
        SchemaAnalyzer.analyze(graph)
    }
}

struct RelationalIndexAnalyzer: PersonaAnalyzer {
    func analyze(_ graph: SchemaGraph, dialect: DriverID) -> [Insight] {
        IndexAdvisor.analyze(graph, dialect: dialect)
    }
}

/// Which workload a `DriverID` represents, for analyzer dispatch.
public enum DatabasePersona: Sendable, Equatable {
    case relational
    case document
    case keyValue
    case vector

    public static func persona(for dialect: DriverID) -> DatabasePersona {
        switch dialect {
        case .postgres, .mysql, .sqlite, .sqlserver: .relational
        case .mongodb, .dynamodb, .elasticsearch: .document
        case .redis: .keyValue
        case .qdrant: .vector
        }
    }

    /// Rule set for this persona. Non-relational personas are empty until
 /// their own rules land alongside…08
    /// — better to say nothing than to flag a document/key-value/vector store
    /// for not having a primary key or a foreign key.
    var analyzers: [PersonaAnalyzer] {
        switch self {
        case .relational: [RelationalSchemaAnalyzer(), RelationalIndexAnalyzer()]
        case .document, .keyValue, .vector: []
        }
    }
}
