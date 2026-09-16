import BerryDriverKit
import Testing
@testable import BerryUI

@MainActor
struct WorkspaceTabTitleTests {
    @Test func tabTitleQualifiesSchemaWhenMultipleSchemasExist() {
        let s1Table = SchemaObject(kind: .table, name: "items", database: "berry_s1")
        let s2Table = SchemaObject(kind: .table, name: "items", database: "berry_s2")
        let tab1 = WorkspaceTab.table(TableTabState(object: s1Table))
        let tab2 = WorkspaceTab.table(TableTabState(object: s2Table))

        #expect(tab1.title.contains("berry_s1.items") || tab1.title == "berry_s1.items")
        #expect(tab2.title.contains("berry_s2.items") || tab2.title == "berry_s2.items")
    }

    @Test func tabTitleUsesBareNameForDefaultSchemas() {
        let pubTable = SchemaObject(kind: .table, name: "items", database: "public")
        let dboTable = SchemaObject(kind: .table, name: "items", database: "dbo")
        let nilTable = SchemaObject(kind: .table, name: "items", database: nil)
        let tabPub = WorkspaceTab.table(TableTabState(object: pubTable))
        let tabDbo = WorkspaceTab.table(TableTabState(object: dboTable))
        let tabNil = WorkspaceTab.table(TableTabState(object: nilTable))

        #expect(tabPub.title == "items")
        #expect(tabDbo.title == "items")
        #expect(tabNil.title == "items")
    }
}
