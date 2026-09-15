import BerryDriverKit
import Foundation

public struct SchemaTreeGroup: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String?
    public let tables: [SchemaObject]
    public let views: [SchemaObject]
    public let functions: [SchemaObject]
    public let procedures: [SchemaObject]
    public let triggers: [SchemaObject]

    public var totalCount: Int {
        tables.count + views.count + functions.count + procedures.count + triggers.count
    }

    public init(
        id: String,
        name: String?,
        tables: [SchemaObject] = [],
        views: [SchemaObject] = [],
        functions: [SchemaObject] = [],
        procedures: [SchemaObject] = [],
        triggers: [SchemaObject] = []
    ) {
        self.id = id
        self.name = name
        self.tables = tables
        self.views = views
        self.functions = functions
        self.procedures = procedures
        self.triggers = triggers
    }
}

public enum SchemaTree {
    public static func group(
        objects: [SchemaObject],
        hasSchemaCapability: Bool
    ) -> [SchemaTreeGroup] {
        let distinctSchemas = Set(objects.compactMap(\.database))
        guard hasSchemaCapability && distinctSchemas.count > 1 else {
            return [
                SchemaTreeGroup(
                    id: "__default__",
                    name: nil,
                    tables: objects.filter { $0.kind == .table },
                    views: objects.filter { $0.kind == .view },
                    functions: objects.filter { $0.kind == .function },
                    procedures: objects.filter { $0.kind == .procedure },
                    triggers: objects.filter { $0.kind == .trigger }
                )
            ]
        }

        return distinctSchemas.sorted().map { schema in
            let inSchema = objects.filter { $0.database == schema }
            return SchemaTreeGroup(
                id: schema,
                name: schema,
                tables: inSchema.filter { $0.kind == .table },
                views: inSchema.filter { $0.kind == .view },
                functions: inSchema.filter { $0.kind == .function },
                procedures: inSchema.filter { $0.kind == .procedure },
                triggers: inSchema.filter { $0.kind == .trigger }
            )
        }
    }
}
