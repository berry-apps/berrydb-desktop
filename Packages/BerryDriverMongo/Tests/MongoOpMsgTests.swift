import BerryDataSourceKit
import Foundation
import Testing

@testable import BerryDriverMongo

@Suite("OP_MSG framing")
struct MongoOpMsgTests {
    @Test func encodeProducesAWellFormedHeader() {
        let body = BerryDocument.object([("ping", .int(1))])
        let message = MongoOpMsg.encodeRequest(requestID: 7, body: body)
        let header = try! MongoOpMsg.decodeHeader([UInt8](message))
        #expect(header.messageLength == Int32(message.count))
        #expect(header.requestID == 7)
        #expect(header.responseTo == 0)
        #expect(header.opCode == MongoOpMsg.opCode)
    }

    @Test func encodeDecodeRoundTripsTheBodyDocument() throws {
        let body = BerryDocument.object([
            ("find", .string("users")),
            ("filter", .object([("age", .int(30))])),
            ("limit", .int(10)),
        ])
        let message = MongoOpMsg.encodeRequest(requestID: 1, body: body)
        let decoded = try MongoOpMsg.decodeReply([UInt8](message))
        #expect(decoded == body)
    }

    @Test func decodeRejectsWrongOpCode() {
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[0] = 16 // messageLength = 16 (little-endian)
        bytes[12] = 99 // bogus opCode
        #expect(throws: MongoOpMsg.FramingError.self) {
            _ = try MongoOpMsg.decodeReply(bytes)
        }
    }

    @Test func decodeRejectsShortHeader() {
        #expect(throws: MongoOpMsg.FramingError.self) {
            _ = try MongoOpMsg.decodeHeader([0, 1, 2])
        }
    }

    @Test func decodeSkipsAKind1DocumentSequenceSection() throws {
        // Hand-build a message with a kind-1 section (identifier "docs" + one
        // document) FOLLOWED by the kind-0 body — exercises the "skip
        // unused section kinds without corrupting the rest of the parse"
 // path (MongoOpMsg).
        var payload = Data()
        payload.append(BSON.uint32LE(0)) // flagBits

        // Kind 1: size(4) + cstring identifier + one document.
        let seqDoc = BSON.encode(.object([("x", .int(1))]))
        var kind1 = Data()
        kind1.append(0x01)
        var kind1Body = Data()
        kind1Body.append(contentsOf: Array("docs".utf8))
        kind1Body.append(0) // cstring terminator
        kind1Body.append(seqDoc)
        let sectionSize = Int32(4 + kind1Body.count)
        kind1.append(BSON.int32LE(sectionSize))
        kind1.append(kind1Body)
        payload.append(kind1)

        // Kind 0: the actual body we expect back.
        let bodyDoc = BerryDocument.object([("ok", .double(1))])
        payload.append(0x00)
        payload.append(BSON.encode(bodyDoc))

        var message = Data()
        message.append(BSON.int32LE(Int32(16 + payload.count)))
        message.append(BSON.int32LE(1))
        message.append(BSON.int32LE(0))
        message.append(BSON.int32LE(MongoOpMsg.opCode))
        message.append(payload)

        let decoded = try MongoOpMsg.decodeReply([UInt8](message))
        #expect(decoded == bodyDoc)
    }
}
