import BerryCore
import BerryDriverKit
import Foundation

/// Copies only the inspected row; column positions preserve duplicate field names.
struct RowTarget {
    struct Field: Identifiable {
        let id: Int
        let column: ColumnMeta
        let value: BerryValue
    }

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

/// Bounds work by UTF-8 bytes, including strings with a single huge combining cluster.
struct RowValuePreview {
    static let byteLimit = 4096
    let text: String
    let isTruncated: Bool

    init(_ value: BerryValue) {
        let fullText: String
        switch value {
        case .null:
            fullText = "NULL"
        case .bytes(let data):
            fullText = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .binary)
        default:
            fullText = value.displayString ?? ""
        }
        let prefix = fullText.utf8.prefix(Self.byteLimit + 1)
        isTruncated = prefix.count > Self.byteLimit
        var bytes = Array(prefix.prefix(Self.byteLimit))
        // Drop an incomplete trailing scalar rather than showing a replacement character.
        while String(bytes: bytes, encoding: .utf8) == nil { bytes.removeLast() }
        text = String(decoding: bytes, as: UTF8.self)
    }
}
