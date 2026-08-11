import Foundation

/// Classic hex dump for the cell viewer's binary tab (DL-06):
/// `00000000  48 65 6c 6c 6f ..  |Hello.|`
public enum HexDump {
    public static func format(_ data: Data, bytesPerLine: Int = 16, maxBytes: Int = 64 * 1024) -> String {
        let slice = data.prefix(maxBytes)
        var lines: [String] = []
        lines.reserveCapacity(slice.count / bytesPerLine + 2)

        var offset = 0
        var iterator = slice.makeIterator()
        var chunk: [UInt8] = []
        chunk.reserveCapacity(bytesPerLine)

        func flush() {
            guard !chunk.isEmpty else { return }
            let hex = chunk.map { String(format: "%02x", $0) }.joined(separator: " ")
            let paddedHex = hex.padding(toLength: bytesPerLine * 3 - 1, withPad: " ", startingAt: 0)
            let ascii = chunk.map { byte -> String in
                (0x20...0x7E).contains(byte) ? String(UnicodeScalar(byte)) : "."
            }.joined()
            lines.append(String(format: "%08x  %@  |%@|", offset, paddedHex, ascii))
            offset += chunk.count
            chunk.removeAll(keepingCapacity: true)
        }

        while let byte = iterator.next() {
            chunk.append(byte)
            if chunk.count == bytesPerLine { flush() }
        }
        flush()

        if data.count > maxBytes {
            lines.append("… (\(data.count - maxBytes) more bytes)")
        }
        return lines.joined(separator: "\n")
    }

    /// Pretty-printed JSON when the text parses; nil otherwise.
    public static func prettyJSON(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let pretty = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]
              )
        else { return nil }
        return String(data: pretty, encoding: .utf8)
    }
}
