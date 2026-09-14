import BerryCore
import Foundation
import Testing
@testable import BerryUI

@Suite("RestoreDumpSheet Tests")
@MainActor
struct RestoreDumpSheetTests {
    @Test("Restore dump options initialize safely")
    func testRestoreDefaults() {
        let state = RestoreDumpState()
        #expect(state.cleanBeforeRestore == false)
        #expect(state.inspectionResult == nil)
    }

    @Test("Restore dump options custom initialization and equality")
    func testCustomState() {
        let inspection = DumpInspectionResult(
            format: .postgresPlainSQL,
            estimatedSizeBytes: 2048,
            isDirectory: false,
            detectedDialectName: "PostgreSQL"
        )
        let state1 = RestoreDumpState(cleanBeforeRestore: true, inspectionResult: inspection)
        let state2 = RestoreDumpState(cleanBeforeRestore: true, inspectionResult: inspection)
        let state3 = RestoreDumpState(cleanBeforeRestore: false, inspectionResult: nil)

        #expect(state1.cleanBeforeRestore == true)
        #expect(state1.inspectionResult?.format == .postgresPlainSQL)
        #expect(state1 == state2)
        #expect(state1 != state3)
    }

    @Test("RestoreDumpSheet initializes with nil sessions")
    func testSheetInit() {
        let sheet = RestoreDumpSheet(session: nil, dataSourceSession: nil, onDismiss: {})
        #expect(sheet.session == nil)
        #expect(sheet.dataSourceSession == nil)
    }

    @Test("RestoreDumpSheet initializes with onSuccess callback")
    func testSheetInitWithOnSuccess() {
        var called = false
        let sheet = RestoreDumpSheet(session: nil, dataSourceSession: nil, onDismiss: {}, onSuccess: { called = true })
        #expect(sheet.session == nil)
        sheet.onSuccess?()
        #expect(called == true)
    }
}
