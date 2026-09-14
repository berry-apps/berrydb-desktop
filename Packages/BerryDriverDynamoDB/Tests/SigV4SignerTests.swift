import Foundation
import Testing

@testable import BerryDriverDynamoDB

/// Byte-correctness of the hand-rolled SigV4 signer
/// against AWS's own published test vectors — the `get-vanilla` /
/// `post-vanilla` cases from the canonical `aws4_testsuite`
/// (`AKIDEXAMPLE`/`wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY`, region
/// `us-east-1`, service `service`, fixed date `2015-08-30T12:36:00Z`).
/// Cross-checked against two independent upstream copies (botocore and
/// aws-sdk-rust's `aws-signing-test-suite`, including its `context.json` —
/// both agree byte-for-byte) before hardcoding here.
@Suite("SigV4Signer — byte-correctness against AWS test vectors")
struct SigV4SignerTests {
    private static let credentials = SigV4Signer.Credentials(
        accessKeyID: "AKIDEXAMPLE",
        secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
    )

    /// 2015-08-30T12:36:00Z, exactly.
    private static let testDate: Date = {
        var components = DateComponents()
        components.year = 2015; components.month = 8; components.day = 30
        components.hour = 12; components.minute = 36; components.second = 0
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components)!
    }()

    @Test func getVanillaMatchesPublishedSignature() {
        var request = URLRequest(url: URL(string: "https://example.amazonaws.com/")!)
        request.httpMethod = "GET"
        SigV4Signer.sign(
            &request, body: Data(), credentials: Self.credentials,
            region: "us-east-1", service: "service", date: Self.testDate
        )
        #expect(request.value(forHTTPHeaderField: "X-Amz-Date") == "20150830T123600Z")
        #expect(request.value(forHTTPHeaderField: "Authorization") == """
        AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, \
        SignedHeaders=host;x-amz-date, \
        Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31
        """)
    }

    @Test func postVanillaMatchesPublishedSignature() {
        var request = URLRequest(url: URL(string: "https://example.amazonaws.com/")!)
        request.httpMethod = "POST"
        SigV4Signer.sign(
            &request, body: Data(), credentials: Self.credentials,
            region: "us-east-1", service: "service", date: Self.testDate
        )
        #expect(request.value(forHTTPHeaderField: "Authorization") == """
        AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, \
        SignedHeaders=host;x-amz-date, \
        Signature=5da7c1a2acd57cee7505fc6676e4e544621c30862966e37dddb68e92efbe5d6b
        """)
    }

    // MARK: Internal building blocks (isolated so a future regression points
    // straight at canonical-request vs. string-to-sign vs. key-derivation).

    @Test func emptyBodyHashesToTheKnownSHA256OfEmptyString() {
        #expect(SigV4Signer.sha256Hex(Data())
            == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test func canonicalURIDefaultsToSlashAndEncodesSegments() {
        #expect(SigV4Signer.canonicalURI(URL(string: "https://example.amazonaws.com/")!) == "/")
        #expect(SigV4Signer.canonicalURI(URL(string: "https://example.amazonaws.com")!) == "/")
        #expect(SigV4Signer.canonicalURI(URL(string: "https://example.amazonaws.com/a%20b/c")!) == "/a%20b/c")
    }

    @Test func canonicalQueryIsEmptyWhenThereIsNoQueryString() {
        #expect(SigV4Signer.canonicalQuery(URL(string: "https://example.amazonaws.com/")!) == "")
    }

    @Test func canonicalQuerySortsByKeyThenEncodes() {
        let url = URL(string: "https://example.amazonaws.com/?b=2&a=1&a=0")!
        // Sorted by (key, value): a=0, a=1, b=2.
        #expect(SigV4Signer.canonicalQuery(url) == "a=0&a=1&b=2")
    }

    // MARK: Real-world signing shape (Content-Type + X-Amz-Target signed too)

    @Test func signsEveryHeaderAlreadyOnTheRequestIncludingContentTypeAndTarget() throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8000/")!)
        request.httpMethod = "POST"
        request.setValue("application/x-amz-json-1.0", forHTTPHeaderField: "Content-Type")
        request.setValue("DynamoDB_20120810.ListTables", forHTTPHeaderField: "X-Amz-Target")
        SigV4Signer.sign(
            &request, body: Data("{}".utf8), credentials: Self.credentials,
            region: "us-east-1", service: "dynamodb", date: Self.testDate
        )
        let authz = try #require(request.value(forHTTPHeaderField: "Authorization"))
        #expect(authz.contains("SignedHeaders=content-type;host;x-amz-date;x-amz-target"))
        #expect(authz.contains("Credential=AKIDEXAMPLE/20150830/us-east-1/dynamodb/aws4_request"))
    }

    @Test func signsSessionTokenWhenPresent() throws {
        var request = URLRequest(url: URL(string: "https://dynamodb.us-east-1.amazonaws.com/")!)
        request.httpMethod = "POST"
        let credentials = SigV4Signer.Credentials(
            accessKeyID: "AKIDEXAMPLE", secretAccessKey: "secret", sessionToken: "the-session-token"
        )
        SigV4Signer.sign(
            &request, body: Data(), credentials: credentials,
            region: "us-east-1", service: "dynamodb", date: Self.testDate
        )
        #expect(request.value(forHTTPHeaderField: "X-Amz-Security-Token") == "the-session-token")
        let authz = try #require(request.value(forHTTPHeaderField: "Authorization"))
        #expect(authz.contains("x-amz-security-token"))
    }

    /// Non-default port (dynamodb-local) — the signed `host` value must
    /// include the port, matching what URLSession puts on the wire.
    @Test func includesPortInHostHeaderForNonDefaultPort() {
        var requestWithPort = URLRequest(url: URL(string: "http://127.0.0.1:18000/")!)
        requestWithPort.httpMethod = "POST"
        var requestNoPort = URLRequest(url: URL(string: "http://127.0.0.1:28000/")!)
        requestNoPort.httpMethod = "POST"

        SigV4Signer.sign(
            &requestWithPort, body: Data(), credentials: Self.credentials,
            region: "us-east-1", service: "dynamodb", date: Self.testDate
        )
        SigV4Signer.sign(
            &requestNoPort, body: Data(), credentials: Self.credentials,
            region: "us-east-1", service: "dynamodb", date: Self.testDate
        )
        // Different ports must produce different signatures (the host header differs).
        #expect(requestWithPort.value(forHTTPHeaderField: "Authorization")
            != requestNoPort.value(forHTTPHeaderField: "Authorization"))
    }
}
