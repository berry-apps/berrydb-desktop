import Foundation

/// Routes each gateway tool call to the executor that owns it
/// (docs/architecture/09 §4 tool registry). Lets `QueryToolExecutor` (SQL /
/// schema tools) and `GraphToolExecutor` (`graph_query`) share one `AISession`
/// without either knowing about the other. Calls whose name has no route go to
/// `fallback` — typically the SQL executor, which reports unknown tools.
@MainActor
public final class ToolRouter: AIToolExecutor {
    private let routes: [String: any AIToolExecutor]
    /// Prefix routes for dynamic namespaces like `skill:` / `mcp:` (docs/agents/architecture/05 §6).
    private let prefixRoutes: [(prefix: String, executor: any AIToolExecutor)]
    private let fallback: (any AIToolExecutor)?

    public init(
        routes: [String: any AIToolExecutor],
        prefixRoutes: [(prefix: String, executor: any AIToolExecutor)] = [],
        fallback: (any AIToolExecutor)? = nil
    ) {
        self.routes = routes
        self.prefixRoutes = prefixRoutes
        self.fallback = fallback
    }

    /// Union of every routed + fallback executor's local handlers, deduped by
    /// name. The host snapshots these; the server owns static descriptors.
    public var toolSpecs: [AIToolSpec] {
        var seen = Set<String>()
        var specs: [AIToolSpec] = []
        let all = (fallback?.toolSpecs ?? []) + routes.values.flatMap(\.toolSpecs) + prefixRoutes.flatMap { $0.executor.toolSpecs }
        for spec in all where seen.insert(spec.name).inserted {
            specs.append(spec)
        }
        return specs
    }

    public var capabilityGeneration: String {
        let exact = routes
            .map { "\($0.key)=\($0.value.capabilityGeneration)" }
            .sorted()
        let prefixes = prefixRoutes
            .map { "\($0.prefix)=\($0.executor.capabilityGeneration)" }
            .sorted()
        return (["router"] + exact + prefixes + ["fallback=\(fallback?.capabilityGeneration ?? "none")"])
            .joined(separator: "|")
    }

    public func execute(_ call: AIToolCall) async -> ToolOutcome {
        if let executor = routes[call.name] {
            return await executor.execute(call)
        }
        for route in prefixRoutes where call.name.hasPrefix(route.prefix) {
            return await route.executor.execute(call)
        }
        if let fallback {
            return await fallback.execute(call)
        }
        return .failed("Unknown tool '\(call.name)'")
    }

    public func execute(_ call: AIToolCall, lease: AIExecutionLease) async -> ToolOutcome {
        guard lease.isValid else { return .denied }
        if let executor = routes[call.name] {
            return await executor.execute(call, lease: lease)
        }
        for route in prefixRoutes where call.name.hasPrefix(route.prefix) {
            return await route.executor.execute(call, lease: lease)
        }
        if let fallback {
            return await fallback.execute(call, lease: lease)
        }
        return .failed("Unknown tool '\(call.name)'")
    }
}
