import Foundation
import Testing
@testable import BerryUI

@Suite("EditorDocument File Tests")
struct EditorDocumentFileTests {
    @Test("EditorDocument tracks fileURL and saves changes atomically")
    @MainActor
    func testFileSaving() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("editor_\(UUID().uuidString).sql")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        
        try "SELECT 1;".write(to: tempURL, atomically: true, encoding: .utf8)
        
        let doc = EditorDocument(title: "test.sql", text: "SELECT 1;")
        doc.fileURL = tempURL
        #expect(doc.isDirty == false)
        
        doc.text = "SELECT 2;"
        #expect(doc.isDirty == true)
        
        try doc.saveToFile()
        #expect(doc.isDirty == false)
        
        let onDisk = try String(contentsOf: tempURL, encoding: .utf8)
        #expect(onDisk == "SELECT 2;")
    }
}
