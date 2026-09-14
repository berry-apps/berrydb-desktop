import Foundation

public struct SQLStreamStatement: Sendable, Equatable {
    public let sql: String
    public let lineNumber: Int
    public let byteOffset: Int

    public init(sql: String, lineNumber: Int, byteOffset: Int) {
        self.sql = sql
        self.lineNumber = lineNumber
        self.byteOffset = byteOffset
    }
}

public enum SQLStreamError: Error, LocalizedError, Sendable, Equatable {
    case invalidEncoding(byteOffset: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidEncoding(let byteOffset):
            return "Invalid UTF-8 encoding encountered at byte offset \(byteOffset)"
        }
    }
}

public enum SQLStreamReader {
    public static func statements(
        from fileURL: URL,
        chunkSize: Int = 65536
    ) -> AsyncThrowingStream<SQLStreamStatement, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    let handle = try FileHandle(forReadingFrom: fileURL)
                    defer { try? handle.close() }

                    var buffer = Data()
                    var lineNumber = 1
                    var currentStatementStartLine = 1
                    var globalByteOffset = 0
                    var statementStartOffset = 0
                    var isAtStatementStart = true

                    enum ScanState {
                        case normal
                        case singleQuote
                        case doubleQuote
                        case backtick
                        case lineComment
                        case blockComment
                        case dollarQuote(tag: String)
                    }

                    var state: ScanState = .normal
                    var currentStatementScalars: [UnicodeScalar] = []

                    func flushStatement() {
                        let str = String(String.UnicodeScalarView(currentStatementScalars))
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if !str.isEmpty {
                            continuation.yield(SQLStreamStatement(
                                sql: str,
                                lineNumber: currentStatementStartLine,
                                byteOffset: statementStartOffset
                            ))
                        }
                        currentStatementScalars.removeAll(keepingCapacity: true)
                        isAtStatementStart = true
                    }

                    var isEOF = false

