import Foundation
import Testing

@testable import BerryUI

/// A collection/table name is data from the connected server, not trusted
/// input — a malicious/compromised server could return one shaped like a
/// path-traversal payload. `DataSourceBackupService` uses this name to build
/// a filesystem path for both backup and restore.
@Suite("DataSourceBackupService path safety")
struct DataSourceBackupServicePathSafetyTests {
    @Test func stripsPathSeparatorsFromAServerSuppliedName() {
        let malicious = "../../../Library/LaunchAgents/evil"
        let safe = DataSourceBackupService.safeFileComponent(malicious)
        #expect(!safe.contains("/"))
    }

    @Test func sanitizedNameStaysWithinTheBundleDirectory() {
        let malicious = "../../../Library/LaunchAgents/evil"
        let bundleURL = URL(fileURLWithPath: "/tmp/some-backup-bundle")
        let fileURL = bundleURL.appendingPathComponent("\(DataSourceBackupService.safeFileComponent(malicious)).ndjson")
        #expect(fileURL.deletingLastPathComponent().path == bundleURL.path)
    }

    @Test func ordinaryNamesAreUnaffected() {
        #expect(DataSourceBackupService.safeFileComponent("orders") == "orders")
        #expect(DataSourceBackupService.safeFileComponent("user_events_2026") == "user_events_2026")
    }
}
