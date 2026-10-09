# Local MCP Server Architecture

Status: **metadata tools**. `berrydb-mcp` runs as a stdio MCP server over
the app's store opened read-only and serves six metadata tools and two
kinds of resources for one selected project (see
[Tools and resources](#tools-and-resources)). The project is selected from
an explicit `--project`, the host's workspace roots or the working
directory, each workspace decided by a repository link file
(`.berrydb.json`) or by the workspace folders registered in the app. The
app's **AI Agents** settings pane creates and edits projects and links
repositories; it shows the host setup commands for the helper bundled in
the app (see [Packaging and signing](#packaging-and-signing)). Underneath
sit key storage, the `MCPProject` persistence model, HMAC-SHA256 row
integrity and key rotation, a SQL-only connection coordinator with bounded
shutdown, the SQL read policy parser and a byte-exact result limiter. No
tool reads live data yet (see
[Implemented and planned](#implemented-and-planned)). See
[`../mcp-server-compatibility.md`](../mcp-server-compatibility.md) for the
protocol gate, the host checks and
[design gates G1–G4](../mcp-server-compatibility.md#design-gates); none of
it establishes Cursor support.

## Purpose and difference from the in-app MCP client

BerryDB has two independent MCP roles:

- The in-app MCP **client** is outbound, inside BerryDB's AI agent. It
  launches external servers from a BerryDB-curated allowlist.
- `berrydb-mcp` is an inbound local MCP **server**. A coding-agent host (Codex,
  Claude Code, Antigravity, or another MCP-capable application) launches the
  `berrydb-mcp` helper, bundled in and signed with the app, as a
  subprocess and calls a bounded,
  BerryDB-owned capability surface: schema/graph inspection and, where a
  profile allows it, bounded read-only queries (not implemented yet).

The server does not replace, relax, or share state with the client's
allowlist, approval flow, or trust model. `berrydb-mcp` is a second, headless
composition root: it registers its own drivers (and, once live reads exist,
constructs its own connection coordinator), and cannot inherit live registry
state, an active profile, or user approval from the BerryDB app process.
Stdout carries only MCP JSON-RPC; diagnostics go to stderr (and, once it
exists, the audit log).

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
| Project selection (which project a process serves) | No | A process can pass `--project` for any project ID it can read from the store, and a repository's `.berrydb.json` can name any project. Selection prevents mistakes and limits exposure; it does not stop a hostile agent or repository from reaching another project's already-enabled capabilities. |
| Audit log | No (visibility only) | The agent can edit it. |

Every guarantee this document calls a boundary holds for any project a
process can name, not only the project of the current workspace. Data
returned by any tool leaves BerryDB and is visible to the MCP host and
potentially its model provider; running the server locally does not keep
returned data on the Mac.

## Tools and resources

Every tool is read-only and reads only the store: the schema and dependency
graph the app last harvested for a connection, never the database itself.
Each tool declares a closed input schema (`additionalProperties: false`)
and an output schema, carries the annotations `readOnlyHint: true`,
`destructiveHint: false`, `idempotentHint: true`, `openWorldHint: false`,
and returns its result as `structuredContent` plus the same compact JSON in
one text block, which the MCP specification asks of tools that return
structured content
([Structured Content](https://modelcontextprotocol.io/specification/2025-11-25/server/tools#structured-content)).

| Tool | Arguments | Returns |
|---|---|---|
| `berrydb_status` | none | Which project the session serves, or why none (see [Status](#status)). Always listed. |
| `berrydb_list_connections` | none | The project's connections: ID, name, driver, `environment` (`production` or `unlabeled`), capabilities and `graph_harvested_at`: the time of the last harvest that changed the graph's structure (a harvest that only refreshes statistics does not move it), or null when the connection was never harvested or its latest harvest found no tables or views. |
| `berrydb_get_schema` | `connection_id`; optional `object_names` (at most 50), `detail` (`overview` or `full`) | Tables and views, at most 200 per call with an `omitted_count` and `harvested_at`, which means the same as `graph_harvested_at`; `full` adds columns, indexes and foreign keys. |
| `berrydb_search_schema` | `connection_id`, `query` (1–200 characters); optional `limit` (1–200, default 50) | Case-insensitive substring matches over table, view, column and index names. |
| `berrydb_graph_query` | `connection_id`, `operation`; `node` for `neighbors` and `blast_radius`, `from` and `to` for `path`, optional `limit` (1–50) for `top_centrality` | The dependency-graph answer. The name lists of `neighbors`, `blast_radius` and `circular_dependencies` are capped at 500; a `path` is returned whole, bounded only by the 1 MiB result ceiling. `circular_dependencies` takes no further argument. |
| `berrydb_get_graph_stats` | `connection_id`; optional `object` | Harvested statistics (rows, size, scans) for every table, or for one table and its indexes; at most 500 tables and 500 unused index names. |

With no project selected, `tools/list` returns only `berrydb_status` and
every other tool answers that no project is selected; nothing about any
project is revealed. A `connection_id` that does not exist and one that
exists but is not assigned to the project produce the identical error text,
`Unknown connection for this project`. A graph name that matches several
nodes is an `isError` result that lists at most 50 tables or views. Each is
named so that it resolves to that one node: its `database.name`, or its
stable id (for example `table:shop.orders`) when that name is shared. A
count of the rest follows. A name that matches only columns or indexes is
told to pass a table or view name. An unknown tool, or (while a project
is selected) an argument that breaks the input schema, is a JSON-RPC
invalid-params error (`-32602`) whose message names the argument but never
echoes its value. This departs from
the specification's suggestion to report input validation failures as tool
results with `isError: true`
([Error Handling](https://modelcontextprotocol.io/specification/2025-11-25/server/tools#error-handling));
the server keeps the stricter contract the protocol gate established, a
protocol error for any argument the schema does not allow. A structured
result larger than 1 MiB is replaced by an `isError` result,
`Result too large; narrow the request`. A failure to read the store
returns a fixed text, never SQLite's message, which can contain a path.

Resources: `berrydb://project` (the project and its connections) and, for
each connection with a non-null `graph_harvested_at`,
`berrydb://connections/<connection-id>/graph` (harvested table and index
statistics). An unconfigured session lists no resources, and any unknown,
malformed or out-of-project URI gets the identical `Unknown resource`
error.

Tool names use `[a-z0-9_]` only. MCP itself allows `.` in tool names
([Tool Names](https://modelcontextprotocol.io/specification/2025-11-25/server/tools#tool-names)),
but the name a host hands to its model must satisfy the model API, and the
Claude API, for one, requires `^[a-zA-Z0-9_-]{1,128}$`
([Define tools](https://platform.claude.com/docs/en/agents-and-tools/tool-use/define-tools)).
Codex 0.157.1 and Claude Code 2.1.294 were observed passing the server's
tool name through unchanged inside `mcp__<server>__<tool>`
([host check](../mcp-server-compatibility.md#metadata-tools-host-check)).
Whether a host would rewrite a dotted name was not tested; avoiding the
character removes the question.

## Setup

1. **The helper.** BerryDB ships it at
   `BerryDB.app/Contents/Helpers/berrydb-mcp`, and the settings pane fills
   that path into the setup commands. Two cases show no commands instead.
   A build without the helper says it is not bundled. And because every
   command embeds the helper's absolute path, a BerryDB running from a
   read-only volume asks to be moved to the Applications folder and opened
   from there (see [Packaging and signing](#packaging-and-signing)).

   Once a session has chosen a project, the helper reads the integrity key
   on every `tools/list`, `tools/call`, `resources/list` and
   `resources/read` request. That includes requests where the project has
   since been disabled (`project_disabled`) or deleted
   (`no_matching_project`), because the key is read before the project
   row. A session whose selection chose no project never reads it. The
   key's Keychain item, `dev.berrydb.mcp.access-key`, is created by the
   app and trusts only the app, so the bundled helper's first such read
   shows a Keychain dialog. Choose **Always Allow**.
   [Gate G1](../mcp-server-compatibility.md#g1-keychain-sharing) saw a
   helper signed by the app's team read an app-created item after that
   choice and show no dialog afterwards, including after it was re-signed,
   because the entry added is the helper's designated requirement (its
   identifier and team), not a code hash. The app rotates the key by
   updating that item in place rather than replacing it, and a release
   keeps the helper's identifier (`berrydb-mcp`) and team, so the entry is
   expected to outlast both key rotation and updates. Neither has been
   observed yet, and the dialog itself has not been seen with a packaged,
   Developer ID–signed helper. **Allow** grants that one read and **Deny**
   refuses it
   ([If you're asked for access to your keychain](https://support.apple.com/guide/keychain-access/if-youre-asked-for-access-to-your-keychain-kyca1243/mac)
   calls the one-time choice "Allow Once"), so the next request asks
   again; each request waits while its dialog is open, and a refused read
   serves that request with `integrity: "unavailable"`. A read that never
   shows a dialog is not implemented: the app would have to add the
   helper's designated requirement to the item's access list when it
   writes the item.

   From a source checkout, `swift build --product berrydb-mcp` builds the
   helper into the folder that `swift build --show-bin-path` prints; the
   executable `<that folder>/berrydb-mcp` is the `<helper>` in the
   commands below. Such a build is not signed by BerryDB's team, so its
   reads show the same dialog: G1 saw one when an ad-hoc signed probe read
   an app-created item. **Always Allow** adds that build to the item's
   access list pinned to its code hash, so the dialog returns only after a
   rebuild. The helper itself was not observed being prompted. **Always
   Allow** puts that unsigned build on the access list of the key that
   seals project settings, so any process able to run that binary can
   read the key without a dialog. Remove the entry when you are done with
   the source build: in Keychain Access, find the login-keychain item
   whose name or service is `dev.berrydb.mcp.access-key` (the item carries
   no separate label) and remove `berrydb-mcp` from the applications its
   **Access Control** tab lists; these steps follow Apple's Keychain
   Access guide (https://support.apple.com/guide/keychain-access/welcome/mac)
   and were not clicked through on this macOS version.
2. **A project.** In **Settings → AI Agents**, create a project, turn on
   **Enabled**, choose its connections, and either add **Workspace
   Folders** (every folder below one is included, unless a `.berrydb.json`
   in or above it decides first) or use **Link Repository…**, which writes
   `.berrydb.json` naming the project into the chosen repository. A
   `.berrydb.json` that is a symbolic link or belongs to another user is
   offered for replacement rather than counted as linked. Committing that
   file lets every clone and worktree select a project of the same name in
   the BerryDB of whoever opens it; adding it to `.gitignore` keeps it
   local.
3. **Each host, once.** Run one command per host, each adding a
   user-level entry named `berrydb`. The pane's **Agent Setup** section
   shows these commands with the bundled helper's path filled in; for a
   source build, run them by hand with the source-built executable as
   `<helper>`:

   ```sh
   claude mcp add --scope user berrydb -- "<helper>"
   codex mcp add berrydb -- "<helper>"
   agy mcp add berrydb -- "<helper>"
   ```

   One shared entry serves every repository; the helper picks the project
   from the host's workspace. Claude Code needs `--scope user` because its
   default scope, `local`, applies to the current project only; the `--`
   keeps any later `-`-prefixed argument an argument of the helper, which
   `agy mcp add --help` (1.3.1) requires. For a saved project the pane
   also shows "always this project" variants that append
   `--project <uuid>`; they are installed at the same user level and serve
   that project from every folder, whatever its link file or workspace
   folders would select. Both variants are named `berrydb`, so a host is
   set up with one or the other.

The helper accepts two optional arguments and rejects any other:
`--project <uuid>` and `--store-path <absolute path>`, the latter for a
store other than the app's.

## Packaging and signing

**Location.** `scripts/make_app.sh` copies the `berrydb-mcp` executable
built for the same configuration to `Contents/Helpers/berrydb-mcp` and
stops, for every configuration, when it is missing, since a bundle
without it ships a settings pane that cannot connect any agent. Every
script that packages the app builds the helper first. The helper links
the same Homebrew FreeTDS `libsybdb` as the app; packaging repoints that
reference at `@rpath/libsybdb.5.dylib`, the copy embedded in
`Contents/Frameworks` together with the OpenSSL it needs, and gives the
helper an `LC_RPATH` of `@executable_path/../Frameworks`. On 2026-10-09,
on macOS 26.6.2, a release build packaged this way loaded `libsybdb`,
`libssl` and `libcrypto` from `Contents/Frameworks` and nothing from
Homebrew (`DYLD_PRINT_LIBRARIES=1`), and answered `initialize` and
`tools/list` over standard input and output.

**Version.** An executable in `Contents/Helpers` has no `Info.plist` of
its own, so the helper reports to hosts the `CFBundleShortVersionString`
of the app around it, read from `Contents/Info.plist` after resolving
symbolic links. Packaged by `scripts/make_app.sh`, it reported the
version written there (`0.1.0` when `BERRYDB_VERSION` is unset), also
when started through a symbolic link. A build run from `.build` still
reports `dev`.

**Signing.** The helper is signed by the release pipeline's one
`codesign --force --deep --options runtime --timestamp` step over the
whole bundle, not separately: `--force --deep` re-signs nested code with
the outer options and replaces any signature made before it. Signed that
way with a non-ad-hoc identity on macOS 26.6.2, the helper carried the
hardened runtime flag, a secure timestamp, the outer identity and the
identifier `berrydb-mcp`, which is what its designated requirement, and
so a Keychain **Always Allow** entry, is tied to. An ad-hoc signature,
as development builds get, appends a per-build suffix to that
identifier. `deploy/release.sh` then fails the release unless the
helper's signature has the hardened runtime flag, a timestamp and the
team ID. Signing with the Developer ID identity and notarizing a bundle
that contains the helper have not been verified yet.

**Guard.** `scripts/check-size.sh` fails a bundle whose helper is
missing, links anything but system libraries, the Swift runtime and
`@rpath/libsybdb`, references an `@rpath` library absent from
`Contents/Frameworks`, or lacks that rpath; `scripts/check-minos.sh`
checks the helper's minimum macOS version as it checks the embedded
libraries'. The 200 MB bundle limit includes the helper: the release
bundle measured 132 MB with a 55 MB helper.

**Read-only volumes.** Each setup command embeds the helper's absolute
path, which must keep existing for as long as the host's entry does. An
app run from a mounted disk image loses that path when the image is
ejected, and Gatekeeper runs an app downloaded outside the Mac App Store
from "a randomized read-only location" until it is moved, usually to
`/Applications`
([`providerTranslocated`](https://developer.apple.com/documentation/fileprovider/nsfileprovidererror/providertranslocated)).
The pane therefore checks whether the app bundle's volume is mounted
read-only (`URLResourceKey.volumeIsReadOnlyKey`) and, when it is, shows
"Move BerryDB to the Applications folder and open it from there to set
up agents." instead of the commands. On macOS 26.6.2 the key read true
inside a compressed disk image mounted with `hdiutil` and false for
`/Applications`. It was not observed for a translocated app.

## Project selection and why it is not a boundary

Selection happens on the first request after `initialize` that needs it
(the first `tools/list`, `tools/call`, `resources/list` or
`resources/read`), not at `initialize`, because a server should send no
request other than pings and logging before the client's `initialized`
notification
([Lifecycle](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle#initialization)),
and `roots/list` is a request. A request sent before `initialize`, which
the same section asks clients not to send, is answered with a selection
made without roots, from `--project` or the working directory, and that
selection is not kept, so one early request cannot fix the project before
the host's roots are known. The inputs are tried in this order:

1. `--project <uuid>` if given; roots are then never requested.
2. Else the workspace roots from MCP `roots/list`, if the host declared the
   roots capability. The request is made once per connection and bounded to
   5 seconds; no answer, an error or a timeout falls through to the next
   input. Roots that are not `file:` URIs are ignored.
3. Else the process working directory.

Within roots or the working directory, each workspace is decided on its
own:

- **By its link file when it has one.** The nearest `.berrydb.json` at or
  above the workspace, stopping before `/`, names the project as
  `{"project": "<name>"}`. Names match case-insensitively after trimming
  surrounding whitespace, and the settings pane refuses two projects whose
  names match this way. A file larger than 4 KiB, one that is not a JSON
  object with a non-empty `project` string, or an entry that cannot be read
  as a regular file, including a symbolic link (never followed), is
  invalid; it is reported, never skipped, so a link does not silently give
  way to another input. A readable regular file owned by another user is
  ignored as if absent, and the walk continues upward; a file this user
  cannot read, or a FIFO, is invalid like any other unusable entry. Other
  keys are ignored.
- **Otherwise by registered workspace folders.** A workspace matches a
  project when it equals or is contained in one of the project's workspace
  folders, compared on path components after resolving symlinks and the
  file system's spelling of case. A folder that resolves to `/` is never
  used. The longest matching folder wins; an exact tie between two projects
  is ambiguous.

The workspaces of an input are then combined: an invalid link file is
reported first (`invalid_link_file`), then a linked name no project has
(`linked_project_not_found`), then a tie between registered folders, a
linked name that more than one project matches (the settings pane refuses
such names, but the store file can still hold them), or workspaces naming
different projects (`ambiguous_projects`). One project is selected,
attributed to `linked_repository` when any contributing workspace used a
link file, else to `roots` or `working_directory`. When none of the roots has a link file
or a registered match, the working directory is tried, since a host may
open a folder BerryDB does not know; a reported problem or an ambiguity
among the roots never falls through. With nothing matched the session is
unconfigured with `no_matching_project`.

The outcome, a project or a reason, is kept for the connection: a project
created or re-mapped in the app is picked up by the host's next session.
Verification is not kept: every request re-reads the selected project's row
and the integrity key, so a project disabled or deleted in the app stops
being served on the next request (`project_disabled` or
`no_matching_project`), a project enabled in the app is served from the
next request, including one that was disabled when the session selected
it, and a key rotated by the app applies from the next request. If the
store cannot be read, that request reports `integrity_unavailable` and
writes one line to standard error, and the next request tries again.

The server declares no `listChanged` tools capability, so it never tells a
host that its tool list changed
([Tools: Capabilities](https://modelcontextprotocol.io/specification/2025-11-25/server/tools#capabilities)).
A host that keeps the `tools/list` answer it fetched when the session
started goes on showing only `berrydb_status` after its project is enabled,
or all six tools after it is disabled, until a new agent session starts;
the settings pane says so.

### Status

`berrydb_status` returns every field on every call:

| Field | Value |
|---|---|
| `state` | `selected` or `unconfigured` |
| `reason` | null when selected; otherwise `no_matching_project`, `ambiguous_projects`, `explicit_project_not_found`, `project_disabled`, `integrity_unavailable`, `linked_project_not_found` or `invalid_link_file` |
| `project` | `{"id", "name"}` of the selected project, else null |
| `selected_by` | `explicit`, `roots`, `working_directory` or `linked_repository`, else null |
| `workspace` | the location that decided the selection: the folder holding the link file for `linked_repository`, the host root or working directory that a workspace folder matched for `roots` or `working_directory`, null for `explicit`; the same location when that project is now `project_disabled` or `no_matching_project`. Otherwise, when unconfigured: the folder holding the link file for `invalid_link_file` and `linked_project_not_found`, the working directory when it was the input that failed, null for the rest |
| `linked_project` | the name a link file gave when no project has it, else null |
| `live_reads` | always `not_available` in this version |
| `integrity` | when selected: `verified` if the project row's tag verifies under the stored key, `unavailable` if it does not or no key could be read; when unconfigured: `unavailable` for `integrity_unavailable` (the store could not be read), null for every other reason |

The project row's tag covers the project's ID, its enabled flag and its
workspace folders, and nothing else. It does not cover the project's name,
which link files select by, and a connection's access row is checked only
when it claims live reads: the connections a project lists, and serves
metadata for, are taken from the stored rows whether or not their tags
verify. `verified` therefore says that the ID, enabled flag and workspace
folders are as the app last saved them, not that the name or the list of
connections is.

A project whose tag does not verify is still selected and served metadata:
schema and graph metadata expose nothing a same-user process cannot read
from the store file directly. What the tag gates is live reads.

### Why selection is not a boundary

Selection identifies which project a session is *for*, not which project a
process is *authorized* to reach. Per the threat model, a process on the same
machine can pass `--project` for any project ID stored locally, so selection
limits accidental cross-project exposure and mistakes, not deliberate
misuse. The capabilities available once a project is selected — whether
`liveRead` is on for a profile — are the actual gate, and that gate is
verified independently through row integrity (below), not through how the
project was chosen.

A link file comes from the repository, which is untrusted: any repository
whose `.berrydb.json` names a project, including one cloned from someone
else, selects that project on the machine, and opening it in a coding
agent then exposes that project's schema and graph metadata to the agent
and to its model provider. The file decides its workspace before the
workspace folders registered in the app, so it also wins inside a folder
registered for another project. The settings pane states this where it
offers repository links. A link only selects; live reads, once they exist,
still require the sealed per-profile opt-in made in the app. The walk up
from a workspace also passes folders other users can write to, such as
`/private/tmp` or `/Users/Shared`. A `.berrydb.json` file another local
user owns there is ignored, as git refuses to read the configuration of a
repository another user owns
([`safe.directory`](https://git-scm.com/docs/git-config#Documentation/git-config.txt-safedirectory)),
so it selects nothing. That applies to a regular file this user can read;
anything else of that name another user leaves there, such as a folder, a
symbolic link, a FIFO or a file this user cannot read, reads as
`invalid_link_file` for workspaces below it with no nearer link: a denial,
not a selection. A link in the home
folder applies to every folder inside it without a nearer link, including
another project's workspace folders; the settings pane warns when it writes
one there.

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
whole project, and `berrydb_status` reports it as `integrity:
"unavailable"`; a bad row tag disables live reads for that profile only,
which has nothing to report until live reads exist. Schema and graph access
continue regardless, since they expose nothing the same-user adversary
cannot already read from the store file directly.

Each profile-access tag also covers a fingerprint of the connection endpoint
taken from the stored connection profile (payload domain
`berrydb.mcp.profile-access.v2`): driver, SQLite file path, host, port, user,
database (for DynamoDB these fields carry the endpoint override, access key
ID and region), TLS mode and certificate/key paths, MongoDB additional hosts
and replica set, the Elasticsearch API-key switch, and SSH enabled/host/
port/user/key path. Without it, a process that can write the store file could
point a live-read profile at a server it controls and receive the credentials
the helper reads from Keychain. The app computes the fingerprint from the
stored profile when it seals the row; the helper recomputes it from the
profile row as it is at verification time. Any change to those fields — or
a profile row that no longer exists — leaves the access row unverifiable,
failing closed, until the app re-seals it; because the editing copy of a
project turns an unverifiable `liveRead` off, re-sealing after an endpoint
change means turning live reads on again for the new endpoint. Display
fields (name, group, environment label, sort order, history switch) are not
part of the fingerprint.

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

Deleting a project is a settings change like any other: the key is rotated
in the same order and every remaining project's verifiable rows are
re-sealed, so a copy of the deleted project's rows restored into the file
does not verify. Deleting a connection profile removes its access rows by
cascade without a rotation. A restored copy of those rows could verify
again, which is acceptable because the profile's secrets are deleted from
Keychain with it: the helper has no credential to send, and a connection
that needs none is one the same-user process can already open without
BerryDB.

Redaction by result-column name is best effort, not a boundary. The name it
matches is whatever the query labels a result column, so an alias
(`SELECT email AS x`), an expression over the column, or a whole-row value
(`SELECT u FROM users u`) carries a sensitive value past it. Database column
privileges on the MCP profile's database user are the boundary for sensitive
columns: a column the user cannot select cannot be returned under any name.

Known limitation: with legacy file-keychain items, a same-user process able
to delete or pre-create the HMAC key item could choose the key, and with it
sign access settings BerryDB never wrote. Closing this needs a
data-protection Keychain access group or an app-written ACL on the key item,
which is packaging work (see
[gate G1](../mcp-server-compatibility.md#g1-keychain-sharing)).

## Read-only enforcement layers

These layers are the design for live reads, which no tool offers yet. What
exists today: the SQL policy parser (layer 3), and a connection coordinator
that no tool uses, which admits only SQLite sessions, sets `PRAGMA
query_only` on them, and rejects every other driver because its read-only
session is not implemented. The PostgreSQL and MySQL read-only sessions and
the least-privilege check (layers 1 and 2, whose queries
[gate G3](../mcp-server-compatibility.md#g3-privilege-checks) verified) and
DynamoDB access (layer 4) are not implemented.

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
the settings UI is to require reviewing the redacted-column list and
acknowledging that reads use database resources and take shared locks, which
can delay DDL or migrations. Once enabled, the profile is subject to the
stricter production-labeled limits below. The settings pane does not show
the live-read switch yet; saving a project carries each profile's `liveRead`
over from the verified editing copy, so a save never turns one on.

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

## Implemented and planned

Implemented:

- `BerryCredentials` key storage; the `MCPProject`/`MCPProfileAccess` model
  with no grant step; per-row HMAC-SHA256 integrity and key rotation on
  settings save.
- `berrydb-mcp` as a stdio MCP server over the store opened read-only, with
  the host compatibility rules recorded in
  [`../mcp-server-compatibility.md`](../mcp-server-compatibility.md).
- The six metadata tools and the two kinds of resources above, served from
  the persisted schema and dependency graph.
- Project selection by `--project`, roots or working directory, each
  workspace decided by its `.berrydb.json` or by registered workspace
  folders; selection on the first request, verification on every request,
  and `berrydb_status`.
- The **AI Agents** settings pane: projects, workspace folders, repository
  links and connections, and setup commands for the bundled helper,
  withheld while the app runs from a read-only volume.
- Packaging: the helper in `Contents/Helpers`, its libraries embedded and
  its signature made by the bundle's deep sign, checked by the release
  pipeline and guarded by `scripts/check-size.sh` and
  `scripts/check-minos.sh` (see [Packaging and signing](#packaging-and-signing)).
- Groundwork no tool uses yet: a SQL-only connection coordinator with
  bounded shutdown, the SQL read policy parser and the byte-exact result
  limiter.

Not implemented:

- Live reads: `berrydb_execute_read_query` for PostgreSQL and MySQL
  (session read-only plus the least-privilege check,
  [gate G3](../mcp-server-compatibility.md#g3-privilege-checks)) and SQLite
  (sessions opened with `SQLITE_OPEN_READONLY`), and `berrydb_dynamodb_query`
  (`Query` only, never `Scan`); the live-read switch and the production
  consent in the settings pane; the production-labeled limits.
- The audit log.
- A read of the integrity key that never shows a Keychain dialog: the
  app adding the helper's designated requirement to the item's access
  list; closing the Keychain key-planting gap noted above (deleting or
  pre-creating the key item).
- Verification of Developer ID signing and notarization of a bundle that
  contains the helper, and of the Keychain dialog with such a helper.
- Any Cursor verification.
