import Foundation
import Testing

@testable import BerryDriverMongo

/// Verified against RFC 7677's own worked example, fetched and grepped
/// directly from https://www.rfc-editor.org/rfc/rfc7677.txt (not transcribed
/// from memory) — username 'user', password 'pencil'. Same "verify against a
/// real, independently-fetched vector" discipline `SigV4SignerTests` used for
/// AWS SigV4.
@Suite("SCRAM-SHA-256 — RFC 7677 section 3 worked example")
struct SCRAMTests {
    // The server appends its own random suffix to the client nonce to form
 // the combined nonce — RFC 7677's example combined nonce is:
    //   rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0
    private let clientNonce = "rOprNGfwEbeRWgbNEkqO"
    private let combinedNonce = "rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0"
    private let serverFirstMessage =
        "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"
    private let expectedClientFinalMessage =
        "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,"
            + "p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ="
    private let serverFinalMessage = "v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4="

    @Test func clientFirstMessageMatchesRFC() {
        let first = SCRAM.clientFirst(username: "user", nonce: clientNonce)
        #expect(first.message == "n,,n=user,r=rOprNGfwEbeRWgbNEkqO")
        #expect(first.messageBare == "n=user,r=rOprNGfwEbeRWgbNEkqO")
    }

    @Test func serverFirstMessageParsesToRFCFields() throws {
        let parsed = try SCRAM.parseServerFirst(serverFirstMessage)
        #expect(parsed.nonce == combinedNonce)
        #expect(parsed.salt.base64EncodedString() == "W22ZaJ0SNY7soEsUEjb6gQ==")
        #expect(parsed.iterations == 4096)
    }

    @Test func clientFinalMessageAndServerSignatureMatchRFC() throws {
        let clientFirst = SCRAM.clientFirst(username: "user", nonce: clientNonce)
        let serverFirst = try SCRAM.parseServerFirst(serverFirstMessage)
        let clientFinal = try SCRAM.clientFinal(password: "pencil", clientFirst: clientFirst, serverFirst: serverFirst)

        #expect(clientFinal.message == expectedClientFinalMessage)
        #expect(clientFinal.serverSignatureExpected.base64EncodedString() == "6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=")

        // The full conversation: verifying the RFC's own server-final message
        // against what we independently computed must succeed.
        try SCRAM.verifyServerFinal(serverFinalMessage, expected: clientFinal.serverSignatureExpected)
    }

    @Test func verifyServerFinalRejectsATamperedSignature() throws {
        let clientFirst = SCRAM.clientFirst(username: "user", nonce: clientNonce)
        let serverFirst = try SCRAM.parseServerFirst(serverFirstMessage)
        let clientFinal = try SCRAM.clientFinal(password: "pencil", clientFirst: clientFirst, serverFirst: serverFirst)

        #expect(throws: SCRAM.SCRAMError.self) {
            try SCRAM.verifyServerFinal("v=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", expected: clientFinal.serverSignatureExpected)
        }
    }

    @Test func clientFinalRejectsANonceThatDoesNotExtendTheClientNonce() throws {
        let clientFirst = SCRAM.clientFirst(username: "user", nonce: clientNonce)
        let tamperedServerFirst = try SCRAM.parseServerFirst("r=totally-different-nonce,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096")
        #expect(throws: SCRAM.SCRAMError.self) {
            _ = try SCRAM.clientFinal(password: "pencil", clientFirst: clientFirst, serverFirst: tamperedServerFirst)
        }
    }

    @Test func generateNonceProducesDistinctBase64Values() {
        let a = SCRAM.generateNonce()
        let b = SCRAM.generateNonce()
        #expect(a != b)
        #expect(Data(base64Encoded: a) != nil)
    }
}
