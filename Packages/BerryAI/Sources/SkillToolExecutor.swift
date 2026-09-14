import Foundation

/// A parsed skill: SKILL.md frontmatter (name, description) + the markdown body
/// the model reads verbatim. Standardized markdown frontmatter format.
public struct Skill: Equatable, Sendable {
    public let name: String
    public let description: String
    public let body: String

    public init(name: String, description: String, body: String) {
        self.name = name
        self.description = description
        self.body = body
    }
}

public enum SkillParseError: Error, Equatable {
    case missingDelimiters
    case missingField(String)
}

/// Minimal SKILL.md parser — flat `key: value` frontmatter only, deliberately
/// lightweight. If a skill ever needs richer YAML, use a dedicated parser library.
public func parseSkillFile(_ contents: String) throws -> Skill {
    let lines = contents.components(separatedBy: "\n")
    guard lines.first == "---",
          let closingIndex = lines.dropFirst().firstIndex(of: "---")
    else {
        throw SkillParseError.missingDelimiters
    }

    var fields: [String: String] = [:]
    for line in lines[1..<closingIndex] {
        guard let colonIndex = line.firstIndex(of: ":") else { continue }
        let key = line[line.startIndex..<colonIndex].trimmingCharacters(in: .whitespaces)
        let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
        fields[key] = value
    }

    guard let name = fields["name"] else { throw SkillParseError.missingField("name") }
    guard let description = fields["description"] else { throw SkillParseError.missingField("description") }

    let body = lines[(closingIndex + 1)...]
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return Skill(name: name, description: description, body: body)
}

/// One skill offered to the backend `/rank` endpoint.
public struct SkillRankInput: Sendable, Equatable {
    public let name: String
    public let description: String
    public let contentHash: String

    public init(name: String, description: String, contentHash: String) {
        self.name = name
        self.description = description
        self.contentHash = contentHash
    }
}

/// Supplies skills for top-K ranking and builds `skill:<name>` specs.
@MainActor
public protocol SkillRanking {
    func skillsForRanking() -> [SkillRankInput]
    func skillToolSpec(named name: String) -> AIToolSpec?
}

/// Client-executed skill tools. Discovers
/// skills under a directory (one subfolder per skill, each with a SKILL.md) and
/// serves `list_skills` / `load_skill`, plus the pre-ranked `skill:<name>`
/// shortcuts. No DB, no approval — reads local files only.
@MainActor
public final class SkillToolExecutor: AIToolExecutor, SkillRanking {
    private let directory: URL

    /// `skillsForRanking()` runs on every chat send, and used to rescan the
    /// directory + re-read + re-hash every SKILL.md each time — extra disk
    /// I/O on the send hot path for a set of files that essentially never
    /// change within a session. Scan once, lazily, and reuse it.
    private var cachedSkills: [(skill: Skill, hash: String)]?

    public init(directory: URL) {
        self.directory = directory
    }

    public var toolSpecs: [AIToolSpec] {
        [
            AIToolSpec(name: "list_skills", description: "List all installed skills as {name, description}. Skills are user-authored instruction snippets you can load for guidance.", parametersJSON: #"{"type":"object","properties":{}}"#),
            AIToolSpec(name: "load_skill", description: "Return the full markdown body of the named skill to use as guidance for the next steps.", parametersJSON: #"{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}"#),
        ]
    }

    public func execute(_ call: AIToolCall) async -> ToolOutcome {
        // A pre-ranked skill:<name> shortcut resolves to the same body as load_skill.
        if call.name.hasPrefix("skill:") {
            return loadSkill(name: String(call.name.dropFirst("skill:".count)))
        }
        switch call.name {
        case "list_skills": return listSkills()
        case "load_skill": return loadSkill(name: call.args["name"])
        default: return .failed("Unknown tool '\(call.name)'")
        }
    }

    public func execute(_ call: AIToolCall, lease: AIExecutionLease) async -> ToolOutcome {
        guard lease.isValid else { return .denied }
        let outcome = await execute(call)
        guard lease.isValid else { return .denied }
        return outcome
    }

 // MARK: - SkillRanking

    public func skillsForRanking() -> [SkillRankInput] {
        discoverWithHashes().map { SkillRankInput(name: $0.skill.name, description: $0.skill.description, contentHash: $0.hash) }
    }

    public func skillToolSpec(named name: String) -> AIToolSpec? {
        guard let skill = discover().first(where: { $0.name == name }) else { return nil }
        return AIToolSpec(name: "skill:\(name)", description: skill.description, parametersJSON: #"{"type":"object","properties":{}}"#)
    }

    /// Each subdirectory of `directory` that holds a parseable SKILL.md, sorted
    /// by name. A missing directory or unparseable file is skipped, not fatal.
    func discover() -> [Skill] {
        discoverWithHashes().map(\.skill)
    }

    private func discoverWithHashes() -> [(skill: Skill, hash: String)] {
        if let cachedSkills { return cachedSkills }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        var out: [(Skill, String)] = []
        for entry in entries {
            let file = entry.appendingPathComponent("SKILL.md")
            guard let contents = try? String(contentsOf: file, encoding: .utf8),
                  let skill = try? parseSkillFile(contents) else { continue }
            out.append((skill, Self.contentHash(contents)))
        }
        let sorted = out.sorted { $0.0.name < $1.0.name }
        cachedSkills = sorted
        return sorted
    }

    /// FNV-1a — a stable non-cryptographic hash to detect skill content changes
 /// No CryptoKit, so BerryAI stays Linux-clean.
    static func contentHash(_ string: String) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return String(hash, radix: 16)
    }

    private func listSkills() -> ToolOutcome {
        let skills = discover().map { ["name": $0.name, "description": $0.description] }
        return .ok(Self.json(["skills": skills]))
    }

    private func loadSkill(name: String?) -> ToolOutcome {
        guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failed("load_skill requires 'name'")
        }
        guard let skill = discover().first(where: { $0.name == name }) else {
            return .failed("No skill named '\(name)'")
        }
        return .ok(Self.json(["name": skill.name, "body": skill.body]))
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }
}
