# Local MCP Server Architecture

Status: **PR 1 (AI-36)**. `BerryCredentials` key storage, the `MCPProject`
persistence model, per-profile access settings, HMAC-SHA256 row integrity and
key rotation, project selection by workspace path, a SQL-only connection
coordinator with bounded shutdown, the SQL read policy parser, a byte-exact
result limiter, and schema listings derived from the persisted graph are
implemented. No MCP tool is exposed yet: the executable registers drivers
only. There is no settings UI and no agent SQL execution. See
[`../mcp-server-compatibility.md`](../mcp-server-compatibility.md) for the
Phase 0 protocol gate and gates G1–G4 evidence; it does not establish Cursor
support.

## Purpose and difference from the AI-16 client

BerryDB has two independent MCP roles:

- AI-16 is an outbound MCP **client** inside BerryDB's AI agent. It launches
  external servers from a BerryDB-curated allowlist.
- AI-36 is an inbound local MCP **server**. A coding-agent host (Codex,
  Claude Code, Antigravity, or another MCP-capable application) launches the
  signed `berrydb-mcp` helper as a subprocess and calls a bounded,
  BerryDB-owned capability surface: schema/graph inspection and, where a
  profile allows it, bounded read-only queries.

AI-36 does not replace, relax, or share state with AI-16's allowlist,
approval flow, or trust model. `berrydb-mcp` is a second, headless
composition root: it registers its own drivers and constructs its own
connection coordinator, and cannot inherit live registry state, an active
profile, or user approval from the BerryDB app process. Stdout carries only
MCP JSON-RPC; diagnostics go to stderr or the audit file.

## Threat model

**Assets:** database/cloud/SSH credentials; data inside connected databases;
integrity of those databases; the settings that control read access.

**Primary adversary:** a coding agent whose instructions were subverted by
prompt injection (from code, issues, web pages, or query results). It runs as
the same macOS user as BerryDB, may have shell access, and can read and write
any file that user can, including agent configuration, BerryDB's SQLite
store, and audit files.

