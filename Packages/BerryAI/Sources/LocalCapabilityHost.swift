import Foundation

public enum AICapabilityTransportMode: Sendable, Equatable {
    case negotiated
    case legacy
    /// A snapshot created by the on-device agent loop. It never trusts or
    /// simulates backend acceptance metadata, but still enforces the exact
    /// local handler set and generation-bound execution lease.
    case local
}

public struct AILocalHandlerCapability: Sendable, Equatable {
    public let id: String
    public let handlerVersion: String

    public init(id: String, handlerVersion: String) {
        self.id = id
        self.handlerVersion = handlerVersion
    }
}

public struct AICapabilityAdvertisement: Sendable, Equatable {
    public let protocolVersion: Int
    public let handlers: [AILocalHandlerCapability]
    public let dynamicTools: [AIToolSpec]

    public init(
        protocolVersion: Int = 1,
        handlers: [AILocalHandlerCapability],
        dynamicTools: [AIToolSpec]
    ) {
        self.protocolVersion = protocolVersion
        self.handlers = handlers
        self.dynamicTools = dynamicTools
    }
}

public struct AIAcceptedCapability: Sendable, Equatable {
    public let id: String
    public let toolVersion: String
    public let schemaVersion: String
    public let handlerVersion: String
    public let risk: String
    public let approval: String

    public init(id: String, toolVersion: String, schemaVersion: String, handlerVersion: String, risk: String, approval: String) {
        self.id = id
        self.toolVersion = toolVersion
        self.schemaVersion = schemaVersion
        self.handlerVersion = handlerVersion
        self.risk = risk
        self.approval = approval
    }
}

public struct AIRejectedCapability: Sendable, Equatable {
    public let id: String
    public let code: String

    public init(id: String, code: String) {
        self.id = id
        self.code = code
    }
}

public struct AICapabilityAcceptance: Sendable, Equatable {
    public let protocolVersion: Int
    public let registryVersion: String
    public let schemaVersion: String
    public let capabilitySetDigest: String
    public let accepted: [AIAcceptedCapability]
    public let rejected: [AIRejectedCapability]

    public init(
        protocolVersion: Int,
        registryVersion: String,
        schemaVersion: String,
        capabilitySetDigest: String,
        accepted: [AIAcceptedCapability],
        rejected: [AIRejectedCapability]
    ) {
        self.protocolVersion = protocolVersion
        self.registryVersion = registryVersion
        self.schemaVersion = schemaVersion
        self.capabilitySetDigest = capabilitySetDigest
        self.accepted = accepted
        self.rejected = rejected
    }
}

public enum LocalCapabilityError: Error, Equatable, LocalizedError {
    case duplicate(String)
    case invalidDynamicName(String)
    case invalidDynamicSchema(String)
    case invalidVersion(String)
    case invalidAcceptance
    case negotiationRequired
    case snapshotInvalidated

    public var errorDescription: String? {
        switch self {
        case .duplicate: "Duplicate local AI capability."
        case .invalidDynamicName: "Invalid local AI capability name."
        case .invalidDynamicSchema: "Invalid local AI capability schema."
        case .invalidVersion: "Invalid local AI capability version."
        case .invalidAcceptance: "The AI server returned an invalid capability set."
        case .negotiationRequired: "AI capability negotiation did not complete."
        case .snapshotInvalidated: "Local AI capabilities changed during this turn."
        }
    }
}

/// The desktop side of the hybrid agent boundary. It snapshots local handler
/// availability for one turn, but never decides built-in schema/risk/policy.
/// Negotiated metadata is checked again before dispatch as defense in depth.
@MainActor
public final class LocalCapabilityHost: AIToolExecutor {
    private let executor: any AIToolExecutor
    private var advertised: [String: AIToolSpec] = [:]
    private var acceptance: AICapabilityAcceptance?
    private var transportMode: AICapabilityTransportMode?
    private var snapshotGeneration: String?
    private var invalidated = false

    public init(executor: any AIToolExecutor) {
        self.executor = executor
    }

    public var toolSpecs: [AIToolSpec] { executor.toolSpecs }

    public func streamPropose(_ partialSQL: String) {
        // A proposal without the originating capability ID cannot be bound to
        // an accepted descriptor, so the host deliberately fails closed.
    }

