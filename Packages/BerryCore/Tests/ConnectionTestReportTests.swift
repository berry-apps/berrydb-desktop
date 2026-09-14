import BerryDriverKit
import BerryDriverSQLite
import Foundation
import Testing

@testable import BerryCore

/// Connection-test step breakdown.
@Suite("ConnectionManager.testReport")
struct ConnectionTestReportTests {
    @Test func reportsConnectAndPingForSQLite() async throws {
        DriverRegistry.register(SQLiteDriver.self)
        let path = NSTemporaryDirectory() + "berry_kn06_\(UUID().uuidString).sqlite"
        FileManager.default.createFile(atPath: path, contents: nil)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let report = await ConnectionManager.shared.testReport(.sqlite(path: path))

        // No SSH configured, so only connect + ping run, in order.
        let stepKinds = report.steps.map(\.step)
        let allPassed = report.steps.allSatisfy(\.passed)
        #expect(report.succeeded)
        #expect(report.errorMessage == nil)
        #expect(stepKinds == [.connect, .ping])
        #expect(allPassed)
    }

    @Test func reportsUnregisteredDriverWithoutSteps() async {
        let config = ConnectionConfig(driver: .redis, name: "x", host: "localhost", port: 6379)
        let report = await ConnectionManager.shared.testReport(config)
        #expect(!report.succeeded)
        #expect(report.steps.isEmpty)
    }
}
