import Foundation

public enum DumpFormat: Sendable, Equatable {
    case postgresCustomDump
    case postgresPlainSQL
    case mysqlPlainSQL
    case sqliteBinary
    case gzippedSQL
    case berryBundle
    case genericSQL
    case unknown
}

public struct DumpInspectionResult: Sendable, Equatable {
    public let format: DumpFormat
    public let estimatedSizeBytes: Int64
    public let isDirectory: Bool
    public let detectedDialectName: String?

    public init(format: DumpFormat, estimatedSizeBytes: Int64, isDirectory: Bool, detectedDialectName: String?) {
        self.format = format
        self.estimatedSizeBytes = estimatedSizeBytes
        self.isDirectory = isDirectory
        self.detectedDialectName = detectedDialectName
    }
}

public enum DumpInspector {
    public static func inspect(url: URL) throws -> DumpInspectionResult {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw CocoaError(.fileNoSuchFile)
        }

        if isDir.boolValue {
            let manifestURL = url.appendingPathComponent("manifest.json")
            if FileManager.default.fileExists(atPath: manifestURL.path) {
                return DumpInspectionResult(
                    format: .berryBundle,
                    estimatedSizeBytes: 0,
                    isDirectory: true,
                    detectedDialectName: "BerryDB Bundle"
                )
            }
            return DumpInspectionResult(
                format: .unknown,
                estimatedSizeBytes: 0,
                isDirectory: true,
                detectedDialectName: nil
            )
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? Int64) ?? 0

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let headerData = (try handle.read(upToCount: 4096)) ?? Data()

        // 1. PostgreSQL custom dump magic: "PGDMP" (0x50, 0x47, 0x44, 0x4D, 0x50)
        if headerData.count >= 5 &&
            headerData[0] == 0x50 && headerData[1] == 0x47 &&
            headerData[2] == 0x44 && headerData[3] == 0x4D && headerData[4] == 0x50 {
            return DumpInspectionResult(
                format: .postgresCustomDump,
                estimatedSizeBytes: fileSize,
                isDirectory: false,
                detectedDialectName: "PostgreSQL"
            )
        }

        // 2. Gzip compressed: 0x1F 0x8B
        if headerData.count >= 2 && headerData[0] == 0x1F && headerData[1] == 0x8B {
            return DumpInspectionResult(
                format: .gzippedSQL,
                estimatedSizeBytes: fileSize,
                isDirectory: false,
                detectedDialectName: nil
            )
        }

        // 3. SQLite binary format: "SQLite format 3\0"
        let sqliteMagic = Data("SQLite format 3\0".utf8)
        if headerData.prefix(sqliteMagic.count) == sqliteMagic {
            return DumpInspectionResult(
                format: .sqliteBinary,
                estimatedSizeBytes: fileSize,
                isDirectory: false,
                detectedDialectName: "SQLite"
            )
        }

        // 4. Text header inspection
        if let headerString = String(data: headerData, encoding: .utf8) {
            let lower = headerString.lowercased()
            if lower.contains("mysql dump") || lower.contains("mariadb dump") || headerString.contains("/*M!") {
                return DumpInspectionResult(
                    format: .mysqlPlainSQL,
                    estimatedSizeBytes: fileSize,
                    isDirectory: false,
                    detectedDialectName: "MySQL"
                )
            }
            if lower.contains("postgresql database dump") || lower.contains("pg_dump") {
                return DumpInspectionResult(
                    format: .postgresPlainSQL,
                    estimatedSizeBytes: fileSize,
                    isDirectory: false,
                    detectedDialectName: "PostgreSQL"
                )
            }
            if url.pathExtension.lowercased() == "sql" {
                return DumpInspectionResult(
                    format: .genericSQL,
                    estimatedSizeBytes: fileSize,
                    isDirectory: false,
                    detectedDialectName: nil
                )
            }
        }

        return DumpInspectionResult(
            format: .unknown,
            estimatedSizeBytes: fileSize,
            isDirectory: false,
            detectedDialectName: nil
        )
    }
}
