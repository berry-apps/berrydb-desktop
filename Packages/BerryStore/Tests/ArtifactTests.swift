import Foundation
import Testing
@testable import BerryStore

@Suite("Artifacts")
struct ArtifactTests {
    private func makeStore() throws -> BerryStore {
        try BerryStore(path: ":memory:")
    }

    @Test func savesAndFetchesArtifactByID() throws {
        let store = try makeStore()
        let profileID = UUID()
        let artifact = Artifact(profileID: profileID, kind: .editorTab, title: "Top customers")
        try store.saveArtifact(artifact)

        let fetched = try store.artifact(id: artifact.id)
        #expect(fetched?.title == "Top customers")
        #expect(fetched?.kind == .editorTab)
        #expect(fetched?.profileID == profileID)
    }

    @Test func scopesArtifactsByProfileAndOrdersNewestFirst() throws {
        let store = try makeStore()
        let profileA = UUID()
        let profileB = UUID()
        let older = Artifact(
            profileID: profileA, kind: .editorTab, title: "Older",
            updatedAt: Date(timeIntervalSince1970: 1000)
        )
        let newer = Artifact(
            profileID: profileA, kind: .editorTab, title: "Newer",
            updatedAt: Date(timeIntervalSince1970: 2000)
        )
        let otherProfile = Artifact(profileID: profileB, kind: .editorTab, title: "Other profile")
        try store.saveArtifact(older)
        try store.saveArtifact(newer)
        try store.saveArtifact(otherProfile)

        let artifacts = try store.artifacts(profileID: profileA)
        #expect(artifacts.map(\.title) == ["Newer", "Older"])
    }

    @Test func appendArtifactVersionIncrementsMonotonically() throws {
        let store = try makeStore()
        let artifact = Artifact(profileID: UUID(), kind: .editorTab, title: "Retry loop")
        try store.saveArtifact(artifact)

        let v1 = try store.appendArtifactVersion(artifactID: artifact.id, payload: "SELECT 1")
        let v2 = try store.appendArtifactVersion(artifactID: artifact.id, payload: "SELECT 1, 2")
        let v3 = try store.appendArtifactVersion(
            artifactID: artifact.id, payload: "SELECT 1, 2, 3",
            resultSnapshotJSON: "{\"truncated\":false}"
        )
        #expect(v1.versionNumber == 1)
        #expect(v2.versionNumber == 2)
        #expect(v3.versionNumber == 3)

        let versions = try store.artifactVersions(artifactID: artifact.id)
        #expect(versions.map(\.payload) == ["SELECT 1", "SELECT 1, 2", "SELECT 1, 2, 3"])

        let latest = try store.latestArtifactVersion(artifactID: artifact.id)
        #expect(latest?.versionNumber == 3)
        #expect(latest?.resultSnapshotJSON == "{\"truncated\":false}")

        let byNumber = try store.artifactVersion(artifactID: artifact.id, versionNumber: 2)
        #expect(byNumber?.payload == "SELECT 1, 2")
        #expect(try store.artifactVersion(artifactID: artifact.id, versionNumber: 99) == nil)
    }

    @Test func deletingArtifactRemovesItsVersionsToo() throws {
        let store = try makeStore()
        let artifact = Artifact(profileID: UUID(), kind: .editorTab, title: "Scratch")
        try store.saveArtifact(artifact)
        try store.appendArtifactVersion(artifactID: artifact.id, payload: "SELECT 1")
        try store.appendArtifactVersion(artifactID: artifact.id, payload: "SELECT 2")

        try store.deleteArtifact(id: artifact.id)

        #expect(try store.artifact(id: artifact.id) == nil)
        #expect(try store.artifactVersions(artifactID: artifact.id).isEmpty)
    }

    @Test func editorSessionRoundTripsSavedQueryAndArtifactLinks() throws {
        let store = try makeStore()
        let profileID = UUID()
        let documentID = UUID()
        let savedQueryID = UUID()
        let artifactID = UUID()
        try store.saveEditorSession(EditorSessionRecord(
            id: documentID, profileID: profileID, title: "Linked tab", text: "SELECT 1",
            savedQueryID: savedQueryID, artifactID: artifactID
        ))

        let restored = try store.editorSessions(profileID: profileID)
        #expect(restored.count == 1)
        #expect(restored.first?.savedQueryID == savedQueryID)
        #expect(restored.first?.artifactID == artifactID)
    }
}
