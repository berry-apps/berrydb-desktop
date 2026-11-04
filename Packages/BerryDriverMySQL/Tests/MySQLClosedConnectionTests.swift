import BerryDriverKit
import MySQLNIO
import Testing

@testable import BerryDriverMySQL

/// Runs without a server, so the mapping is checked on every run; the live
/// suite that kills a connection runs only where a server is configured.
@Suite("MySQL closed connection")
struct MySQLClosedConnectionTests {
    /// MySQLNIO raises `MySQLError.closed` for a statement on a connection
    /// whose channel is gone. A query error here would read as a statement
    /// the server refused, and the read-only path would report the server
    /// as unable to run read-only.
    @Test func aClosedChannelIsALostConnection() {
        let mapped = MySQLDriverConnection.mapError(MySQLError.closed)
        guard case .connectionLost = mapped else {
            Issue.record("expected a lost connection, got \(mapped)")
            return
        }
    }
}
