# MCP Server Compatibility Gate

Date: 2026-09-26
Base: `8581f388376965b2759a27e913ceb7888ebd66b1`

The protocol gate below ran on 2026-09-26 against a fixture executable,
`MCPCompatibilitySpike`, that has since been removed. Its sections are a
record of what was tested then; the fixture's commands no longer run in
this repository. The current server, `berrydb-mcp`, was checked against
newer versions of the same three coding hosts on 2026-10-09: see
[Metadata tools host check](#metadata-tools-host-check).

## Decision

BerryDB's local stdio server implements MCP `2025-11-25` using the official Swift SDK pinned exactly to `0.12.1` (`a0ae212ebf6eab5f754c3129608bc5557637e605`). Do not claim MCP `2026-07-28` support.

The official 0.12.1 README and `Version.supported` source identify `2025-11-25` as the newest supported protocol. The newer `2026-07-28` protocol removes the initialize session lifecycle and introduces a stateless request envelope; adding `server/discover` alone would not make this SDK conformant. Re-run this gate before changing the declared protocol.

The selected package exports product `MCP`, requires Swift 6.1, and supports macOS 13 or newer. BerryDB uses Swift 6.3 and targets macOS 15. The upstream license file covers an Apache-2.0/MIT transition; its documentation is CC-BY-4.0. The newly introduced EventSource 1.5.1 transitive package is MIT licensed. Both are recorded in `THIRD-PARTY-NOTICES.md`.

## Fixture

`MCPCompatibilitySpike` was a production-shaped, strict stdio server using SDK APIs verified at tag 0.12.1:

- `Server(configuration: .strict)` and the initialize/initialized lifecycle;
- `StdioTransport`, with stdout reserved for newline-delimited JSON-RPC;
- `tools/list` with one read-only, idempotent, closed-world tool;
- `tools/call` for `berrydb_compatibility_echo`;
- an object input schema with no properties and `additionalProperties: false`;
- JSON-RPC `-32602` rejection for any unexpected argument;
- SDK cancellation handling and `waitUntilCompleted()` shutdown on EOF.

`BERRYDB_MCP_SPIKE_ECHO_DELAY_MS` was a spike-only cancellation seam. With `BERRYDB_MCP_SPIKE_EMIT_STARTED_MARKER=1`, the handler emitted a single stderr marker immediately before entering that delay, allowing the integration test to prove the call was in flight before cancellation. Neither setting added a tool argument, stdout content, or protocol capability, and neither exists in `berrydb-mcp`.

`HostCompatibleStdioTransport` is a narrow wrapper around the SDK's `StdioTransport` with one compatibility rule. It also writes each outgoing message whole before the next starts. The SDK's `StdioTransport.send` sleeps with its actor free whenever standard output is full, and the server sends each response from its own task, so two responses larger than the pipe could otherwise interleave on stdout.

The rule applies to inbound `initialize` messages only: it retains string-valued `params.capabilities.experimental` entries that 0.12.1 can decode and removes only object, array, null, numeric, and Boolean values; it removes the map only when no supported entry remains. Every other envelope field is semantically retained, including Codex's `elicitation.form` and `elicitation.url`. Non-initialize messages, initialize messages without `experimental`, and initialize messages whose experimental values are all strings are forwarded byte-for-byte; rewritten initialize JSON is semantically equivalent apart from the unsupported entries and may have different key ordering. This works around upstream [swift-sdk issue #262](https://github.com/modelcontextprotocol/swift-sdk/issues/262), where 0.12.1 models `experimental` as `[String: String]` even though MCP clients may send object-valued entries. Remove this rule only after upgrading to an exact pinned SDK release or commit whose arbitrary-object experimental regression passes with the wrapper disabled. BerryDB does not consume experimental client capabilities in this server.

A second rule intercepted request-shaped `server/discover` messages and replied with JSON-RPC `-32601 Method not found`, preserving the request identifier. It has been removed. The official 2026-07-28 [discovery specification](https://modelcontextprotocol.io/specification/2026-07-28/server/discover) defines discovery as the stdio backward-compatibility probe: dual-era clients should fall back to legacy `initialize` when discovery is unsupported, and Antigravity 1.2.11 does so only on `-32601`. The fixture used for the host gate ran `.strict`, under which the pinned SDK sends no response at all to a request other than `initialize` or `ping` before initialization, so the rule was needed there. `berrydb-mcp` runs the SDK's default configuration, under which the SDK itself answers a method it has no handler for, `server/discover` included, with `-32601`; the rule only repeated that answer. `BerryMCPStdioTests` pins the contract: the captured Antigravity request gets `-32601`, then legacy initialize and list succeed. Switched to `.strict`, the server would leave that request unanswered and the test would time out, as observed on 2026-10-09. BerryDB still does not advertise or implement stateless MCP 2026-07-28.

The fixture target was removed after the shims moved into `BerryMCPServer`; the evidence above describes the fixture as it was tested. The remaining rule and the whole-message writes are tested by `HostCompatibleStdioTransportTests`, and the built helper's stdio contract, including the captured Codex initialize shape and the `-32601` answer to the Antigravity discovery probe, by `BerryMCPStdioTests`:

```sh
swift build --product berrydb-mcp
swift test --filter 'HostCompatibleStdioTransportTests|BerryMCPStdioTests'
```

On 2026-10-09 this ran 15 tests in 2 suites, all passing. The fixture's protocol-cancellation test was not carried over to the helper.

## Evidence

### Automated tests

The fixture's suite, `MCPCompatibilitySpikeTests`, was removed with the fixture; the results below are as recorded on 2026-09-26.

Result: PASS, 9 tests in 1 serialized Swift Testing suite, 0 failures. Five tests exercised pure contracts, including byte preservation for supported string-only experimental maps, semantic preservation for mixed maps, and the narrow discovery-response scope with valid string/number request-ID preservation. Wrong or missing JSON-RPC versions and missing, null, Boolean, object, or array IDs remained untouched for the SDK. Four Foundation `Process` integration tests launched the built fixture and drove the real stdio transport. The Codex regression used the captured 0.154.0 initialize shape, negotiated `2025-06-18`, completed initialized/list/call, and retained the elicitation capabilities while filtering only unsupported experimental values. The server-side discovery regression used the captured Antigravity 1.2.11 `server/discover` request shape, verified `-32601`, then independently drove legacy initialize/list/call. It did not claim to observe the client's internal fallback sequence. The initial red test timed out waiting for response ID 1 because the SDK swallowed discovery behind its pre-initialize state gate; the host transport made that server contract green. The existing package emits FreeTDS linker warnings because the local library was built for macOS 26 while the package target is macOS 15; this was not introduced by the MCP target.

The initial fixture red phase was observed before implementation: SwiftPM rejected the declared target because `MCP/CompatibilitySpike/Sources` did not exist. After source was added, compilation also caught an argument-order mismatch with the exact SDK API (`instructions` must precede `capabilities`); the implementation was corrected from the checked-out 0.12.1 signature. The integration-harness red phase first caught Swift 6's rejection of untyped dictionary equality inside `#expect`; assertions were changed to require and compare every schema, annotation, and content field explicitly. The strengthened cancellation test then failed deterministically with `Timed out waiting for stderr marker berrydb-mcp-spike:echo-started` until the guarded handler-start barrier was added. Before the compatibility wrapper, the exact Codex regression returned JSON-RPC `-32603` with `The data couldn’t be read because it isn’t in the correct format.` and failed because no initialize result existed. The sanitizer-narrowing regression then failed because the first shim removed a supported string-only map and removed the supported string from a mixed map; the implementation now filters values instead of dropping the whole map.

### Wire transcript

A Swift/Foundation child-process harness, removed with the fixture, sent initialize, initialized, list, valid call, invalid call, and cancellation messages to the built `MCPCompatibilitySpike` executable. It parsed every stdout line as JSON and waited for deterministic responses and process exit with bounded deadlines. Observed results:

| Check | Result |
| --- | --- |
| Initialize | PASS; negotiated `2025-11-25` and advertised only tools |
| List | PASS; exactly one tool and the strict empty-object schema |
| Call | PASS; returned `berrydb-mcp-compatible` |
| Invalid input | PASS; JSON-RPC error `-32602` |
| Cancellation | PASS; the test observed the handler-start stderr barrier, cancelled the in-flight call, kept stdin open beyond the uncancelled delay, and received no tool response |
| Stdout hygiene | PASS; captured stdout contained JSON-RPC messages only |
| EOF shutdown | PASS; the process exited after stdin closed |

Sending all messages and EOF without allowing dispatch tasks to complete produced no responses. The production host must keep stdin open for the connection lifetime, as MCP stdio clients normally do.

### MCP Inspector

PASS outside the restricted sandbox with the official `@modelcontextprotocol/inspector@2.8.0`, launched from the gate's worktree against `.build/debug/MCPCompatibilitySpike`. The temporary npm cache used for the run was removed afterwards. The commands as run then, kept as a record (the fixture executable and its `berrydb_compatibility_echo` tool no longer exist):

```text
npx --yes --cache <temporary-cache> @modelcontextprotocol/inspector@2.8.0 --cli .build/debug/MCPCompatibilitySpike --format json --protocol-era legacy --method initialize
npx --yes --cache <temporary-cache> @modelcontextprotocol/inspector@2.8.0 --cli .build/debug/MCPCompatibilitySpike --format json --protocol-era legacy --method tools/list --strict
npx --yes --cache <temporary-cache> @modelcontextprotocol/inspector@2.8.0 --cli .build/debug/MCPCompatibilitySpike --format json --protocol-era legacy --method tools/call --tool-name berrydb_compatibility_echo --tool-args-json '{}'
npx --yes --cache <temporary-cache> @modelcontextprotocol/inspector@2.8.0 --cli .build/debug/MCPCompatibilitySpike --format json --protocol-era legacy --method tools/call --tool-name berrydb_compatibility_echo --tool-args-json '{"unexpected":true}'
```

Initialize reported server version `0.1.0`, protocol `2025-11-25`, and tools capability. Strict list reported the one declared tool and its strict empty-object schema. The valid call returned `berrydb-mcp-compatible` with `isError: false`. The unexpected-argument call exited `1` with `Invalid params`, as required. This established Inspector coverage for initialize, list, valid call, and invalid input; cancellation and shutdown were covered by the fixture's Foundation integration harness above.

The earlier sandbox result was an environmental DNS failure, not an Inspector or server failure: npm could not resolve `registry.npmjs.org` (`ENOTFOUND`). It must not be represented as an Inspector compatibility failure.

### Coding hosts

| Host | Version | Result |
| --- | --- | --- |
| Codex CLI | `0.154.0` | PASS. An authenticated CLI run used an isolated temporary `CODEX_HOME` and returned exactly `berrydb-mcp-compatible`. Its JSON trace contained `mcp_tool_call` started and completed events with no startup errors. Existing authentication material was copied into the isolated home without printing its contents, and the temporary home was removed after the run. The committed child-process regression separately pins the exact initialize shape and negotiates `2025-06-18` through initialized/list/call. |
| Claude Code | `2.1.283` | PASS. A fresh Codex CLI agent running in the host environment ran the Claude Code CLI, confirmed authentication through `claude.ai`, and used an isolated temporary MCP config. Claude connected to a temporary server entry, called `berrydb_compatibility_echo` with `{}`, received `berrydb-mcp-compatible`, returned the same exact final text, and exited `0` without API, MCP, permission, or execution errors. The temporary config was removed and no authentication material was read or printed. A direct sandboxed probe had reported `loggedIn: false`; the successful host-agent run establishes that result as a sandbox/TTY false negative, not the host's actual authentication state. |
| Google Antigravity (`agy`) | `1.2.11` | PASS. Before the adapter, an authenticated wire capture showed `server/discover`; the `.strict` fixture sent no response (the SDK's pre-initialize guard swallows the request, as the test evidence above records) and Antigravity timed out. After the adapter, an authenticated real-home run emitted initialization events, invoked `call_mcp_tool` against a temporary server entry, tool `berrydb_compatibility_echo`, arguments `{}`, received `berrydb-mcp-compatible`, returned that exact final text, and completed with `status: SUCCESS`, `num_turns: 1`. The automated regression separately verifies the captured discovery request receives the server-side `-32601` contract and that legacy initialize/list/call works; it does not claim to capture Antigravity's internal fallback sequence. The temporary MCP entry was removed and authentication material was neither read nor printed. |
| Cursor desktop | `3.7.36` | NOT VERIFIED. Opening/mutating the GUI was outside the headless spike. |
| Cursor Agent | `2026.06.15-03-48-54-da23e37` | PARTIAL. A fresh Codex CLI agent running in the host environment loaded a temporary project `.cursor/mcp.json`, spawned the absolute fixture executable, and reported the server ready. This establishes discovery, spawn, and handshake. Exact list-and-call remains blocked before model execution: `cursor-agent about` reports `User Email: Not logged in`, the prompt exits with `Authentication required`, and `mcp list-tools` reports the server unapproved even after `mcp enable` reports success. The earlier sandbox-only `SecItemCopyMatching failed -50` result is therefore a sandbox false negative rather than a host or fixture failure. All temporary Cursor workspace, config, approval, cache, and state were removed. |

For this gate's acceptance scope, the authenticated coding-host set is Codex, Claude, and Antigravity. No authenticated Cursor account was available for this gate; authenticated Antigravity was used as the third coding host. Inspector plus authenticated Codex, Claude, and Antigravity list-and-call are therefore verified. This is a scope decision, not evidence of Cursor compatibility: Cursor Agent discovery/spawn/handshake is verified, but authenticated list-and-call and Cursor desktop remain unverified and must be completed before any Cursor support claim.

## Dependency size

Measured on 2026-09-26 from the fixture's debug build on arm64 macOS:

- Swift SDK checkout: 1,684 KiB on disk.
- `MCPCompatibilitySpike` debug executable: 7,024,640 bytes (6,860 KiB allocated).
- Dynamic linkage consisted of Apple system frameworks/libraries; no new non-system dylib appeared in `otool -L` output.

This is development evidence, not packaged-release size. The fixture linked only the SDK; `berrydb-mcp` also links every database driver the app registers, so the fixture's size says nothing about the helper's. The signed release helper must be measured again after release optimization, stripping, and app bundling.

## Gate status

**PASS.** The protocol gate was complete for its host scope: official MCP Inspector plus authenticated Codex 0.154.0, Claude Code 2.1.283, and Antigravity 1.2.11 list-and-call all passed. The fixture's lifecycle suite, exact Codex initialize regression, and Antigravity discovery/legacy-fallback server regressions passed alongside cancellation, license, and development-size checks. The Antigravity adapter deliberately preserves the declared 2025-11-25 scope rather than pretending to implement stateless MCP 2026-07-28.

Cursor is outside the current authenticated acceptance scope because no Cursor account is available. Its partial evidence remains recorded above, but this PASS does not claim Cursor desktop or authenticated Cursor Agent compatibility. Cursor support requires a separate authenticated list-and-call and desktop verification gate.

## Design gates

Four design questions were each settled by a test before the code that
depends on them was written, and are referred to by these labels
elsewhere: G1, whether a separate helper can read the app's Keychain
items; G2, how each host tells a server its workspace; G3, whether a
database session that could write can be rejected before any query
runs; G4, whether the existing harvester produces a usable graph for
DynamoDB. Each section below records one of them.

### G3 Privilege checks

Question: can the helper reject a database session whose role could write,
before running any agent query? Tested on 2026-09-28 against PostgreSQL
17.11 and MySQL 8.4.11 in local containers. Amazon RDS itself was not
available; its `rds_superuser` role was simulated by a plain role of that
name, so RDS-specific role behavior remains unverified.

#### PostgreSQL

The check runs as the connected role and rejects the session when any row
is returned: superuser; membership in `rds_superuser`; ownership of any
user relation (through inherited membership); `INSERT`, `UPDATE`,
`DELETE` or `TRUNCATE` on any user relation; column-level `INSERT` or
`UPDATE` (`has_any_column_privilege`, which `has_table_privilege`
does not report); `CREATE` on any user schema or on the database;
`USAGE`/`UPDATE` on any sequence; membership in any role, inherited or
`NOINHERIT`, that holds a table or column write privilege (reachable via
`SET ROLE`).

| Role fixture | Expected | Result |
|---|---|---|
| `SELECT` only | pass | pass |
| `INSERT` on one table | reject | table_write, column_write |
| inherited `UPDATE` via role | reject | table_write, column_write, setrole_writer |
| `NOINHERIT` member of a writer role | reject | setrole_writer |
| owns a table | reject | owner, table_write, column_write |
| `CREATE` on schema | reject | schema_create |
| member of `rds_superuser` | reject | rds_superuser |
| `CREATE` on database | reject | db_create |
| column-level `UPDATE` only | reject | column_write |
| `USAGE` on a sequence | reject | sequence_usage |
| `EXECUTE` on a `SECURITY DEFINER` function that deletes | not detected | pass |

Cost: 40–52 ms for a read-only role over 10,003 relations (worst case,
every relation scanned); 6 ms when a write privilege is found early.

Read-only transaction behavior (`BEGIN READ ONLY`), observed:

- blocked: `INSERT`; `nextval()`; `UPDATE` after `SET ROLE` to a
  writer role; `DELETE` inside a `SECURITY DEFINER` function (the one
  case the privilege check cannot see);
- not blocked: `SET TRANSACTION READ WRITE` issued before any query in
  the transaction, `SET default_transaction_read_only = off`, `COMMIT`
  followed by a write, and `pg_advisory_lock()` (a session-level lock that
  outlives the transaction).

#### MySQL

`SHOW GRANTS FOR CURRENT_USER()` includes privileges of active roles,
including nested ones, but not of roles granted and not yet active. The
check therefore runs `SET ROLE ALL` first, then rejects any `GRANT … ON`
line containing a privilege outside `SELECT`, `SHOW VIEW`, `USAGE`, or
carrying `WITH GRANT OPTION`.

| User fixture | Expected | Result |
|---|---|---|
| `SELECT`, `SHOW VIEW` | pass | pass |
| `INSERT` on one table | reject | INSERT |
| `UPDATE` via default role | reject | UPDATE |
| `UPDATE` via granted, inactive role | reject | UPDATE |
| `UPDATE` via nested role | reject | UPDATE |
| `FILE` | reject | FILE |
| column-level `UPDATE` | reject | UPDATE |
| `ALL PRIVILEGES` on schema | reject | ALL PRIVILEGES |
| `EXECUTE` on schema | reject (conservative) | EXECUTE |

Without `SET ROLE ALL`, the inactive-role fixture passes the check; the
statement is required.

Read-only transaction behavior (`START TRANSACTION READ ONLY`), observed:
blocked `INSERT` and `UPDATE` after `SET ROLE ALL`; not blocked:
`COMMIT` followed by a write, `GET_LOCK()`, `SLEEP()`.

#### Conclusion

Both dialects: **rigorous** for the tested fixtures; no attestation
fallback is needed. The layers depend on each other:

1. The helper, not the agent, opens and ends every transaction, verifies
   `transaction_read_only` is on before running the query, and never
   reuses a session after an error.
2. The read policy must keep rejecting transaction control, `SET`,
   `set_config()`, advisory/user locks and sleep functions, because the
   database's read-only mode does not stop them.
3. The privilege check covers the case where layer 2 is bypassed: a role
   without write privileges cannot write even after escaping the
   read-only transaction. `SECURITY DEFINER` functions are covered only
   by layer 1 and by the function allowlist.

#### Exact checks used

PostgreSQL (one row per failed condition; empty result passes):

```sql
SELECT string_agg(reason, ',' ORDER BY reason) FROM (
SELECT 'superuser' AS reason WHERE (SELECT rolsuper FROM pg_roles WHERE rolname = current_user)
UNION ALL SELECT 'rds_superuser' WHERE EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rds_superuser')
  AND pg_has_role(current_user, 'rds_superuser', 'MEMBER')
UNION ALL SELECT 'owner' WHERE EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND n.nspname NOT LIKE 'pg_toast%' AND pg_has_role(current_user, c.relowner, 'MEMBER'))
UNION ALL SELECT 'table_write' WHERE EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND c.relkind IN ('r','p','v','m','f')
  AND has_table_privilege(current_user, c.oid, 'INSERT,UPDATE,DELETE,TRUNCATE'))
UNION ALL SELECT 'column_write' WHERE EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND c.relkind IN ('r','p','v','m','f')
  AND has_any_column_privilege(current_user, c.oid, 'INSERT,UPDATE'))
UNION ALL SELECT 'schema_create' WHERE EXISTS (SELECT 1 FROM pg_namespace n
  WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND n.nspname NOT LIKE 'pg_toast%' AND has_schema_privilege(current_user, n.oid, 'CREATE'))
UNION ALL SELECT 'db_create' WHERE has_database_privilege(current_user, current_database(), 'CREATE')
UNION ALL SELECT 'sequence_usage' WHERE EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND c.relkind = 'S'
  AND has_sequence_privilege(current_user, c.oid, 'USAGE,UPDATE'))
UNION ALL SELECT 'setrole_writer' WHERE EXISTS (SELECT 1 FROM pg_auth_members m JOIN pg_roles r ON r.oid = m.roleid
  WHERE pg_has_role(current_user, m.roleid, 'MEMBER') AND r.rolname <> current_user
  AND (r.rolsuper OR EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND c.relkind IN ('r','p','v','m','f')
     AND (has_table_privilege(r.oid, c.oid, 'INSERT,UPDATE,DELETE,TRUNCATE') OR has_any_column_privilege(r.oid, c.oid, 'INSERT,UPDATE')))))
) x;
```

MySQL: after `SET ROLE ALL`, for every `SHOW GRANTS FOR CURRENT_USER()` line matching `GRANT <privileges> ON `, split `<privileges>` on commas outside parentheses, drop any column list, uppercase, and reject if any name is outside the allowlist or the line ends with `WITH GRANT OPTION`. Role-membership lines (`GRANT <role> TO`) are skipped because `SET ROLE ALL` has already folded their privileges into the output.

### G4 DynamoDB harvest

Question: does the existing `SchemaHarvester` produce a usable schema graph
for a DynamoDB profile? Tested on 2026-09-28 against `amazon/dynamodb-local`
with table `orders` (partition key `pk` S, sort key `sk` S, global secondary
index `by_status` on `status` S, one item with an extra `total` N
attribute), using the DynamoDB driver through `ConnectionManager`,
`SchemaCatalog` and `SchemaHarvester.buildGraph`.

Harvested graph: 4 nodes, 3 edges.

| Node | Attributes |
|---|---|
| table `orders` | none |
| column `pk` | `type` "String (S)", `primaryKey` true, `nullable` false |
| column `sk` | `type` "String (S)", `primaryKey` true, `nullable` false |
| index `by_status` | `columns` "status", `unique` false |

Edges: `orders → pk` and `orders → sk` (`hasColumn`), `orders → by_status`
(`hasIndex`).

Conclusion: **harvest usable** for schema and graph tools; the
`DescribeTable` fallback is not needed. Two limits carry into the DynamoDB
query tool: partition and sort keys are both marked `primaryKey` without
their `HASH`/`RANGE` role, and non-key attributes are absent because
DynamoDB has no declared schema. The query tool therefore reads key roles
and index key schemas from `DescribeTable` at request time.

DynamoDB Local keeps a separate database per access key and region unless
started with `-sharedDb`; fixtures must be created with the same credentials
the driver uses.

### G2 Workspace discovery

Question: how does each host tell a stdio server which workspace it serves?
Tested on 2026-09-28 by registering a transparent wrapper around the
compatibility fixture (records the process working directory, workspace
environment variables and raw stdin/stdout, otherwise forwards unchanged)
through each host's per-invocation configuration, then starting the host in
a fresh git repository at `/tmp/g2-repo` (a symlink to `/private/tmp/g2-repo`
on macOS). No persistent host configuration was modified.

| Host | Version | Configuration | Server cwd | Workspace env | `roots` capability | First method |
|---|---|---|---|---|---|---|
| Claude Code | 2.1.283 | `--mcp-config … --strict-mcp-config` | `/tmp/g2-repo` | `CLAUDE_PROJECT_DIR=/private/tmp/g2-repo` | `{"listChanged": true}` | `server/discover`, then `initialize` (`2025-11-25`) |
| Codex CLI | 0.157.1 | `-c mcp_servers.<name>.command=…` | `/private/tmp/g2-repo` | none | absent | `initialize` (`2025-06-18`) |
| Antigravity | 1.2.11 | `agy mcp add` (temporary global entry, removed after the run) | `/tmp/g2-repo` | none | `{"listChanged": true}`; sends `notifications/roots/list_changed` | `server/discover`, then `initialize` (`2025-11-25`) |

Antigravity has no per-invocation MCP configuration; a temporary entry was
added with `agy mcp add` and removed with `agy mcp remove` after the run.

Conclusion: **pass.** The process working directory identifies the
workspace for all three hosts; Claude Code and Antigravity also offer
`roots`, Codex does not. The
selection order in the design (an explicit `--project` first, then roots,
then the working directory) is viable. The two hosts spell the same directory
differently (`/tmp/…` versus `/private/tmp/…`), so selection must compare
symlink-resolved paths.

### G1 Keychain sharing

Question: can a separate helper executable read database secrets that the
BerryDB app stored in Keychain, without weakening their access control?
Tested on 2026-09-28 on macOS 26.6.2 with the installed release BerryDB
1.0.8 (`dev.berrydb.app`, Developer ID team `WZ2Z528AM6`). A throwaway probe
linked `BerryCredentials`, called `KeychainService.readPassword`, and printed
only whether the value matched a canary (never the value).

Items are legacy file-keychain items (`KeychainService` sets neither
`kSecUseDataProtectionKeychain` nor an access group). An item saved by the
release app for a new PostgreSQL profile had:

- an application ACL for decrypt trusting only `dev.berrydb.app` by
  designated requirement (identifier plus team);
- a partition list of `teamid:WZ2Z528AM6`.

| Probe | Signature | First read | Later reads |
|---|---|---|---|
| `berrydb-mcp` | Developer ID, identifier `dev.berrydb.mcp`, same team | Keychain confirmation dialog; readable after approval | no dialog after "Always Allow", including after re-signing (the ACL entry is the designated requirement, not a code hash) |
| control | ad-hoc, no team | Keychain confirmation dialog | ACL entry pinned to the code hash |

"Always Allow" appended each probe to the item's ACL; nothing is readable by
an unlisted binary without a dialog, so the Keychain ACL is an effective
boundary against other same-user processes.

A second item created with `security add-generic-password -T` trusting both
the app and the helper did not isolate the ACL question: items created by
the `security` tool carry partition `apple-tool:` rather than the app's
team, which itself triggers a dialog for other signers. Pre-authorizing the
helper must therefore be verified with items written by the app.

Conclusion: **pass, no broker needed.** A helper signed by the same team
reads app-created secrets. Without further work it prompts once per item
(one secret per profile credential kind). Removing that prompt requires the
app to include the helper's designated requirement in each item's ACL when
writing it, and to rewrite existing items once, which the app can do because
it is already trusted. That change and its verification with a packaged,
app-written item belong to the packaging work. Data-protection keychain
access groups were not evaluated.

## Metadata tools host check

Question: do current coding hosts list and call the metadata tools of the
real `berrydb-mcp` helper, report why no project is selected, and select a
project through a repository's `.berrydb.json`? Tested on 2026-10-09 on
macOS 26.6.2 with a debug build (`swift build --product berrydb-mcp`, which
reports server version `dev`).

### Fixtures

Everything ran inside one fresh `mktemp -d` folder; no ancestor of it held
a `.berrydb.json`. Two stores were created there by a throwaway program
calling `BerryStore(path:)` and `saveMCPProject`, the calls the app makes:

- **Empty store, empty folder.** A store with no projects; the host started
  in an empty folder.
- **Linked folder.** A store with one enabled project named `smoke`, no
  workspace folders and no connections, sealed with a throwaway key that
  was never stored anywhere; the host started in a folder holding
  `.berrydb.json` with `{"project": "smoke"}`.

For the linked folder the helper was launched as
`/usr/bin/sandbox-exec -f <profile> <helper> --store-path <store>`, where
the profile is `(allow default)` plus `deny mach-lookup` of
`com.apple.SecurityServer`, `com.apple.securityd.xpc`, `com.apple.secd`
and `com.apple.security.agent`. Once selection has chosen a project,
enabled or not, the helper loads its integrity key from the login
Keychain on every request; the
sandbox kept that read from reaching the Keychain or raising an approval
dialog, and the system log recorded the denials for every run
(`Sandbox: berrydb-mcp(<pid>) deny(1) mach-lookup com.apple.SecurityServer`
and `… com.apple.securityd.xpc`). With no key, or with a tag sealed by
another key, the project still selects and reports `integrity:
"unavailable"`, which is the expected result here. The empty-store runs
launched the helper directly: selection chose no project there, so the
helper never read the Keychain.

Each host was asked to note the tools of the server, call
`berrydb_status` once with no arguments, and print the tool names and the
returned JSON. Host configuration was per invocation, except for
Antigravity, which has no per-invocation MCP configuration:

| Host | Configuration |
|---|---|
| Codex CLI | `codex exec --ephemeral --ignore-user-config --skip-git-repo-check -s read-only -C <folder> --json -c 'mcp_servers.berrydb.command="<helper>"' -c 'mcp_servers.berrydb.args=["--store-path","<store>"]' "<prompt>"` |
| Claude Code | `claude -p --no-session-persistence --setting-sources project --strict-mcp-config --mcp-config '{"mcpServers":{"berrydb":{"type":"stdio","command":"<helper>","args":["--store-path","<store>"]}}}' --allowedTools mcp__berrydb__berrydb_status --output-format stream-json --verbose "<prompt>"` |
| Antigravity | `agy mcp add berrydb-smoke-<random> -- <helper> --store-path <store>`, then `agy -p "<prompt>" --output-format stream-json --print-timeout 150s`, then `agy mcp remove berrydb-smoke-<random>` from a shell trap. `agy mcp list` printed the same entries before and after. |

### Results

| Host | Version | Empty store: tools listed | Empty store: `berrydb_status` | Linked folder: tools listed | Linked folder: `berrydb_status` |
|---|---|---|---|---|---|
| Codex CLI | 0.157.1 | `berrydb_status` only | called; `state: "unconfigured"`, `reason: "no_matching_project"` | all six | called; `state: "selected"`, `selected_by: "linked_repository"`, `integrity: "unavailable"` |
| Claude Code | 2.1.294 | `berrydb_status` only | called; `unconfigured`, `no_matching_project` | all six | called; `selected`, `linked_repository`, `unavailable` |
| Antigravity | 1.3.1 | `berrydb_status` only | called; `unconfigured`, `no_matching_project` | all six | called; `selected`, `linked_repository`, `unavailable` |

"Tools listed" is what each model reported from its own tool list; Claude
Code's `init` event listed the same names. The empty-store result also
reported `workspace` as the host's folder,
spelled `/private/var/folders/…` although the hosts started in
`/var/folders/…`. The linked result named the project
(`{"id": "<UUID>", "name": "smoke"}`) with the ID in upper case;
`--project` accepts either case. Every result reported
`live_reads: "not_available"`.

The same stores were also driven without a host by a stdio script that
sends initialize, `tools/list` and `tools/call`: identical results, and,
with the roots capability declared and `roots/list` answered with the
linked folder while the process ran in the temporary root, selection was
`linked_repository` through the root as well.

### Host behavior observed

- **Tool names.** Codex and Claude Code present the tools to the model as
  `mcp__<server>__<tool>`, e.g. `mcp__berrydb__berrydb_status`.
  Antigravity presents one generic `call_mcp_tool` taking `ServerName` and
  `ToolName`, and was called with `ToolName: "berrydb_status"`.
- **Result content.** The helper returns the same compact JSON as
  `structuredContent` and as a text block. Codex's event stream carried
  both, equal after parsing. Antigravity's tool output was the text block
  verbatim, including the `\/` escapes the helper's encoder wrote then (it
  has since stopped escaping `/`). Claude Code passed the model JSON equal
  to `structuredContent` without those escapes, so it does not forward the
  text block byte for byte. All three models reproduced the same fields.
- **Tool loading.** Claude Code listed the server's tools as deferred; the
  model loaded `berrydb_status` through its tool search before calling it.
- **Approval.** Claude Code ran with `--allowedTools` naming the tool; a
  print-mode run without it was not tried. Codex `exec` and Antigravity (in
  its configured `always-proceed` permission mode) called the tool without
  an approval step.
- **Setup commands.** The `--help` of the same versions matches the
  commands the AI Agents settings pane shows once the helper is bundled
  (until then it shows none):
  `codex mcp add <NAME> -- <COMMAND>...`;
  `claude mcp add [options] <name> <commandOrUrl> [args...]` with
  `--scope` defaulting to `local` (the current project only), hence
  `--scope user` for one entry serving every repository;
  `agy mcp add [flags] <name> <commandOrUrl> [args...]`, flags before the
  name and `--` before arguments that begin with `-`.

Conclusion: **pass** for listing, calling, the unconfigured reason and
selection by link file on all three hosts. Not covered: an integrity tag
verified with the app's real key through a host, live reads (not
implemented), a packaged and signed helper, and Cursor.
