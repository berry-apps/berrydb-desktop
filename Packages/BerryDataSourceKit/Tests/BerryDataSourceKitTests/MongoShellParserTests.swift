// Packages/BerryDataSourceKit/Tests/MongoShellParserTests.swift
import Testing
@testable import BerryDataSourceKit

@Suite("MongoShellParser")
struct MongoShellParserTests {
    @Test func parsesASimpleFindCall() throws {
        let statements = try MongoShellParser.parse(#"db.users.find({"active": true});"#)
        #expect(statements.count == 1)
        #expect(statements[0].collection == "users")
        #expect(statements[0].calls == [
            MongoShellCall(method: "find", arguments: [.object([("active", .bool(true))])]),
        ])
    }

    @Test func parsesChainedSortAndLimit() throws {
        let statements = try MongoShellParser.parse(
            #"db.users.find({ age: { $gt: 25 } }, { _id: 0 }).sort({ age: -1 }).limit(10);"#
        )
        #expect(statements.count == 1)
        #expect(statements[0].calls.map(\.method) == ["find", "sort", "limit"])
        #expect(statements[0].calls[2].arguments == [.int(10)])
    }

    @Test func parsesMultipleSemicolonSeparatedStatements() throws {
        let script = #"""
        db.users.insertOne({ name: "A" });
        db.users.deleteOne({ name: "A" });
        """#
        let statements = try MongoShellParser.parse(script)
        #expect(statements.count == 2)
        #expect(statements[0].calls[0].method == "insertOne")
        #expect(statements[1].calls[0].method == "deleteOne")
    }

    @Test func parsesTheFullFeedbackExample() throws {
        let script = #"""
        db.users.insertOne({
          name: "Nguyen Van A",
          email: "a@example.com",
          age: 28,
          role: "admin",
          skills: ["Rust", "MongoDB", "AI"]
        });

        db.users.find(
          { age: { $gt: 25 } },
          { _id: 0, name: 1, email: 1, age: 1, role: 1 }
        ).sort({ age: -1 }).limit(10);

        db.users.updateOne(
          { email: "a@example.com" },
          { $set: { age: 29 }, $push: { skills: "Graph Database" } }
        );

        db.users.deleteOne({ email: "a@example.com" });

        db.users.aggregate([
          { $group: { _id: "$role", total: { $sum: 1 }, avgAge: { $avg: "$age" } } },
          { $sort: { total: -1 } }
        ]);
        """#
        let statements = try MongoShellParser.parse(script)
        #expect(statements.count == 5)
        #expect(statements.map { $0.calls[0].method } == [
            "insertOne", "find", "updateOne", "deleteOne", "aggregate",
        ])
        #expect(statements[1].calls.map(\.method) == ["find", "sort", "limit"])
        guard case .array(let stages) = statements[4].calls[0].arguments[0] else {
            Issue.record("expected aggregate's argument to be an array")
            return
        }
        #expect(stages.count == 2)
    }

    @Test func throwsOnMissingDbPrefix() {
        #expect(throws: MongoShellParseError.self) {
            try MongoShellParser.parse("users.find({});")
        }
    }

    @Test func parsesNewDateConstructor() throws {
        let statements = try MongoShellParser.parse(#"db.users.insertOne({ createdAt: new Date() });"#)
        #expect(statements.count == 1)
        guard case .object(let fields) = statements[0].calls[0].arguments[0] else {
            Issue.record("expected insertOne argument to be an object")
            return
        }
        guard let (_, createdAtValue) = fields.first(where: { $0.0 == "createdAt" }) else {
            Issue.record("expected createdAt field to be present")
            return
        }
        guard case .date = createdAtValue else {
            Issue.record("expected createdAt field to be a date")
            return
        }
    }

    @Test func parsesObjectIdConstructor() throws {
        let statements = try MongoShellParser.parse(#"db.users.find({ _id: ObjectId("507f1f77bcf86cd799439011") });"#)
        #expect(statements.count == 1)
        guard case .object(let fields) = statements[0].calls[0].arguments[0] else {
            Issue.record("expected find argument to be an object")
            return
        }
        guard let (_, idValue) = fields.first(where: { $0.0 == "_id" }) else {
            Issue.record("expected _id field to be present")
            return
        }
        #expect(idValue == .objectID("507f1f77bcf86cd799439011"))
    }

    @Test func throwsOnInvalidISODateString() {
        #expect(throws: MongoShellParseError.self) {
            try MongoShellParser.parse(#"db.users.find({ timestamp: ISODate("not-a-valid-date") });"#)
        }
    }

    @Test func preservesRawTextWithWhitespace() throws {
        let statements = try MongoShellParser.parse("  db.users.find({});  ")
        #expect(statements.count == 1)
        #expect(statements[0].rawText == "db.users.find({})")
    }
}