**Out of scope:** root/admin compromise, other macOS users (they cannot read
this user's files or Keychain), a compromised BerryDB binary.

| Mechanism | Boundary against the primary adversary? | Reason |
|---|---|---|
| Keychain ACL on connection secrets | Yes | Only BerryDB-signed binaries can read items; the helper never emits secrets. |
| Helper-side capability policy (read-only, limits, no `Scan`) | Yes | Enforced in signed code the agent cannot modify. |
| Database session read-only + least-privilege DB user | Yes | Enforced by the database itself. |
| Per-profile live-read setting and project settings | Yes, via integrity check | Stored in a user-writable file; an HMAC keyed from Keychain is what stops the agent from enabling itself. |
| Project selection (which project a process serves) | No | A process can pass `--project` for any project ID it can read from the store. Selection prevents mistakes and limits exposure; it does not stop a hostile agent from reaching another project's already-enabled capabilities. |
| Audit log | No (visibility only) | The agent can edit it. |

Every guarantee this document calls a boundary holds for any project a
process can name, not only the project of the current workspace. Data
returned by any tool leaves BerryDB and is visible to the MCP host and
potentially its model provider; running the server locally does not keep
returned data on the Mac.

## Project selection and why it is not a boundary

At `initialize`, the helper resolves exactly one project:

1. `--project <uuid>` if given;
2. else the workspace reported by MCP `roots/list`, if the host supports it;
3. else the process working directory.

A workspace matches a project when it equals or is contained in one of the
project's `workspaceRoots`, compared after resolving symlinks and case. Root
paths (`/`) are ignored as workspace roots because they would match every
workspace. The longest matching root wins; an exact tie between two projects
is a configuration error. No match, or a disabled project, means the helper
starts and `tools/list` returns only `berrydb.status`; nothing about other
projects is revealed.

Selection identifies which project a session is *for*, not which project a
process is *authorized* to reach. Per the threat model, a process on the same
machine can pass `--project` for any project ID stored locally, so selection
limits accidental cross-project exposure and mistakes, not deliberate
misuse. The capabilities available once a project is selected — whether
`liveRead` is on for a profile — are the actual gate, and that gate is
verified independently through row integrity (below), not through how the
project was chosen.

## Per-profile access and integrity

Access is modeled per project with an explicit, ordered list of profiles and
no separate grant step:

```swift
public struct MCPProject: Identifiable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var isEnabled: Bool
    public var workspaceRoots: [String]
    public var profiles: [MCPProfileAccess]
}

public struct MCPProfileAccess: Codable, Sendable, Equatable {
    public let profileID: UUID
    public var liveRead: Bool             // default false
    public var redactedColumns: [String]
}
```

A profile must be added explicitly; nothing implicit grants access. `liveRead`
defaults to `false`. Project and profile-access records hold no secrets.

The helper opens the BerryDB store read-only and never migrates it; a store
whose migration set the helper does not recognize is a startup error.

Because the store file is writable by the same-user adversary, every project
row and every profile-access row carries an HMAC-SHA256 tag keyed from a
256-bit key in Keychain under the same ACL as connection secrets. Each
payload includes a domain string and the project ID so a tag cannot be
replayed onto another row or project. Tags are per row, so removing one
profile leaves the others' tags valid. The helper verifies tags on every
request: a bad project tag or a missing key disables live reads for the
whole project; a bad row tag disables live reads for that profile only; both
are reported through `berrydb.status`. Schema and graph access continue
regardless, since they expose nothing the same-user adversary cannot already
read from the store file directly.

Tags carry no freshness of their own: a copy of an older row with its older
tag would otherwise re-verify after settings change. The key is therefore
rotated on every settings save, in this order: read the current key
(aborting the save on any read failure other than "not found"); write a new
key to Keychain; then, in one store transaction, re-seal only the rows that
still verify under the previous key — rows that do not verify, or cannot be
decoded, are left unsealed. Writing the key before re-sealing means a failure
at any step leaves rows unverifiable rather than silently valid, and a
restored older copy of the store never re-verifies under the new key. The
value that gets saved and signed is built from a verified view of the
project in which any unverified `liveRead` switch is forced off and an
unverified project is forced disabled, so a save never signs a value the app
did not itself show as current. The key item is addressed by service and
account so a second item cannot shadow it.

Known limitation: with legacy file-keychain items, a process that creates the
HMAC key item before BerryDB does could choose the key's value. Closing this
gap needs a data-protection Keychain access group or an app-written ACL and
is part of the packaging work (gate G1, see
[`../mcp-server-compatibility.md`](../mcp-server-compatibility.md)).

## Read-only enforcement layers

`DangerGuard`, `QueryToolExecutor.isReadOnly`, and `dangerPreconfirmed: true`
are never used in MCP code. Enforcement is layered; the database session and
the least-privilege check are the boundary, the SQL policy parser is defense
in depth:

1. **Database session read-only.** PostgreSQL: read-only transaction plus
   `statement_timeout`. MySQL: `START TRANSACTION READ ONLY` plus
   `max_execution_time`. SQLite: session opened with `SQLITE_OPEN_READONLY`
   plus `PRAGMA query_only`. A driver that cannot enforce this does not
   advertise a live-read tool.
2. **Least-privilege check, on every connect.** Rejects a session whose role
   could write, including through inherited roles, `rds_superuser`
   membership, ownership, or column-level write privileges. SQLite has no
   equivalent step (read-only open already applies).
3. **SQL policy parser, defense in depth.** Exactly one statement, an
   enumerated read grammar, a function allowlist, deny-by-default for
   anything not understood. It cannot see function invocation written
   without `name(` syntax — attribute notation, operators, casts,
   `search_path` shadowing, views, or defaults — so it stops side-effecting
   calls the session-level guard misses (e.g. `dblink`, file-reading
   functions, `pg_sleep`, advisory locks) rather than substituting for
   layers 1–2. Live reads are not enabled for a SQL dialect until layers 1–2
   exist for it, and the MCP role must lack `CREATE` on its `search_path`
   schemas.
4. **DynamoDB** is read-only by construction: only the `Query` API is
   called; `Scan` and PartiQL are never issued from MCP code.

Data returned by any tool call leaves the process boundary of BerryDB and is
visible to the calling MCP host, and from there potentially to that host's
model provider; the server running locally does not keep returned schema,
graph, or row data on the Mac.

## Limits

The production label on a profile only selects which row in the limits table
below applies; it never decides whether the profile can be read. That
decision is the per-profile `liveRead` switch alone, so an untagged
production database is never readable without `liveRead` either. A
production-labeled profile may be read live only after an explicit
per-profile opt-in: before `liveRead` can be turned on for such a profile,
the settings UI (PR 2) requires reviewing the redacted-column list and
acknowledging that reads use database resources and take shared locks, which
can delay DDL or migrations. Once enabled, the profile is subject to the
stricter production-labeled limits below.

| Limit | Default | Production-labeled profile |
|---|---|---|
| Request timeout | 30 s | 5 s |
| Rows / items per response | 100 | 50 |
| Serialized result | 1 MiB | 256 KiB |
| Encoded cell | 64 KiB | 64 KiB |
| Schema objects per response | 200 | 200 |
| Graph nodes / edges | 500 / 1,000 | 500 / 1,000 |

Projects may configure stricter values only. Truncation is explicit
(`truncated`, omitted counts, an opaque continuation cursor where supported);
the limiter's cost is linear in the rows it keeps, not in the rows scanned.

## PR 1 scope versus later PRs

PR 1 (this document's current scope) implements: `BerryCredentials` key
storage; the `MCPProject`/`MCPProfileAccess` model with no grant step;
per-row HMAC-SHA256 integrity and key rotation on settings save; project
selection by workspace containment; a SQL-only connection coordinator with
bounded shutdown; the SQL read policy parser; the byte-exact result limiter;
and schema listings derived from the persisted schema/dependency graph. No
MCP tool or resource is registered; the executable only registers drivers.
There is no settings UI and no agent-initiated SQL execution.

PR 2 adds the MCP adapter that exposes `berrydb.status`,
`berrydb.list_connections`, `berrydb.get_schema`, `berrydb.search_schema`,
`berrydb.graph_query`, `berrydb.get_graph_stats`, `berrydb.execute_read_query`
and `berrydb.dynamodb_query`; the project settings UI; live reads for
PostgreSQL and MySQL (session read-only plus the least-privilege check, gate
G3) and for SQLite (sessions opened with `SQLITE_OPEN_READONLY`); DynamoDB
`Query` support (never `Scan`); and the production consent and limits rules.

PR 3 adds the audit log, packaging (including closing the Keychain
pre-creation gap noted above), and the public setup documentation.
