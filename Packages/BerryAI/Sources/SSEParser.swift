import Foundation

/// A raw Server-Sent Event: its `event:` name and joined `data:` payload.
public struct SSERawEvent: Equatable, Sendable {
    public let event: String
    public let data: String
}

/// Incremental SSE parser (docs/architecture/09 §3). Feed it text chunks as
/// they arrive; it buffers partial lines and emits a raw event on each blank
/// line. Heartbeat comment lines (starting with `:`) are ignored.
public final class SSEParser {
    private var buffer = ""
    private var currentEvent = "message"
    private var currentData: [String] = []

    public init() {}

    public func feed(_ chunk: String) -> [SSERawEvent] {
        buffer += chunk
        var out: [SSERawEvent] = []
        let parts = buffer.components(separatedBy: "\n")
        // Everything but the last element is a complete line; the last may be
        // a partial line still being received.
        buffer = parts.last ?? ""

        for rawLine in parts.dropLast() {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if line.isEmpty {
                if !currentData.isEmpty {
                    out.append(SSERawEvent(event: currentEvent, data: currentData.joined(separator: "\n")))
                }
                currentEvent = "message"
                currentData = []
            } else if line.hasPrefix(":") {
                continue // heartbeat / comment
            } else if let colon = line.firstIndex(of: ":") {
                let field = String(line[line.startIndex..<colon])
                var value = String(line[line.index(after: colon)...])
                if value.hasPrefix(" ") { value.removeFirst() }
                switch field {
                case "event": currentEvent = value
                case "data": currentData.append(value)
                default: break
                }
            }
        }
        return out
    }
}

/// Turns a raw byte stream (e.g. `URLSession.AsyncBytes`) into SSE events.
///
/// We must NOT use `AsyncBytes.lines`: `AsyncLineSequence` drops empty lines,
/// and the blank line is exactly what delimits one SSE event from the next —
/// so the parser would never dispatch and no event would reach the client (the
/// empty-bubble bug). Iterating raw bytes preserves the `\n\n` delimiters. A
/// `\n` byte (0x0A) is never a UTF-8 continuation byte, so decoding each line
/// at a newline boundary is always valid UTF-8.
public func sseEvents<S: AsyncSequence & Sendable>(from bytes: S) -> AsyncThrowingStream<SSERawEvent, Error>
where S.Element == UInt8 {
    AsyncThrowingStream { continuation in
        let task = Task {
            let parser = SSEParser()
            var pending: [UInt8] = []
            do {
                for try await byte in bytes {
                    pending.append(byte)
                    guard byte == 0x0A else { continue }
                    for event in parser.feed(String(decoding: pending, as: UTF8.self)) {
                        continuation.yield(event)
                    }
                    pending.removeAll(keepingCapacity: true)
                }
                if !pending.isEmpty {
                    for event in parser.feed(String(decoding: pending, as: UTF8.self)) {
                        continuation.yield(event)
                    }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}
