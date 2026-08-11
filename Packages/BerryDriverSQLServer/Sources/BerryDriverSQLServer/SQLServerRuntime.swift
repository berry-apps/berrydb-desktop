import BerryDriverKit
import CFreeTDS
import Foundation

/// FreeTDS DB-Library is a process-global C API: `dbinit()` runs once per
/// process, and `dberrhandle`/`dbmsghandle` are process-wide function
/// pointers — C has no per-call captured context here, unlike a Swift
/// closure. This actor serializes the two operations that genuinely need
/// process-wide coordination: one-time init, and the login/open sequence.
/// Confirmed via a real spike (not assumed): FreeTDS's error handler can fire
/// with an in-progress DBPROCESS during `dbopen()` even when `dbopen()`
/// ultimately returns NULL, so two connections opening concurrently could
/// misattribute each other's connection error without this actor's
/// serialization. Once a connection is open, its own queries run
/// independently on its own actor (`SQLServerConnection`) — only the
/// init/open sequence itself needs this global lock.
actor SQLServerRuntime {
    static let shared = SQLServerRuntime()
    private var initialized = false

    /// Returns a `SQLServerHandle` (not a raw `OpaquePointer`, which isn't
    /// `Sendable` and can't cross this actor boundary) wrapping the newly
    /// opened `DBPROCESS`.
    func open(host: String, port: Int, username: String, password: String, appName: String) throws -> SQLServerHandle {
        if !initialized {
            dberrhandle(sqlServerErrorHandler)
            dbmsghandle(sqlServerMessageHandler)
            guard dbinit() == SUCCEED else {
                throw DriverError.connectionFailed("FreeTDS dbinit() failed")
            }
            // `dbopen()` below is a single blocking C call with no per-call
            // cancellation (see `SQLServerConnection.cancelCurrentQuery`'s
            // comment on why client-side Task cancellation can't interrupt
            // it), and this whole `open()` sequence is serialized on this
            // actor. Without a bound, a bad host/port that accepts-but-never-
            // responds (or a container still starting) hangs `dbopen()`
            // indefinitely and wedges every subsequent connection attempt for
            // the rest of the app session, not just the one that triggered
            // it. `dbsetlogintime` is process-global (applies to every
            // dbopen() from here on), so one call at init time is enough.
            _ = dbsetlogintime(15)
            initialized = true
        }
        guard let login = dblogin() else {
            throw DriverError.connectionFailed("FreeTDS dblogin() failed")
        }
        defer { dbloginfree(login) }
        cfreetds_dbsetluser(login, username)
        cfreetds_dbsetlpwd(login, password)
        cfreetds_dbsetlapp(login, appName)

        SQLServerErrorBox.shared.clearMostRecent()
        guard let dbproc = dbopen(login, "\(host):\(port)") else {
            let message = SQLServerErrorBox.shared.takeMostRecent() ?? "Could not connect to \(host):\(port)"
            throw DriverError.connectionFailed(message)
        }
        return SQLServerHandle(dbproc: dbproc)
    }
}

/// Correlates DB-Library's global error/message callbacks back to a Swift
/// error message. Two slots: `mostRecent` (read by `SQLServerRuntime.open`
/// immediately after a failed `dbopen()`, safe because `open()` is
/// actor-serialized so no other open() can be interleaving) and a
/// per-`dbproc`-keyed dictionary (read by an already-open connection's own
/// query methods, safe because a live `DBPROCESS` pointer is a stable,
/// unique key once `dbopen()` has actually returned it).
final class SQLServerErrorBox: @unchecked Sendable {
    static let shared = SQLServerErrorBox()
    private let lock = NSLock()
    private var mostRecent: String?
    private var perConnection: [UInt: String] = [:]

    func clearMostRecent() {
        lock.lock(); mostRecent = nil; lock.unlock()
    }

    func takeMostRecent() -> String? {
        lock.lock(); defer { lock.unlock() }
        let m = mostRecent
        mostRecent = nil
        return m
    }

    func record(dbproc: OpaquePointer?, message: String) {
        lock.lock()
        mostRecent = message
        if let dbproc { perConnection[UInt(bitPattern: dbproc)] = message }
        lock.unlock()
    }

    func take(dbproc: OpaquePointer) -> String? {
        lock.lock(); defer { lock.unlock() }
        return perConnection.removeValue(forKey: UInt(bitPattern: dbproc))
    }

    func clear(dbproc: OpaquePointer) {
        lock.lock(); perConnection.removeValue(forKey: UInt(bitPattern: dbproc)); lock.unlock()
    }
}

/// Registered once via `dberrhandle` — must be a plain top-level `let`
/// closure capturing no context (C function pointer, not a Swift closure
/// with state). Returning 2 (`INT_CANCEL`) tells DB-Library to abandon the
/// operation and return control to the caller instead of DB-Library's own
/// default retry/prompt behavior, which has no meaning in a non-interactive
/// driver.
private let sqlServerErrorHandler: EHANDLEFUNC = { dbproc, severity, dberr, oserr, dberrstr, oserrstr in
    let message = dberrstr.map { String(cString: $0) } ?? "Unknown FreeTDS error (severity \(severity), dberr \(dberr))"
    SQLServerErrorBox.shared.record(dbproc: dbproc, message: message)
    return 2
}

/// Registered once via `dbmsghandle` — server messages (e.g. `PRINT`, `RAISERROR`)
/// arrive here, not through `dberrhandle`. Severity 0 covers informational
/// messages (e.g. a `USE <database>` confirmation) — not a real error, so
/// only severity > 0 is recorded as the connection's current error.
private let sqlServerMessageHandler: MHANDLEFUNC = { dbproc, msgno, msgstate, severity, msgtext, srvname, procname, line in
    guard severity > 0 else { return 0 }
    let message = msgtext.map { String(cString: $0) } ?? "Unknown FreeTDS message #\(msgno)"
    SQLServerErrorBox.shared.record(dbproc: dbproc, message: message)
    return 0
}
