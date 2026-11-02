import BerryCore
import BerryDriverKit
import Foundation

/// Copies only the inspected row; column positions preserve duplicate field names.
struct RowTarget: Identifiable {
    struct Field: Identifiable {
        let id: Int
        let column: ColumnMeta
        let value: BerryValue
    }

    let id = UUID()
    let row: Int
    let fields: [Field]

    @MainActor
    static func from(
        buffer: ResultBuffer,
        row: Int,
        appendedRowCount: Int = 0,
        overlay: ((Int) -> BerryValue?)? = nil
    ) -> RowTarget? {
        guard row >= 0, row < buffer.rowCount + max(0, appendedRowCount),
              !buffer.columns.isEmpty else { return nil }
        let values = row < buffer.rowCount ? buffer.rows[row] : []
        return RowTarget(row: row, fields: buffer.columns.enumerated().map { index, column in
            Field(
                id: index, column: column,
                value: overlay?(index) ?? (index < values.count ? values[index] : .null)
            )
        })
    }
}
