import Testing
@testable import BerryCore

@Suite("MongoShellBuiltins")
struct MongoShellBuiltinsTests {
    @Test func everyMethodSignatureStartsWithItsOwnName() {
        for method in MongoShellBuiltins.methods {
            #expect(method.signature.hasPrefix(method.name))
        }
    }

    @Test func methodNamesAreUnique() {
        let names = MongoShellBuiltins.methods.map(\.name)
        #expect(Set(names).count == names.count)
    }

    @Test func findSignatureMatchesItsRealParameters() {
        let find = MongoShellBuiltins.methods.first { $0.name == "find" }
        #expect(find?.signature == "find(query, projection)")
    }

    @Test func insertOneSignatureMatchesItsRealParameters() {
        let insertOne = MongoShellBuiltins.methods.first { $0.name == "insertOne" }
        #expect(insertOne?.signature == "insertOne(document)")
    }
}
