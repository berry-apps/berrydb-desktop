import BerryDataSourceKit
import Testing

@testable import BerryAI

/// The panel runs a Mongo statement the AI classifier auto-approved through
/// the shell parser and resolver. Every method the classifier treats as a
/// read must resolve to a query there, or an auto-approved call fails.
@Suite("Mongo read methods agree with the shell resolver")
struct MongoReadMethodAgreementTests {
    private static let samples: [String: String] = [
        "find": "db.c.find({})",
        "findOne": "db.c.findOne({})",
        "aggregate": "db.c.aggregate([])",
        "countDocuments": "db.c.countDocuments({})",
        "estimatedDocumentCount": "db.c.estimatedDocumentCount()",
        "distinct": #"db.c.distinct("a")"#,
    ]

    @Test func everyClassifiedReadResolvesToAQuery() throws {
        for method in ReadOnlyStatement.mongoReadMethods.sorted() {
            guard let sample = Self.samples[method] else {
                Issue.record("no sample call for \(method)")
                continue
            }
            #expect(ReadOnlyStatement.isReadOnlyMongoShell(sample), "\(method)")
            let statement = try #require(try MongoShellParser.parse(sample).first)
            let resolved = Result { try MongoShellResolver.resolve(statement) }
            guard case .success(.query) = resolved else {
                Issue.record("\(method) does not resolve to a query: \(resolved)")
                continue
            }
        }
    }
}
