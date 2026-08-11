import BerryDataSourceKit
import Testing

@testable import BerryUI

@Suite("Qdrant query DSL")
struct QdrantQueryScriptTests {
    @Test func parsesVectorSearchWithAllFields() throws {
        let q = try QdrantQueryScript.parse("""
        { "collection": "docs", "vector": [0.1, 0.2], "top": 5,
          "filter": { "lang": "vi" }, "score_threshold": 0.7 }
        """)
        guard case let .search(collection, vector, filter, topK, threshold) = q else {
            Issue.record("expected .search, got \(q)"); return
        }
        #expect(collection == "docs")
        #expect(vector == [0.1, 0.2])
        #expect(topK == 5)
        #expect(threshold == 0.7)
        #expect(filter == .object([("lang", .string("vi"))]))

        guard case .qdrantSearch = q.readQuery else { Issue.record("readQuery not qdrantSearch"); return }
        #expect(q.isWrite == false)
        #expect(q.changeSets == nil)
    }

    @Test func defaultsTopKToTenWhenOmitted() throws {
        let q = try QdrantQueryScript.parse(#"{ "collection": "docs", "vector": [1, 2] }"#)
        guard case let .search(_, _, _, topK, threshold) = q else { Issue.record("expected .search"); return }
        #expect(topK == 10)
        #expect(threshold == nil)
    }

    @Test func noVectorParsesAsScroll() throws {
        let q = try QdrantQueryScript.parse(#"{ "collection": "docs", "filter": { "lang": "vi" } }"#)
        guard case let .scroll(collection, filter) = q else { Issue.record("expected .scroll"); return }
        #expect(collection == "docs")
        #expect(filter == .object([("lang", .string("vi"))]))
        guard case .qdrantScroll = q.readQuery else { Issue.record("readQuery not qdrantScroll"); return }
    }

    @Test func explicitScrollIgnoresVector() throws {
        let q = try QdrantQueryScript.parse(#"{ "op": "scroll", "collection": "docs", "vector": [1, 2] }"#)
        guard case .scroll = q else { Issue.record("expected .scroll"); return }
    }

    @Test func parsesUpsertToInsertChangeSets() throws {
        let q = try QdrantQueryScript.parse("""
        { "op": "upsert", "collection": "docs",
          "points": [ { "id": 1, "vector": [0.1, 0.2], "payload": { "lang": "vi" } },
                      { "id": 2, "vector": [0.3, 0.4] } ] }
        """)
        guard case let .upsert(collection, points) = q else { Issue.record("expected .upsert"); return }
        #expect(collection == "docs")
        #expect(points.count == 2)
        #expect(q.isWrite)
        let changes = try #require(q.changeSets)
        #expect(changes.count == 2)
        guard case let .insert(c, doc) = changes[0] else { Issue.record("expected .insert"); return }
        #expect(c == "docs")
        #expect(doc["id"] == .int(1))
        #expect(doc["vector"] == .array([.double(0.1), .double(0.2)]))
    }

    @Test func parsesDeleteToDeleteChangeSets() throws {
        let q = try QdrantQueryScript.parse(#"{ "op": "delete", "collection": "docs", "ids": [1, "abc"] }"#)
        guard case let .delete(_, ids) = q else { Issue.record("expected .delete"); return }
        #expect(ids == [.int(1), .string("abc")])
        let changes = try #require(q.changeSets)
        #expect(changes.count == 2)
        guard case let .delete(_, id) = changes[1] else { Issue.record("expected .delete change"); return }
        #expect(id == .string("abc"))
    }

    @Test func roundTripsThroughJSON() throws {
        for text in [
            #"{ "collection": "docs", "vector": [0.1, 0.2], "top": 5, "filter": { "lang": "vi" }, "score_threshold": 0.7 }"#,
            #"{ "collection": "docs" }"#,
            #"{ "op": "delete", "collection": "docs", "ids": [1, 2] }"#,
        ] {
            let once = try QdrantQueryScript.parse(text)
            let twice = try QdrantQueryScript.parse(QdrantQueryScript.json(for: once))
            #expect(once == twice, "round trip changed \(text)")
        }
    }

    @Test func reportsErrors() {
        func err(_ text: String) -> QdrantQueryError? {
            do { _ = try QdrantQueryScript.parse(text); return nil }
            catch let e as QdrantQueryError { return e }
            catch { return nil }
        }
        #expect(err("   ") == .empty)
        #expect(err("not json") == .notJSON)
        #expect(err("[1,2,3]") == .notObject)
        #expect(err(#"{ "vector": [1] }"#) == .missingCollection)
        #expect(err(#"{ "op": "search", "collection": "c" }"#) == .searchNeedsVector)
        #expect(err(#"{ "op": "upsert", "collection": "c", "points": [] }"#) == .upsertNeedsPoints)
        #expect(err(#"{ "op": "upsert", "collection": "c", "points": [ { "id": 1 } ] }"#) == .pointNeedsVector)
        #expect(err(#"{ "op": "delete", "collection": "c" }"#) == .deleteNeedsIDs)
        #expect(err(#"{ "op": "explode", "collection": "c" }"#) == .invalidOp("explode"))
    }
}
