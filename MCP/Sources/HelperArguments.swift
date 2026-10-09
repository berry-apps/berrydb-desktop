import BerryMCP
import Foundation

/// The command line of `berrydb-mcp`: `--project <uuid|name>` and
/// `--store-path <absolute path>`, each optional and given at most once.
///
/// Neither value is a secret; both are visible in the process list. An
/// explicit project is a selection input, not an authorization: the project
/// is still verified against the store on every request.
public struct HelperArguments: Equatable {
    /// The project to serve regardless of the host's workspace, by its ID
    /// or by its name as `MCPProjectReference(argument:)` parses the value;
    /// nil lets the host's roots or the working directory decide.
    public let project: MCPProjectReference?
    /// The store file to read instead of the app's default location; always
    /// absolute, so it never depends on the directory a host launches from.
    public let storePath: String?

    public init(project: MCPProjectReference?, storePath: String?) {
        self.project = project
        self.storePath = storePath
    }

    /// Parses the arguments that follow the executable name. Any argument
    /// other than the two flags and their values is rejected rather than
    /// ignored, so a misspelled flag in a host configuration fails loudly
    /// instead of silently serving a different project or store.
    public static func parse(_ arguments: [String]) throws -> HelperArguments {
        var project: MCPProjectReference?
        var storePath: String?
        var remaining = arguments[...]
        while let flag = remaining.popFirst() {
            switch flag {
            case "--project":
                guard project == nil else { throw HelperArgumentsError.repeated(flag) }
                guard let value = remaining.popFirst() else { throw HelperArgumentsError.missingValue(flag) }
                guard let reference = MCPProjectReference(argument: value) else {
                    throw HelperArgumentsError.invalidProject
                }
                project = reference
            case "--store-path":
                guard storePath == nil else { throw HelperArgumentsError.repeated(flag) }
                guard let value = remaining.popFirst() else { throw HelperArgumentsError.missingValue(flag) }
                guard value.hasPrefix("/") else { throw HelperArgumentsError.relativeStorePath }
                storePath = value
            default:
                throw rejection(of: flag)
            }
        }
        return HelperArguments(project: project, storePath: storePath)
    }

    /// The error for an argument that is neither flag. A stray positional
    /// argument is not echoed at all, and of a flag only the leading run of
    /// ASCII letters and hyphens is kept, plus an `=` that directly follows
    /// it, because the rest of `--store-path=<path>`, `--store-path<path>`
    /// or `-s<path>` may be a local path, and the error is printed on
    /// standard error.
    private static func rejection(of argument: String) -> HelperArgumentsError {
        guard argument.hasPrefix("-") else { return .positional }
        let name = argument.prefix { $0 == "-" || ($0.isASCII && $0.isLetter) }
        let equals = argument.dropFirst(name.count).first == "=" ? "=" : ""
        return .unknown(name + equals)
    }
}

/// Why a command line was rejected. `description` is the text printed after
/// `berrydb-mcp: ` on standard error; it names at most the offending flag and
/// never carries a value given on the command line.
public enum HelperArgumentsError: Error, Equatable, CustomStringConvertible {
    /// An argument that starts with `-` but is neither flag, cut to the
    /// characters a flag name can have.
    case unknown(String)
    /// An argument that is not a flag, such as a stray value.
    case positional
    case missingValue(String)
    case repeated(String)
    case invalidProject
    case relativeStorePath

    public var description: String {
        switch self {
        case let .unknown(argument):
            return "unknown argument '\(argument)'"
        case .positional:
            return "unexpected positional argument"
        case let .missingValue(flag):
            return "missing value for \(flag)"
        case let .repeated(flag):
            return "\(flag) given more than once"
        case .invalidProject:
            return "--project expects a project UUID or name"
        case .relativeStorePath:
            return "--store-path expects an absolute path"
        }
    }
}
