import BerryDriverKit
import Foundation
import Testing

@testable import BerryCore

/// Seeding columns for empty (0-row) results (docs/ui, network-driver fix:
/// Postgres/MySQL ship no columns when there are no rows).
@Suite("ResultBuffer seed columns")
@MainActor
struct ResultBufferSeedTests {
    @Test func seedsWhenCompleteAndEmpty() async {
        let buffer = ResultBuffer()
        buffer.consume(AsyncThrowingStream { c in
            c.yield(.complete(QueryStats(rowsAffected: nil, duration: .zero)))
            c.finish()
        })
        await buffer.waitUntilFinished()
        buffer.seedColumnsIfEmpty([ColumnMeta(name: "id", declaredType: "int")])
        #expect(buffer.columns.map(\.name) == ["id"])
    }

    @Test func doesNotOverwriteExistingColumns() async {
        let buffer = ResultBuffer()
        buffer.consume(AsyncThrowingStream { c in
            c.yield(.columns([ColumnMeta(name: "name", declaredType: "text")]))
            c.yield(.rows([[.text("a")]]))
            c.yield(.complete(QueryStats(rowsAffected: nil, duration: .zero)))
            c.finish()
        })
        await buffer.waitUntilFinished()
        buffer.seedColumnsIfEmpty([ColumnMeta(name: "id", declaredType: "int")])
        #expect(buffer.columns.map(\.name) == ["name"]) // unchanged — had rows
    }
}