                    while true {
                        try Task.checkCancellation()

                        if !isEOF {
                            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
                            if chunk.isEmpty {
                                isEOF = true
                            } else {
                                buffer.append(chunk)
                            }
                        }

                        if buffer.isEmpty && isEOF {
                            break
                        }

                        var chunkString: String? = nil

                        if let decoded = String(data: buffer, encoding: .utf8) {
                            chunkString = decoded
                        } else if !isEOF {
                            // Check if trailing 1, 2, or 3 bytes are an incomplete UTF-8 sequence
                            for trailing in 1...min(3, buffer.count) {
                                let prefixData = buffer.prefix(buffer.count - trailing)
                                if let decoded = String(data: prefixData, encoding: .utf8) {
                                    chunkString = decoded
                                    break
                                }
                            }
                        }

                        guard let validChunkString = chunkString else {
                            throw SQLStreamError.invalidEncoding(byteOffset: globalByteOffset)
                        }

                        let scalars = Array(validChunkString.unicodeScalars)
                        var i = 0
                        var processedBytes = 0
                        var shouldBreakForNextChunk = false

                        while i < scalars.count {
                            let c = scalars[i]

                            // Track statement start position at first non-whitespace character
                            if isAtStatementStart {
                                if CharacterSet.whitespacesAndNewlines.contains(c) {
                                    if c == "\n" { lineNumber += 1 }
                                    let charBytes = c.utf8.count
                                    globalByteOffset += charBytes
                                    processedBytes += charBytes
                                    i += 1
                                    continue
                                }
                                if c == ";" {
                                    // Stray / redundant semicolon between statements
                                    let charBytes = c.utf8.count
                                    globalByteOffset += charBytes
                                    processedBytes += charBytes
                                    i += 1
                                    continue
                                }
                                currentStatementStartLine = lineNumber
                                statementStartOffset = globalByteOffset
                                isAtStatementStart = false
                            }

                            switch state {
                            case .normal:
                                if c == "'" {
                                    state = .singleQuote
                                    currentStatementScalars.append(c)
                                    let charBytes = c.utf8.count
                                    globalByteOffset += charBytes
                                    processedBytes += charBytes
                                    i += 1
                                } else if c == "\"" {
                                    state = .doubleQuote
                                    currentStatementScalars.append(c)
                                    let charBytes = c.utf8.count
                                    globalByteOffset += charBytes
                                    processedBytes += charBytes
                                    i += 1
                                } else if c == "`" {
                                    state = .backtick
                                    currentStatementScalars.append(c)
                                    let charBytes = c.utf8.count
                                    globalByteOffset += charBytes
                                    processedBytes += charBytes
                                    i += 1
                                } else if c == "-" {
                                    if i + 1 < scalars.count {
                                        if scalars[i + 1] == "-" {
                                            state = .lineComment
                                            currentStatementScalars.append(c)
                                            currentStatementScalars.append(scalars[i + 1])
                                            let twoBytes = c.utf8.count + scalars[i + 1].utf8.count
                                            globalByteOffset += twoBytes
                                            processedBytes += twoBytes
                                            i += 2
                                        } else {
                                            currentStatementScalars.append(c)
                                            let charBytes = c.utf8.count
                                            globalByteOffset += charBytes
                                            processedBytes += charBytes
                                            i += 1
                                        }
                                    } else {
                                        if !isEOF {
                                            shouldBreakForNextChunk = true
                                            break
                                        } else {
                                            currentStatementScalars.append(c)
                                            let charBytes = c.utf8.count
                                            globalByteOffset += charBytes
                                            processedBytes += charBytes
                                            i += 1
                                        }
                                    }
                                } else if c == "/" {
                                    if i + 1 < scalars.count {
                                        if scalars[i + 1] == "*" {
                                            state = .blockComment
                                            currentStatementScalars.append(c)
                                            currentStatementScalars.append(scalars[i + 1])
                                            let twoBytes = c.utf8.count + scalars[i + 1].utf8.count
                                            globalByteOffset += twoBytes
                                            processedBytes += twoBytes
                                            i += 2
                                        } else {
                                            currentStatementScalars.append(c)
                                            let charBytes = c.utf8.count
                                            globalByteOffset += charBytes
                                            processedBytes += charBytes
                                            i += 1
                                        }
                                    } else {
                                        if !isEOF {
                                            shouldBreakForNextChunk = true
                                            break
                                        } else {
                                            currentStatementScalars.append(c)
                                            let charBytes = c.utf8.count
                                            globalByteOffset += charBytes
                                            processedBytes += charBytes
                                            i += 1
                                        }
                                    }
                                } else if c == "$" {
                                    var j = i + 1
                                    while j < scalars.count && (scalars[j] == "_" || CharacterSet.alphanumerics.contains(scalars[j])) {
                                        j += 1
                                    }
                                    if j < scalars.count {
                                        if scalars[j] == "$" {
                                            let tag = String(String.UnicodeScalarView(scalars[i...j]))
                                            state = .dollarQuote(tag: tag)
                                            var tagBytes = 0
                                            for k in i...j {
                                                currentStatementScalars.append(scalars[k])
                                                tagBytes += scalars[k].utf8.count
                                            }
                                            globalByteOffset += tagBytes
                                            processedBytes += tagBytes
                                            i = j + 1
                                        } else {
                                            currentStatementScalars.append(c)
                                            let charBytes = c.utf8.count
                                            globalByteOffset += charBytes
                                            processedBytes += charBytes
                                            i += 1
                                        }
                                    } else {
                                        if !isEOF {
                                            shouldBreakForNextChunk = true
                                            break
                                        } else {
                                            currentStatementScalars.append(c)
                                            let charBytes = c.utf8.count
                                            globalByteOffset += charBytes
                                            processedBytes += charBytes
                                            i += 1
                                        }
                                    }
                                } else if c == ";" {
                                    let charBytes = c.utf8.count
                                    globalByteOffset += charBytes
                                    processedBytes += charBytes
                                    i += 1
                                    flushStatement()
                                } else {
                                    if c == "\n" { lineNumber += 1 }
                                    currentStatementScalars.append(c)
                                    let charBytes = c.utf8.count
                                    globalByteOffset += charBytes
                                    processedBytes += charBytes
                                    i += 1
                                }

                            case .singleQuote:
                                if c == "\\" {
                                    if i + 1 < scalars.count {
                                        currentStatementScalars.append(c)
                                        currentStatementScalars.append(scalars[i + 1])
                                        if scalars[i + 1] == "\n" { lineNumber += 1 }
                                        let twoBytes = c.utf8.count + scalars[i + 1].utf8.count
                                        globalByteOffset += twoBytes
                                        processedBytes += twoBytes
                                        i += 2
                                    } else {
                                        if !isEOF {
                                            shouldBreakForNextChunk = true
                                            break
                                        } else {
                                            currentStatementScalars.append(c)
                                            let charBytes = c.utf8.count
                                            globalByteOffset += charBytes
                                            processedBytes += charBytes
                                            i += 1
                                        }
                                    }
                                } else if c == "'" {
                                    if i + 1 < scalars.count {
                                        if scalars[i + 1] == "'" {
                                            currentStatementScalars.append(c)
                                            currentStatementScalars.append(scalars[i + 1])
                                            let twoBytes = c.utf8.count + scalars[i + 1].utf8.count
                                            globalByteOffset += twoBytes
                                            processedBytes += twoBytes
                                            i += 2
                                        } else {
                                            currentStatementScalars.append(c)
                                            let charBytes = c.utf8.count
                                            globalByteOffset += charBytes
                                            processedBytes += charBytes
                                            i += 1
                                            state = .normal
                                        }
                                    } else {
                                        if !isEOF {
                                            shouldBreakForNextChunk = true
                                            break
                                        } else {
                                            currentStatementScalars.append(c)
                                            let charBytes = c.utf8.count
                                            globalByteOffset += charBytes
                                            processedBytes += charBytes
                                            i += 1
                                            state = .normal
                                        }
                                    }
                                } else {
                                    if c == "\n" { lineNumber += 1 }
                                    currentStatementScalars.append(c)
                                    let charBytes = c.utf8.count
                                    globalByteOffset += charBytes
                                    processedBytes += charBytes
                                    i += 1
                                }

                            case .doubleQuote:
                                if c == "\n" { lineNumber += 1 }
                                currentStatementScalars.append(c)
                                let charBytes = c.utf8.count
                                globalByteOffset += charBytes
                                processedBytes += charBytes
                                i += 1
                                if c == "\"" { state = .normal }

                            case .backtick:
                                if c == "\n" { lineNumber += 1 }
                                currentStatementScalars.append(c)
                                let charBytes = c.utf8.count
                                globalByteOffset += charBytes
                                processedBytes += charBytes
                                i += 1
                                if c == "`" { state = .normal }

                            case .lineComment:
                                if c == "\n" { lineNumber += 1 }
                                currentStatementScalars.append(c)
                                let charBytes = c.utf8.count
                                globalByteOffset += charBytes
                                processedBytes += charBytes
                                i += 1
                                if c == "\n" { state = .normal }

                            case .blockComment:
                                if c == "*" {
                                    if i + 1 < scalars.count {
                                        if scalars[i + 1] == "/" {
                                            currentStatementScalars.append(c)
                                            currentStatementScalars.append(scalars[i + 1])
                                            let twoBytes = c.utf8.count + scalars[i + 1].utf8.count
                                            globalByteOffset += twoBytes
                                            processedBytes += twoBytes
                                            i += 2
                                            state = .normal
                                        } else {
                                            currentStatementScalars.append(c)
                                            let charBytes = c.utf8.count
                                            globalByteOffset += charBytes
                                            processedBytes += charBytes
                                            i += 1
                                        }
                                    } else {
                                        if !isEOF {
                                            shouldBreakForNextChunk = true
                                            break
                                        } else {
                                            currentStatementScalars.append(c)
                                            let charBytes = c.utf8.count
                                            globalByteOffset += charBytes
                                            processedBytes += charBytes
                                            i += 1
                                        }
                                    }
                                } else {
                                    if c == "\n" { lineNumber += 1 }
                                    currentStatementScalars.append(c)
                                    let charBytes = c.utf8.count
                                    globalByteOffset += charBytes
                                    processedBytes += charBytes
                                    i += 1
                                }

                            case .dollarQuote(let tag):
                                if c == "\n" { lineNumber += 1 }
                                currentStatementScalars.append(c)
                                let charBytes = c.utf8.count
                                globalByteOffset += charBytes
                                processedBytes += charBytes
                                i += 1
                                if c == "$" {
                                    let tagScalars = Array(tag.unicodeScalars)
                                    let tagLen = tagScalars.count
                                    if currentStatementScalars.count >= tagLen {
                                        let slice = Array(currentStatementScalars.suffix(tagLen))
                                        if slice == tagScalars {
                                            state = .normal
                                        }
                                    }
                                }
                            }

                            if shouldBreakForNextChunk {
                                break
                            }
                        }

                        if processedBytes > 0 {
                            buffer.removeSubrange(0..<processedBytes)
                        }
                    }
                    flushStatement()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}
