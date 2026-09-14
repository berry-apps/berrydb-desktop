import Foundation

public enum CLIExecutable: Sendable {
    case psql
    case mysql
    case sqlite3
    case pg_restore

    public var binaryName: String {
        switch self {
        case .psql: "psql"
        case .mysql: "mysql"
        case .sqlite3: "sqlite3"
        case .pg_restore: "pg_restore"
        }
    }
}

public enum SQLCLIImporter {
    private static let searchPaths = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin"
    ]

    public static func findExecutable(_ executable: CLIExecutable) -> URL? {
        let name = executable.binaryName
        for dir in searchPaths {
            let path = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    public static func buildArguments(
        for executable: CLIExecutable,
        fileURL: URL,
        host: String?,
        port: Int?,
        database: String?,
        user: String?
    ) -> [String] {
        var args: [String] = []
        switch executable {
        case .psql:
            args.append("-w")
            if let host, !host.isEmpty { args.append(contentsOf: ["-h", host]) }
            if let port, port > 0 { args.append(contentsOf: ["-p", "\(port)"]) }
            if let user, !user.isEmpty { args.append(contentsOf: ["-U", user]) }
            if let database, !database.isEmpty { args.append(contentsOf: ["-d", database]) }
            args.append(contentsOf: ["-f", fileURL.path(percentEncoded: false)])

        case .pg_restore:
            args.append("-w")
            if let host, !host.isEmpty { args.append(contentsOf: ["-h", host]) }
            if let port, port > 0 { args.append(contentsOf: ["-p", "\(port)"]) }
            if let user, !user.isEmpty { args.append(contentsOf: ["-U", user]) }
            if let database, !database.isEmpty { args.append(contentsOf: ["-d", database]) }
            args.append(fileURL.path(percentEncoded: false))

        case .mysql:
            if let host, !host.isEmpty { args.append(contentsOf: ["-h", host]) }
            if let port, port > 0 { args.append(contentsOf: ["-P", "\(port)"]) }
            if let user, !user.isEmpty { args.append(contentsOf: ["-u", user]) }
            if let database, !database.isEmpty { args.append(database) }

        case .sqlite3:
            if let database, !database.isEmpty { args.append(database) }
        }
        return args
    }
}
