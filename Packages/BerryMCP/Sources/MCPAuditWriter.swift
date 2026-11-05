import Foundation

/// Appends one audit line per tool call. A failure is reported once and never
/// reaches the caller: the audit file must not be able to fail a tool call.
///
/// The file is opened, written and closed on every record instead of keeping a
/// descriptor. The app replaces the file by renaming a trimmed copy over it to
/// cap its size, and a descriptor held open would go on writing to the
/// unlinked old file. `O_APPEND` with the whole line in one `write(2)` keeps
/// lines whole when several helper processes append to the same regular file.
///
/// The directory is never created here: it belongs to the app, and a helper
/// that created it would hide that the app has not run.
public actor MCPAuditWriter {
    public nonisolated let url: URL
    private let diagnostics: @Sendable (String) -> Void
    private var warned = false

    public init(url: URL, diagnostics: @escaping @Sendable (String) -> Void) {
        self.url = url
        self.diagnostics = diagnostics
    }

    public func record(_ record: MCPAuditRecord) async {
        let line: Data
        do {
            line = try MCPAuditLog.line(record)
        } catch {
            warn(String(describing: error))
            return
        }
        let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            warn(String(cString: strerror(errno)))
            return
        }
        defer { close(descriptor) }
        let failure: Int32? = line.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    let code = errno
                    if code == EINTR { continue }
                    return code
                }
                offset += written
            }
            return nil
        }
        if let failure { warn(String(cString: strerror(failure))) }
    }

    private func warn(_ reason: String) {
        guard !warned else { return }
        warned = true
        diagnostics("audit log unavailable: \(reason)")
    }
}
