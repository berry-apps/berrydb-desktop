import Foundation

/// Turn-scoped authorization that remains live across async approval. Executors
/// must revalidate it after every suspension and immediately before an action.
@MainActor
public final class AIExecutionLease {
    private let validate: @MainActor () -> Bool

    public init(validate: @escaping @MainActor () -> Bool) {
        self.validate = validate
    }

    public var isValid: Bool { validate() }

    public static func alwaysValid() -> AIExecutionLease {
        AIExecutionLease(validate: { true })
    }
}

/// Result of running a tool locally. Status is fed
/// back to the gateway so the model reacts to denials/errors.
public struct ToolOutcome: Sendable, Equatable {
    public let status: String // "ok" | "denied" | "error"
    public let resultJSON: String?

    public init(status: String, resultJSON: String?) {
        self.status = status
        self.resultJSON = resultJSON
    }

    public static func ok(_ resultJSON: String) -> ToolOutcome {
        ToolOutcome(status: "ok", resultJSON: resultJSON)
    }

    public static let denied = ToolOutcome(status: "denied", resultJSON: nil)

    public static func failed(_ message: String) -> ToolOutcome {
        let escaped = message.replacingOccurrences(of: "\"", with: "'")
        return ToolOutcome(status: "error", resultJSON: "{\"error\":\"\(escaped)\"}")
    }
}

/// A tool the client advertises to the gateway each turn.
/// For static tools, only name/handler version cross the negotiated boundary;
/// the backend owns the provider-facing descriptor. `parametersJSON` is sent
/// only for validated dynamic `skill:`/`mcp:` extensions.
public struct AIToolSpec: Sendable, Equatable {
    public let name: String
    public let description: String
    public let parametersJSON: String
    public let version: String
    public let handlerVersion: String

    public init(
        name: String,
        description: String,
        parametersJSON: String,
        version: String = "1.0.0",
        handlerVersion: String = "1.0.0"
    ) {
        self.name = name
        self.description = description
        self.parametersJSON = parametersJSON
        self.version = version
        self.handlerVersion = handlerVersion
    }
}

/// Runs the tools the gateway requests. Implemented in the UI layer where the
/// session, schema catalog, editor, and the approval prompt live.
/// Every write/DDL must be approved; SELECT may auto-approve per setting.
@MainActor
public protocol AIToolExecutor {
    func execute(_ call: AIToolCall) async -> ToolOutcome
    func execute(_ call: AIToolCall, lease: AIExecutionLease) async -> ToolOutcome
    /// Specs for the tools this executor handles, advertised to the gateway so
 /// the model knows they exist. Default none.
    var toolSpecs: [AIToolSpec] { get }
    /// Called with a partial SQL/query string as the LLM streams a `propose_sql`
    /// argument, so the editor tab can update in real-time. Default: no-op.
    func streamPropose(_ partialSQL: String)
    /// Changes whenever the identity or availability of a routed local handler
    /// changes. A per-turn host snapshot binds dispatch to this generation.
    var capabilityGeneration: String { get }
}

public extension AIToolExecutor {
    var toolSpecs: [AIToolSpec] { [] }
    func streamPropose(_ partialSQL: String) {}
    var capabilityGeneration: String { String(reflecting: Self.self) }
    func execute(_ call: AIToolCall, lease: AIExecutionLease) async -> ToolOutcome {
        // Lease participation is explicit. A newly added executor cannot be
        // reached through a negotiated host until it implements this overload.
        .denied
    }
}
