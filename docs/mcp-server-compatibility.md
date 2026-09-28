# MCP Server Compatibility Gate

Date: 2026-09-26
Branch: `feat/ai-36-local-mcp-server`
Base: `8581f388376965b2759a27e913ceb7888ebd66b1`

## Decision

BerryDB's initial local stdio server will implement MCP `2025-11-25` using the official Swift SDK pinned exactly to `0.12.1` (`a0ae212ebf6eab5f754c3129608bc5557637e605`). Do not claim MCP `2026-07-28` support.

The official 0.12.1 README and `Version.supported` source identify `2025-11-25` as the newest supported protocol. The newer `2026-07-28` protocol removes the initialize session lifecycle and introduces a stateless request envelope; adding `server/discover` alone would not make this SDK conformant. Re-run this gate before changing the declared protocol.

The selected package exports product `MCP`, requires Swift 6.1, and supports macOS 13 or newer. BerryDB uses Swift 6.3 and targets macOS 15. The upstream license file covers an Apache-2.0/MIT transition; its documentation is CC-BY-4.0. The newly introduced EventSource 1.5.1 transitive package is MIT licensed. Both are recorded in `THIRD-PARTY-NOTICES.md`.

## Fixture

`MCPCompatibilitySpike` is a production-shaped, strict stdio server using SDK APIs verified at tag 0.12.1:

- `Server(configuration: .strict)` and the initialize/initialized lifecycle;
- `StdioTransport`, with stdout reserved for newline-delimited JSON-RPC;
- `tools/list` with one read-only, idempotent, closed-world tool;
- `tools/call` for `berrydb_compatibility_echo`;
- an object input schema with no properties and `additionalProperties: false`;
- JSON-RPC `-32602` rejection for any unexpected argument;
- SDK cancellation handling and `waitUntilCompleted()` shutdown on EOF.

`BERRYDB_MCP_SPIKE_ECHO_DELAY_MS` is a spike-only cancellation seam. With `BERRYDB_MCP_SPIKE_EMIT_STARTED_MARKER=1`, the handler emits a single stderr marker immediately before entering that delay, allowing the integration test to prove the call is in flight before cancellation. Neither setting adds a tool argument, stdout content, or protocol capability.

`HostCompatibleStdioTransport` is a narrow wrapper around the SDK's `StdioTransport` with two independently tested compatibility rules.

First, on inbound `initialize` messages only, it retains string-valued `params.capabilities.experimental` entries that 0.12.1 can decode and removes only object, array, null, numeric, and Boolean values; it removes the map only when no supported entry remains. Every other envelope field is semantically retained, including Codex's `elicitation.form` and `elicitation.url`. Non-initialize messages, initialize messages without `experimental`, and initialize messages whose experimental values are all strings are forwarded byte-for-byte; rewritten initialize JSON is semantically equivalent apart from the unsupported entries and may have different key ordering. This works around upstream [swift-sdk issue #262](https://github.com/modelcontextprotocol/swift-sdk/issues/262), where 0.12.1 models `experimental` as `[String: String]` even though MCP clients may send object-valued entries. Remove this rule only after upgrading to an exact pinned SDK release or commit whose arbitrary-object experimental regression passes with the wrapper disabled. BerryDB does not consume experimental client capabilities in this server.

