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
        guard case .selected(let verified, .explicit, _) = context else { Issue.record("\(context)"); return }
        #expect(verified.project.id == b.id)
    }

    @Test func rootsSelectBeforeWorkingDirectory() throws {
        let context = try resolver(projects: [a, b]).resolve(explicit: nil, roots: ["file:///work/b/src"], workingDirectory: "/work/a")
        guard case .selected(let verified, .roots, _) = context else { Issue.record("\(context)"); return }
        #expect(verified.project.id == b.id)
    }

    @Test func unmatchedRootsFallBackToWorkingDirectory() throws {
        let context = try resolver(projects: [a]).resolve(explicit: nil, roots: ["file:///elsewhere"], workingDirectory: "/work/a/sub")
        guard case .selected(_, .workingDirectory, _) = context else { Issue.record("\(context)"); return }
    }

    @Test func rootsSpanningTwoProjectsAreAmbiguous() throws {
        let context = try resolver(projects: [a, b]).resolve(explicit: nil, roots: ["file:///work/a", "file:///work/b"], workingDirectory: "/")
        #expect(context == .unconfigured(.ambiguousProjects, workspace: nil))
    }

    @Test func nonFileRootsAreIgnored() throws {
        let context = try resolver(projects: [a]).resolve(explicit: nil, roots: ["https://work/a"], workingDirectory: "/work/a")
        guard case .selected(_, .workingDirectory, _) = context else { Issue.record("\(context)"); return }
    }

    @Test func invalidProjectTagStillSelects() throws {
        let context = try resolver(projects: [a], tagValid: false).resolve(explicit: nil, roots: nil, workingDirectory: "/work/a")
        guard case .selected(let verified, .workingDirectory, _) = context else { Issue.record("\(context)"); return }
        #expect(verified.project.id == a.id)
        #expect(verified.projectTagValid == false)
    }

    @Test func disabledProjectIsReported() throws {
        let disabled = MCPProject(name: "D", isEnabled: false, workspaceRoots: ["/work/d"])
        let context = try resolver(projects: [disabled]).resolve(explicit: nil, roots: nil, workingDirectory: "/work/d")
        #expect(context == .unconfigured(.projectDisabled, workspace: "/work/d"))
    }

    /// Selection does not depend on verification, so a session that keeps the
    /// selection serves the project once the app enables it.
    @Test func disabledProjectIsStillTheSelection() throws {
        let disabled = MCPProject(name: "D", isEnabled: false, workspaceRoots: ["/work/d"])
        let resolver = resolver(projects: [disabled])
        let selection = try resolver.select(explicit: nil, roots: nil, workingDirectory: "/work/d")
        #expect(selection == .project(disabled.id, source: .workingDirectory, workspace: "/work/d"))
        #expect(try resolver.context(of: selection) == .unconfigured(.projectDisabled, workspace: "/work/d"))
    }

    /// The helper reads the Keychain inside `verify`, so a session whose
    /// selection chose no project must never call it, neither while
    /// selecting nor on any later request, and a chosen project calls it
    /// exactly once per request.
    @Test func verifyRunsOncePerRequestForAProjectAndNeverOtherwise() throws {
        let counter = CallCounter()
        let projects = [a, b, MCPProject(name: "B", isEnabled: true, workspaceRoots: ["/work/b2"])]
        let links: [String: MCPRepositoryLink.Lookup] = [
            "/work/invalid": .invalid(directory: "/work/invalid"),
            "/work/unknown": .found(directory: "/work/unknown", projectName: "Nope"),
            "/work/shared": .found(directory: "/work/shared", projectName: "B"),
        ]
        let resolver = MCPProjectContextResolver(
            loadProjects: { projects },
            verify: { id in
                counter.bump("verify")
                return projects.first { $0.id == id }.map { MCPVerifiedProject(project: $0, liveReadProfileIDs: []) }
            },
            selector: MCPProjectSelector(canonicalize: { $0 }),
            findLink: { links[$0] ?? .none }
        )
        let unconfigured: [(MCPUnconfiguredReason, UUID?, [String]?, String)] = [
            (.noMatchingProject, nil, nil, "/elsewhere"),
            (.ambiguousProjects, nil, ["file:///work/a", "file:///work/b"], "/elsewhere"),
            (.ambiguousProjects, nil, nil, "/work/shared"),
            (.explicitProjectNotFound, UUID(), nil, "/work/a"),
            (.invalidLinkFile, nil, nil, "/work/invalid"),
            (.linkedProjectNotFound, nil, nil, "/work/unknown"),
        ]

        for (reason, explicit, roots, workingDirectory) in unconfigured {
            let selection = try resolver.select(explicit: explicit, roots: roots, workingDirectory: workingDirectory)
            guard case .unconfigured(reason, _, _) = selection else {
                Issue.record("expected \(reason), got \(selection)")
                continue
            }
            for _ in 0 ..< 3 {
                _ = try resolver.context(of: selection)
            }
            #expect(counter.count("verify") == 0, "\(reason)")
        }

        let selection = try resolver.select(explicit: nil, roots: nil, workingDirectory: "/work/a")
        #expect(selection == .project(a.id, source: .workingDirectory, workspace: "/work/a"))
        #expect(counter.count("verify") == 0)
        for request in 1 ... 3 {
            _ = try resolver.context(of: selection)
            #expect(counter.count("verify") == request)
        }
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

        guard case .selected(let verified, .roots, _) = try resolver.verified(id: a.id, source: .roots, workspace: nil) else {
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
        guard case .selected(let verified, .linkedRepository, _) = context else { Issue.record("\(context)"); return }
        #expect(verified.project.id == b.id)
    }

    @Test func workingDirectoryLinkBeatsItsRegisteredRoot() throws {
        let context = try resolver(projects: [a, b], links: link("B", at: "/work/a"))
            .resolve(explicit: nil, roots: nil, workingDirectory: "/work/a")
        guard case .selected(let verified, .linkedRepository, _) = context else { Issue.record("\(context)"); return }
        #expect(verified.project.id == b.id)
    }

    @Test func linkedNameMatchesCaseInsensitivelyAfterTrimming() throws {
        let spaced = MCPProject(name: "  Shop Ops ", isEnabled: true, workspaceRoots: [])
        let context = try resolver(projects: [a, spaced], links: link(" sHOP oPS\n", at: "/repo"))
            .resolve(explicit: nil, roots: nil, workingDirectory: "/repo")
        guard case .selected(let verified, .linkedRepository, _) = context else { Issue.record("\(context)"); return }
        #expect(verified.project.id == spaced.id)
    }

    /// The status names the directory holding the link file, which sits
    /// above the workspace here, so the user knows which file to change.
    @Test func linkNamingAnUnknownProjectReportsTheNameAndItsDirectory() throws {
        let links: [String: MCPRepositoryLink.Lookup] = ["/work/a/src": .found(directory: "/work/a", projectName: "Ledger")]
        let fromRoots = try resolver(projects: [a, b], links: links)
            .resolve(explicit: nil, roots: ["file:///work/a/src"], workingDirectory: "/work/b")
        #expect(fromRoots == .unconfigured(.linkedProjectNotFound, workspace: "/work/a", linkedProject: "Ledger"))

        let fromWorkingDirectory = try resolver(projects: [a, b], links: links)
            .resolve(explicit: nil, roots: nil, workingDirectory: "/work/a/src")
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
        guard case .selected(let verified, .linkedRepository, _) = context else { Issue.record("\(context)"); return }
        #expect(verified.project.id == a.id)
    }

    @Test func rootsWithoutALinkFallThroughToTheWorkingDirectoryLink() throws {
        let context = try resolver(projects: [a, b], links: link("B", at: "/repo"))
            .resolve(explicit: nil, roots: ["file:///elsewhere"], workingDirectory: "/repo")
        guard case .selected(let verified, .linkedRepository, _) = context else { Issue.record("\(context)"); return }
        #expect(verified.project.id == b.id)
    }

    @Test func rootsMatchingARegisteredRootWinOverAWorkingDirectoryLink() throws {
        let context = try resolver(projects: [a, b], links: link("B", at: "/repo"))
            .resolve(explicit: nil, roots: ["file:///work/a"], workingDirectory: "/repo")
        guard case .selected(let verified, .roots, _) = context else { Issue.record("\(context)"); return }
        #expect(verified.project.id == a.id)
    }

    @Test func disabledLinkedProjectIsReportedWithItsLinkDirectory() throws {
        let disabled = MCPProject(name: "D", isEnabled: false, workspaceRoots: [])
        let context = try resolver(projects: [a, disabled], links: link("D", at: "/repo"))
            .resolve(explicit: nil, roots: nil, workingDirectory: "/repo")
        #expect(context == .unconfigured(.projectDisabled, workspace: "/repo"))
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

    // MARK: Where the selection was decided

    /// The workspace of a selection is the location that decided it: the
    /// host root or working directory that matched a registered folder, the
    /// directory holding the link file, or none for an explicit project.
    @Test func selectionsReportTheLocationThatDecidedThem() throws {
        func workspace(_ context: MCPProjectContext) -> String?? {
            guard case let .selected(_, _, workspace) = context else { return .none }
            return .some(workspace)
        }
        let links: [String: MCPRepositoryLink.Lookup] = ["/repo/app": .found(directory: "/repo", projectName: "B")]
        let resolver = resolver(projects: [a, b], links: links)

        let explicit = try resolver.resolve(explicit: b.id, roots: ["file:///work/a"], workingDirectory: "/work/a")
        #expect(workspace(explicit) == .some(nil))
        let root = try resolver.resolve(explicit: nil, roots: ["file:///elsewhere", "file:///work/b/src"], workingDirectory: "/work/a")
        #expect(workspace(root) == "/work/b/src")
        let workingDirectory = try resolver.resolve(explicit: nil, roots: nil, workingDirectory: "/work/a/sub")
        #expect(workspace(workingDirectory) == "/work/a/sub")
        let linkedRoot = try resolver.resolve(explicit: nil, roots: ["file:///repo/app"], workingDirectory: "/work/a")
        #expect(workspace(linkedRoot) == "/repo")
        let linkedWorkingDirectory = try resolver.resolve(explicit: nil, roots: nil, workingDirectory: "/repo/app")
        #expect(workspace(linkedWorkingDirectory) == "/repo")
    }

    /// A link and a registered folder naming one project attribute it to the
    /// link, so the link's directory is reported.
    @Test func linkedAndRegisteredRootsReportTheLinkDirectory() throws {
        let links: [String: MCPRepositoryLink.Lookup] = ["/repo/app": .found(directory: "/repo", projectName: "A")]
        let context = try resolver(projects: [a, b], links: links)
            .resolve(explicit: nil, roots: ["file:///work/a", "file:///repo/app"], workingDirectory: "/work/b")
        guard case .selected(_, .linkedRepository, let workspace) = context else { Issue.record("\(context)"); return }
        #expect(workspace == "/repo")
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
        guard case .selected(let verified, .linkedRepository, _) = context else { Issue.record("\(context)"); return }
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
        #expect(context == .unconfigured(.linkedProjectNotFound, workspace: "/repo", linkedProject: "Ledger"))
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
        guard case .selected(let verified, .linkedRepository, _) = context else { Issue.record("\(context)"); return }
        #expect(verified.project.id == project.id)
    }

    @Test func explicitProjectWinsOverALink() throws {
        let context = try resolver(projects: [a, b], links: link("B", at: "/work/a"))
            .resolve(explicit: a.id, roots: ["file:///work/a"], workingDirectory: "/work/a")
        guard case .selected(let verified, .explicit, _) = context else { Issue.record("\(context)"); return }
        #expect(verified.project.id == a.id)
    }
}
