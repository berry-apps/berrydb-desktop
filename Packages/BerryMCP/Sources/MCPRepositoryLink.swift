import Foundation

/// A repository's link file: `.berrydb.json` naming the BerryDB project the
/// repository uses, so every clone and worktree selects that project without
/// registering its path in the app.
///
/// The file belongs to the repository, which is untrusted: it can name any
/// project, so it only chooses which project is offered, and verification of
/// that project decides what is served. Its content is bounded and any file
/// that cannot be used is reported as invalid rather than skipped, so a link
/// never silently gives way to another selection input.
public enum MCPRepositoryLink {
    /// The link file's name, looked up in a workspace and its ancestors.
    public static let fileName = ".berrydb.json"

    /// The largest link file read. A link holds one short name; the bound
    /// keeps a large or endless file in an untrusted repository from being
    /// read into memory.
    public static let maximumBytes = 4096

    /// What the walk up from a workspace found.
    public enum Lookup: Equatable, Sendable {
        /// No link file between the workspace and the file system root.
        case none
        /// The nearest link file, in `directory`, names `projectName`,
        /// trimmed of surrounding whitespace.
        case found(directory: String, projectName: String)
        /// The nearest link file, in `directory`, cannot be read or does not
        /// name a project.
        case invalid(directory: String)
    }

    /// The nearest link file at or above `workspace`, after canonicalizing it
    /// with `MCPProjectSelector.canonicalPath`.
    ///
    /// The walk stops at the first directory holding a link file, valid or
    /// not, and never consults `/`: a file there would name a project for
    /// every workspace on the machine.
    ///
    /// - Parameter read: Returns a file's bytes, or nil when nothing exists
    ///   at the path; `readBounded` unless replaced.
    public static func find(
        from workspace: String, read: @Sendable (String) -> Data? = MCPRepositoryLink.readBounded
    ) -> Lookup {
        var directory = MCPProjectSelector.canonicalPath(workspace)
        while directory.hasPrefix("/"), directory != "/" {
            if let data = read((directory as NSString).appendingPathComponent(fileName)) {
                guard let name = projectName(in: data) else { return .invalid(directory: directory) }
                return .found(directory: directory, projectName: name)
            }
            directory = (directory as NSString).deletingLastPathComponent
        }
        return .none
    }

    /// The first `maximumBytes + 1` bytes of the regular file at `path`, so
    /// the caller can tell a file over the limit without reading all of it.
    ///
    /// Returns nil only when nothing exists at `path`. An entry that exists
    /// but is not a readable regular file, such as a directory, a file
    /// without read permission or a symbolic link to nothing, returns empty
    /// data, which no link parses from, so it is reported as invalid instead
    /// of letting the walk continue past it. Any other failure to open, such
    /// as EACCES or EPERM, fails closed the same way: whether a link exists
    /// there cannot be known, and skipping it could select another project.
    ///
    /// The file is opened with `O_NONBLOCK` because opening a FIFO for
    /// reading otherwise waits for a writer (open(2)); observed on macOS with
    /// a FIFO made by mkfifo, where the blocking open never returned and the
    /// non-blocking one returned at once.
    public static func readBounded(_ path: String) -> Data? {
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            let failure = errno
            guard failure == ENOENT || failure == ENOTDIR else { return Data() }
            // `open` follows symbolic links, so a link to nothing fails with
            // ENOENT although the entry itself exists.
            var entry = stat()
            return lstat(path, &entry) == 0 ? Data() : nil
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else { return Data() }
        return (try? handle.read(upToCount: maximumBytes + 1)) ?? Data()
    }

    /// The file BerryDB writes to link a repository to `projectName`:
    /// `{"project":"<name>"}` and a newline.
    public static func contents(projectName: String) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // `encode` throws when a value fails to encode, is not encodable as a
        // JSON object or array, or holds a non-finite floating-point number
        // (https://developer.apple.com/documentation/foundation/jsonencoder/encode(_:)).
        // A keyed structure holding one string is none of these.
        guard var data = try? encoder.encode(Content(project: projectName)) else {
            preconditionFailure("A link file holding one string always encodes")
        }
        data.append(UInt8(ascii: "\n"))
        return data
    }

    /// Whether a link naming `linkedName` selects a project called
    /// `projectName`: names are compared without letter case after trimming
    /// surrounding whitespace, so a link survives a change of capitalization
    /// on either side.
    ///
    /// The app's settings refuse to save a project whose name matches
    /// another project's by this same rule, so that a link names one project.
    public static func matches(projectName: String, linkedName: String) -> Bool {
        let project = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        let linked = linkedName.trimmingCharacters(in: .whitespacesAndNewlines)
        return project.caseInsensitiveCompare(linked) == .orderedSame
    }

    /// The trimmed project name `data` holds, or nil when it is over the
    /// size limit, is not a JSON object, or has no non-empty `project`
    /// string. Other keys are ignored.
    public static func projectName(in data: Data) -> String? {
        guard data.count <= maximumBytes, let content = try? JSONDecoder().decode(Content.self, from: data) else {
            return nil
        }
        let name = content.project.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private struct Content: Codable {
        let project: String
    }
}
