import CryptoKit
import Foundation

/// A window identifier that can be restored without storing connection secrets.
public struct DatabaseWorkspaceTarget: Codable, Hashable, Sendable {
    public let profileID: UUID
    public let database: String
    private let windowID: UUID

    public init(profileID: UUID, database: String) {
        self.profileID = profileID
        self.database = database
        self.windowID = UUID()
    }

    /// Editor sessions and query history are scoped to the target database.
    var workspaceProfileID: UUID {
        var bytes = Array(SHA256.hash(data: Data("berrydb.database-workspace.\(profileID.uuidString).\(database)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return NSUUID(uuidBytes: bytes) as UUID
    }
}
