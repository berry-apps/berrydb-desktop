import BerryDataSourceKit
import Testing

@testable import BerryUI

@Suite("Elasticsearch query DSL")
struct ElasticsearchQueryScriptTests {
    @Test func parsesSearchWithAllFields() throws {
        let q = try ElasticsearchQueryScript.parse("""
        { "index": "logs", "query": { "match": { "level": "error" } }, "from": 10, "size": 25 }
        """)
        guard case let .search(index, query, from, size) = q else {
            Issue.record("expected .search, got \(q)"); return
        }
        #expect(index == "logs")
        #expect(from == 10)
        #expect(size == 25)
        #expect(query == .object([("match", .object([("level", .string("error"))]))]))

        guard case .esSearch = q.readQuery else { Issue.record("readQuery not esSearch"); return }
        #expect(q.isWrite == false)
        #expect(q.changeSets == nil)
    }

    @Test func defaultsFromAndSizeWhenOmitted() throws {
        let q = try ElasticsearchQueryScript.parse(#"{ "index": "logs" }"#)
        guard case let .search(_, query, from, size) = q else { Issue.record("expected .search"); return }
        #expect(from == 0)
        #expect(size == 50)
        #expect(query == .null)
    }

    @Test func explicitScrollOp() throws {
        let q = try ElasticsearchQueryScript.parse(#"{ "op": "scroll", "index": "logs", "query": { "match_all": {} } }"#)
        guard case let .scroll(index, query) = q else { Issue.record("expected .scroll"); return }
        #expect(index == "logs")
        #expect(query == .object([("match_all", .object([]))]))
        guard case .esScroll = q.readQuery else { Issue.record("readQuery not esScroll"); return }
    }

    @Test func parsesIndexOpToInsertChangeSet() throws {
        let q = try ElasticsearchQueryScript.parse("""
        { "op": "index", "index": "logs", "document": { "level": "info", "message": "hello" } }
        """)
        guard case let .index(index, document) = q else { Issue.record("expected .index"); return }
        #expect(index == "logs")
        #expect(q.isWrite)
        let changes = try #require(q.changeSets)
        #expect(changes.count == 1)
        guard case let .insert(c, doc) = changes[0] else { Issue.record("expected .insert"); return }
        #expect(c == "logs")
        #expect(doc == document)
        #expect(doc["level"] == .string("info"))
    }

    @Test func parsesUpdateOpToUpdateChangeSet() throws {
        let q = try ElasticsearchQueryScript.parse(#"{ "op": "update", "index": "logs", "id": "abc", "doc": { "level": "warn" } }"#)
        guard case let .update(index, id, doc) = q else { Issue.record("expected .update"); return }
        #expect(index == "logs")
        #expect(id == "abc")
        let changes = try #require(q.changeSets)
        guard case let .update(_, changeID, patch) = changes[0] else { Issue.record("expected .update change"); return }
        #expect(changeID == .string("abc"))
        #expect(patch == doc)
    }

    @Test func parsesDeleteOpToDeleteChangeSet() throws {
        let q = try ElasticsearchQueryScript.parse(#"{ "op": "delete", "index": "logs", "id": "abc" }"#)
        guard case let .delete(index, id) = q else { Issue.record("expected .delete"); return }
        #expect(index == "logs")
        #expect(id == "abc")
        let changes = try #require(q.changeSets)
        guard case let .delete(_, changeID) = changes[0] else { Issue.record("expected .delete change"); return }
        #expect(changeID == .string("abc"))
    }

    @Test func parsesDeleteByQueryOpToDeleteByFilterChangeSet() throws {
        let q = try ElasticsearchQueryScript.parse("""
        { "op": "delete_by_query", "index": "logs", "query": { "term": { "level": "debug" } } }
        """)
        guard case let .deleteByQuery(index, query) = q else { Issue.record("expected .deleteByQuery"); return }
        #expect(index == "logs")
        let changes = try #require(q.changeSets)
        guard case let .deleteByFilter(_, filter, multi) = changes[0] else { Issue.record("expected .deleteByFilter change"); return }
        #expect(filter == query)
        #expect(multi)
    }

    @Test func roundTripsThroughJSON() throws {
        for text in [
            #"{ "index": "logs", "query": { "match": { "level": "error" } }, "from": 0, "size": 50 }"#,
            #"{ "index": "logs" }"#,
            #"{ "op": "delete", "index": "logs", "id": "abc" }"#,
            #"{ "op": "update", "index": "logs", "id": "abc", "doc": { "level": "warn" } }"#,
        ] {
            let once = try ElasticsearchQueryScript.parse(text)
            let twice = try ElasticsearchQueryScript.parse(ElasticsearchQueryScript.json(for: once))
            #expect(once == twice, "round trip changed \(text)")
        }
    }

    @Test func reportsErrors() {
        func err(_ text: String) -> ElasticsearchQueryError? {
            do { _ = try ElasticsearchQueryScript.parse(text); return nil }
            catch let e as ElasticsearchQueryError { return e }
            catch { return nil }
        }
        #expect(err("   ") == .empty)
        #expect(err("not json") == .notJSON)
        #expect(err("[1,2,3]") == .notObject)
        #expect(err(#"{ "query": {} }"#) == .missingIndex)
        #expect(err(#"{ "op": "index", "index": "i" }"#) == .indexNeedsDocument)
        #expect(err(#"{ "op": "update", "index": "i" }"#) == .updateNeedsIDAndDoc)
        #expect(err(#"{ "op": "update", "index": "i", "id": "x" }"#) == .updateNeedsIDAndDoc)
        #expect(err(#"{ "op": "delete", "index": "i" }"#) == .deleteNeedsID)
        #expect(err(#"{ "op": "explode", "index": "i" }"#) == .invalidOp("explode"))
    }
}
