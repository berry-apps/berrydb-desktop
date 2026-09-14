import BerryCore
import BerryDriverKit
import BerryDriverSQLite
import Foundation
import Testing
@testable import BerryUI

@Suite("ImportSQLSheet Tests")
struct ImportSQLSheetTests {
    @Test("Import options default to pureSwift and stopOnError")
    func testDefaultOptions() {
        let options = ImportSQLOptions()
        #expect(options.stopOnError == true)
        #expect(options.useCLIIfAvailable == false)
        #expect(options.wrapInTransaction == false)
    }

    @Test("Custom options retain configured values")
    func testCustomOptions() {
        let options = ImportSQLOptions(stopOnError: false, useCLIIfAvailable: true, wrapInTransaction: true)
        #expect(options.stopOnError == false)
        #expect(options.useCLIIfAvailable == true)
        #expect(options.wrapInTransaction == true)
    }

    @Test("Import options conform to Equatable")
    func testOptionsEquatable() {
        let opt1 = ImportSQLOptions(stopOnError: true, useCLIIfAvailable: false, wrapInTransaction: true)
        let opt2 = ImportSQLOptions(stopOnError: true, useCLIIfAvailable: false, wrapInTransaction: true)
        let opt3 = ImportSQLOptions(stopOnError: false, useCLIIfAvailable: true, wrapInTransaction: false)
        #expect(opt1 == opt2)
        #expect(opt1 != opt3)
    }

    @Test("ImportSQLSheet initializes with initialFileURL and onSuccess callback")
    @MainActor
    func testSheetInitWithOptions() async throws {
        DriverRegistry.register(SQLiteDriver.self)
        let path = NSTemporaryDirectory() + "berrydb-import-test-\(UUID().uuidString).sqlite"
        FileManager.default.createFile(atPath: path, contents: nil)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let session = try await ConnectionManager().open(.sqlite(path: path))

        var called = false
        let dummyURL = URL(fileURLWithPath: "/tmp/dummy.sql")
        let sheet = ImportSQLSheet(session: session, initialFileURL: dummyURL, onDismiss: {}, onSuccess: { called = true })
        sheet.onSuccess?()
        #expect(called == true)
    }
}
