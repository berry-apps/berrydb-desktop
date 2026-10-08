import Foundation

/// The command line of `berrydb-mcp`: `--project <uuid>` and
/// `--store-path <absolute path>`, each optional and given at most once.
///
/// Neither value is a secret; both are visible in the process list. An
/// explicit project is a selection input, not an authorization: the project
/// is still verified against the store on every request.
public struct HelperArguments: Equatable {
    /// The project to serve regardless of the host's workspace; nil lets the
    /// host's roots or the working directory decide.
    public let project: UUID?
    /// The store file to read instead of the app's default location; always
    /// absolute, so it never depends on the directory a host launches from.
    public let storePath: String?

    public init(project: UUID?, storePath: String?) {
        self.project = project
        self.storePath = storePath
    }

    /// Parses the arguments that follow the executable name. Any argument
    /// other than the two flags and their values is rejected rather than
    /// ignored, so a misspelled flag in a host configuration fails loudly
    /// instead of silently serving a different project or store.
    public static func parse(_ arguments: [String]) throws -> HelperArguments {
        var project: UUID?
        var storePath: String?
        var remaining = arguments[...]
        while let flag = remaining.popFirst() {
            switch flag {
            case "--project":
                guard project == nil else { throw HelperArgumentsError.repeated(flag) }
                guard let value = remaining.popFirst() else { throw HelperArgumentsError.missingValue(flag) }
                guard let id = UUID(uuidString: value) else { throw HelperArgumentsError.invalidProject }
                project = id
            case "--store-path":
                guard storePath == nil else { throw HelperArgumentsError.repeated(flag) }
                guard let value = remaining.popFirst() else { throw HelperArgumentsError.missingValue(flag) }
                guard value.hasPrefix("/") else { throw HelperArgumentsError.relativeStorePath }
                storePath = value
            default:
                throw HelperArgumentsError.unknown(flag)
            }
        }
        return HelperArguments(project: project, storePath: storePath)
    }
}

/// Why a command line was rejected. `description` is the text printed after
/// `berrydb-mcp: ` on standard error; it names the offending argument and
/// never repeats the value given to `--project` or `--store-path`.
public enum HelperArgumentsError: Error, Equatable, CustomStringConvertible {
    case unknown(String)
    case missingValue(String)
    case repeated(String)
    case invalidProject
    case relativeStorePath

    public var description: String {
        switch self {
        case let .unknown(argument):
            return "unknown argument '\(argument)'"
        case let .missingValue(flag):
            return "missing value for \(flag)"
        case let .repeated(flag):
            return "\(flag) given more than once"
        case .invalidProject:
            return "--project expects a project UUID"
        case .relativeStorePath:
            return "--store-path expects an absolute path"
        }
    }
}
