import BerryDriverKit
import Foundation
import Testing

@testable import BerryUI

/// URI-paste convenience for the Mongo connection sheet (task 3,
/// ``) — pure parser, no SwiftUI/Docker involved.
@Suite("Mongo connection URI parsing")
struct MongoConnectionURITests {
    @Test func userPassHostPortDatabase() {
        let result = MongoConnectionURI.parse("mongodb://alice:s3cret@db.example.com:27018/mydb")
        let fields = try! result.get()
        #expect(fields.host == "db.example.com")
        #expect(fields.port == 27018)
        #expect(fields.username == "alice")
        #expect(fields.password == "s3cret")
        #expect(fields.database == "mydb")
        #expect(fields.tlsMode == nil)
    }

    @Test func noAuthDefaultsPort() {
        let fields = try! MongoConnectionURI.parse("mongodb://localhost/mydb").get()
        #expect(fields.host == "localhost")
        #expect(fields.port == 27017)
        #expect(fields.username == nil)
        #expect(fields.password == nil)
        #expect(fields.database == "mydb")
    }

    @Test func hostOnlyNoDatabaseNoTrailingSlash() {
        let fields = try! MongoConnectionURI.parse("mongodb://localhost").get()
        #expect(fields.host == "localhost")
        #expect(fields.port == 27017)
        #expect(fields.database == nil)
    }

    @Test func hostOnlyWithTrailingSlashAndNoDatabase() {
        let fields = try! MongoConnectionURI.parse("mongodb://localhost/").get()
        #expect(fields.host == "localhost")
        #expect(fields.database == nil)
    }

    @Test func customPortWithoutAuth() {
        let fields = try! MongoConnectionURI.parse("mongodb://10.0.0.5:27000").get()
        #expect(fields.host == "10.0.0.5")
        #expect(fields.port == 27000)
    }

    @Test func percentEncodedCredentialsAreDecoded() {
        // "p@ss:word" -> "p%40ss%3Aword"
        let fields = try! MongoConnectionURI.parse("mongodb://us%20er:p%40ss%3Aword@host/db").get()
        #expect(fields.username == "us er")
        #expect(fields.password == "p@ss:word")
    }

    @Test func plusSignInCredentialIsNotDecodedAsSpace() {
        // RFC 3986 percent-decoding, not form/application-x-www-form-urlencoded:
        // a literal '+' must survive untouched.
        let fields = try! MongoConnectionURI.parse("mongodb://user:pa+ss@host/db").get()
        #expect(fields.password == "pa+ss")
    }

    @Test func authSourceQueryParamPreferredOverPathDatabase() {
        // ConnectionConfig only has one `database` field, used as both the
 // SCRAM authSource and the working database
        // point 2) — authSource wins because that's what auth actually uses.
        let fields = try! MongoConnectionURI.parse("mongodb://user:pass@host/appdb?authSource=admin").get()
        #expect(fields.database == "admin")
    }

    @Test func pathDatabaseUsedWhenNoAuthSource() {
        let fields = try! MongoConnectionURI.parse("mongodb://host/appdb?retryWrites=true").get()
        #expect(fields.database == "appdb")
    }

    @Test func tlsTrueSetsRequireMode() {
        let fields = try! MongoConnectionURI.parse("mongodb://host/db?tls=true").get()
        #expect(fields.tlsMode == .require)
    }

    @Test func sslTrueSetsRequireMode() {
        let fields = try! MongoConnectionURI.parse("mongodb://host/db?ssl=true").get()
        #expect(fields.tlsMode == .require)
    }

    @Test func noTLSParamLeavesTLSModeNil() {
        let fields = try! MongoConnectionURI.parse("mongodb://host/db?retryWrites=true").get()
        #expect(fields.tlsMode == nil)
    }

    @Test func srvSchemeIsRejectedExplicitly() {
        let result = MongoConnectionURI.parse("mongodb+srv://user:pass@cluster0.example.mongodb.net/mydb")
        #expect(result == .failure(.srvNotSupported))
    }

    @Test func multiHostBecomesHostPlusAdditionalHosts() {
 // Replica set support (v1) — the first host
        // becomes host/port, the rest become normalized "host:port" additionalHosts.
        let fields = try! MongoConnectionURI.parse("mongodb://host1:27017,host2:27018,host3/mydb").get()
        #expect(fields.host == "host1")
        #expect(fields.port == 27017)
        #expect(fields.additionalHosts == ["host2:27018", "host3:27017"])
        #expect(fields.database == "mydb")
    }

    @Test func replicaSetQueryParamIsParsed() {
        let fields = try! MongoConnectionURI.parse("mongodb://host1:27017,host2:27017/mydb?replicaSet=rs0").get()
        #expect(fields.replicaSet == "rs0")
        #expect(fields.additionalHosts == ["host2:27017"])
    }

    @Test func singleHostHasNoAdditionalHosts() {
        let fields = try! MongoConnectionURI.parse("mongodb://localhost:27017/mydb").get()
        #expect(fields.additionalHosts.isEmpty)
        #expect(fields.replicaSet == nil)
    }

    @Test func wrongSchemeIsRejected() {
        let result = MongoConnectionURI.parse("postgres://user:pass@host:5432/db")
        #expect(result == .failure(.notMongoDBScheme))
    }

    @Test func garbageInputIsRejected() {
        let result = MongoConnectionURI.parse("not a uri at all")
        #expect(result == .failure(.notMongoDBScheme))
    }

    @Test func emptyAfterSchemeIsMissingHost() {
        let result = MongoConnectionURI.parse("mongodb://")
        #expect(result == .failure(.missingHost))
    }

    @Test func whitespaceIsTrimmed() {
        let fields = try! MongoConnectionURI.parse("  mongodb://localhost:27017/db  \n").get()
        #expect(fields.host == "localhost")
        #expect(fields.port == 27017)
    }
}
