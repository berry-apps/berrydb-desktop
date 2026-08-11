import BerryDataSourceKit
import Foundation

/// OP_MSG wire framing (MongoDB Wire Protocol, opcode 2013) — the only opcode
/// this driver speaks. Legacy OP_QUERY/OP_REPLY are not implemented: every
/// server new enough to matter (4.0+, well below any realistic BerryDB
/// target) accepts OP_MSG for commands, so there is no fallback path to
/// build (docs/architecture/12 §3 "Trạng thái hiện thực").
///
/// Only "kind 0" (single body document) sections are built when encoding a
/// request — "kind 1" document-sequence sections are a wire-size
/// optimization this driver's modest batch sizes (N3, 500-1000) don't need.
/// Kind-1 sections in a REPLY are still parsed (and skipped) so an
/// unexpected server reply shape doesn't corrupt framing for the rest of the
/// message.
enum MongoOpMsg {
    static let opCode: Int32 = 2013
    private static let headerLength = 16

    enum FramingError: Error, LocalizedError {
        case malformedHeader
        case unexpectedOpCode(Int32)
        case noBodySection

        var errorDescription: String? {
            switch self {
            case .malformedHeader:
                return "Malformed MongoDB wire protocol message header"
            case .unexpectedOpCode(let code):
                return "Unexpected MongoDB wire protocol opCode \(code) (expected OP_MSG/2013)"
            case .noBodySection:
                return "OP_MSG reply had no kind-0 body section"
            }
        }
    }

    struct Header: Sendable, Equatable {
        let messageLength: Int32
        let requestID: Int32
        let responseTo: Int32
        let opCode: Int32
    }

    /// Encodes a full OP_MSG request: header + `flagBits` (always 0, no
    /// checksum/moreToCome) + a single kind-0 section wrapping `body`.
    static func encodeRequest(requestID: Int32, body: BerryDocument) -> Data {
        var payload = Data()
        payload.append(BSON.uint32LE(0)) // flagBits
        payload.append(0x00) // section kind 0
        payload.append(BSON.encode(body))

        var message = Data()
        message.append(BSON.int32LE(Int32(headerLength + payload.count)))
        message.append(BSON.int32LE(requestID))
        message.append(BSON.int32LE(0)) // responseTo — unused for requests
        message.append(BSON.int32LE(opCode))
        message.append(payload)
        return message
    }

    /// Parses just the 16-byte standard message header — callers read this
    /// first over the wire to learn `messageLength`, then read the rest.
    static func decodeHeader(_ bytes: [UInt8]) throws -> Header {
        guard bytes.count >= headerLength else { throw FramingError.malformedHeader }
        var offset = 0
        let messageLength = try BSON.readInt32(bytes, &offset)
        let requestID = try BSON.readInt32(bytes, &offset)
        let responseTo = try BSON.readInt32(bytes, &offset)
        let opCode = try BSON.readInt32(bytes, &offset)
        return Header(messageLength: messageLength, requestID: requestID, responseTo: responseTo, opCode: opCode)
    }

    /// Decodes a FULL OP_MSG message (header included — the transport reads
    /// the 16-byte header, learns `messageLength`, reads the rest, and hands
    /// the concatenation here) into its reply body document (the first
    /// kind-0 section seen).
    static func decodeReply(_ message: [UInt8]) throws -> BerryDocument {
        let header = try decodeHeader(message)
        guard header.opCode == opCode else { throw FramingError.unexpectedOpCode(header.opCode) }

        var offset = headerLength
        let flagBits = try BSON.readUInt32(message, &offset)
        let checksumPresent = (flagBits & 0x1) != 0
        let end = message.count - (checksumPresent ? 4 : 0)

        var body: BerryDocument?
        while offset < end {
            let kind = message[offset]
            offset += 1
            switch kind {
            case 0:
                let doc = try BSON.decodeDocument(message, at: &offset)
                if body == nil { body = doc }
            case 1:
                let sectionStart = offset
                let sectionSize = try BSON.readInt32(message, &offset)
                _ = try BSON.readCString(message, &offset) // identifier — unused, request-only shape
                while offset < sectionStart + Int(sectionSize) {
                    _ = try BSON.decodeDocument(message, at: &offset)
                }
            default:
                // Unknown/malformed section kind — stop parsing defensively
                // rather than walking off into garbage offsets.
                offset = end
            }
        }
        guard let body else { throw FramingError.noBodySection }
        return body
    }
}
