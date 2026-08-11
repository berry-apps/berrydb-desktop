import AppKit
import BerryDataSourceKit

/// Confirmation gate for a `DataSourceChangeSet` write (docs/architecture/12
/// §6/§7) — the NoSQL/vector sibling of `DangerConfirmer` (BerryCore, 07 §6).
/// There is no `QueryService`-style single funnel for
/// `DataSourceConnection.write` the way SQL has — `applyDataSourceWrite` on
/// `WorkspaceViewModel` IS that one path, and it reads this swappable static
/// (`WorkspaceViewModel.dataSourceWriteConfirmer`) — same reasoning as
/// `QueryService.dangerConfirmer` being replaceable in tests instead of
/// popping a real, test-blocking alert.
public protocol DataSourceWriteConfirming: Sendable {
    func confirm(_ level: DataSourceDangerLevel, preview: String) async -> Bool
}

/// NSAlert-based implementation — mirrors `AlertDangerConfirmer`'s pattern:
/// `.safe` proceeds without prompting (insert/update/delete-by-id all
/// classify as safe); only `.confirm` (empty-filter delete, NS-08) blocks on
/// a real alert showing the native-command preview.
struct AlertDataSourceWriteConfirmer: DataSourceWriteConfirming {
    func confirm(_ level: DataSourceDangerLevel, preview: String) async -> Bool {
        switch level {
        case .safe:
            return true
        case .confirm(let reason):
            return await MainActor.run { Self.alert(reason: reason, preview: preview) }
        case .typedConfirm(let objectName, let reason):
            return await MainActor.run { Self.typedConfirm(objectName: objectName, reason: reason, preview: preview) }
        }
    }

    @MainActor
    private static func alert(reason: DataSourceDangerReason, preview: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message(for: reason)
        alert.informativeText = preview.count > 800 ? String(preview.prefix(800)) + "…" : preview
        alert.addButton(withTitle: String(localized: "Run Statement", bundle: berryModuleBundle))
        alert.addButton(withTitle: String(localized: "Cancel", bundle: berryModuleBundle))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Mirrors `AlertDangerConfirmer.typedConfirm` (SQL's DROP/TRUNCATE-on-
    /// production gate, docs/architecture/07 §6 CT-04) verbatim — the user
    /// must retype the exact object name, not just click a button.
    @MainActor
    private static func typedConfirm(objectName: String, reason: DataSourceDangerReason, preview: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = message(for: reason)
        let snippet = preview.count > 800 ? String(preview.prefix(800)) + "…" : preview
        alert.informativeText = String(localized: "Type “\(objectName)” to confirm.\n\n\(snippet)", bundle: berryModuleBundle)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = objectName
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Run Statement", bundle: berryModuleBundle))
        alert.addButton(withTitle: String(localized: "Cancel", bundle: berryModuleBundle))
        alert.window.initialFirstResponder = field

        while true {
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            if field.stringValue == objectName { return true }
            field.stringValue = ""
        }
    }

    private static func message(for reason: DataSourceDangerReason) -> String {
        switch reason {
        case .deleteWithoutFilter:
            String(localized: "This deletes every document/point in the collection — there is no filter.", bundle: berryModuleBundle)
        case .updateWithoutFilter:
            String(localized: "This updates every document in the collection — there is no filter.", bundle: berryModuleBundle)
        case .dropCollection:
            String(localized: "This permanently removes the collection and all its documents.", bundle: berryModuleBundle)
        case .dropIndex:
            String(localized: "This drops an index — queries relying on it may slow down until it's recreated.", bundle: berryModuleBundle)
        }
    }
}
