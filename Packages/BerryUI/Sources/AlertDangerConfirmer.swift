import AppKit
import BerryCore

/// NSAlert-based implementation of the DangerGuard confirmation gate
/// Wired into QueryService at startup — every SQL
/// path in the app funnels through it (principle N1).
struct AlertDangerConfirmer: DangerConfirmer {
    func confirm(_ level: DangerLevel, sql: String) async -> Bool {
        await MainActor.run {
            switch level {
            case .safe:
                return true
            case .confirm(let reason):
                return Self.simpleConfirm(reason: reason, sql: sql)
            case .typedConfirm(let objectName, let reason):
                return Self.typedConfirm(objectName: objectName, reason: reason, sql: sql)
            }
        }
    }

    @MainActor
    private static func simpleConfirm(reason: DangerReason, sql: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message(for: reason)
        alert.informativeText = snippet(sql)
        alert.addButton(withTitle: String(localized: "Run Statement", bundle: berryModuleBundle))
        alert.addButton(withTitle: String(localized: "Cancel", bundle: berryModuleBundle))
        return alert.runModal() == .alertFirstButtonReturn
    }

 /// destructive DDL on production requires typing the object name.
    @MainActor
    private static func typedConfirm(objectName: String, reason: DangerReason, sql: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = message(for: reason)
        alert.informativeText = String(
            localized: "Type “\(objectName)” to confirm.\n\n\(snippet(sql))",
            bundle: berryModuleBundle
        )
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = objectName
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Run Statement", bundle: berryModuleBundle))
        alert.addButton(withTitle: String(localized: "Cancel", bundle: berryModuleBundle))
        alert.window.initialFirstResponder = field

        while true {
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            if field.stringValue == objectName { return true }
            // Wrong name → shake expectation: keep asking.
            field.stringValue = ""
        }
    }

    private static func message(for reason: DangerReason) -> String {
        switch reason {
        case .updateWithoutWhere:
            String(localized: "UPDATE without WHERE — every row will be modified.", bundle: berryModuleBundle)
        case .deleteWithoutWhere:
            String(localized: "DELETE without WHERE — every row will be deleted.", bundle: berryModuleBundle)
        case .writeOnProduction:
            String(localized: "Write statement on a PRODUCTION connection.", bundle: berryModuleBundle)
        case .dropOnProduction:
            String(localized: "DROP on a PRODUCTION connection.", bundle: berryModuleBundle)
        case .truncateOnProduction:
            String(localized: "TRUNCATE on a PRODUCTION connection.", bundle: berryModuleBundle)
        case .deleteData:
            String(localized: "This DELETE will remove data.", bundle: berryModuleBundle)
        case .dropObject:
            String(localized: "DROP removes the object and its data.", bundle: berryModuleBundle)
        case .truncateTable:
            String(localized: "TRUNCATE removes every row in the table.", bundle: berryModuleBundle)
        case .deleteBatch(let count):
            String(localized: "This run contains \(count) data-deleting statement(s). Run them all?", bundle: berryModuleBundle)
        }
    }

    private static func snippet(_ sql: String) -> String {
        sql.count > 400 ? String(sql.prefix(400)) + "…" : sql
    }
}
