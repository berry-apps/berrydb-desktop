<div align="center">

<img src="webapp/public/images/berrydb-logo.png" alt="BerryDB Logo" width="112" height="112" />

# BerryDB 🫐

### A Native Database Client Built for macOS

[![GitHub Stars](https://img.shields.io/github/stars/berry-apps/berrydb-desktop?style=for-the-badge&logo=github&color=gold)](https://github.com/berry-apps/berrydb-desktop/stargazers)
[![Homebrew](https://img.shields.io/badge/brew-berry--apps%2Ftap%2Fberrydb-orange?style=for-the-badge&logo=homebrew)](https://github.com/berry-apps/homebrew-tap)
[![macOS](https://img.shields.io/badge/macOS-15.0%2B-000000?style=for-the-badge&logo=apple&logoColor=white)](https://apple.com/macos)
[![Swift 6](https://img.shields.io/badge/Swift-6.0-F05138?style=for-the-badge&logo=swift&logoColor=white)](https://swift.org)
[![Zero Electron](https://img.shields.io/badge/Electron-0%25_Pure_Native-007ACC?style=for-the-badge)](https://db.berryhub.app)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg?style=for-the-badge)](LICENSE)
[![Donate via Ko-fi](https://img.shields.io/badge/Donate-Ko--fi-FF5E5B?style=for-the-badge&logo=ko-fi&logoColor=white)](https://ko-fi.com/dautay)

<p align="center">
  <b>Swift 6 + AppKit</b> • <b>9 database engines</b> • <b>AI SQL assistant</b> • <b>Apache 2.0</b>
</p>

<p align="center">
  <a href="https://download-db.berryhub.app/BerryDB-latest.dmg"><b>Download .DMG (macOS 15+)</b></a> •
  <a href="https://db.berryhub.app"><b>Official Website</b></a> •
  <a href="https://github.com/berry-apps/berrydb-desktop/stargazers"><b>⭐️ Star on GitHub</b></a> •
  <a href="https://ko-fi.com/dautay"><b>☕ Donate on Ko-fi</b></a>
</p>

---

![BerryDB Preview](webapp/public/images/og-preview.png)

</div>

<br/>

## 📖 Overview

**BerryDB** is a native database client for macOS developers, data engineers, and DBAs. It is built with **Swift 6, AppKit, and SwiftUI**, with no Electron: the data grid is an AppKit `NSTableView`.

Whether you're querying production PostgreSQL databases, inspecting Redis caches, managing MongoDB collections, exploring Qdrant vector spaces, or querying SQLite files locally, BerryDB keeps the grid responsive and every credential in the macOS Keychain.

---

## ✨ Key Features

### ⚡ Native, No Electron
- **Fast Launch**: A window is on screen about 0.85s after a cold start — no Chromium runtime, no NodeJS backend overhead.
- **Streaming Data Grid**: A view-based AppKit `NSTableView`. Rows arrive in batches while the query is still running, and only the rows on screen get cell views.
- **Bounded by Default**: Results are capped at 1,000 rows; raise the limit or turn it off when you need more. Every row you load is kept in memory.

> Launch time measured on an Apple M1 (16GB, macOS 26.6.2) with a release build. Run `scripts/measure-performance.sh` to reproduce it on your own machine — it reports process spawn and first window separately, because they are not the same number.

### 🗄️ Multi-Engine Database Support
Connect to SQL, NoSQL, Key-Value, and Vector databases all in a unified native workspace:
- **Relational / SQL**:
  - **PostgreSQL**: Native wire protocol (`PostgresNIO`), query cancellation via `pg_cancel_backend`, SSL/TLS.
  - **MySQL & MariaDB**: Native driver (`MySQLNIO`), `caching_sha2_password` (with TLS on) and `mysql_native_password`, SSL/TLS, `KILL QUERY`.
  - **SQLite**: Direct embedded driver via `libsqlite3`, opens WAL-mode databases.
  - **Microsoft SQL Server**: TDS protocol via dynamically linked FreeTDS (`libsybdb`).
- **In-Memory & Key-Value**:
  - **Redis & Valkey**: Valkey-Swift driver, key browser, TTL inspection, and viewers for Strings, Hashes, Lists, Sets, Sorted Sets, and Streams.
- **Document & Cloud NoSQL**:
  - **MongoDB**: Collection browser, JSON document editor, custom filter syntax, and Replica Set support.
  - **AWS DynamoDB**: Query via PartiQL syntax, item inspection, and AWS SigV4 authentication.
- **Vector & Full-Text Search**:
  - **Elasticsearch**: Index browser, search query execution, and JSON document insert/edit/delete.
  - **Qdrant**: Vector collections browser and distance metric inspector.

### 🔒 Keychain & Connection Security
- **Keychain secrets**: Passwords, API keys, SSH passwords, and SSH key passphrases are stored in the macOS Keychain. SSH private keys stay in their own files; BerryDB stores only the path.
- **Built-in SSH Tunneling**: Powered by Citadel (pure Swift SSH client) for secure bastion jump hosts without relying on external terminal sessions.
- **TLS/SSL Encryption**: Verify modes, a custom CA, and client certificates for PostgreSQL and MySQL; TLS on/off with system trust for MongoDB, Redis, Elasticsearch, Qdrant, and DynamoDB.

### 🤖 Intelligent AI SQL Copilot
- **Context-Aware SQL Generation**: Turn natural language into SQL; the assistant reads your schema through tools.
- **Query Explanation & Tuning**: `EXPLAIN` analysis, bottleneck detection, and index recommendations.
- **Chat with Your Database**: Ask questions about your schema, tables, and relationships directly inside the integrated AI panel.
- **Where the AI runs**: In cloud mode (free trial, then a paid plan), your questions, the database type, your schema (table and column names), and the results of queries the assistant runs (up to 100 rows each) are sent to BerryDB's AI service; table sample rows are shared only if you turn that on. On macOS 26 with Apple Intelligence you can switch to Apple's on-device model for free; the conversation text is still sent to BerryDB's service to index your chat history for search.
- **What runs without asking**: Read-only queries the assistant writes run automatically unless you turn off *Auto-run safe SELECTs*; anything that changes data needs your approval. AI is off by default on connections marked as production.

### 🔌 Schema for Coding Agents (MCP)
- **Local MCP helper**: Claude Code, Codex, and Antigravity can start `berrydb-mcp`, a helper inside BerryDB.app, to read the schema BerryDB has cached for the connections you choose: tables, columns, keys, indexes, relationships, and the schema graph.
- **Metadata only**: The helper opens BerryDB's local store read-only, never connects to your databases, and never reads connection passwords. Whatever it returns goes to the agent and from there to that agent's model provider.

### 📊 Database Intelligence & ER Diagrams
- **Mermaid Diagrams**: The AI assistant can draw Mermaid diagrams, such as an ER diagram of your schema, and open them in a tab.
- **Table Analytics & Health**: On-demand table sizing, index usage statistics, and row count estimations.
- **Persistent Query History**: Searchable query log with execution duration, row counts, and one click to open a statement in a new SQL tab.

### ✏️ Pro Query Editor & Inline Data Editing
- **Atomic Inline Editing**: Edit cells directly in the grid (the result needs a primary key); staged edits are written in one transaction when you apply them.
- **Code Editor**: SQL syntax highlighting, completion for keywords, tables, columns, and aliases, and multiple editor tabs.
- **Query Cancellation**: Cancel long-running queries (PostgreSQL, MySQL, SQLite).

---

## 📊 Database Compatibility Matrix

| Database Engine | Driver / Protocol | Direct Connection | SSH Tunnel | Inline Grid Edit | Schema Browser |
| :--- | :--- | :---: | :---: | :---: | :---: |
| **PostgreSQL** | Pure Swift (`PostgresNIO`) | ✅ | ✅ | ✅ | ✅ |
| **MySQL / MariaDB** | Pure Swift (`MySQLNIO`) | ✅ | ✅ | ✅ | ✅ |
| **SQLite** (3.x) | Embedded (`libsqlite3`) | ✅ | N/A | ✅ | ✅ |
| **Microsoft SQL Server** | FreeTDS (`libsybdb`) | ✅ | ✅ | ✅ | ✅ |
| **Redis / Valkey** | Pure Swift (`valkey-swift`) | ✅ | ✅ | ✅ (KV Editor) | ✅ (Keyspace) |
| **MongoDB** | Pure Swift (`MongoWireClient`) | ✅ | ✅ | ✅ (JSON Edit) | ✅ (Collections) |
| **AWS DynamoDB** | AWS REST + SigV4 | ✅ | Self-hosted endpoint only | ✅ | ✅ (Tables) |
| **Elasticsearch** | REST Client | ✅ | ✅ | ✅ (JSON Edit) | ✅ (Indices) |
| **Qdrant** | REST Client | ✅ | ✅ | ✅ (JSON Edit) | ✅ (Collections) |

Integration tests target PostgreSQL 16, MySQL 8.4, SQL Server 2022, MongoDB 7, Elasticsearch 9.5, Qdrant 1.10, and dynamodb-local 3.3 (see `Tests/docker/compose.yml`). Other versions may work but are not tested.

---

## 🚀 Installation & Quick Start

### Option 1: Via Homebrew (Recommended)

Install BerryDB in a single command using the official Homebrew tap:

```sh
brew install --cask berry-apps/tap/berrydb
```

Or add the tap first and install:

```sh
brew tap berry-apps/tap
brew install --cask berrydb
```

### Option 2: Download Pre-built DMG

1. Download the latest release `.dmg` from [download-db.berryhub.app/BerryDB-latest.dmg](https://download-db.berryhub.app/BerryDB-latest.dmg) (or from [GitHub Releases](https://github.com/berry-apps/berrydb-desktop/releases/latest)).
2. Open the `.dmg` file and drag **BerryDB.app** into your **Applications** folder.
3. Launch BerryDB from Spotlight (⌘Space) or Launchpad.

> **System Requirements**: macOS 15.0 (Sequoia) or later. Apple Silicon only (M1/M2/M3/M4).

### Option 3: Build from Source

BerryDB uses the standard Swift Package Manager (SPM) and `make`.

#### Prerequisites
- macOS 15.0 or higher
- **Xcode 16.0+** (with Swift 6 toolchain)
- **FreeTDS library**: `brew install freetds` (required for FreeTDS / SQL Server C headers)

#### Build Steps
```sh
# 1. Clone repository
git clone https://github.com/berry-apps/berrydb-desktop.git
cd berrydb-desktop

# 2. Setup local development configuration
cp .env.example .env

# 3. Build debug bundle and launch application
make run
```

#### Available Make Commands
| Command | Description |
| :--- | :--- |
| `make run` | Build debug app bundle, package into `dist/BerryDB.app`, and launch. |
| `make watch` | Watch for file changes, auto-rebuild, and reload application. |
| `make test` | Run the complete Swift unit and integration test suite. |
| `make app` | Build optimized release application bundle in `dist/BerryDB.app`. |

---

## 🎯 User Guide

### 1. Adding a Database Connection
1. Click **New Connection** (⇧⌘N) or select the `+` button in the sidebar.
2. Choose your database type (PostgreSQL, MySQL, SQLite, Redis, MongoDB, SQL Server, etc.).
3. Enter your connection credentials (Host, Port, User, Password, Database).
   - *Optional*: Toggle **SSH Tunnel** to route traffic through a jump server.
   - *Optional*: Toggle **SSL/TLS** for secure encrypted connections.
4. Click **Test Connection** to verify connectivity, then click **Save**. Passwords are encrypted securely in your macOS Keychain.

### 2. Navigating Schema & ER Diagrams
- Use the sidebar schema tree to browse tables, views, functions, procedures, and triggers; **Edit Table…** and **Show DDL** show columns, keys, and indexes.
- Right-click a table for **Open Data**, **Edit Table…**, **Show DDL**, or **Quick Info…**.

### 3. Writing Queries & Using the AI Copilot
- Press **⌘T** to open a new query editor tab.
- Type SQL queries with keyword completion, then press **⌘Return** to execute.
- Open the **AI Assistant** panel (or press **⌘J**):
  - Type a natural language prompt, e.g. *"Show top 10 customers by revenue this month"* or *"Find slow queries and suggest index optimization"*.
  - The assistant writes proposed SQL into the active editor tab. Before running a statement itself, it asks you to **Run** or **Deny**; read-only queries run automatically unless you turn off *Auto-run safe SELECTs*.

### 4. Editing Data Directly in the Grid
- Double-click a cell in the data grid to edit it inline (the result needs a primary key).
- Edited values show in orange and deleted rows are dimmed. Use the **Apply** (✓) or **Discard** button in the status bar to commit them in one transaction or revert.

### 5. Connecting Coding Agents (MCP)
1. Run BerryDB from your **Applications** folder, and open each connection you want agents to see once, so BerryDB caches its schema. Connections marked as production are not cached.
2. Open **Settings** (⌘,) → **AI Agents** → **New Project…**. Name the project, turn on **Enabled**, add the repositories it covers under **Workspace Folders**, turn on its connections, and click **Save**.
3. Copy your agent's command from the project's **Agent Setup** section and run it once in Terminal. For Claude Code it looks like this:
   ```sh
   claude mcp add --scope user berrydb -- '/Applications/BerryDB.app/Contents/Helpers/berrydb-mcp'
   ```
4. Start a new agent session in one of those folders and ask the agent to call `berrydb_status`. If macOS asks whether `berrydb-mcp` may use a key in your login keychain, choose **Always Allow**.

Only add connections whose schema you are willing to share: what the tools return goes to the agent's model provider. Per-repository entries, status reasons, and current limits are in the [Coding Agents (MCP) guide](https://db.berryhub.app/docs#coding-agents).

---

## ☕ Support the Project (Donate)

BerryDB is completely free and open-source for all local database management capabilities; only the cloud AI service is paid. If BerryDB saves you time, enhances your workflow, or replaces expensive subscription tools, consider buying the creators a coffee:

<div align="center">

[![Buy Me A Coffee on Ko-fi](https://img.shields.io/badge/Ko--fi-Support_Development-FF5E5B?style=for-the-badge&logo=ko-fi&logoColor=white)](https://ko-fi.com/dautay)

### 👉 **[https://ko-fi.com/dautay](https://ko-fi.com/dautay)**

Your support helps cover Apple Developer program fees, maintain server infrastructure, and fuel continuous feature development!

</div>

---

## 🤝 Contributing

Contributions, issues, and feature requests are welcome!
1. Fork the repository.
2. Create your feature branch (`git checkout -b feature/AmazingFeature`).
3. Commit your changes (`git commit -m 'feat: add amazing feature'`).
4. Push to the branch (`git push origin feature/AmazingFeature`).
5. Open a Pull Request.

---

## 📄 License & Third-Party Notices

BerryDB is open-source software licensed under the **[Apache License 2.0](LICENSE)** — free for personal and commercial use.

For detailed third-party attributions and compliance (including LGPL-2.1 dynamic linking compliance for FreeTDS), please refer to **[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)**.

---

## ⭐️ Support the Project

If you find BerryDB useful, please consider giving it a **star on GitHub**! It helps more developers discover the tool and supports continuous open-source development.
