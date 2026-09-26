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

`CodexCompatibleStdioTransport` is a narrow wrapper around the SDK's `StdioTransport`. On inbound `initialize` messages only, it retains string-valued `params.capabilities.experimental` entries that 0.12.1 can decode and removes only object, array, null, numeric, and Boolean values; it removes the map only when no supported entry remains. Every other envelope field is semantically retained, including Codex's `elicitation.form` and `elicitation.url`. Non-initialize messages, initialize messages without `experimental`, and initialize messages whose experimental values are all strings are forwarded byte-for-byte; rewritten initialize JSON is semantically equivalent apart from the unsupported entries and may have different key ordering. This works around upstream [swift-sdk issue #262](https://github.com/modelcontextprotocol/swift-sdk/issues/262), where 0.12.1 models `experimental` as `[String: String]` even though MCP clients may send object-valued entries. Remove the wrapper only after upgrading to an exact pinned SDK release or commit whose arbitrary-object experimental regression passes with the wrapper disabled. BerryDB does not consume experimental client capabilities in this server.

## Evidence

### Automated tests

Command:

```sh
swift test --filter MCPCompatibilitySpikeTests
```

Result: PASS, 7 tests in 1 serialized Swift Testing suite, 0 failures. Four tests exercise pure contracts, including byte preservation for supported string-only experimental maps and semantic preservation for mixed maps, and three committed Foundation `Process` integration tests launch the built executable and drive the real stdio transport. The Codex regression uses the captured 0.154.0 initialize shape, negotiates `2025-06-18`, completes initialized/list/call, and retains the elicitation capabilities while filtering only unsupported experimental values. The final focused suite passed three consecutive times in 1.899, 1.210, and 1.206 seconds. The initial clean build completed in 498.57 seconds. The existing package emits FreeTDS linker warnings because the local library was built for macOS 26 while the package target is macOS 15; this was not introduced by the MCP target.

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
| Claude Code | `2.1.282` | PASS for MCP transport. Its ephemeral `--mcp-config` path reached the fixture transport successfully. Tool invocation remains **AUTH-UNVERIFIED**: the available session was not logged in, so this does not establish an authenticated invocation pass. |
| Cursor desktop | `3.7.36` | NOT VERIFIED. Opening/mutating the GUI was outside the headless spike. |
| Cursor Agent | `2026.06.15-03-48-54-da23e37` | HOST-BLOCKED BEFORE SPAWN. `mcp list` and `mcp list-tools` exited with `SecItemCopyMatching failed -50` from Keychain access before `MCPCompatibilitySpike` was spawned. The temporary project config was removed. This is not a fixture protocol failure and does not verify the host. |

These results are not sufficient for a complete native-host compatibility claim. Inspector and authenticated Codex list-and-call are verified. Cursor desktop still needs an observed list-and-call run; Cursor Agent must first be made able to access its host Keychain and spawn the fixture. Claude transport evidence does not replace authenticated invocation evidence.

## Dependency size

Measured from the debug build on arm64 macOS:

- Swift SDK checkout: 1,684 KiB on disk.
- `MCPCompatibilitySpike` debug executable: 7,023,424 bytes (6,860 KiB allocated).
- Dynamic linkage consists of Apple system frameworks/libraries; no new non-system dylib appears in `otool -L` output.

This is development evidence, not packaged-release size. The signed release helper must be measured again after release optimization, stripping, and app bundling.

## Gate status

**PARTIAL / BLOCKED FOR PHASE 1.** The exact Swift API, protocol wire behavior, Inspector behavior, authenticated Codex 0.154.0 list-and-call, deterministic Codex wire regression, cancellation, tests, license, and development-size evidence are established. The gate is not complete while Cursor desktop remains unverified, Cursor Agent is host-blocked before spawn, and Claude invocation authentication has not been verified. A scope change still requires an approved architecture decision.
