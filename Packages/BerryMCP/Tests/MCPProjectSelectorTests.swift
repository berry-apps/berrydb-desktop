import BerryStore
import Foundation
import Testing

@testable import BerryMCP

@Suite("MCP project selection")
struct MCPProjectSelectorTests {
    let repoA = MCPProject(name: "A", workspaceRoots: ["/work/a"])
    let repoANested = MCPProject(name: "A-api", workspaceRoots: ["/work/a/services/api"])
    let repoB = MCPProject(name: "B", workspaceRoots: ["/work/b"])

    var plain: MCPProjectSelector { MCPProjectSelector(canonicalize: { $0 }) }

    @Test func exactAndNestedPathsSelectTheOwner() {
        #expect(plain.select(workspace: "/work/a", projects: [repoA, repoB]) == .selected(repoA.id))
        #expect(plain.select(workspace: "/work/a/src/x", projects: [repoA, repoB]) == .selected(repoA.id))
    }

    @Test func siblingPrefixIsNotAMatch() {
        #expect(plain.select(workspace: "/work/ab", projects: [repoA]) == .noMatch)
    }

    @Test func longestRootWins() {
        #expect(plain.select(workspace: "/work/a/services/api/x", projects: [repoA, repoANested]) == .selected(repoANested.id))
    }

    @Test func equalRootsInTwoProjectsAreAmbiguous() {
        let twin = MCPProject(name: "A2", workspaceRoots: ["/work/a"])
        guard case .ambiguous(let ids) = plain.select(workspace: "/work/a", projects: [repoA, twin]) else {
            Issue.record("expected ambiguous")
            return
        }
        #expect(Set(ids) == [repoA.id, twin.id])
    }

    @Test func explicitProjectMustExist() {
        #expect(plain.select(explicit: repoB.id, projects: [repoA, repoB]) == .selected(repoB.id))
        #expect(plain.select(explicit: UUID(), projects: [repoA]) == .noMatch)
    }

    @Test func symlinkTrailingSlashAndCaseResolveToTheSameProject() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sel-\(UUID())")
        let real = base.appendingPathComponent("Repo")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: base) }

        let selector = MCPProjectSelector()
        let project = MCPProject(name: "R", workspaceRoots: [real.path])
        #expect(selector.select(workspace: link.path, projects: [project]) == .selected(project.id))
        #expect(selector.select(workspace: real.path + "/", projects: [project]) == .selected(project.id))
        #expect(selector.select(workspace: real.path.replacingOccurrences(of: "/Repo", with: "/repo"), projects: [project]) == .selected(project.id))
    }
}
