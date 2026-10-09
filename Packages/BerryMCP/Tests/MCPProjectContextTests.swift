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
        let context = try resolver(projects: [a, b]).resolve(explicit: .id(b.id), roots: ["file:///work/a"], workingDirectory: "/work/a")
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
        let projects = [
            a, b,
            MCPProject(name: "B", isEnabled: true, workspaceRoots: ["/work/shared"]),
            MCPProject(name: "Shared", isEnabled: true, workspaceRoots: ["/work/shared"]),
        ]
        let resolver = MCPProjectContextResolver(
            loadProjects: { projects },
            verify: { id in
                counter.bump("verify")
                return projects.first { $0.id == id }.map { MCPVerifiedProject(project: $0, liveReadProfileIDs: []) }
            },
            selector: MCPProjectSelector(canonicalize: { $0 })
        )
        let unconfigured: [(MCPUnconfiguredReason, MCPProjectReference?, [String]?, String)] = [
            (.noMatchingProject, nil, nil, "/elsewhere"),
            (.ambiguousProjects, nil, ["file:///work/a", "file:///work/b"], "/elsewhere"),
            (.ambiguousProjects, nil, nil, "/work/shared"),
            (.explicitProjectNotFound, .id(UUID()), nil, "/work/a"),
            (.explicitProjectNotFound, .name("Nope"), nil, "/work/a"),
            (.ambiguousProjects, .name("b"), nil, "/work/a"),
        ]

        for (reason, explicit, roots, workingDirectory) in unconfigured {
            let selection = try resolver.select(explicit: explicit, roots: roots, workingDirectory: workingDirectory)
            guard case .unconfigured(reason, _) = selection else {
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
        #expect(try resolver(projects: [a]).resolve(explicit: .id(UUID()), roots: nil, workingDirectory: "/work/a")
            == .unconfigured(.explicitProjectNotFound, workspace: nil))
    }

    // MARK: Explicit project by name

    @Test func explicitNameSelectsTheProjectWithThatNameOverRootsAndWorkingDirectory() throws {
        let spaced = MCPProject(name: "  Shop Ops ", isEnabled: true, workspaceRoots: [])
        let reference = try #require(MCPProjectReference(argument: " sHOP oPS\n"))
        let context = try resolver(projects: [a, b, spaced])
            .resolve(explicit: reference, roots: ["file:///work/a"], workingDirectory: "/work/b")
        #expect(context == .selected(
            MCPVerifiedProject(project: spaced, liveReadProfileIDs: [], projectTagValid: true),
            source: .explicit, workspace: nil
        ))
    }

    @Test func explicitNameNoProjectHasIsNotFoundAndNeverFallsBack() throws {
        let context = try resolver(projects: [a, b])
            .resolve(explicit: .name("Ledger"), roots: ["file:///work/a"], workingDirectory: "/work/b")
        #expect(context == .unconfigured(.explicitProjectNotFound, workspace: nil))
    }

    /// Possible only in a store edited outside the app, since the settings
    /// pane refuses a second project with a matching name.
    @Test func explicitNameSeveralProjectsShareIsAmbiguousAndNeverFallsBack() throws {
        let twin = MCPProject(name: "a ", isEnabled: true, workspaceRoots: [])
        let context = try resolver(projects: [a, b, twin])
            .resolve(explicit: .name("A"), roots: ["file:///work/b"], workingDirectory: "/work/b")
        #expect(context == .unconfigured(.ambiguousProjects, workspace: nil))
    }

    /// A value shaped like a UUID is only ever an ID, so it never selects a
    /// project whose name happens to be that text.
    @Test func uuidShapedArgumentIsOnlyAnID() throws {
        let text = "6f9619ff-8b86-d011-b42d-00c04fc964ff"
        let namedLikeAnID = MCPProject(name: text, isEnabled: true, workspaceRoots: [])
        let reference = try #require(MCPProjectReference(argument: text.uppercased()))
        #expect(reference == .id(UUID(uuidString: text)!))
        let context = try resolver(projects: [a, namedLikeAnID])
            .resolve(explicit: reference, roots: nil, workingDirectory: "/work/a")
        #expect(context == .unconfigured(.explicitProjectNotFound, workspace: nil))
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

    // MARK: Where the selection was decided

    /// The workspace of a selection is the location that decided it: the
    /// host root or working directory that matched a registered folder, or
    /// none for an explicit project.
    @Test func selectionsReportTheLocationThatDecidedThem() throws {
        func workspace(_ context: MCPProjectContext) -> String?? {
            guard case let .selected(_, _, workspace) = context else { return .none }
            return .some(workspace)
        }
        let resolver = resolver(projects: [a, b])

        let explicit = try resolver.resolve(explicit: .id(b.id), roots: ["file:///work/a"], workingDirectory: "/work/a")
        #expect(workspace(explicit) == .some(nil))
        let root = try resolver.resolve(explicit: nil, roots: ["file:///elsewhere", "file:///work/b/src"], workingDirectory: "/work/a")
        #expect(workspace(root) == "/work/b/src")
        let workingDirectory = try resolver.resolve(explicit: nil, roots: nil, workingDirectory: "/work/a/sub")
        #expect(workspace(workingDirectory) == "/work/a/sub")
    }

    // MARK: Roots decided one by one

    /// A tie on one root is ambiguous even when another root matches a
    /// single project, and it never falls back to the working directory.
    @Test func registeredTieOnOneRootBesideAnotherMatchIsAmbiguous() throws {
        let twin = MCPProject(name: "Twin", isEnabled: true, workspaceRoots: ["/work/a"])
        let context = try resolver(projects: [a, b, twin])
            .resolve(explicit: nil, roots: ["file:///work/a/src", "file:///work/b"], workingDirectory: "/work/b")
        #expect(context == .unconfigured(.ambiguousProjects, workspace: nil))
    }

    @Test func rootsMatchingOneProjectTwiceSelectIt() throws {
        let context = try resolver(projects: [a, b])
            .resolve(explicit: nil, roots: ["file:///work/a/one", "file:///elsewhere", "file:///work/a/two"], workingDirectory: "/work/b")
        guard case .selected(let verified, .roots, let workspace) = context else { Issue.record("\(context)"); return }
        #expect(verified.project.id == a.id)
        #expect(workspace == "/work/a/one")
    }
}
