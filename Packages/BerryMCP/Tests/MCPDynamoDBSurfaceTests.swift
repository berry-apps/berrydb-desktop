import Foundation
import Testing

/// The helper's read-only promise rests on never naming a DynamoDB write, scan or PartiQL target
/// and never importing the driver module, in the two MCP packages and the helper executable. The
/// partition session's `MCPPartitionReader` exposes only `DescribeTable` and `Query`; this scan
/// guards the source text around it, not the types.
@Suite("MCP — DynamoDB surface")
struct MCPDynamoDBSurfaceTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static func swiftFiles(under relative: String) -> [URL] {
        let dir = repoRoot.appendingPathComponent(relative)
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    @Test func mcpCodeNeverNamesAWriteScanOrPartiQLTargetAndNeverImportsTheDynamoDBDriver() throws {
        let forbidden = [
            "DynamoDB_20120810.Scan", "DynamoDB_20120810.ExecuteStatement",
            "DynamoDB_20120810.BatchExecuteStatement", "DynamoDB_20120810.PutItem",
            "DynamoDB_20120810.UpdateItem", "DynamoDB_20120810.DeleteItem",
            "DynamoDB_20120810.BatchWriteItem", "DynamoDB_20120810.TransactWriteItems",
            "import BerryDriverDynamoDB",
        ]
        for directory in ["Packages/BerryMCP/Sources", "Packages/BerryMCPServer/Sources", "MCP/Sources"] {
            let files = Self.swiftFiles(under: directory)
            #expect(!files.isEmpty, "no Swift files found under \(directory)")
            for file in files {
                let text = try String(contentsOf: file, encoding: .utf8)
                for needle in forbidden {
                    #expect(!text.contains(needle), "\(file.path) contains \(needle)")
                }
            }
        }
    }
}
