import AppKit
import BerryCore
import BerryDataSourceKit
import BerryDriverDynamoDB
import BerryDriverElasticsearch
import BerryDriverKit
import BerryDriverMongo
import BerryDriverMySQL
import BerryDriverPostgres
import BerryDriverQdrant
import BerryDriverRedis
import BerryDriverSQLite
import BerryDriverSQLServer
import BerryKeyValueKit
import BerryUI
import SwiftUI

@main
struct BerryDBApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // The ONLY place where concrete drivers are wired (docs/architecture/05 §2).
        DriverRegistry.register(SQLiteDriver.self)
        DriverRegistry.register(PostgresDriver.self)
        DriverRegistry.register(MySQLDriver.self)
        DriverRegistry.register(DynamoDBDriver.self)     // PartiQL (docs/architecture/12 §4)
        DriverRegistry.register(SQLServerDriver.self)    // FreeTDS C interop (docs/architecture/05 §4, V2⚠️)
        // DataSourceDriver family (docs/architecture/12 §8) — independent registry.
        DataSourceRegistry.register(QdrantDriver.self)
        DataSourceRegistry.register(MongoDriver.self)
        DataSourceRegistry.register(ElasticsearchDriver.self)
        // KeyValueDriver family (docs/architecture/15 §2) — independent registry.
        // RedisDriver requires macOS 15+ (valkey-swift's own minimum); the app
        // itself stays at .macOS(.v14), so this is the one place that gates on
        // it — on macOS 14 this branch never runs, KeyValueRegistry.registered
        // stays empty, and .redis never appears in the connection picker.
        if #available(macOS 15, *) {
            KeyValueRegistry.register(RedisDriver.self)
        }
    }

    var body: some Scene {
        WindowGroup {
            WorkspaceView()
                .frame(minWidth: 900, minHeight: 560)
        }
        .windowToolbarStyle(.unifiedCompact) // shorter title bar (ui.md §3)
        // UD-07: open with a generous default so content shows without
        // scrolling wherever the screen allows.
        .defaultSize(width: 1240, height: 800)
        .commands {
            // Sparkle auto-update entry (docs/architecture/10 §3). No-op in
            // dev / unsigned builds; the real updater lights up in a signed
            // release (see AppUpdater + deploy/README.md).
            CommandGroup(replacing: .appInfo) {
                Button(L("About BerryDB")) {
                    showAboutPanel()
                }
                Button(L("Check for Updates…")) { appDelegate.updater.checkForUpdates() }
            }
            CommandGroup(replacing: .help) {
                Button(L("BerryDB Documentation")) {
                    if let url = URL(string: "https://berrydb.app/docs") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button(L("Keyboard Shortcuts")) {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
            }
            // The full BerryDB menu bar (ui.md §3) — File/Query/Database/
            // Intelligence/View, all keyboard-navigable.
            WorkspaceCommands()
        }

        // Settings (⌘,): customizable keyboard shortcuts (docs/ui).
        Settings {
            ShortcutSettingsView()
        }

        // A tab moved into its own window (docs/ui/01 D1) — same document and
        // session as the main workspace.
        WindowGroup(id: "detached-tab", for: String.self) { $tabID in
            DetachedTabWindow(tabID: tabID ?? "")
        }
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 900, height: 620)
    }

    @MainActor
    private func showAboutPanel() {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "BerryDB",
            .version: "1.0.0",
            .applicationVersion: "Build 2026.1",
            .credits: NSAttributedString(
                string: "BerryDB — Fast, Native Database Client for macOS\nCopyright © 2026 BerryDB Team. All rights reserved.",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            )
        ]
        if let icon = NSApp.applicationIconImage {
            options[.applicationIcon] = icon
        }
        NSApp.orderFrontStandardAboutPanel(options)
    }
}

/// When running dev via `swift run` (no app bundle), the process must promote
/// itself to a regular app to get a Dock icon and receive focus.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let updater: any UpdaterControlling = makeUpdater()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        
        #if DEBUG
        // Load the icon for local development (run.sh)
        if NSApp.applicationIconImage == nil {
            let fileURL = URL(fileURLWithPath: #filePath)
            let rootURL = fileURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let iconURL = rootURL.appendingPathComponent("icons/AppIcon.icns")
            let fallbackURL = rootURL.appendingPathComponent("deploy/AppIcon.icns")
            if let image = NSImage(contentsOf: iconURL) ?? NSImage(contentsOf: fallbackURL) {
                NSApp.applicationIconImage = image
            }
        }
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// `ConnectionManager.closeAll()` existed but nothing ever called it —
    /// every SQL-family session (Postgres/MySQL/SQLite/DynamoDB/SQL Server)
    /// relied entirely on the OS tearing down its socket/file descriptors on
    /// process exit. That's fine for a plain TCP connection, but SQLite in
    /// particular benefits from a real `sqlite3_close()` instead of the file
    /// just vanishing mid-WAL-checkpoint. `terminate()` waits for
    /// `applicationShouldTerminate` to return, so this actually runs before
    /// the process exits rather than racing it.
    ///
    /// Bounded at 3s: quitting the app must never hang because one driver's
    /// `close()` misbehaves — this session already hit that exact "missing
    /// timeout" bug class more than once elsewhere (SQL Server login, AI
    /// query execution). Whichever finishes first wins; the loser is simply
    /// abandoned as the process exits anyway.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await ConnectionManager.shared.closeAll() }
                group.addTask { try? await Task.sleep(nanoseconds: 3_000_000_000) }
                await group.next()
                group.cancelAll()
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
