// swift-tools-version: 6.0
// BerryDB — native database manager for macOS.
// Pure Swift 6, AppKit & SwiftUI native architecture.
import PackageDescription

let package = Package(
    name: "BerryDB",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "BerryApp", targets: ["BerryApp"]),
        .library(name: "BerryDriverKit", targets: ["BerryDriverKit"]),
        .library(name: "BerryDataSourceKit", targets: ["BerryDataSourceKit"]),
        .library(name: "BerryCore", targets: ["BerryCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
        .package(url: "https://github.com/vapor/mysql-nio.git", from: "1.7.0"),
 // Redis/Valkey driver (KV-*). RediStack (the design
        // doc's original pick) is deprecated by the Swift Server Workgroup in
        // favor of this: https://forums.swift.org/t/deprecating-redistack-
        // transitioning-to-valkey-swift/86172. Valkey is the Linux Foundation's
        // wire-compatible fork of Redis (post relicensing); valkey-swift is 1.0,
        // Swift 6 native, and connects to real Redis servers too (compatible up
        // to the v7.2.4 fork point). Requires macOS 15+ (its own AvailabilityMacro)
        // — BerryDriverRedis is @available(macOS 15, *) throughout; the app's own
 // minimum stays.macOS(.v14).
        .package(url: "https://github.com/valkey-io/valkey-swift.git", from: "1.0.0"),
        // Forked from orlandos-nl/Citadel at ae8562f (the tip when forked) with
        // upstream PR #135 (RFC 8332 rsa-sha2-256/512) cherry-picked on top —
        // needed because OpenSSH 8.8+ servers reject Citadel's SHA-1-only
 // `ssh-rsa` by default. Re-point at upstream once that PR
        // merges and a release including it ships.
        .package(url: "https://github.com/quangtaned/Citadel.git", revision: "aef7eebf90860a6abca4580c31e85b88ab9ce832"),
        // Sparkle auto-update — unconditional, like every other dependency
        // here. `canImport(Sparkle)` in AppUpdater.swift is therefore true
        // for every ordinary build (`swift build`/`swift test`/`swift run`),
        // not only a packaged release. scripts/check-size.sh's runtime-
        // dependency guard already sanctions Sparkle.framework as a permanent
        // embedded exception (see its own comment) and deploy/release.sh
        // embeds and signs it unconditionally too, so there is no
        // dependency-free build variant to preserve here. See deploy/README.md.
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
    ],
    targets: [
 // MARK: Driver contracts — no dependencies
        .target(
            name: "BerryDriverKit",
            path: "Packages/BerryDriverKit/Sources",
            resources: [.process("Resources")]
        ),

 // MARK: NoSQL/vector contracts — sibling of
        // BerryDriverKit, for data with no SQL shape (Mongo, Qdrant). DynamoDB
        // implements DatabaseDriver instead (PartiQL) and stays in BerryDriverKit's
        // family, not this one.
        .target(
            name: "BerryDataSourceKit",
            dependencies: ["BerryDriverKit"],
            path: "Packages/BerryDataSourceKit/Sources",
            resources: [.process("Resources")]
        ),

 // MARK: Key-value contracts — third driver
        // family, sibling of BerryDriverKit/BerryDataSourceKit, for a
        // schemaless key space with no SQL and no "collection" shape (Redis).
        // No dependency on any concrete client library — stays usable at the
        // app's real deployment target (macOS 14) so the connection picker
        // can query KeyValueRegistry.registered unconditionally.
        .target(
            name: "BerryKeyValueKit",
            dependencies: ["BerryDriverKit"],
            path: "Packages/BerryKeyValueKit/Sources"
        ),

        // MARK: SQLite driver (system libsqlite3)
        .target(
            name: "BerryDriverSQLite",
            dependencies: ["BerryDriverKit"],
            path: "Packages/BerryDriverSQLite/Sources",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),

        // MARK: PostgreSQL driver (PostgresNIO, pure Swift)
        .target(
            name: "BerryDriverPostgres",
            dependencies: [
                "BerryDriverKit",
                .product(name: "PostgresNIO", package: "postgres-nio"),
            ],
            path: "Packages/BerryDriverPostgres/Sources"
        ),

        // MARK: MySQL/MariaDB driver (MySQLNIO, pure Swift)
        .target(
            name: "BerryDriverMySQL",
            dependencies: [
                "BerryDriverKit",
                .product(name: "MySQLNIO", package: "mysql-nio"),
            ],
            path: "Packages/BerryDriverMySQL/Sources"
        ),

 // MARK: Qdrant driver — zero vendored deps,
 // plain REST/JSON over URLSession (same pattern as the AI client).
        .target(
            name: "BerryDriverQdrant",
            dependencies: ["BerryDataSourceKit", "BerryDriverKit"],
            path: "Packages/BerryDriverQdrant/Sources"
        ),

 // MARK: Elasticsearch driver — zero vendored
        // deps, plain REST/JSON over URLSession (same pattern as
        // BerryDriverQdrant — no maintained/production-ready Swift ES client
 // exists).
        .target(
            name: "BerryDriverElasticsearch",
            dependencies: ["BerryDataSourceKit", "BerryDriverKit"],
            path: "Packages/BerryDriverElasticsearch/Sources"
        ),

 // MARK: MongoDB driver — zero vendored deps,
        // hand-rolled OP_MSG wire protocol + BSON + SCRAM-SHA-256 (CryptoKit,
        // an Apple platform framework, not a new SwiftPM package). The design
        // doc's first choice, `mongo-swift-driver`, was tried and rejected:
        // even its latest tag still wraps the C `libmongoc` driver
        // (`CLibMongoC` target) — no pure-Swift rewrite ever shipped, and the
        // project has been in "Development Pause" (EOL, no further commits) since 2023.
        .target(
            name: "BerryDriverMongo",
            dependencies: ["BerryDataSourceKit", "BerryDriverKit"],
            path: "Packages/BerryDriverMongo/Sources"
        ),

        // MARK: DynamoDB driver — PartiQL over the existing DatabaseDriver contract.
        // Zero vendored dependency: hand-rolled AWS SigV4 (CryptoKit, an Apple platform
        // framework) + plain REST/JSON over URLSession, keeping the binary lean.
        .target(
            name: "BerryDriverDynamoDB",
            dependencies: ["BerryDriverKit"],
            path: "Packages/BerryDriverDynamoDB/Sources"
        ),

 // MARK: SQL Server driver (V2⚠️) — the one
        // deliberate exception to this app's pure-Swift/no-FFI rule (Q8): TDS
        // has no REST/JSON surface to reuse the way DynamoDB/Qdrant do, and no
        // production-viable pure-Swift TDS implementation exists yet (both
        // candidates found in research are alpha-stage, evaluated and
 // rejected). Bridges to
        // FreeTDS's DB-Library C API (`-lsybdb`), LGPL, must stay dynamically
 // linked (NOTICE requirement). Homebrew's
        // freetds formula ships no pkg-config file, hence the explicit
        // include/library search paths instead of `pkgConfig:`.
        .systemLibrary(name: "CFreeTDS", path: "Packages/BerryDriverSQLServer/Sources/CFreeTDS"),
        .target(
            name: "BerryDriverSQLServer",
            dependencies: ["BerryDriverKit", "CFreeTDS"],
            path: "Packages/BerryDriverSQLServer/Sources/BerryDriverSQLServer",
            cSettings: [.unsafeFlags([
                "-I/opt/homebrew/opt/freetds/include",
                "-I/usr/local/opt/freetds/include",
            ])],
            swiftSettings: [.unsafeFlags([
                "-Xcc", "-I/opt/homebrew/opt/freetds/include",
                "-Xcc", "-I/usr/local/opt/freetds/include",
            ])],
            linkerSettings: [
                .unsafeFlags([
                    "-L/opt/homebrew/opt/freetds/lib",
                    "-L/usr/local/opt/freetds/lib",
                ]),
                .linkedLibrary("sybdb"),
            ]
        ),

 // MARK: Redis/Valkey driver (KV-*) — implements
        // KeyValueDriver (BerryKeyValueKit), the third contract family, on top
        // of valkey-swift. @available(macOS 15, *) throughout (see
        // RedisDriver.swift's doc comment).
        .target(
            name: "BerryDriverRedis",
            dependencies: [
                "BerryDriverKit",
                "BerryKeyValueKit",
                .product(name: "Valkey", package: "valkey-swift"),
            ],
            path: "Packages/BerryDriverRedis/Sources"
        ),

 // MARK: SSH tunnel — local forwarder over Citadel
        .target(
            name: "BerryTunnel",
            dependencies: [
                "BerryDriverKit",
                .product(name: "Citadel", package: "Citadel"),
            ],
            path: "Packages/BerryTunnel/Sources"
        ),

        // MARK: Business logic — no UI, no concrete drivers
        .target(
            name: "BerryCore",
            dependencies: ["BerryDriverKit", "BerryTunnel"],
            path: "Packages/BerryCore/Sources"
        ),

        // MARK: sqlite-vec (vendored C amalgamation, v0.1.9) — statically linked
 // vector-search SQLite extension for local chat-message RAG
 // architecture). SQLITE_CORE links it directly against the
        // system libsqlite3 symbols instead of the loadable-extension API, so
 // it can be registered once via sqlite3_auto_extension without
        // shipping/loading a separate .dylib.
        .target(
            name: "CSQLiteVec",
            path: "Packages/BerryStore/Sources/CSQLiteVec",
            cSettings: [.define("SQLITE_CORE")],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),

 // MARK: Local persistence — profiles/history/prefs
        .target(
            name: "BerryStore",
            dependencies: [
                "BerryDriverKit",
                "CSQLiteVec",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Packages/BerryStore/Sources",
            exclude: ["CSQLiteVec"]
        ),

 // MARK: Licensing & commercialization client
        // Offline Ed25519 verification + activation/trial/pricing against
        // berrydb-backend. No driver/UI dependencies.
        .target(
            name: "BerryLicense",
            path: "Packages/BerryLicense/Sources"
        ),

 // MARK: Database Intelligence graph — in-memory
        // DSG + pure-Swift algorithms. Depends only on the driver contracts for
        // schema types; no module depends on BerryGraph (removing V1.5 leaves
        // 1.0 intact). Store persistence + harvesters land in later chunks.
        .target(
            name: "BerryGraph",
            dependencies: ["BerryDriverKit", "BerryStore", "BerryCore"],
            path: "Packages/BerryGraph/Sources"
        ),

 // MARK: AI agent client — SSE consumer + tool
        // executor. Tools run through BerryCore (QueryService/SchemaCatalog);
        // Bearer token comes from BerryLicense. BerryGraph backs the local
 // graph_query tool. BerryStore: local chat history + sqlite-vec
 // RAG (Q17) — already reachable
        // transitively via BerryGraph, this just makes the edge direct since
        // AISession/search_conversation use it directly. No module depends on
        // BerryAI.
        .target(
            name: "BerryAI",
            dependencies: ["BerryCore", "BerryDriverKit", "BerryLicense", "BerryGraph", "BerryStore"],
            path: "Packages/BerryAI/Sources",
            resources: [.process("Resources")]
        ),

        // MARK: UI (SwiftUI + AppKit) — never imports drivers directly.
 // BerryGraph backs harvest-on-refresh + the graph_query tool.
        .target(
            name: "BerryUI",
            // BerryDataSourceKit: the Mongo/Qdrant sidebar/tab/grid path
 // touches only the DataSourceDriver
            // protocol surface — never a concrete driver package, same
            // registry-pattern discipline as the SQL side. BerryKeyValueKit:
 // the Redis key-browser path — same
            // discipline again, only the KeyValueDriver protocol surface,
            // never BerryDriverRedis (which is macOS-15-gated and app-target-
            // only). BerryTunnel: connectDataSource/connectKeyValue need
            // SSHTunnel directly (BerryCore's ConnectionManager.prepareEndpoint
            // has no DataSourceDriver/KeyValueDriver equivalent to reuse).
            dependencies: [
                "BerryCore", "BerryStore", "BerryLicense", "BerryAI", "BerryGraph",
                "BerryDataSourceKit", "BerryKeyValueKit", "BerryTunnel",
            ],
            path: "Packages/BerryUI/Sources",
            resources: [.process("Resources")]
        ),

        // MARK: App target — the only place that wires drivers into the registry
        .executableTarget(
            name: "BerryApp",
            dependencies: [
                "BerryUI", "BerryCore",
                "BerryDriverSQLite", "BerryDriverPostgres", "BerryDriverMySQL",
                "BerryDriverSQLServer",
                "BerryDriverQdrant", "BerryDriverDynamoDB", "BerryDriverMongo",
                "BerryDriverElasticsearch",
                // BerryKeyValueKit: KeyValueRegistry.register(...) call below.
                // BerryDriverRedis: @available(macOS 15, *) throughout — see
                // its own registration call for why this app target can still
                // depend on it unconditionally while staying .macOS(.v14).
                "BerryKeyValueKit", "BerryDriverRedis",
                // Sparkle product — unconditional, see the dependency
                // comment above.
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "App/Sources"
        ),
        // BerryApp has no other consumer to exercise its launch-time
        // scheduling logic (UpdaterAutoStart) against — Sparkle itself can't
        // be driven in a test, but the decision of *when* to call
        // `startIfNeeded()` can via an injected scheduler + a recording
        // UpdaterControlling double. `@testable import BerryApp` needs an
        // executable-target test, hence this lives here rather than in a
        // Packages/*/Tests directory.
        .testTarget(
            name: "BerryAppTests",
            dependencies: ["BerryApp"],
            path: "App/Tests"
        ),

        // MARK: Tests
        .target(
            name: "BerryDriverTestKit",
            dependencies: ["BerryDriverKit"],
            path: "Packages/BerryDriverTestKit/Sources"
        ),
        .testTarget(
            name: "BerryDataSourceKitTests",
            dependencies: ["BerryDataSourceKit", "BerryDriverKit"],
            path: "Packages/BerryDataSourceKit/Tests/BerryDataSourceKitTests"
        ),
        .testTarget(
            name: "BerryKeyValueKitTests",
            dependencies: ["BerryKeyValueKit", "BerryDriverKit"],
            path: "Packages/BerryKeyValueKit/Tests"
        ),
        .testTarget(
            name: "BerryDriverSQLiteTests",
            dependencies: ["BerryDriverSQLite", "BerryDriverKit", "BerryDriverTestKit"],
            path: "Packages/BerryDriverSQLite/Tests"
        ),
        .testTarget(
            name: "BerryDriverPostgresTests",
            dependencies: ["BerryDriverPostgres", "BerryDriverKit", "BerryDriverTestKit"],
            path: "Packages/BerryDriverPostgres/Tests"
        ),
        .testTarget(
            name: "BerryDriverSQLServerTests",
            dependencies: ["BerryDriverSQLServer", "BerryDriverKit", "BerryDriverTestKit"],
            path: "Packages/BerryDriverSQLServer/Tests",
            cSettings: [.unsafeFlags([
                "-I/opt/homebrew/opt/freetds/include",
                "-I/usr/local/opt/freetds/include",
            ])],
            swiftSettings: [.unsafeFlags([
                "-Xcc", "-I/opt/homebrew/opt/freetds/include",
                "-Xcc", "-I/usr/local/opt/freetds/include",
            ])],
            linkerSettings: [
                .unsafeFlags([
                    "-L/opt/homebrew/opt/freetds/lib",
                    "-L/usr/local/opt/freetds/lib",
                ]),
                .linkedLibrary("sybdb"),
            ]
        ),
        .testTarget(
            name: "BerryDriverMySQLTests",
            dependencies: ["BerryDriverMySQL", "BerryDriverKit", "BerryDriverTestKit"],
            path: "Packages/BerryDriverMySQL/Tests"
        ),
        .testTarget(
            name: "BerryDriverQdrantTests",
            dependencies: [
                "BerryDriverQdrant", "BerryDataSourceKit", "BerryDriverKit", "BerryDriverTestKit",
            ],
            path: "Packages/BerryDriverQdrant/Tests"
        ),
        .testTarget(
            name: "BerryDriverElasticsearchTests",
            dependencies: [
                "BerryDriverElasticsearch", "BerryDataSourceKit", "BerryDriverKit", "BerryDriverTestKit",
            ],
            path: "Packages/BerryDriverElasticsearch/Tests"
        ),
        .testTarget(
            name: "BerryDriverDynamoDBTests",
            dependencies: ["BerryDriverDynamoDB", "BerryDriverKit", "BerryDriverTestKit"],
            path: "Packages/BerryDriverDynamoDB/Tests"
        ),
        .testTarget(
            name: "BerryDriverRedisTests",
            dependencies: ["BerryDriverRedis", "BerryKeyValueKit", "BerryDriverKit", "BerryDriverTestKit"],
            path: "Packages/BerryDriverRedis/Tests"
        ),
        .testTarget(
            name: "BerryDriverMongoTests",
            dependencies: [
                "BerryDriverMongo", "BerryDataSourceKit", "BerryDriverKit", "BerryDriverTestKit",
            ],
            path: "Packages/BerryDriverMongo/Tests"
        ),
        .testTarget(
            name: "BerryTunnelTests",
            dependencies: [
                "BerryTunnel", "BerryDriverKit", "BerryDriverTestKit",
                "BerryDriverPostgres",
            ],
            path: "Packages/BerryTunnel/Tests"
        ),
        .testTarget(
            name: "BerryCoreTests",
            // BerryDriverSQLite: integration tests apply ChangeSets to a real
            // in-process database.
            dependencies: ["BerryCore", "BerryDriverKit", "BerryDriverSQLite"],
            path: "Packages/BerryCore/Tests"
        ),
        .testTarget(
            name: "BerryStoreTests",
            dependencies: [
                "BerryStore", "BerryDriverKit",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Packages/BerryStore/Tests"
        ),
        .testTarget(
            name: "BerryLicenseTests",
            dependencies: ["BerryLicense"],
            path: "Packages/BerryLicense/Tests"
        ),
        .testTarget(
            name: "BerryGraphTests",
            // Postgres/MySQL + TestKit: the harvester test builds the DSG from a
            // real schema on the Docker matrix (skips when env is unset).
 // BerryDriverSQLite: the Query Analyzer plans EXPLAIN output
            // against an in-process SQLite database — deterministic, no Docker.
            dependencies: [
                "BerryGraph", "BerryDriverKit", "BerryStore", "BerryCore",
                "BerryDriverPostgres", "BerryDriverMySQL", "BerryDriverSQLite",
                "BerryDriverTestKit",
            ],
            path: "Packages/BerryGraph/Tests"
        ),
        .testTarget(
            name: "BerryUITests",
            // BerryDriverSQLite: harvest-on-refresh + graph_query wiring is
            // exercised end-to-end against an in-process SQLite schema.
            // BerryDataSourceKit/BerryDriverMongo/BerryDriverQdrant/
            // BerryDriverTestKit: the Mongo/Qdrant workspace wiring
 // has its own Docker-gated conformance
            // suite here, same pattern as the SQLite one above.
            // BerryKeyValueKit/BerryDriverRedis: the Redis workspace wiring
 // has its own Docker/local-server-gated
            // conformance suite here too, same pattern as Mongo/Qdrant above.
            dependencies: [
                "BerryUI", "BerryCore", "BerryStore", "BerryGraph", "BerryAI",
                "BerryDriverKit", "BerryDriverSQLite",
                "BerryDataSourceKit", "BerryDriverMongo", "BerryDriverQdrant", "BerryDriverTestKit",
                "BerryKeyValueKit", "BerryDriverRedis",
            ],
            path: "Packages/BerryUI/Tests"
        ),
        .testTarget(
            name: "BerryAITests",
            // BerryDriverSQLite: the tool executor runs SQL against a real
            // in-process database through QueryService. BerryStore/BerryGraph:
            // the graph_query tool reads a persisted DSG.
            dependencies: [
                "BerryAI", "BerryCore", "BerryDriverKit", "BerryDriverSQLite",
                "BerryStore", "BerryGraph",
            ],
            path: "Packages/BerryAI/Tests"
        ),

 // MARK: Performance benchmarks (M7) — opt-in
        // via `make bench` (BERRYDB_BENCH=1 + Docker matrix); skipped otherwise.
        .testTarget(
            name: "BerryBenchmarks",
            dependencies: [
                "BerryCore", "BerryDriverKit", "BerryDriverTestKit",
                "BerryDriverPostgres", "BerryDriverMySQL",
            ],
            path: "Benchmarks"
        ),
    ]
)
