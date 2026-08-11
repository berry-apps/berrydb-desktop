import BerryDataSourceKit
import Testing

@testable import BerryUI

/// Pure grouping logic (docs/architecture/12 §7) — no Docker, always runs.
@Suite("DataSourceTree grouping")
struct DataSourceTreeTests {
    @Test func mongoLikeCollectionsShareOneDatabaseGroup() {
        let collections = [
            CollectionRef(database: "test", name: "zeta"),
            CollectionRef(database: "test", name: "alpha"),
        ]
        let groups = DataSourceTree.group(collections)
        #expect(groups.count == 1)
        #expect(groups[0].database == "test")
        // Sorted by name within the group.
        #expect(groups[0].collections.map(\.name) == ["alpha", "zeta"])
    }

    @Test func qdrantLikeCollectionsHaveNoDatabaseAndCollapseToOneFlatGroup() {
        let collections = [
            CollectionRef(name: "vectors_b"),
            CollectionRef(name: "vectors_a"),
        ]
        let groups = DataSourceTree.group(collections)
        #expect(groups.count == 1)
        #expect(groups[0].database == nil)
        #expect(groups[0].collections.map(\.name) == ["vectors_a", "vectors_b"])
    }

    @Test func multipleDatabasesSortByDatabaseName() {
        let collections = [
            CollectionRef(database: "zeta_db", name: "a"),
            CollectionRef(database: "alpha_db", name: "b"),
        ]
        let groups = DataSourceTree.group(collections)
        #expect(groups.map(\.database) == ["alpha_db", "zeta_db"])
    }

    @Test func emptyCollectionsProduceNoGroups() {
        #expect(DataSourceTree.group([]).isEmpty)
    }
}
