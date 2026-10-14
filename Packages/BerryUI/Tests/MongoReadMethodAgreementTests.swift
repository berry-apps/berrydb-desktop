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

    /// A call for each cursor modifier the classifier accepts.
    private static let modifierSamples: [String: String] = [
        "sort": ".sort({a: 1})",
        "limit": ".limit(1)",
    ]

    private static func resolvesToAQuery(_ text: String) throws -> Bool {
        let statement = try #require(try MongoShellParser.parse(text).first)
        guard case .success(.query) = Result(catching: { try MongoShellResolver.resolve(statement) }) else {
            return false
        }
        return true
    }

    /// Every read method with every cursor modifier chained on gets the same
    /// verdict from the classifier as from the resolver, which takes
    /// modifiers only after `find`.
    @Test func everyModifierChainAgreesWithTheResolver() throws {
        for method in ReadOnlyStatement.mongoReadMethods.sorted() {
            guard let base = Self.samples[method] else { continue }
            for modifier in ReadOnlyStatement.mongoCursorMethods.sorted() {
                guard let call = Self.modifierSamples[modifier] else {
                    Issue.record("no sample call for .\(modifier)")
                    continue
                }
                let chain = base + call
                #expect(ReadOnlyStatement.isReadOnlyMongoShell(chain) == (try Self.resolvesToAQuery(chain)), "\(chain)")
            }
        }
        let findChain = "db.c.find({}).sort({a: 1}).limit(1)"
        #expect(ReadOnlyStatement.isReadOnlyMongoShell(findChain))
        #expect(try Self.resolvesToAQuery(findChain))
    }
}
