import Foundation
import Testing
@testable import BerryCredentials

@Suite("Keychain service identifiers")
struct KeychainServiceTests {
    @Test("Secret kinds retain their persisted raw values")
    func secretKindRawValues() {
        #expect(KeychainService.SecretKind.allCases.map(\.rawValue) == [
            "db", "ssh", "sshpp", "esapikey",
        ])
    }

    @Test("Service identifiers retain their lowercase UUID format")
    func serviceIdentifiers() {
        let profileID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let expected: [(KeychainService.SecretKind, String)] = [
            (.database, "db"),
            (.ssh, "ssh"),
            (.sshPassphrase, "sshpp"),
            (.elasticsearchAPIKey, "esapikey"),
        ]

        for (kind, rawValue) in expected {
            #expect(
                KeychainService.service(kind, profileID)
                    == "dev.berrydb.\(rawValue).aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
            )
        }
    }
}
