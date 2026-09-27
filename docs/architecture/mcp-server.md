# Local MCP Server Architecture

Status: **in development (AI-36)**. The Phase 0 protocol compatibility gate has
passed for MCP Inspector and authenticated Codex, Claude Code, and Google
Antigravity. Phase 1 now implements project and scoped-grant persistence locally.
The project-grant UI, production server, database policy enforcement, and release
packaging are not implemented or release-ready yet. See
[`../mcp-server-compatibility.md`](../mcp-server-compatibility.md) for the Phase 0
evidence and exact host scope; it does not establish Cursor support.

## Direction and scope

BerryDB has two separate MCP roles:

- AI-16 is an outbound MCP **client** inside BerryDB's AI agent. It launches
  reviewed external servers from BerryDB's allowlist.
- AI-36 is an inbound local MCP **server**. A coding-agent host launches the
  signed `berrydb-mcp` helper and calls a small BerryDB-owned capability surface.

AI-36 does not replace or relax AI-16's allowlist, approval, or trust model. The
initial server uses MCP `2025-11-25` over stdio. It is local and single-process;
remote HTTP hosting, LAN access, OAuth, and multi-user operation are out of scope.

## Process and trust boundaries

`berrydb-mcp` is a second, headless composition root. It must register its own
drivers and construct its own connection coordinator; it cannot inherit live
registry state, an active profile, or user approval from the BerryDB app process.
Stdout is reserved exclusively for MCP JSON-RPC. Diagnostics may use stderr only
after redaction.

The MCP host and its model provider are outside BerryDB's trust boundary. Every
tool or resource response returned over stdio is visible to the host. Depending
on that host's configuration, schema names, graph metadata, query text, and row
values in the response may then leave the Mac for a third-party model provider.
Running the server locally therefore does **not** mean its returned data stays on
the Mac. Users must review the host and model-provider privacy policy separately.

The server does not authorize requests from MCP `clientInfo`, the process current
working directory, an asserted workspace path, or whichever profile is active in
the GUI. The host supplies an explicit project identifier and opaque project
grant. In the current persisted model there is no separate project `enabled`
flag: issuance and continued existence of at least one active, unrevoked,
unexpired, correctly scoped grant is the explicit act that enables that project
scope. Revoking the grant, allowing it to expire, or deleting its durable record
disables that scope. The future server must validate the project, stored grant
digest, scope, expiration/revocation, requested capability, and production policy
on every tool/resource request.

## Secret boundary

Database passwords, SSH credentials and passphrases, API keys, full connection
strings, and the plaintext project grant are never MCP inputs or outputs. After
authorization, the helper resolves connection credentials internally through the
shared Keychain service and keeps them in memory only. Secrets must not appear in
stdout, stderr, error details, audit fields, query history, or tool/resource
results. Stored grant material is one-way hashed; displaying a newly minted grant
is a one-time UI operation.

The host configuration necessarily contains the opaque project grant because it
must present that credential to the helper. Users must treat the host config as a
secret-bearing file, keep it out of source control, and revoke the grant if it is
copied or exposed. A grant authorizes only its project and enabled capabilities;
it is not a database password or a BerryDB cloud credential.

## Production defaults and query policy

The production contract is deny-by-default:

- MCP is disabled for a project scope until the user explicitly issues a scoped
  grant. There is no second enabled switch in the current persisted model: an
  active, unrevoked, unexpired grant is the enablement record.
- A production-labelled profile has no MCP access by default. Enabling a normal
  project must not implicitly enable production access.
- SQL execution is read-only and must pass a structural policy check. Unknown,
  multi-statement, write, DDL, transaction-control, and privilege-changing input
  is rejected; interactive confirmation and `dangerPreconfirmed` are not security
  boundaries and must not be used as bypasses.
- Results have row, byte, and execution-time limits. Truncation is explicit in
  the returned contract, never silent.
- MCP query history is off by default. Audit records contain bounded metadata and
  sanitized outcomes, not SQL text, row values, secrets, or raw driver errors.
- Schema/graph search is deterministic and local. It does not call a remote
  embedding service.
- Connections owned by the helper are closed on cancellation, EOF, SIGTERM, and
  fatal protocol shutdown.

These are required release gates, not claims about the current compatibility
fixture. The Phase 0 fixture exposes only a fixed echo tool and proves transport,
decoder, lifecycle, cancellation, and selected-host compatibility. Production
tools/resources and their policy enforcement will be added and tested in later
phases before the helper is bundled or advertised as available.

## Current Phase 1 persistence evidence

Phase 1 locally implements durable project records and scoped grant records. The
plaintext grant is returned only at issuance; persistence retains the verifier
material needed for later validation rather than making the plaintext grant a
general read API. This persistence work is local implementation evidence, not a
claim that the UI or production MCP server consumes it yet.

On 2026-09-27, a development-signed native helper using stable code signing
completed a real macOS Keychain insert/read/update/read/delete round trip for the
shared credential service. The temporary Keychain item and test artifact were
removed after the run. This verifies the native Keychain path on the local Mac;
it is **not** a committed automated test, CI proof, release-signing proof, or
evidence for another machine/runtime.

## Planned capability surface

The first production surface is project-scoped and intentionally small:

- list the profiles explicitly attached to the authorized project;
- inspect bounded schema metadata and database graph metadata;
- search that metadata locally;
- execute bounded read-only queries only when the project capability permits it.

No capability may enumerate unrelated profiles, use ambient GUI state, expose
credentials, perform writes, or turn the helper into a general shell/file/network
execution service.
