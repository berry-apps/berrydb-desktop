import CSQLiteVec
import GRDB
import SQLite3

/// Registers the vendored `sqlite-vec` extension (v0.1.9, statically linked —
/// see `CSQLiteVec`) so GRDB's `vec0` virtual tables work (docs/agents/
/// architecture/11 §7.3, local RAG for chat messages).
///
/// `sqlite3_auto_extension` (the usual process-global registration API) is
/// explicitly unsupported on Apple platforms — the system libsqlite3 no-ops
/// it (`API_DEPRECATED("Process-global auto extensions are not supported on
/// Apple platforms", ...)` in the SDK's sqlite3.h). Instead, call
/// `sqlite3_vec_init` directly on each connection via GRDB's
/// `Configuration.prepareDatabase` hook, which GRDB runs once per opened
/// connection before handing it back for use.
enum SQLiteVecExtension {
    static func install(into db: Database) throws {
        let status = sqlite3_vec_init(db.sqliteConnection, nil, nil)
        guard status == SQLITE_OK else {
            throw DatabaseError(resultCode: ResultCode(rawValue: status), message: "sqlite-vec extension failed to initialize")
        }
    }
}
