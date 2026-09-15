# Contributing to BerryDB 🫐

Thank you for your interest in contributing to BerryDB! We welcome contributions from developers of all skill levels to help make BerryDB the fastest, most reliable native database client on macOS.

---

## Code of Conduct

All contributors and participants are expected to uphold our [Code of Conduct](CODE_OF_CONDUCT.md). Please be kind, welcoming, and respectful.

---

## How Can I Contribute?

- **Reporting Bugs:** Open an issue with steps to reproduce, macOS version, database engine, and expected vs actual behavior.
- **Suggesting Features:** Share ideas for new database drivers, UI improvements, or performance optimizations via an issue.
- **Submitting Pull Requests:** Fix a bug, add unit tests, improve documentation, or implement an approved feature.

---

## Local Development Setup

### 1. Prerequisites

- macOS 15.0 (Sequoia) or later
- **Xcode 16.0+** (with Swift 6 toolchain)
- **FreeTDS** C library (for TDS / SQL Server driver):
  ```sh
  brew install freetds
  ```

### 2. Fork and Clone

```sh
# Clone your fork
git clone https://github.com/<your-username>/berrydb-desktop.git
cd berrydb-desktop

# Setup local environment
cp .env.example .env
```

### 3. Build & Run

BerryDB provides convenient Make targets for development:

```sh
# Run the debug app
make run

# Run in watch mode (auto-rebuilds and restarts on Swift source changes)
make watch

# Run test suite
make test
```

> **Tip:** If you see repeated macOS Keychain prompts for database passwords across development rebuilds, run `make dev-sign-setup` once to configure a stable local code-signing identity.

---

## Development Guidelines

### Architecture Principles

1. **Pure Native & Lightweight**: BerryDB avoids Electron or web wrappers for its desktop client core. Code should be written in clean, idiomatic Swift 6 using SwiftUI and AppKit.
2. **Strict Concurrency**: The codebase complies with Swift 6 strict concurrency checks (`Sendable`, `@MainActor`, actors). Avoid unsafe concurrency workarounds.
3. **Hardware Enclave Security**: Never store raw credentials, passwords, or private keys on disk. Use the macOS Keychain via `BerryCore` / `BerryTunnel`.
4. **Performance First**: Virtualized lists (`NSTableView`), lazy loading, and streaming data feeds are preferred over loading massive datasets directly into memory.

### Git & Pull Request Workflow

1. Create a descriptive feature branch from `main`:
   ```sh
   git checkout -b feat/support-new-engine
   # or
   git checkout -b fix/grid-scrolling-glitch
   ```
2. Make your changes and ensure all tests pass:
   ```sh
   make test
   ```
3. Commit using conventional commit format:
   - `feat: ...` for new features
   - `fix: ...` for bug fixes
   - `perf: ...` for performance improvements
   - `docs: ...` for documentation changes
   - `test: ...` for test additions
4. Push your branch to GitHub and open a Pull Request against `main`.
5. Clearly describe the problem, the solution, and attach screenshots or videos for UI changes.

---

## License

By contributing to BerryDB, you agree that your contributions will be licensed under the [Apache License 2.0](LICENSE).
