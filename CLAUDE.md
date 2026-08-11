# CLAUDE.md

Behavioral guidelines to reduce common LLM coding mistakes. Merge with project-specific instructions as needed.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

---

**These guidelines are working if:** fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and clarifying questions come before implementation rather than after mistakes.

---

# BerryDB — Project Conventions

## Language rules

- **Code comments: English only.** This includes doc comments (`///`), inline comments, TODO/FIXME markers, and comments in `Package.swift`, Makefiles, and shell scripts.
- **Identifiers (types, functions, variables): English only.**
- **User-facing UI strings: localized, following the system language.** English is the
  base (`en.lproj`), Vietnamese (`vi.lproj`) is maintained in the same PR that adds a
  string. In BerryUI use the `L(_:)` helper (`String(localized:bundle:)`); never
  hardcode a display language. `LocalizedError` messages follow the same rule.
- **Test failure messages: English** (developer-facing).
- **Architecture docs (`docs/architecture/`): Vietnamese** — they are the source of truth and reviewed in Vietnamese.

## Window & layout rules

- Windows and sheets show their content in full without internal scrolling whenever
  it can fit on screen: size sheets to their intrinsic content (`scrollDisabled` +
  generous fixed frames), give windows a generous `defaultSize`, and never rely on
  a scroll view to paper over a too-small container.

## Architecture rules (enforced — see docs/architecture/04)

- Dependency direction is one-way: `BerryApp → BerryUI → {BerryCore, BerryStore} → BerryDriverKit ← BerryDriver*`.
  UI never imports a concrete driver; drivers never import core.
- Every SQL statement goes through `QueryService` — the single SQL path (principle N1). Never call `connection.execute` directly from UI.
- Drivers stream results in batches of 500–1000 rows (principle N3). Never buffer a full result set inside a driver.
- Secrets live in the Keychain only, are read at a single point, passed in RAM, and never logged or persisted (docs/architecture/07 §2).
- New features must reference a feature ID from docs/architecture/02 (e.g. `KN-03`, `ED-04`). PR titles carry the ID.
- Any change to module boundaries, dependencies, or driver/AI/license contracts must update the matching doc in `docs/architecture/` in the same PR.

## Comment style

- Comment the *why* and the constraints, not the *what* — reference the governing doc section (e.g. `// docs/architecture/05 §4`) when a decision comes from the architecture docs.
- No redundant comments narrating obvious code.

## Build & test

```sh
make build   # swift build
make test    # swift test (all suites)
make run     # launch the app for development
make app     # package dist/BerryDB.app (release)
```

Driver conformance tests against real servers read env vars
(`BERRYDB_TEST_POSTGRES`, `BERRYDB_TEST_MYSQL`, format `host:port:user:pass`)
and skip silently when unset. `Tests/docker/compose.yml` starts the matrix.