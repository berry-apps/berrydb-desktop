import BerryDriverKit
import Foundation
import Testing

@testable import BerryCore

/// A single statement/proc can return several differently-shaped result
/// sets (e.g. SQL Server's multi-result batches, `EXEC sp_who2; SELECT *
/// FROM sys.tables;`) — each gets its own `.columns` event. Reported
/// crash-risk audit: `rows` kept accumulating across shapes while `columns`
/// only ever reflected the latest, leaving `rows` ragged against
/// `columns.count` — `DataGridView`'s cell renderer guards only
/// `columnIndex < buffer.columns.count` before indexing
/// `buffer.rows[row][columnIndex]`, so a row from a narrower earlier result
/// set crashed with an out-of-range index the moment the grid rendered it.
@Suite("ResultBuffer multi-result-set rows")
@MainActor
struct ResultBufferMultiResultSetTests {
    @Test func aNewDifferentlyShapedColumnsEventDropsThePriorResultSetsRows() async {
        let buffer = ResultBuffer()
        buffer.consume(AsyncThrowingStream { c in
            c.yield(.columns([ColumnMeta(name: "a", declaredType: "int")]))
            c.yield(.rows([[.int(1)], [.int(2)]]))
            c.yield(.columns([
                ColumnMeta(name: "x", declaredType: "int"), ColumnMeta(name: "y", declaredType: "int"),
            ]))
            c.yield(.rows([[.int(3), .int(4)]]))
            c.yield(.complete(QueryStats(rowsAffected: nil, duration: .zero)))
            c.finish()
        })
        await buffer.waitUntilFinished()

        #expect(buffer.columns.map(\.name) == ["x", "y"])
        // Every buffered row must be as wide as `columns` — no leftover
        // single-column rows from the first result set.
        #expect(buffer.rows.allSatisfy { $0.count == buffer.columns.count })
        #expect(buffer.rows == [[.int(3), .int(4)]])
    }

    @Test func aRepeatedIdenticalColumnsEventDoesNotDropAlreadyBufferedRows() async {
        let buffer = ResultBuffer()
        buffer.consume(AsyncThrowingStream { c in
            c.yield(.columns([ColumnMeta(name: "a", declaredType: "int")]))
            c.yield(.rows([[.int(1)]]))
            c.yield(.columns([ColumnMeta(name: "a", declaredType: "int")])) // same shape, e.g. a per-batch repeat
            c.yield(.rows([[.int(2)]]))
            c.yield(.complete(QueryStats(rowsAffected: nil, duration: .zero)))
            c.finish()
        })
        await buffer.waitUntilFinished()

        #expect(buffer.rows == [[.int(1)], [.int(2)]])
    }
}
