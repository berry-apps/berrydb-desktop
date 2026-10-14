import BerryDataSourceKit

/// Refuses a document-store statement that runs without its own approval
/// card yet resolves to a write. Such a statement got through only because
/// the read-only check passed its text; if the shell resolver reads it as a
/// write all the same, the resolver wins and nothing is written.
enum AutoRunWriteGuard {
    /// What the model sees instead of the write, or nil when the statement
    /// may run.
    static func refusal(for action: MongoShellAction, autoRun: Bool) -> String? {
        guard autoRun else { return nil }
        switch action {
        case .query:
            return nil
        case .write, .writeMany:
            return "This statement writes, so it needs the user's approval on its own card. It was not run."
        }
    }
}
