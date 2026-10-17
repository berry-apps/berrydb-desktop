# Local MCP Server Architecture

Status: **metadata tools and live reads**. `berrydb-mcp` runs as a stdio MCP
server over the app's store opened read-only. It serves seven metadata tools
and two kinds of resources for one selected project, and, when the project has
a connection with live reads turned on, `berrydb_execute_read_query` (see
[Tools and resources](#tools-and-resources)). The project is selected by
an explicit `--project`, which takes a project ID or name, or else from
the host's workspace roots or the working directory, matched against the
workspace folders registered in the app. The app's **AI Agents** settings
pane creates and edits projects; it shows the host setup commands for the
helper bundled in the app (see [Packaging and signing](#packaging-and-signing)).
Underneath sit key storage, the `MCPProject` persistence model, HMAC-SHA256
row integrity and key rotation, a SQL-only connection coordinator with
bounded shutdown, the SQL read policy parser and a byte-exact result
limiter carry the live read (see
[Read-only enforcement layers](#read-only-enforcement-layers)). See
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
  profile allows it, bounded read-only SQL queries (see [Live reads](#read-only-enforcement-layers)).

The server does not replace, relax, or share state with the client's
allowlist, approval flow, or trust model. `berrydb-mcp` is a second, headless
composition root: it registers its own drivers (and constructs its own
connection coordinator for live reads), and cannot inherit live registry
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
| Helper-side tool surface (read-only tools, no `Scan`) | Yes | Enforced in signed code the agent cannot modify. |
| Database read-only session for live reads | Yes | Enforced by the database itself, and the only boundary on what a live read can change (see [Read-only enforcement layers](#read-only-enforcement-layers)). |
| SQL read policy | No (defense in depth) | Refuses a statement before it reaches the server, but it is lexical: it cannot see a function behind a view, an operator or a cast. |
| Privilege check when live reads are turned on | No (warning) | Settings warns when the connection's database user can write; the owner can confirm and turn live reads on anyway. |
| SELECT-only database user | Yes, where configured | Enforced by the database. Recommended, not required: nothing checks for it except the warning above. |
| Default result limits (rows, size, time) | Yes | Enforced in signed code. |
| Stricter limits of a production-labeled connection | No | The label is stored outside the sealed fields, so these limits guard against mistakes, not against a same-user process that edits the store file (see [Limits](#limits)). |
| Per-profile live-read setting, redacted columns and project settings | Yes, via integrity check | Stored in a user-writable file; an HMAC keyed from Keychain is what stops the agent from enabling itself. |
| Project selection (which project a process serves) | No | A process can pass `--project` with any project ID or name it can read from the store, and a repository's own agent configuration can name any project. An interactive Claude Code session asks before it uses a repository's `.mcp.json` and Codex reads a repository's `.codex/config.toml` only for a trusted project, but `claude -p` runs, Agent SDK sessions and cloud sessions load a repository's `.mcp.json` without asking ([Project scope](https://code.claude.com/docs/en/mcp#project-scope)). Selection prevents mistakes and limits exposure; it does not stop a hostile agent or repository from reaching another project's already-enabled capabilities. |
| Audit log | No (visibility only) | The agent can edit it. |

Every guarantee this document calls a boundary holds for any project a
process can name, not only the project of the current workspace. Data
returned by any tool leaves BerryDB and is visible to the MCP host and
potentially its model provider; running the server locally does not keep
returned data on the Mac.

## Tools and resources

Every tool is read-only. All but `berrydb_execute_read_query` read only the store: the schema and dependency
graph the app last harvested for a connection, never the database itself.
Every answer that reads the stored schema carries `checked_at` (when a pass
last confirmed that schema against the database, or null if none has) and
`stale` (true when it was never checked or was last checked more than 60 s
ago), so an agent can tell a stored answer from a current one.
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
| `berrydb_list_connections` | none | The project's connections: ID, name, driver, `environment` (`production` or `unlabeled`), capabilities and the state of the stored schema. `graph_harvested_at` is the time of the last pass that changed the schema (a pass that found it unchanged, or that only refreshed statistics, does not move it), or null when the connection was never harvested or its stored schema holds no table or view. `checked_at` and `stale` are as above. `stale_reason` is, for a stale schema, the code of the failure that stopped its last pass (`connection_failed`, `timeout`, `cancelled`, `store_write_failed` or `introspection_failed`), never text a server wrote, and null otherwise. `detail_coverage` is `{detailed, total}`: how many stored tables and views have had their columns read. `scope` lists the schemas the harvest is limited to, or is null for the default scope: every user schema, except on MySQL and MariaDB, where it is the connection's database when the profile names one. `hint` is `selectSchemas` when the catalog is too large to harvest whole and schemas should be selected in the app, else null. |
| `berrydb_get_schema` | `connection_id`; optional `object_names` (at most 50), `detail` (`overview` or `full`, default `overview`), `offset` (0 or more, default 0) | One page of tables and views from `offset`: at most 200 objects, and at `full` detail as many as fit an estimated 512 KB, never fewer than one. The page reports `total` (all matching objects), `omitted_count` (those after the page), `next_offset` (pass it back as `offset`; null on the last page), `harvested_at` (when the schema last changed, as `graph_harvested_at`, omitted when none), `checked_at` and `stale`. `full` adds columns, indexes and foreign keys. An object with `detail_pending: true` is listed but its columns have not been read yet, so its `columns`, `indexes` and `foreign_keys` are empty: at `overview` the flag says whether a definition exists, at `full` it marks a definition still missing. |
| `berrydb_search_schema` | `connection_id`, `query` (1–200 characters after trimming); optional `limit` (1–200, default 50) | Case-insensitive, literal substring matches over table, view, column and index names, each with `name`, `kind` and, where known, `database` and `table` (the owner of a column or index), ordered by kind (table, view, column, index), then database, owning table and name; plus `checked_at` and `stale`. |
| `berrydb_graph_query` | `connection_id`, `operation`; `node` for `neighbors` and `blast_radius`, `from` and `to` for `path`, optional `limit` (1–50) for `top_centrality` | The dependency-graph answer. The name lists of `neighbors`, `blast_radius` and `circular_dependencies` are capped at 500; a `path` is returned whole, bounded only by the 1 MiB result ceiling. `circular_dependencies` takes no further argument. |
| `berrydb_get_graph_stats` | `connection_id`; optional `object` | Harvested statistics (rows, size, scans) for every table, or for one table and its indexes. A summary lists the first 500 tables by name and the unused indexes of those tables, at most 500 names. |
| `berrydb_get_schema_changes` | `connection_id`; optional `since` (at most 64 characters), `limit` (1–200, default 50) | The schema changes the app recorded, oldest first, with `next_since`, `checked_at` and `stale`. Each entry has `at`, `kind` (`added`, `changed`, `removed`, `relation_added` or `relation_removed`), `name`, `database` where it has one and `object_kind` (`table` or `view`). A `changed` entry carries `diff` (columns and indexes added, removed or changed, and whether the columns were reordered) when both versions have a readable definition; a relation entry carries `relation`, as `source.column -> target.column`, and is named after its source table. `since` left out lists every change, an ISO 8601 time for the changes written at or after it, or the `next_since` of an earlier page; `next_since` is opaque, is null once no entry remains, and resumes at the same entry however many changes are written later. A page can stop inside one change, since a first harvest records every object as one change. Only the changes of passes that completed are listed, those written at or before `checked_at`, so a pass still running is not listed until a later one completes; a connection never checked returns an empty page. |

With no project selected, `tools/list` returns only `berrydb_status` and
every other tool answers that no project is selected; nothing about any
project is revealed. A `connection_id` that does not exist and one that
exists but is not assigned to the project produce the identical error text,
`Unknown connection for this project`. A graph name that matches several
nodes is an `isError` result that lists at most 50 tables or views. Each is
named so that it resolves to that one node: its `database.name`, or its
stable id (for example `table:shop.orders`) when that name is shared. A
count of the rest follows. A name that matches only columns or indexes is
told to pass a table or view name. A `since` that is neither an ISO 8601
time nor a cursor from an earlier page is a tool result with `isError`,
`Invalid since cursor`, which does not repeat it; one longer than 64
characters, or a negative `offset`, is an invalid-params error. A
connection whose stored schema holds no table or view answers the schema,
search and graph tools with `No schema graph has been harvested for this
connection. Open it in BerryDB to refresh.`
An unknown tool, or (while a project
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
statistics, with `harvested_at`, `checked_at` and `stale`). An
unconfigured session lists no resources, and any unknown, malformed or
out-of-project URI gets the identical `Unknown resource` error.

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
   Folders** (every folder below one is included) or name the project in
   the repository's own agent configuration
   ([Per-repository agent configuration](#per-repository-agent-configuration)).
3. **Each host, once.** Run one command per host, each adding a
   user-level entry named `berrydb`. The pane's **Agent Setup** section
   shows these commands with the bundled helper's path filled in; for a
   source build, run them by hand with the source-built executable as
   `<helper>`:

   ```sh
   claude mcp add --scope user berrydb -- '<helper>'
   codex mcp add berrydb -- '<helper>'
   agy mcp add berrydb -- '<helper>'
   ```

   One shared entry serves every repository; the helper picks the project
   from the host's workspace. Claude Code needs `--scope user` because its
   default scope, `local`, applies to the current project only; the `--`
   keeps any later `-`-prefixed argument an argument of the helper, which
   `agy mcp add --help` (1.3.1) requires. For a saved project the pane
   also shows "always this project" variants that append
   `--project <uuid>`; they are installed at the same user level and serve
   that project from every folder, whatever workspace folders would
   select. Both variants are named `berrydb`, so a host is set up with one
   or the other.

The helper accepts two optional arguments and rejects any other:
`--project <uuid|name>` and `--store-path <absolute path>`, the latter for
a store other than the app's. A `--project` value that is a UUID once
surrounding whitespace is trimmed is a project ID, and only ever an ID,
even when some project is named that way; any other non-empty value is a
project name, matched without letter case after trimming surrounding
whitespace. The settings pane refuses to save a project whose name
matches another project's that way, and warns when a rename stops
matching the old name. An empty value is rejected, and the error never
echoes the value given.

### Per-repository agent configuration

A repository can carry its own agent entry that passes `--project <name>`,
so every clone selects the project of that name without registering a
folder in the app. Use the name, not the ID: an ID differs in every store,
while a name also matches a teammate's project of the same name. In
interactive use, the hosts that support this gate configuration a
repository defines behind the user's trust (details below); the helper
adds no gate of its own. For a saved project, and once the helper is
bundled, the pane's **Agent Setup** section shows these entries with the
helper path and the name filled in.

The pane single-quotes the helper path and the project name in every
command it shows, writing an embedded `'` as `'\''`. Inside POSIX single
quotes every character is literal; inside double quotes an interactive
bash or zsh still expands `!`, so `"it!!s"` would paste in the previous
command (observed with /bin/bash 3.2.57 and zsh 5.9 on macOS 26.6.2). The
Codex entry writes both values as TOML basic strings instead.

- **Claude Code.** Run in the repository's top folder:

  ```sh
  claude mcp add --scope project berrydb -- '<helper>' --project '<name>'
  ```

  This writes `.mcp.json` in that folder, which can be committed. Claude
  Code asks for approval in an interactive session before it uses a server
  from `.mcp.json`, and loads it without asking in `claude -p` runs, Agent
  SDK sessions and cloud sessions
  ([Project scope](https://code.claude.com/docs/en/mcp#project-scope)).
  Once approved, the repository's entry takes precedence over a user-level
  `berrydb` entry, which the documentation ranks below project scope
  ([Scope hierarchy and precedence](https://code.claude.com/docs/en/mcp#scope-hierarchy-and-precedence));
  until then the user-level entry is used. The pane's caption says so.
  Observed on 2026-10-09 with Claude Code 2.1.295 and a throwaway `HOME`:
  `claude mcp add --scope project berrydb -- /usr/bin/true --project "repo
  pinned"` wrote `.mcp.json` in the current folder with
  `"args": ["--project", "repo pinned"]`, and `claude mcp list` showed the
  entry as ``⏸ Pending approval (run `claude` to approve)``. Writing
  `enabledMcpjsonServers` into the folder's `.claude/settings.local.json`
  did not approve it. With a user-level `berrydb` entry also present,
  `claude mcp list` and `claude mcp get berrydb` used the user-level entry
  while the project entry was pending. Once the approval was recorded in
  `~/.claude.json` under `projects["<folder>"]`
  (`enabledMcpjsonServers: ["berrydb"]`, `hasTrustDialogAccepted: true`),
  both used the project entry and `claude mcp get berrydb` reported
  `Scope: Project config (shared via .mcp.json)`. `claude mcp list` printed
  a `[Conflicting scopes]` diagnostic for `berrydb` in both states.
- **Codex.** Add to the repository's `.codex/config.toml`:

  ```toml
  [mcp_servers.berrydb]
  command = "<helper>"
  args = ["--project", "<name>"]
  ```

  Codex reads that file only for a trusted project, and there it takes
  precedence over the user-level `berrydb` entry. Observed on 2026-10-09
  with codex-cli 0.157.1 and a throwaway `HOME`, with
  `[mcp_servers.berrydb]` in the user `config.toml` (`args = []`) and in a
  repository's `.codex/config.toml` (`args = ["--project",
  "repo-pinned"]`): `codex mcp get berrydb` run inside the repository
  showed `args: --project repo-pinned` when the user configuration marked
  the folder `trust_level = "trusted"`, and `args: -` in an untrusted
  folder.
- **Antigravity.** No per-repository entry. Observed on 2026-10-09 with
  agy 1.3.1: `agy mcp list` inside a folder holding
  `.agents/mcp_config.json` (and `.agent/mcp_config.json`) with a server
  named `berrydb-ws` listed only the user-level server, and the CLI's
  embedded documentation names only `~/.gemini/config/mcp_config.json` and
  `plugins/<name>/mcp_config.json`.

Nothing was installed into a real host configuration for these
observations.

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
whole bundle, not separately: `man codesign` (macOS 26.6) lists
`Contents/Helpers` among the places `--deep` signs and says every
signing option, the (empty) entitlements included, applies to nested
code, and `--force --deep` replaces any signature made before it. That
command was run on a copy of the bundle with a throwaway self-signed
code-signing certificate, the only non-ad-hoc identity used: the helper
carried the hardened runtime flag, a secure timestamp, that certificate
as authority and the identifier `berrydb-mcp`, which is what its
designated requirement, and so a Keychain **Always Allow** entry, is
tied to. An ad-hoc signature, as development builds get, appends a
per-build suffix to that identifier. That a Developer ID signature keeps
the same identifier, and with the team the same designated requirement,
from one release to the next is inferred from that experiment, not
observed. `deploy/release.sh` then fails the release unless the helper's
signature has the hardened runtime flag, a timestamp and the team ID. A
self-signed certificate has no team, so that last check has not yet run
against a signature that should pass. Signing with the Developer ID
identity and notarizing a bundle that contains the helper have not been
verified yet.

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

1. `--project` if given; roots are then never requested. An ID or a name
   that no project has is `explicit_project_not_found`, and a name that
   several projects share, possible only in a store edited outside the
   app, is `ambiguous_projects`; neither falls through to the next input.
2. Else the workspace roots from MCP `roots/list`, if the host declared the
   roots capability. The request is made once per connection and bounded to
   5 seconds; no answer, an error or a timeout falls through to the next
   input. Roots that are not `file:` URIs are ignored.
3. Else the process working directory.

Within roots or the working directory, each workspace is matched against
the registered workspace folders. A workspace matches a project when it
equals or is contained in one of the project's workspace folders, compared
on path components after resolving symlinks and the file system's
spelling of case. A folder that resolves to `/` is never used. The longest
matching folder wins; an exact tie between two projects is ambiguous.

The workspaces of an input are then combined: a tie on any of them, or
workspaces matching different projects, is `ambiguous_projects`;
otherwise the one project matched is selected, attributed to `roots` or
`working_directory`. When none of the roots matches, the working directory
is tried, since a host may open a folder BerryDB does not know; an
ambiguity among the roots never falls through. With nothing matched the
session is unconfigured with `no_matching_project`.

The outcome, a project or a reason, is kept for the connection: a project
created or re-mapped in the app is picked up by the host's next session.
A project selected by name is kept by its ID, so renaming it in the app
does not change the session's selection.
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
or all seven tools after it is disabled, until a new agent session starts;
the settings pane says so.

### Status

`berrydb_status` returns every field on every call:

| Field | Value |
|---|---|
| `state` | `selected` or `unconfigured` |
| `reason` | null when selected; otherwise `no_matching_project`, `ambiguous_projects`, `explicit_project_not_found`, `project_disabled` or `integrity_unavailable` |
| `project` | `{"id", "name"}` of the selected project, else null |
| `selected_by` | `explicit`, `roots` or `working_directory`, else null |
| `workspace` | the location that decided the selection: the host root or working directory that a workspace folder matched for `roots` or `working_directory`, null for `explicit`; the same location when that project is now `project_disabled` or `no_matching_project`. Otherwise, when unconfigured: the working directory when it was the input that failed, null for the rest |
| `live_reads` | `available` when the project has a connection with live reads turned on whose driver supports them and whose settings verify (the connections `berrydb_execute_read_query` accepts), else `not_available` |
| `integrity` | when selected: `verified` if the project row's tag verifies under the stored key, `unavailable` if it does not or no key could be read; when unconfigured: `unavailable` for `integrity_unavailable` (the store could not be read), null for every other reason |
| `connections` | when selected: one entry per connection of the project, `{"id", "name", "checked_at", "stale", "stale_reason", "hint"}` as `berrydb_list_connections` reports them, so an agent learns how fresh each stored schema is, why a stale one is, and which needs its schemas selected in the app; null when unconfigured or when the store could not be read |

The project row's tag covers the project's ID, its enabled flag and its
workspace folders, and nothing else. It does not cover the project's name,
which `--project <name>` selects by, and a connection's access row is
checked only when it claims live reads: the connections a project lists,
and serves metadata for, are taken from the stored rows whether or not
their tags verify. `verified` therefore says that the ID, enabled flag and workspace
folders are as the app last saved them, not that the name or the list of
connections is.

A project whose tag does not verify is still selected and served metadata:
schema and graph metadata expose nothing a same-user process cannot read
from the store file directly. What the tag gates is live reads.

### Why selection is not a boundary

Selection identifies which project a session is *for*, not which project a
process is *authorized* to reach. Per the threat model, a process on the same
machine can pass `--project` with any project ID or name stored locally,
so selection limits accidental cross-project exposure and mistakes, not
deliberate misuse. The capabilities available once a project is selected — whether
`liveRead` is on for a profile — are the actual gate, and that gate is
verified independently through row integrity (below), not through how the
project was chosen.

A repository's own agent configuration can name a project with
`--project <name>` (see
[Per-repository agent configuration](#per-repository-agent-configuration)).
Once the agent uses that configuration, the repository selects that
project as surely as a registered folder would, including a repository
cloned from someone else that happens to name one of the user's projects,
and opening it in the agent then exposes that project's schema and graph
metadata to the agent and its model provider. Whether the agent uses it
depends on the host and how it runs. An interactive Claude Code session
asks before it uses a server from a repository's `.mcp.json`, and Codex
reads a repository's `.codex/config.toml` only for a trusted project.
`claude -p` runs, Agent SDK sessions and cloud sessions load a
repository's `.mcp.json` without asking
([Project scope](https://code.claude.com/docs/en/mcp#project-scope)); in
those modes the repository can already start any command the user can
run, so naming a BerryDB project in it reaches nothing beyond what running
an agent in that repository already grants. Selection by name, like any
selection, never turns on live reads, which still require the sealed
per-profile opt-in made in the app.

### Withdrawn before release: repository link files

Development builds once selected a project through a `.berrydb.json`
file, `{"project": "<name>"}`, which the helper looked up at and above each
workspace, ahead of the registered workspace folders, and which the
settings pane could write into a chosen repository. It was removed before
any release shipped it. A file inside the repository selected one of the
user's projects with no prompt, so any cloned repository naming a project
the user has got that project's schema metadata, even in an interactive
Claude Code session that would have asked before starting a server the
repository defines. A per-repository agent entry that passes
`--project <name>` goes through the host's own handling of repository
configuration instead: an interactive Claude Code session asks before it
uses a server from a repository's `.mcp.json`, and Codex reads a
repository's `.codex/config.toml` only for a trusted project. `claude -p`
runs, Agent SDK sessions and cloud sessions load a repository's
`.mcp.json` without asking
([Project scope](https://code.claude.com/docs/en/mcp#project-scope)), but
there the repository can already start any command the user can run, so
naming a BerryDB project in it adds nothing beyond what running an agent
in that repository already grants. A file in the repository that the
helper reads on its own should not come back without a gate of its own.

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
which makes that connection unavailable to the live-read tool. Schema and graph access
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

`berrydb_execute_read_query` runs one read-only SQL statement on a PostgreSQL,
MySQL/MariaDB or SQLite connection whose live reads the user turned on in the
**AI Agents** pane. It is listed only when the selected project has such a
connection with settings that verify; with none, `tools/list` omits it.
Input: `connection_id`, `sql` (at most 65,536 bytes of UTF-8), optional `parameters` (at most
100 scalars: `$1`, `$2`, … on PostgreSQL, `?` on MySQL/MariaDB and SQLite) and
`row_limit` (1–100). Output: `columns`, `rows` (arrays), `row_count`,
`truncated`, `has_more_rows`, `truncated_cells`, `byte_limit_reached`,
`elapsed_ms` and `redacted_columns`. Unlike the metadata tools it reads the
database, so it declares `openWorldHint: true` and no `idempotentHint`.

`DangerGuard`, `QueryToolExecutor.isReadOnly`, and `dangerPreconfirmed: true`
are never used in MCP code. Enforcement is layered. The database's own
read-only mode is the boundary. The privilege check is a warning shown
before live reads turn on, which the owner can confirm and go past, and the
SQL read policy is defense in depth that refuses a statement before it
reaches the server:

1. **Database session read-only, per statement.** PostgreSQL: `BEGIN READ
   ONLY` with a statement timeout and a lock timeout. MySQL/MariaDB: a
   read-only session plus `START TRANSACTION READ ONLY`. SQLite: `PRAGMA
   query_only` set again before every statement. The SQLite file is opened
   in the normal mode, not `SQLITE_OPEN_READONLY`, so `query_only` is what
   refuses a write. A driver that cannot enforce this does not advertise the
   tool.
2. **Privilege check, a warning before live reads turn on.** When live
   reads are switched on for a PostgreSQL or MySQL/MariaDB connection,
   Settings checks whether its database user could write, including
   through inherited roles, `rds_superuser` membership, ownership, or
   column-level write privileges (the queries and how they were verified are
   in [Privilege checks](../mcp-server-compatibility.md#g3-privilege-checks)).
   A user that can write, or a check that cannot run or cannot read the
   server's answer, produces a warning; the owner can confirm it and turn
   live reads on anyway, and the helper never refuses such a user. A
   SELECT-only database user is recommended, not required, and for a
   production database a read replica. SQLite has no equivalent step.
3. **Statement allowlist and SQL policy parser, defense in depth before
   the server sees the text.** Exactly one statement, an enumerated read
   grammar, a function allowlist, deny-by-default for anything not
   understood. It cannot see function invocation written without `name(`
   syntax — attribute notation, operators, casts, `search_path` shadowing,
   views, or defaults — so it stops side-effecting calls the session-level
   guard misses (e.g. `dblink`, file-reading functions, `pg_sleep`, advisory
   locks) rather than substituting for layer 1. Nothing requires the
   PostgreSQL user to lack `CREATE` on the schemas in its `search_path`;
   the privilege check reports it as `schema_create`. A user that has it
   can create a function that shadows an allowlisted name, and only the
   read-only session then refuses that function's writes.
4. **Bound parameters.** Values go to the driver as parameters, never into the
   SQL text, and the helper checks the placeholder count against
   `parameters`. On MySQL/MariaDB the count cannot always be made reliable, so
   the helper refuses parameters when a text value contains NUL, when a
   MariaDB session is in `MSSQL` or `ORACLE` mode, and when the client
   character set is not `utf8mb4`, `utf8mb3`, `utf8`, `latin1`, `ascii` or
   `binary`.

DynamoDB `Query` is not available: `berrydb_execute_read_query` refuses a
DynamoDB connection, and `Scan` and PartiQL are never issued from MCP code.

Known limitation: on MySQL and MariaDB, `SELECT … INTO OUTFILE` and `INTO
DUMPFILE` write a file on the database server from inside `START
TRANSACTION READ ONLY` (verified against MySQL 8.4.11 and MariaDB 11.8.9
with the read policy bypassed). For a database user with the `FILE`
privilege, only the read policy, which refuses `INTO`, `OUTFILE` and
`DUMPFILE`, and the server's `secure_file_priv` stop it. The privilege
check lists `FILE` among its findings.

Once the arguments are valid, every failure is a one-line tool result. A
failure while resolving the connection or opening it (reading its secrets,
the SSH tunnel, the connection, the read-only session) is reported as fixed
text and the driver's error is never forwarded, because a connect error can
name a host, a user or a file path: `BerryDB could not connect to this
database.`, `BerryDB could not open a read-only session on this database,
so the query did not run.`, or `BerryDB could not open a connection to this
database within 15 seconds.` once the open budget in [Limits](#limits) has
passed. A connection the driver reports as lost gets the first of those
texts at any time. A query error raised once the statement runs is
forwarded in the driver's own words, prefixed `The database refused the
query:`, on one line, with every MySQL/MariaDB `'user'@'host'` account
masked, and cut at 500 characters. That covers the server's refusal and
also a client-side driver error during the read: the PostgreSQL driver
reports a connection dropped mid-read as a failed query, so it arrives in
the PostgreSQL client library's own text.

Returned rows leave BerryDB: they go to the calling MCP host and from there
potentially to that host's model provider; the server running locally does
not keep returned schema, graph, or row data on the Mac. Redaction hides
columns by name and is best effort, so only column privileges keep a column
from being returned.

## Limits

The production label on a profile only selects which row in the limits table
below applies; it never decides whether the profile can be read. That
decision is the per-profile `liveRead` switch alone, so an untagged
production database is never readable without `liveRead` either. A
production-labeled profile may be read live only after an explicit
per-profile opt-in: before `liveRead` can be turned on for such a profile,
the settings pane requires reviewing the redacted-column list and
acknowledging that reads use database resources and take shared locks, which
can delay DDL or migrations. Once enabled, the profile is subject to the
stricter production-labeled limits below. The pane's per-connection **Live
reads** switch exists for PostgreSQL, MySQL/MariaDB and SQLite connections.
A save applies the draft's live-read switches and redacted columns to the
verified editing copy of the project, in which a switch whose row does not
verify is already off. For each connection whose live reads the save turns
on (off in that copy, on in the draft) it requires the production consent
when the connection is production-labeled, and, on PostgreSQL and
MySQL/MariaDB, a finished privilege check run against the server and
account the stored connection still points at; a check that found a user
that can write, or could not run, also needs the confirmation to use the
connection anyway. A save that lacks any of these changes nothing. Live
reads that stay on are not checked again, and turning them off needs
nothing.

The production label is the connection's environment label, a display
field stored outside the sealed fields (see the fingerprint above). Whether
live reads are on, and which columns are redacted, are sealed; which row of
the table applies is not. The stricter production limits therefore guard
against mistakes, not against a process running as the same macOS user that
can edit the store file and remove the label.

| Limit | Default | Production-labeled profile |
|---|---|---|
| Opening the connection | 15 s | 15 s |
| Statement time limit | 30 s | 5 s |
| Rows / items per response | 100 | 50 |
| Serialized result | 1 MiB | 256 KiB |
| Encoded cell | 64 KiB | 64 KiB |
| Schema objects per response | 200 | 200 |
| Estimated size of a full-detail schema page | 512 KiB | 512 KiB |
| Graph nodes / edges | 500 / 1,000 | 500 / 1,000 |

A live read first has 15 s to resolve the connection, read its secrets
from Keychain, open any SSH tunnel and the connection, and make the session
read-only; past that it fails with `BerryDB could not open a connection to
this database within 15 seconds.` The statement then has the time limit
above, which the server enforces where it can: PostgreSQL through
`statement_timeout` (with a 5 s `lock_timeout`) on every statement, MySQL
through a `MAX_EXECUTION_TIME` hint and MariaDB through `SET STATEMENT
max_statement_time` on a statement that starts with `SELECT`. If the
server has not ended the statement one second after the limit, the helper
ends it; that is the only bound on SQLite, and on a MySQL or MariaDB
statement that does not start with `SELECT`. Either way the result is `The
query did not finish within 30 seconds.` (5 for a production-labeled
connection). A last bound of 47 s (15 + 30 + 2) covers the whole request,
including building the result and closing the session.

A schema page ends at 200 objects or, at `full` detail, at an estimated
512 KiB, whichever comes first, and `next_offset` continues it; the
estimate is half the 1 MiB result ceiling so that the page's own keys and
an estimate that runs short still fit. Graph queries share a per-process
cache of table-level graphs, at most 4 entries and 32 MB, each dropped
after 60 s unused.

Truncation is explicit (`truncated`, omitted counts, an opaque continuation
cursor where supported); the limiter's cost is linear in the rows it keeps,
not in the rows scanned.
A live read stops reading once it has the row limit: `has_more_rows` says the
server had more, `byte_limit_reached` that the serialized-result ceiling
ended the page, and `truncated_cells` counts cells cut at 64 KiB.

## Implemented and planned

Implemented:

- `BerryCredentials` key storage; the `MCPProject`/`MCPProfileAccess` model
  with no grant step; per-row HMAC-SHA256 integrity and key rotation on
  settings save.
- `berrydb-mcp` as a stdio MCP server over the store opened read-only, with
  the host compatibility rules recorded in
  [`../mcp-server-compatibility.md`](../mcp-server-compatibility.md).
- The seven metadata tools and the two kinds of resources above, served from
  the persisted schema and dependency graph.
- A versioned catalog store with one row per table, incremental harvest that
  rereads only what changed, and the schema change feed behind
  `berrydb_get_schema_changes`; the helper reads them through narrow, paged
  queries instead of loading a whole graph.
- Project selection by `--project` (a project ID or name), roots or
  working directory, matched against registered workspace folders;
  selection on the first request, verification on every request, and
  `berrydb_status`.
- The **AI Agents** settings pane: projects, workspace folders and
  connections, and setup commands for the bundled helper, including
  per-repository entries, withheld while the app runs from a read-only
  volume.
- Packaging: the helper in `Contents/Helpers`, its libraries embedded and
  its signature made by the bundle's deep sign, checked by the release
  pipeline and guarded by `scripts/check-size.sh` and
  `scripts/check-minos.sh` (see [Packaging and signing](#packaging-and-signing)).
- Live reads: `berrydb_execute_read_query` for PostgreSQL, MySQL/MariaDB and
  SQLite, with the per-statement database read-only mode, the SQL read
  policy, the privilege check and warning, the production-labeled limits,
  and, in **AI Agents**, the per-connection **Live reads** switch, redacted
  columns and the production consent.

Not implemented:

- A freshness channel from the app to the helper, so the helper can tell a
  stale answer from a current one by more than the age of the last check, and
  lazy connection and refresh timers in the app.
- Live reads on DynamoDB: `berrydb_dynamodb_query` (`Query` only, never
  `Scan`).
- The audit log.
- A read of the integrity key that never shows a Keychain dialog: the
  app adding the helper's designated requirement to the item's access
  list; closing the Keychain key-planting gap noted above (deleting or
  pre-creating the key item).
- Verification of Developer ID signing and notarization of a bundle that
  contains the helper, and of the Keychain dialog with such a helper.
- Any Cursor verification.
