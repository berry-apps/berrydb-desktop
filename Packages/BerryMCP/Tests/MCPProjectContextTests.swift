import BerryStore
import Foundation
import Testing

@testable import BerryMCP

@Suite("MCP project context")
struct MCPProjectContextTests {
    let a = MCPProject(name: "A", isEnabled: true, workspaceRoots: ["/work/a"])
    let b = MCPProject(name: "B", isEnabled: true, workspaceRoots: ["/work/b"])

    /// `links` maps a workspace path to what its link lookup finds; any other
    /// workspace has no link file.
    func resolver(
        projects: [MCPProject], tagValid: Bool = true, links: [String: MCPRepositoryLink.Lookup] = [:]
    ) -> MCPProjectContextResolver {
        MCPProjectContextResolver(
            loadProjects: { projects },
            verify: { id in
                projects.first { $0.id == id }.map {
                    MCPVerifiedProject(project: $0, liveReadProfileIDs: [], projectTagValid: tagValid)
                }
            },
            selector: MCPProjectSelector(canonicalize: { $0 }),
            findLink: { links[$0] ?? .none }
        )
    }

    func link(_ name: String, at directory: String) -> [String: MCPRepositoryLink.Lookup] {
        [directory: .found(directory: directory, projectName: name)]
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

    @Test func verifiedReturnsTheCurrentStateOfAKnownProject() throws {
        let disabled = MCPProject(name: "D", isEnabled: false, workspaceRoots: ["/work/d"])
        let resolver = resolver(projects: [a, disabled])

        guard case .selected(let verified, .roots) = try resolver.verified(id: a.id, source: .roots, workspace: nil) else {
            Issue.record("expected the enabled project to stay selected")
            return
        }
        #expect(verified.project.id == a.id)
        #expect(try resolver.verified(id: disabled.id, source: .workingDirectory, workspace: "/work/d")
            == .unconfigured(.projectDisabled, workspace: "/work/d"))
        #expect(try resolver.verified(id: UUID(), source: .explicit, workspace: nil)
            == .unconfigured(.noMatchingProject, workspace: nil))
    }

    @Test func verifiedPropagatesStoreFailures() {
        struct Unreadable: Error {}
        let failing = MCPProjectContextResolver(
            loadProjects: { [] },
            verify: { _ in throw Unreadable() },
            selector: MCPProjectSelector(canonicalize: { $0 })
        )
        #expect(throws: Unreadable.self) {
            try failing.verified(id: a.id, source: .roots, workspace: nil)
        }
    }

    // MARK: Repository link

    @Test func linkBeatsARegisteredRootThatAlsoMatches() throws {
        let context = try resolver(projects: [a, b], links: link("B", at: "/work/a"))
            .resolve(explicit: nil, roots: ["file:///work/a"], workingDirectory: "/")
        guard case .selected(let verified, .linkedRepository) = context else { Issue.record("\(context)"); return }
        #expect(verified.project.id == b.id)
    }

    @Test func workingDirectoryLinkBeatsItsRegisteredRoot() throws {
        let context = try resolver(projects: [a, b], links: link("B", at: "/work/a"))
            .resolve(explicit: nil, roots: nil, workingDirectory: "/work/a")
        guard case .selected(let verified, .linkedRepository) = context else { Issue.record("\(context)"); return }
        #expect(verified.project.id == b.id)
    }

    @Test func linkedNameMatchesCaseInsensitivelyAfterTrimming() throws {
        let spaced = MCPProject(name: "  Shop Ops ", isEnabled: true, workspaceRoots: [])
        let context = try resolver(projects: [a, spaced], links: link(" sHOP oPS\n", at: "/repo"))
            .resolve(explicit: nil, roots: nil, workingDirectory: "/repo")
        guard case .selected(let verified, .linkedRepository) = context else { Issue.record("\(context)"); return }
        #expect(verified.project.id == spaced.id)
    }

    @Test func linkNamingAnUnknownProjectReportsTheName() throws {
        let fromRoots = try resolver(projects: [a, b], links: link("Ledger", at: "/work/a"))
            .resolve(explicit: nil, roots: ["file:///work/a"], workingDirectory: "/work/b")
        #expect(fromRoots == .unconfigured(.linkedProjectNotFound, workspace: nil, linkedProject: "Ledger"))

        let fromWorkingDirectory = try resolver(projects: [a, b], links: link("Ledger", at: "/work/a"))
            .resolve(explicit: nil, roots: nil, workingDirectory: "/work/a")
        #expect(fromWorkingDirectory == .unconfigured(.linkedProjectNotFound, workspace: "/work/a", linkedProject: "Ledger"))
    }

    @Test func twoProjectsWithTheLinkedNameAreAmbiguous() throws {
        let twin = MCPProject(name: "a ", isEnabled: false, workspaceRoots: [])
        let context = try resolver(projects: [a, b, twin], links: link("A", at: "/repo"))
            .resolve(explicit: nil, roots: ["file:///repo"], workingDirectory: "/work/a")
        #expect(context == .unconfigured(.ambiguousProjects, workspace: nil))
    }

    @Test func rootsLinkingTwoProjectsAreAmbiguous() throws {
        let links = link("A", at: "/one").merging(link("B", at: "/two")) { $1 }
        let context = try resolver(projects: [a, b], links: links)
            .resolve(explicit: nil, roots: ["file:///one", "file:///two"], workingDirectory: "/work/a")
        #expect(context == .unconfigured(.ambiguousProjects, workspace: nil))
    }

    @Test func rootsLinkingOneProjectByDifferentSpellingsSelectIt() throws {
        let links = link("A", at: "/one").merging(link(" a", at: "/two")) { $1 }
        let context = try resolver(projects: [a, b], links: links)
            .resolve(explicit: nil, roots: ["file:///one", "file:///two"], workingDirectory: "/work/b")
        guard case .selected(let verified, .linkedRepository) = context else { Issue.record("\(context)"); return }
        #expect(verified.project.id == a.id)
    }

    @Test func rootsWithoutALinkFallThroughToTheWorkingDirectoryLink() throws {
        let context = try resolver(projects: [a, b], links: link("B", at: "/repo"))
            .resolve(explicit: nil, roots: ["file:///elsewhere"], workingDirectory: "/repo")
        guard case .selected(let verified, .linkedRepository) = context else { Issue.record("\(context)"); return }
        #expect(verified.project.id == b.id)
    }

    @Test func rootsMatchingARegisteredRootWinOverAWorkingDirectoryLink() throws {
        let context = try resolver(projects: [a, b], links: link("B", at: "/repo"))
            .resolve(explicit: nil, roots: ["file:///work/a"], workingDirectory: "/repo")
        guard case .selected(let verified, .roots) = context else { Issue.record("\(context)"); return }
        #expect(verified.project.id == a.id)
    }

    @Test func disabledLinkedProjectIsReported() throws {
        let disabled = MCPProject(name: "D", isEnabled: false, workspaceRoots: [])
        let context = try resolver(projects: [a, disabled], links: link("D", at: "/repo"))
            .resolve(explicit: nil, roots: nil, workingDirectory: "/repo")
        #expect(context == .unconfigured(.projectDisabled, workspace: nil))
    }

    /// The bad file sits in an ancestor of the workspace, and the status
    /// names the directory that holds it so the user knows which file to fix.
    @Test func invalidLinkFileIsNeverSkippedAndNamesItsDirectory() throws {
        let invalid: [String: MCPRepositoryLink.Lookup] = ["/work/a": .invalid(directory: "/work")]
        let alone = try resolver(projects: [a, b], links: invalid)
            .resolve(explicit: nil, roots: ["file:///work/a"], workingDirectory: "/work/b")
        #expect(alone == .unconfigured(.invalidLinkFile, workspace: "/work"))

        let besideAValidLink = try resolver(projects: [a, b], links: invalid.merging(link("B", at: "/two")) { $1 })
            .resolve(explicit: nil, roots: ["file:///two", "file:///work/a"], workingDirectory: "/work/b")
        #expect(besideAValidLink == .unconfigured(.invalidLinkFile, workspace: "/work"))

        let besideARegisteredRoot = try resolver(projects: [a, b], links: invalid)
            .resolve(explicit: nil, roots: ["file:///work/b", "file:///work/a"], workingDirectory: "/work/b")
        #expect(besideARegisteredRoot == .unconfigured(.invalidLinkFile, workspace: "/work"))

        let inWorkingDirectory = try resolver(projects: [a, b], links: invalid)
            .resolve(explicit: nil, roots: nil, workingDirectory: "/work/a")
        #expect(inWorkingDirectory == .unconfigured(.invalidLinkFile, workspace: "/work"))
    }

    // MARK: Roots decided one by one

    @Test func linkedRootAndRegisteredRootNamingDifferentProjectsAreAmbiguous() throws {
        let context = try resolver(projects: [a, b], links: link("B", at: "/repo"))
            .resolve(explicit: nil, roots: ["file:///work/a", "file:///repo"], workingDirectory: "/work/a")
        #expect(context == .unconfigured(.ambiguousProjects, workspace: nil))
    }

    @Test func linkedRootAndRegisteredRootNamingOneProjectSelectItByLink() throws {
        let context = try resolver(projects: [a, b], links: link("A", at: "/repo"))
            .resolve(explicit: nil, roots: ["file:///work/a", "file:///repo"], workingDirectory: "/work/b")
        guard case .selected(let verified, .linkedRepository) = context else { Issue.record("\(context)"); return }
        #expect(verified.project.id == a.id)
    }

    @Test func registeredTieOnOneRootBesideALinkIsAmbiguous() throws {
        let twin = MCPProject(name: "Twin", isEnabled: true, workspaceRoots: ["/work/a"])
        let context = try resolver(projects: [a, b, twin], links: link("B", at: "/repo"))
            .resolve(explicit: nil, roots: ["file:///work/a/src", "file:///repo"], workingDirectory: "/work/b")
        #expect(context == .unconfigured(.ambiguousProjects, workspace: nil))
    }

    @Test func unknownLinkedNameIsReportedBeforeAmbiguity() throws {
        let context = try resolver(projects: [a, b], links: link("Ledger", at: "/repo"))
            .resolve(explicit: nil, roots: ["file:///work/a", "file:///work/b", "file:///repo"], workingDirectory: "/")
        #expect(context == .unconfigured(.linkedProjectNotFound, workspace: nil, linkedProject: "Ledger"))
    }

    @Test func linkFileOnDiskSelectsThroughTheDefaultLookup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ctx-link-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try MCPRepositoryLink.contents(projectName: "Linked")
            .write(to: directory.appendingPathComponent(MCPRepositoryLink.fileName))
        let project = MCPProject(name: "Linked", isEnabled: true, workspaceRoots: [])
        let real = MCPProjectContextResolver(
            loadProjects: { [project] },
            verify: { _ in MCPVerifiedProject(project: project, liveReadProfileIDs: []) }
        )
        let context = try real.resolve(explicit: nil, roots: ["file://" + directory.path], workingDirectory: "/")
        guard case .selected(let verified, .linkedRepository) = context else { Issue.record("\(context)"); return }
        #expect(verified.project.id == project.id)
    }

    @Test func explicitProjectWinsOverALink() throws {
        let context = try resolver(projects: [a, b], links: link("B", at: "/work/a"))
            .resolve(explicit: a.id, roots: ["file:///work/a"], workingDirectory: "/work/a")
        guard case .selected(let verified, .explicit) = context else { Issue.record("\(context)"); return }
        #expect(verified.project.id == a.id)
    }
}
