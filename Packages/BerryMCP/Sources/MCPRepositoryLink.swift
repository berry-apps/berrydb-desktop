import Foundation

/// A repository's link file: `.berrydb.json` naming the BerryDB project the
/// repository uses, so every clone and worktree selects that project without
/// registering its path in the app.
///
/// The file belongs to the repository, which is untrusted. It can name any
/// of the user's projects, matched by name, and for every workspace at or
/// below it that choice takes precedence over the folders registered in the
/// app. The named project's metadata is then served whenever the project
/// exists and its stored enabled flag is on, whether or not its integrity tag
/// verifies; the tag gates live reads only. A link cannot create a project,
/// enable one, assign it a connection or change any other project setting.
///
/// Its content is bounded. A readable regular file owned by another user is
/// ignored as if absent; any other entry of the name that cannot be used,
/// such as a symbolic link, a folder, a FIFO or a file this user cannot
/// read, is reported as invalid rather than skipped, so a link never
/// silently gives way to another selection input.
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
    /// - Parameter read: Returns a file's bytes, or nil when the walk goes on
    ///   past the path because there is no link file there to trust;
    ///   `readBounded` unless replaced.
    public static func find(
        from workspace: String, read: @Sendable (String) -> Data? = { MCPRepositoryLink.readBounded($0) }
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
    /// Returns nil when nothing exists at `path`, and for a regular file
    /// that `owner` does not own: a file another account could plant, such
    /// as one in a shared or world-writable folder above the workspace, is
    /// not trusted to name a project, the rule git applies to repositories
    /// it does not own (https://git-scm.com/docs/git-config#Documentation/git-config.txt-safedirectory).
    /// The owner is that of the opened descriptor, so it cannot change
    /// between the check and the read.
    ///
    /// Any other entry that is not a readable regular file, such as a
    /// directory, a symbolic link or a file without read permission, returns
    /// empty data, which no link parses from, so it is reported as invalid
    /// instead of letting the walk continue past it. Any other failure to
    /// open, such as EACCES or EPERM, fails closed the same way: whether a
    /// link exists there cannot be known, and skipping it could select
    /// another project.
    ///
    /// The open flags keep a file the repository controls from reaching
    /// anything but the one regular file (open(2)):
    /// - `O_NOFOLLOW`: a symbolic link, which git stores and a clone
    ///   recreates, is never followed. It fails with ELOOP, observed on macOS
    ///   26.6 for links to a file and to nothing alike.
    /// - `O_NOCTTY`: a terminal device is never made the controlling one.
    /// - `O_NONBLOCK`: opening a FIFO for reading otherwise waits for a
    ///   writer; observed on macOS with a FIFO made by mkfifo, where the
    ///   blocking open never returned and the non-blocking one returned at
    ///   once.
    ///
    /// - Parameter owner: The user whose files are trusted; the current user
    ///   unless replaced.
    public static func readBounded(_ path: String, owner: uid_t = getuid()) -> Data? {
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW | O_NOCTTY)
        guard descriptor >= 0 else {
            let failure = errno
            return failure == ENOENT || failure == ENOTDIR ? nil : Data()
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else { return Data() }
        guard status.st_uid == owner else { return nil }
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
