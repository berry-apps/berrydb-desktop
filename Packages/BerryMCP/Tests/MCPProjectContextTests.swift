import BerryStore
import Foundation
import Testing

@testable import BerryMCP

@Suite("MCP project context")
struct MCPProjectContextTests {
    let a = MCPProject(name: "A", isEnabled: true, workspaceRoots: ["/work/a"])
    let b = MCPProject(name: "B", isEnabled: true, workspaceRoots: ["/work/b"])

    func resolver(projects: [MCPProject], tagValid: Bool = true) -> MCPProjectContextResolver {
        MCPProjectContextResolver(
            loadProjects: { projects },
            verify: { id in
                projects.first { $0.id == id }.map {
                    MCPVerifiedProject(project: $0, liveReadProfileIDs: [], projectTagValid: tagValid)
                }
            },
            selector: MCPProjectSelector(canonicalize: { $0 })
        )
    }

    @Test func explicitWinsOverRootsAndWorkingDirectory() throws {
        let context = try resolver(projects: [a, b]).resolve(explicit: b.id, roots: ["file:///work/a"], workingDirectory: "/work/a")
        guard case .selected(let verified, .explicit) = context else { Issue.record("\(context)"); return }
        #expect(verified.project.id == b.id)
    }

    @Test func rootsSelectBeforeWorkingDirectory() throws {
        let context = try resolver(projects: [a, b]).resolve(explicit: nil, roots: ["file:///work/b/src"], workingDirectory: "/work/a")
        guard case .selected(let verified, .roots) = context else { Issue.record("\(context)"); return }
        #expect(verified.project.id == b.id)
    }

    @Test func unmatchedRootsFallBackToWorkingDirectory() throws {
        let context = try resolver(projects: [a]).resolve(explicit: nil, roots: ["file:///elsewhere"], workingDirectory: "/work/a/sub")
        guard case .selected(_, .workingDirectory) = context else { Issue.record("\(context)"); return }
    }

    @Test func rootsSpanningTwoProjectsAreAmbiguous() throws {
        let context = try resolver(projects: [a, b]).resolve(explicit: nil, roots: ["file:///work/a", "file:///work/b"], workingDirectory: "/")
        #expect(context == .unconfigured(.ambiguousProjects, workspace: nil))
    }

    @Test func nonFileRootsAreIgnored() throws {
        let context = try resolver(projects: [a]).resolve(explicit: nil, roots: ["https://work/a"], workingDirectory: "/work/a")
        guard case .selected(_, .workingDirectory) = context else { Issue.record("\(context)"); return }
    }

    @Test func invalidProjectTagStillSelects() throws {
        let context = try resolver(projects: [a], tagValid: false).resolve(explicit: nil, roots: nil, workingDirectory: "/work/a")
        guard case .selected(let verified, .workingDirectory) = context else { Issue.record("\(context)"); return }
        #expect(verified.project.id == a.id)
        #expect(verified.projectTagValid == false)
    }

    @Test func disabledProjectIsReported() throws {
        let disabled = MCPProject(name: "D", isEnabled: false, workspaceRoots: ["/work/d"])
        let context = try resolver(projects: [disabled]).resolve(explicit: nil, roots: nil, workingDirectory: "/work/d")
        #expect(context == .unconfigured(.projectDisabled, workspace: "/work/d"))
    }

    @Test func unknownExplicitProject() throws {
        #expect(try resolver(projects: [a]).resolve(explicit: UUID(), roots: nil, workingDirectory: "/work/a")
            == .unconfigured(.explicitProjectNotFound, workspace: nil))
    }

    @Test func privateTmpSpellingMatchesTmpRoot() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = MCPProject(name: "T", isEnabled: true, workspaceRoots: [dir.path])
        let real = MCPProjectContextResolver(
            loadProjects: { [project] },
            verify: { _ in MCPVerifiedProject(project: project, liveReadProfileIDs: []) }
        )
        let resolved = URL(fileURLWithPath: dir.path).resolvingSymlinksInPath().path
        guard case .selected = try real.resolve(explicit: nil, roots: ["file://" + resolved], workingDirectory: "/") else {
            Issue.record("expected selection through the resolved spelling")
            return
        }
    }
}