    public func streamPropose(
        _ partialSQL: String,
        for capabilityID: String
    ) {
        guard !invalidated,
              snapshotGeneration == executor.capabilityGeneration,
              advertised[capabilityID] != nil else { return }
        switch transportMode {
        case .negotiated:
            guard acceptance?.accepted.contains(where: {
                $0.id == capabilityID
            }) == true else { return }
        case .local:
            break
        case .legacy, nil:
            return
        }
        guard let expectedGeneration = snapshotGeneration else { return }
        let lease = AIExecutionLease { [weak self] in
            guard let self else { return false }
            return !self.invalidated
                && self.snapshotGeneration == expectedGeneration
                && self.executor.capabilityGeneration == expectedGeneration
                && self.advertised[capabilityID] != nil
        }
        guard lease.isValid else { return }
        executor.streamPropose(partialSQL)
    }

    /// Freeze the exact handler set for a turn. Static capabilities disclose
    /// only ID/version; dynamic MCP/skill descriptors remain explicit.
    public func beginTurn(with specs: [AIToolSpec]) throws -> AICapabilityAdvertisement {
        var snapshot: [String: AIToolSpec] = [:]
        var handlers: [AILocalHandlerCapability] = []
        var dynamic: [AIToolSpec] = []

        for spec in specs {
            guard snapshot[spec.name] == nil else {
                throw LocalCapabilityError.duplicate(spec.name)
            }
            guard Self.isCanonicalVersion(spec.handlerVersion),
                  Self.isCanonicalVersion(spec.version)
            else {
                throw LocalCapabilityError.invalidVersion(spec.name)
            }
            snapshot[spec.name] = spec
            if spec.name.hasPrefix("mcp:") || spec.name.hasPrefix("skill:") {
                guard Self.isValidDynamicName(spec.name) else {
                    throw LocalCapabilityError.invalidDynamicName(spec.name)
                }
                guard Self.isValidObjectSchema(spec.parametersJSON) else {
                    throw LocalCapabilityError.invalidDynamicSchema(spec.name)
                }
                dynamic.append(spec)
            } else {
                handlers.append(.init(id: spec.name, handlerVersion: spec.handlerVersion))
            }
        }

        handlers.sort { $0.id < $1.id }
        dynamic.sort { $0.name < $1.name }
        advertised = snapshot
        acceptance = nil
        transportMode = nil
        snapshotGeneration = executor.capabilityGeneration
        invalidated = false
        return AICapabilityAdvertisement(handlers: handlers, dynamicTools: dynamic)
    }

    /// Start an on-device-only turn from the same validated snapshot used by
    /// negotiated requests. No server policy is inferred and no acceptance
    /// envelope is manufactured.
    public func beginLocalTurn(with specs: [AIToolSpec]) throws {
        _ = try beginTurn(with: specs)
        transportMode = .local
    }

    public func setTransportMode(_ mode: AICapabilityTransportMode) throws {
        guard transportMode == nil || transportMode == mode else {
            throw LocalCapabilityError.invalidAcceptance
        }
        transportMode = mode
    }

    public func accept(_ value: AICapabilityAcceptance) throws {
        guard transportMode == .negotiated,
              value.protocolVersion == 1,
              !value.registryVersion.isEmpty,
              !value.schemaVersion.isEmpty,
              !value.capabilitySetDigest.isEmpty
        else {
            throw LocalCapabilityError.invalidAcceptance
        }
        var seen = Set<String>()
        for item in value.accepted {
            guard seen.insert(item.id).inserted,
                  let local = advertised[item.id],
                  local.handlerVersion == item.handlerVersion,
                  !item.toolVersion.isEmpty,
                  !item.schemaVersion.isEmpty,
                  !item.risk.isEmpty,
                  !item.approval.isEmpty
            else {
                throw LocalCapabilityError.invalidAcceptance
            }
        }
        for item in value.rejected {
            guard seen.insert(item.id).inserted,
                  advertised[item.id] != nil,
                  !item.code.isEmpty else {
                throw LocalCapabilityError.invalidAcceptance
            }
        }
        guard seen.count == advertised.count else {
            throw LocalCapabilityError.invalidAcceptance
        }
        acceptance = value
    }

    public func finishTurn() throws {
        defer { clearSnapshot() }
        try validateTurnClosure()
    }

