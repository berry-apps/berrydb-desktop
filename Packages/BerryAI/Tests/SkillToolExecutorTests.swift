import Foundation
import Testing

@testable import BerryAI

@Suite("SkillToolExecutor")
struct SkillToolExecutorTests {
    private func makeSkillsDir(_ skills: [(name: String, contents: String)]) throws -> URL {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("berrydb-skills-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for skill in skills {
            let dir = root.appendingPathComponent(skill.name)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try skill.contents.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        }
        return root
    }

    private func decode(_ outcome: ToolOutcome) -> [String: Any] {
        guard let json = outcome.resultJSON,
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        else { return [:] }
        return object
    }

 // MARK: - Parser

    @Test func parsesValidSkillFile() throws {
        let skill = try parseSkillFile("---\nname: pg-explain\ndescription: Analyze EXPLAIN output.\n---\n\n# Body\nDo the thing.")
        #expect(skill.name == "pg-explain")
        #expect(skill.description == "Analyze EXPLAIN output.")
        #expect(skill.body == "# Body\nDo the thing.")
    }

    @Test func parseRejectsMissingDelimiters() {
        #expect(throws: SkillParseError.missingDelimiters) {
            try parseSkillFile("no frontmatter here")
        }
    }

    @Test func parseRejectsMissingName() {
        #expect(throws: SkillParseError.missingField("name")) {
            try parseSkillFile("---\ndescription: x\n---\nbody")
        }
    }

 // MARK: - Discovery + tools

    @MainActor
    @Test func listSkillsReturnsAllDiscoveredSorted() async throws {
        let dir = try makeSkillsDir([
            (name: "beta", contents: "---\nname: beta\ndescription: B.\n---\nbody b"),
            (name: "alpha", contents: "---\nname: alpha\ndescription: A.\n---\nbody a"),
        ])
        let executor = SkillToolExecutor(directory: dir)

        let outcome = await executor.execute(AIToolCall(id: "c", name: "list_skills", args: [:]))

        #expect(outcome.status == "ok")
        let skills = decode(outcome)["skills"] as? [[String: Any]] ?? []
        #expect(skills.compactMap { $0["name"] as? String } == ["alpha", "beta"])
    }

    @MainActor
    @Test func loadSkillReturnsBody() async throws {
        let dir = try makeSkillsDir([
            (name: "alpha", contents: "---\nname: alpha\ndescription: A.\n---\nbody alpha here"),
        ])
        let executor = SkillToolExecutor(directory: dir)

        let outcome = await executor.execute(AIToolCall(id: "c", name: "load_skill", args: ["name": "alpha"]))

        #expect(outcome.status == "ok")
        #expect(decode(outcome)["body"] as? String == "body alpha here")
    }

    @MainActor
    @Test func loadUnknownSkillIsAnError() async throws {
        let dir = try makeSkillsDir([])
        let executor = SkillToolExecutor(directory: dir)
        let outcome = await executor.execute(AIToolCall(id: "c", name: "load_skill", args: ["name": "nope"]))
        #expect(outcome.status == "error")
    }

    @MainActor
    @Test func skillsForRankingCarryStableHashes() async throws {
        let dir = try makeSkillsDir([(name: "alpha", contents: "---\nname: alpha\ndescription: A.\n---\nbody a")])
        let executor = SkillToolExecutor(directory: dir)
        let inputs = executor.skillsForRanking()
        #expect(inputs.map(\.name) == ["alpha"])
        #expect(inputs[0].contentHash.isEmpty == false)
        // Same content → same hash (stable across calls).
        #expect(executor.skillsForRanking()[0].contentHash == inputs[0].contentHash)
    }

    @MainActor
    @Test func skillsForRankingCachesTheDiskScanAcrossCalls() async throws {
        // Every chat send calls skillsForRanking(); rescanning + re-reading
        // every SKILL.md on disk each time adds latency to every message,
        // not just the first. It should be scanned once per session.
        let dir = try makeSkillsDir([(name: "alpha", contents: "---\nname: alpha\ndescription: A.\n---\nbody a")])
        let executor = SkillToolExecutor(directory: dir)
        let first = executor.skillsForRanking()
        #expect(first.map(\.name) == ["alpha"])

        // Added to disk *after* the first scan — a cached second call must
        // not pick it up, since picking it up would mean it rescanned.
        let betaDir = dir.appendingPathComponent("beta")
        try FileManager.default.createDirectory(at: betaDir, withIntermediateDirectories: true)
        try "---\nname: beta\ndescription: B.\n---\nbody b"
            .write(to: betaDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let second = executor.skillsForRanking()
        #expect(second.map(\.name) == ["alpha"])
    }

    @MainActor
    @Test func skillNamespaceShortcutLoadsBody() async throws {
        let dir = try makeSkillsDir([(name: "alpha", contents: "---\nname: alpha\ndescription: A.\n---\nbody alpha")])
        let executor = SkillToolExecutor(directory: dir)
        let outcome = await executor.execute(AIToolCall(id: "c", name: "skill:alpha", args: [:]))
        #expect(outcome.status == "ok")
        #expect(decode(outcome)["body"] as? String == "body alpha")
        #expect(executor.skillToolSpec(named: "alpha")?.name == "skill:alpha")
    }

    @MainActor
    @Test func advertisesListAndLoadTools() {
        let executor = SkillToolExecutor(directory: URL(fileURLWithPath: "/nonexistent"))
        let names = executor.toolSpecs.map(\.name)
        #expect(names.contains("list_skills"))
        #expect(names.contains("load_skill"))
    }
}
