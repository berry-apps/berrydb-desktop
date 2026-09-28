import BerryCredentials
import BerryDriverKit
import BerryStore
import Foundation

/// What a tool needs from a profile: metadata never opens a connection;
/// liveRead requires the verified per-profile switch (spec §8.4).
public enum MCPAccessLevel: Sendable {
    case metadata
    case liveRead
}

public enum MCPProjectResolutionError: Error, Equatable, Sendable {
    case projectNotFound
    case projectDisabled
    case unauthorizedProfile(UUID)
    case liveReadNotEnabled(UUID)
    case missingProfile(UUID)
    case unsupportedDriver(String)
}

public struct MCPConnectionProfile: Sendable {
    public let id: UUID
    public let driverID: DriverID
    public let config: ConnectionConfig

    public init(id: UUID, driverID: DriverID, config: ConnectionConfig) {
        self.id = id
        self.driverID = driverID
        self.config = config
    }
}

public struct MCPCredentialResolver: Sendable {
    public let resolve: @Sendable (UUID) async throws -> ConnectionSecrets

    public init(resolve: @escaping @Sendable (UUID) async throws -> ConnectionSecrets) {
        self.resolve = resolve
    }

    public static let keychain = MCPCredentialResolver { profileID in
        ConnectionSecrets(
            dbPassword: KeychainService.readPassword(profileID: profileID),
            sshPassword: KeychainService.readPassword(kind: .ssh, profileID: profileID),
            sshPassphrase: KeychainService.readPassword(kind: .sshPassphrase, profileID: profileID),
            elasticsearchAPIKey: KeychainService.readPassword(kind: .elasticsearchAPIKey, profileID: profileID)
        )
    }
}

/// Resolves a profile for one request of the helper's selected project.
///
/// The project is reloaded on every call so disabling a project or a
/// profile's live reads in the app takes effect on the next request.
/// Unassigned profiles produce the same error whether or not they exist.
public struct MCPProjectResolver: Sendable {
    private let loadProject: @Sendable () async throws -> MCPVerifiedProject?
    private let loadProfile: @Sendable (UUID) async throws -> MCPConnectionProfile?

    public init(
        loadProject: @escaping @Sendable () async throws -> MCPVerifiedProject?,
        profile: @escaping @Sendable (UUID) async throws -> MCPConnectionProfile?
    ) {
        self.loadProject = loadProject
        self.loadProfile = profile
    }

    public init(
        store: BerryStore,
        projectID: UUID,
        keyStore: MCPAccessKeyStore = .keychain,
        credentialResolver: MCPCredentialResolver = .keychain
    ) {
        self.loadProject = { try store.verifiedMCPProject(id: projectID, key: keyStore.load()) }
        self.loadProfile = { profileID in
            guard let profile = try store.allProfiles().first(where: { $0.id == profileID }) else { return nil }
            guard let driverID = DriverID(rawValue: profile.driverID) else {
                throw MCPProjectResolutionError.unsupportedDriver(profile.driverID)
            }
            let secrets = try await credentialResolver.resolve(profileID)
            return MCPConnectionProfile(
                id: profileID,
                driverID: driverID,
                config: profile.makeConfig(
                    password: secrets.dbPassword,
                    sshPassword: secrets.sshPassword,
                    sshPassphrase: secrets.sshPassphrase,
                    elasticsearchAPIKey: secrets.elasticsearchAPIKey
                )
            )
        }
    }

    /// Resolves `profileID` against the freshly loaded project. Metadata
    /// tools (PR 2) need no credentials; for now `.metadata` still loads
    /// credentials through `loadProfile` too — acceptable because the
    /// coordinator (Task 10) is the only caller today and always uses
    /// `.liveRead`.
    public func resolve(profileID: UUID, access: MCPAccessLevel) async throws -> MCPConnectionProfile {
        guard let verified = try await loadProject() else { throw MCPProjectResolutionError.projectNotFound }
        guard verified.project.isEnabled else { throw MCPProjectResolutionError.projectDisabled }
        guard verified.project.profiles.contains(where: { $0.profileID == profileID }) else {
            throw MCPProjectResolutionError.unauthorizedProfile(profileID)
        }
        if access == .liveRead, !verified.liveReadProfileIDs.contains(profileID) {
            throw MCPProjectResolutionError.liveReadNotEnabled(profileID)
        }
        guard let profile = try await loadProfile(profileID) else {
            throw MCPProjectResolutionError.missingProfile(profileID)
        }
        return profile
    }
}