    /// A backend/local model interaction ended the current request while
    /// retaining only its opaque continuation state outside this host. The
    /// capability lease itself never spans the user think-time.
    public func suspendTurn() throws {
        defer { clearSnapshot() }
        try validateTurnClosure()
    }

    /// Fail-closed cleanup for a transport/provider error.
    public func abandonTurn() {
        invalidated = true
        clearSnapshot()
    }

    private func validateTurnClosure() throws {
        guard !invalidated,
              snapshotGeneration == executor.capabilityGeneration else {
            throw LocalCapabilityError.snapshotInvalidated
        }
        if transportMode == .negotiated, acceptance == nil {
            throw LocalCapabilityError.negotiationRequired
        }
        if transportMode == nil {
            throw LocalCapabilityError.negotiationRequired
        }
    }

    private func clearSnapshot() {
        advertised = [:]
        acceptance = nil
        transportMode = nil
        snapshotGeneration = nil
    }

    public func invalidate() {
        invalidated = true
    }

    public func execute(_ call: AIToolCall) async -> ToolOutcome {
        guard advertised[call.name] != nil else {
            return .failed("Capability was not advertised for this turn")
        }
        guard !invalidated,
              snapshotGeneration == executor.capabilityGeneration else {
            return .failed("Local capability snapshot was invalidated")
        }

        switch transportMode {
        case .negotiated:
            guard let acceptance else {
                return .failed("Capability negotiation did not complete")
            }
            guard let accepted = acceptance.accepted.first(where: { $0.id == call.name }),
                  call.registryVersion == acceptance.registryVersion,
                  call.toolVersion == accepted.toolVersion,
                  call.schemaVersion == accepted.schemaVersion,
                  call.risk == accepted.risk,
                  call.approval == accepted.approval,
                  call.capabilitySetDigest == acceptance.capabilitySetDigest
            else {
                return .failed("Capability authorization mismatch")
            }
        case .legacy:
            // Explicit compatibility mode asserted by the transport response.
            break
        case .local:
            // The on-device loop originated this call from the frozen local
            // tool list. Generation + lease checks below remain mandatory.
            break
        case nil:
            return .failed("Capability transport mode was not established")
        }
        guard let expectedGeneration = snapshotGeneration else { return .denied }
        let lease = AIExecutionLease { [weak self] in
            guard let self else { return false }
            return !self.invalidated
                && self.snapshotGeneration == expectedGeneration
                && self.executor.capabilityGeneration == expectedGeneration
        }
        guard lease.isValid else { return .denied }
        return await executor.execute(call, lease: lease)
    }

    private static func isValidObjectSchema(_ json: String) -> Bool {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "object"
        else {
            return false
        }
        return !containsRef(object)
    }

    private static func containsRef(_ value: Any) -> Bool {
        if let object = value as? [String: Any] {
            if object["$ref"] != nil { return true }
            return object.values.contains(where: containsRef)
        }
        if let array = value as? [Any] {
            return array.contains(where: containsRef)
        }
        return false
    }

    private static func isValidDynamicName(_ name: String) -> Bool {
        let parts = name.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        if parts.first == "skill" {
            return parts.count == 2 && safeSegment(parts[1], max: 64)
        }
        if parts.first == "mcp" {
            return parts.count == 3
                && safeSegment(parts[1], max: 64)
                && safeSegment(parts[2], max: 96)
        }
        return false
    }

    private static func safeSegment(_ value: String, max: Int) -> Bool {
        guard !value.isEmpty, value.utf8.count <= max,
              let first = value.utf8.first,
              isASCIIAlphaNumeric(first)
        else {
            return false
        }
        return value.utf8.allSatisfy {
            isASCIIAlphaNumeric($0) || $0 == 46 || $0 == 95 || $0 == 45
        }
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }

    private static func isCanonicalVersion(_ value: String) -> Bool {
        let coreAndPre = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = coreAndPre[0].split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3,
              core.allSatisfy({ part in
                  !part.isEmpty
                      && part.allSatisfy(\.isNumber)
                      && (part == "0" || !part.hasPrefix("0"))
              })
        else {
            return false
        }
        if coreAndPre.count == 2 {
            let pre = coreAndPre[1]
            guard !pre.isEmpty,
                  pre.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") })
            else {
                return false
            }
        }
        return !value.contains("+")
    }
}
