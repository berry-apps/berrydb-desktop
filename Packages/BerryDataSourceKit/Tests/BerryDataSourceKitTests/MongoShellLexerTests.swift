// Packages/BerryDataSourceKit/Tests/MongoShellLexerTests.swift
import Testing
@testable import BerryDataSourceKit

@Suite("MongoShellLexer")
struct MongoShellLexerTests {
    @Test func tokenizesACallWithAStringAndANumber() throws {
        let tokens = try MongoShellLexer.tokenize(#"db.users.find({"age": 25})"#)
        #expect(tokens == [
            .identifier("db"), .dot, .identifier("users"), .dot, .identifier("find"),
            .leftParen, .leftBrace, .string("age"), .colon, .number(25), .rightBrace, .rightParen,
        ])
    }

    @Test func tokenizesOperatorKeysAndSingleQuotedStrings() throws {
        let tokens = try MongoShellLexer.tokenize("{ $gt: 'x' }")
        #expect(tokens == [.leftBrace, .identifier("$gt"), .colon, .string("x"), .rightBrace])
    }

    @Test func tokenizesBooleansNullAndNegativeNumbers() throws {
        let tokens = try MongoShellLexer.tokenize("[true, false, null, -1.5]")
        #expect(tokens == [
            .leftBracket, .keywordTrue, .comma, .keywordFalse, .comma,
            .keywordNull, .comma, .number(-1.5), .rightBracket,
        ])
    }

    @Test func skipsLineAndBlockComments() throws {
        let tokens = try MongoShellLexer.tokenize("db.a.find({}) // trailing\n/* block */ ;")
        #expect(tokens == [
            .identifier("db"), .dot, .identifier("a"), .dot, .identifier("find"),
            .leftParen, .leftBrace, .rightBrace, .rightParen, .semicolon,
        ])
    }

    @Test func throwsOnUnterminatedString() {
        #expect(throws: MongoShellLexError.self) {
            try MongoShellLexer.tokenize(#"{"age": "25}"#)
        }
    }
}