Second, it intercepts only request-shaped `server/discover` messages and replies with JSON-RPC `-32601 Method not found`, preserving the request identifier. The official 2026-07-28 [discovery specification](https://modelcontextprotocol.io/specification/2026-07-28/server/discover) defines discovery as the stdio backward-compatibility probe: dual-era clients should fall back to legacy `initialize` when discovery is unsupported. The pinned Swift SDK instead applies its pre-initialize state guard and returns `-32600 Server is not initialized`, which prevents Antigravity 1.2.11 from falling back. This adapter does not advertise or implement stateless MCP 2026-07-28; it truthfully declines that method so a dual-era client can negotiate the server's actual 2025-era protocol. Notifications and every method other than `server/discover` remain untouched. Remove this rule when the pinned SDK itself returns the correct method-not-found response before initialization or when BerryDB adopts a fully conformant 2026-07-28 implementation.

## Evidence

### Automated tests

Command:

```sh
swift test --filter MCPCompatibilitySpikeTests
```

Result: PASS, 9 tests in 1 serialized Swift Testing suite, 0 failures. Five tests exercise pure contracts, including byte preservation for supported string-only experimental maps, semantic preservation for mixed maps, and the narrow discovery-response scope with valid string/number request-ID preservation. Wrong or missing JSON-RPC versions and missing, null, Boolean, object, or array IDs remain untouched for the SDK. Four committed Foundation `Process` integration tests launch the built executable and drive the real stdio transport. The Codex regression uses the captured 0.154.0 initialize shape, negotiates `2025-06-18`, completes initialized/list/call, and retains the elicitation capabilities while filtering only unsupported experimental values. The server-side discovery regression uses the captured Antigravity 1.2.11 `server/discover` request shape, verifies `-32601`, then independently drives legacy initialize/list/call. It does not claim to observe the client's internal fallback sequence. The initial red test timed out waiting for response ID 1 because the SDK swallowed discovery behind its pre-initialize state gate; the host transport makes that server contract green. The existing package emits FreeTDS linker warnings because the local library was built for macOS 26 while the package target is macOS 15; this was not introduced by the MCP target.

The initial fixture red phase was observed before implementation: SwiftPM rejected the declared target because `MCP/CompatibilitySpike/Sources` did not exist. After source was added, compilation also caught an argument-order mismatch with the exact SDK API (`instructions` must precede `capabilities`); the implementation was corrected from the checked-out 0.12.1 signature. The integration-harness red phase first caught Swift 6's rejection of untyped dictionary equality inside `#expect`; assertions were changed to require and compare every schema, annotation, and content field explicitly. The strengthened cancellation test then failed deterministically with `Timed out waiting for stderr marker berrydb-mcp-spike:echo-started` until the guarded handler-start barrier was added. Before the compatibility wrapper, the exact Codex regression returned JSON-RPC `-32603` with `The data couldn’t be read because it isn’t in the correct format.` and failed because no initialize result existed. The sanitizer-narrowing regression then failed because the first shim removed a supported string-only map and removed the supported string from a mixed map; the implementation now filters values instead of dropping the whole map.

### Wire transcript

A committed Swift/Foundation child-process harness sends initialize, initialized, list, valid call, invalid call, and cancellation messages to the built `MCPCompatibilitySpike` executable. It parses every stdout line as JSON and waits for deterministic responses and process exit with bounded deadlines. Observed results:

| Check | Result |
| --- | --- |
| Initialize | PASS; negotiated `2025-11-25` and advertised only tools |
| List | PASS; exactly one tool and the strict empty-object schema |
| Call | PASS; returned `berrydb-mcp-compatible` |
| Invalid input | PASS; JSON-RPC error `-32602` |
| Cancellation | PASS; the test observes the handler-start stderr barrier, cancels the in-flight call, keeps stdin open beyond the uncancelled delay, and receives no tool response |
| Stdout hygiene | PASS; captured stdout contained JSON-RPC messages only |
| EOF shutdown | PASS; the process exited after stdin closed |

Sending all messages and EOF without allowing dispatch tasks to complete produced no responses. The production host must keep stdin open for the connection lifetime, as MCP stdio clients normally do.

### MCP Inspector

PASS outside the restricted sandbox with the official `@modelcontextprotocol/inspector@2.8.0`, launched from this worktree against `.build/debug/MCPCompatibilitySpike`. The temporary npm cache used for the run was removed afterwards. The observed commands were:

```sh
npx --yes --cache <temporary-cache> @modelcontextprotocol/inspector@2.8.0 --cli .build/debug/MCPCompatibilitySpike --format json --protocol-era legacy --method initialize
npx --yes --cache <temporary-cache> @modelcontextprotocol/inspector@2.8.0 --cli .build/debug/MCPCompatibilitySpike --format json --protocol-era legacy --method tools/list --strict
npx --yes --cache <temporary-cache> @modelcontextprotocol/inspector@2.8.0 --cli .build/debug/MCPCompatibilitySpike --format json --protocol-era legacy --method tools/call --tool-name berrydb_compatibility_echo --tool-args-json '{}'
npx --yes --cache <temporary-cache> @modelcontextprotocol/inspector@2.8.0 --cli .build/debug/MCPCompatibilitySpike --format json --protocol-era legacy --method tools/call --tool-name berrydb_compatibility_echo --tool-args-json '{"unexpected":true}'
```

Initialize reported server version `0.1.0`, protocol `2025-11-25`, and tools capability. Strict list reported the one declared tool and its strict empty-object schema. The valid call returned `berrydb-mcp-compatible` with `isError: false`. The unexpected-argument call exited `1` with `Invalid params`, as required. This establishes Inspector coverage for initialize, list, valid call, and invalid input; cancellation and shutdown remain covered by the committed Foundation integration harness above.

The earlier sandbox result was an environmental DNS failure, not an Inspector or server failure: npm could not resolve `registry.npmjs.org` (`ENOTFOUND`). It must not be represented as an Inspector compatibility failure.

### Coding hosts

| Host | Version | Result |
| --- | --- | --- |
| Codex CLI | `0.154.0` | PASS. An authenticated CLI run used an isolated temporary `CODEX_HOME` and returned exactly `berrydb-mcp-compatible`. Its JSON trace contained `mcp_tool_call` started and completed events with no startup errors. Existing authentication material was copied into the isolated home without printing its contents, and the temporary home was removed after the run. The committed child-process regression separately pins the exact initialize shape and negotiates `2025-06-18` through initialized/list/call. |
| Claude Code (`c20x`) | `2.1.283` | PASS. A fresh Codex CLI agent running in the host environment resolved `c20x` to `claude-20x`, confirmed authentication through `claude.ai`, and used an isolated temporary MCP config. Claude connected to `berrydb-phase0`, called `berrydb_compatibility_echo` with `{}`, received `berrydb-mcp-compatible`, returned the same exact final text, and exited `0` without API, MCP, permission, or execution errors. The temporary config was removed and no authentication material was read or printed. A direct sandboxed probe had reported `loggedIn: false`; the successful host-agent run establishes that result as a sandbox/TTY false negative, not the host's actual authentication state. |
| Google Antigravity (`agy`) | `1.2.11` | PASS. Before the adapter, an authenticated wire capture showed `server/discover`; the SDK returned `-32600` and Antigravity timed out. After the adapter, an authenticated real-home run emitted initialization events, invoked `call_mcp_tool` against server `berrydb-phase0-agy-final`, tool `berrydb_compatibility_echo`, arguments `{}`, received `berrydb-mcp-compatible`, returned that exact final text, and completed with `status: SUCCESS`, `num_turns: 1`. The automated regression separately verifies the captured discovery request receives the server-side `-32601` contract and that legacy initialize/list/call works; it does not claim to capture Antigravity's internal fallback sequence. The temporary MCP entry was removed and authentication material was neither read nor printed. |
| Cursor desktop | `3.7.36` | NOT VERIFIED. Opening/mutating the GUI was outside the headless spike. |
| Cursor Agent | `2026.06.15-03-48-54-da23e37` | PARTIAL. A fresh Codex CLI agent running in the host environment loaded a temporary project `.cursor/mcp.json`, spawned the absolute fixture executable, and reported `berrydb-phase0: ready`. This establishes discovery, spawn, and handshake. Exact list-and-call remains blocked before model execution: `cursor-agent about` reports `User Email: Not logged in`, the prompt exits with `Authentication required`, and `mcp list-tools` reports the server unapproved even after `mcp enable` reports success. The earlier sandbox-only `SecItemCopyMatching failed -50` result is therefore a sandbox false negative rather than a host or fixture failure. All temporary Cursor workspace, config, approval, cache, and state were removed. |

For the Phase 0 acceptance scope, the authenticated coding-host set is Codex, Claude, and Antigravity. No authenticated Cursor account was available for this gate; authenticated Antigravity was used as the third coding host. Inspector plus authenticated Codex, Claude, and Antigravity list-and-call are therefore verified. This is a scope decision, not evidence of Cursor compatibility: Cursor Agent discovery/spawn/handshake is verified, but authenticated list-and-call and Cursor desktop remain unverified and must be completed before any Cursor support claim.

## Dependency size

Measured from the debug build on arm64 macOS:

- Swift SDK checkout: 1,684 KiB on disk.
- `MCPCompatibilitySpike` debug executable: 7,024,640 bytes (6,860 KiB allocated).
- Dynamic linkage consists of Apple system frameworks/libraries; no new non-system dylib appears in `otool -L` output.

This is development evidence, not packaged-release size. The signed release helper must be measured again after release optimization, stripping, and app bundling.

## Gate status

**PASS FOR PHASE 1.** The Phase 0 gate is complete for its host scope: official MCP Inspector plus authenticated Codex 0.154.0, Claude Code 2.1.283, and Antigravity 1.2.11 list-and-call all pass. The standard lifecycle suite, exact Codex initialize regression, and Antigravity discovery/legacy-fallback server regressions pass alongside cancellation, license, and development-size checks. The Antigravity adapter deliberately preserves the declared 2025-11-25 scope rather than pretending to implement stateless MCP 2026-07-28.

Cursor is outside the current authenticated acceptance scope because no Cursor account is available. Its partial evidence remains recorded above, but Phase 0 PASS does not claim Cursor desktop or authenticated Cursor Agent compatibility. Cursor support requires a separate authenticated list-and-call and desktop verification gate.

## G3 Privilege checks

Question: can the helper reject a database session whose role could write,
before running any agent query? Tested on 2026-09-28 against PostgreSQL
17.11 and MySQL 8.4.11 in local containers. Amazon RDS itself was not
available; its `rds_superuser` role was simulated by a plain role of that
name, so RDS-specific role behavior remains unverified.

### PostgreSQL

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

### MySQL

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

### Conclusion

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

### Exact checks used

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

## G4 DynamoDB harvest

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

## G2 Workspace discovery

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
selection order in the design (roots, then working directory, then an
explicit project) is viable. The two hosts spell the same directory
differently (`/tmp/…` versus `/private/tmp/…`), so selection must compare
symlink-resolved paths.

## G1 Keychain sharing

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
