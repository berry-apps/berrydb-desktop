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
 // The ONLY place where concrete drivers are wired.
        DriverRegistry.register(SQLiteDriver.self)
        DriverRegistry.register(PostgresDriver.self)
        DriverRegistry.register(MySQLDriver.self)
 DriverRegistry.register(DynamoDBDriver.self) // PartiQL
 DriverRegistry.register(SQLServerDriver.self) // FreeTDS C interop (V2⚠️)
 // DataSourceDriver family — independent registry.
        DataSourceRegistry.register(QdrantDriver.self)
        DataSourceRegistry.register(MongoDriver.self)
        DataSourceRegistry.register(ElasticsearchDriver.self)
 // KeyValueDriver family — independent registry.
        // RedisDriver and BerryDB share the same macOS 15 deployment target.
        KeyValueRegistry.register(RedisDriver.self)
    }

    var body: some Scene {
        WindowGroup {
            WorkspaceView(checkForUpdates: { appDelegate.updater.checkForUpdates() })
                .frame(minWidth: 900, minHeight: 560)
                .onOpenURL { url in
                    if url.pathExtension.lowercased() == "sql" {
                        WorkspaceViewModel.pendingOpenURLs.append(url)
                        NotificationCenter.default.post(name: .berryDBOpenSQLFile, object: url)
                    }
                }
        }
        .handlesExternalEvents(matching: ["*"])
 .windowToolbarStyle(.unifiedCompact) // shorter title bar
 // open with a generous default so content shows without
        // scrolling wherever the screen allows.
        .defaultSize(width: 1240, height: 800)
        .commands {
 // Sparkle auto-update entry. No-op in
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
 // The full BerryDB menu bar — File/Query/Database/
            // Intelligence/View, all keyboard-navigable.
            WorkspaceCommands()
        }

 // Settings (⌘): customizable keyboard shortcuts.
        Settings {
            ShortcutSettingsView()
        }

 // A tab moved into its own window (D1) — same document and
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
    private let updaterAutoStart = UpdaterAutoStart()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        warnIfRunningFromAVolumeThatCanVanish()

        // Arms Sparkle's own background-check timer a few seconds from now
        // (see UpdaterAutoStart.delay) so update checks happen every launch,
        // not only when the user opens "Check for Updates…" — without
        // starting Sparkle in this same call, which is the collision with
        // the Gatekeeper quarantine re-scan that `startingUpdater: false`
        // exists to avoid.
        updaterAutoStart.run(updater: updater)

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


    // MARK: - Running from a volume that can vanish

    /// Launched from the mounted .dmg, the app dies with SIGBUS the moment the
    /// image is ejected — see `InstallLocation` for why nothing can catch it.
    /// The only useful moment to say so is now, before there is unsaved work.
    private func warnIfRunningFromAVolumeThatCanVanish() {
        let bundleURL = Bundle.main.bundleURL
        let values = try? bundleURL.resourceValues(forKeys: [
            .volumeIsReadOnlyKey, .volumeIsRemovableKey,
        ])
        let location = InstallLocation.of(
            bundlePath: bundleURL.path,
            isRemovable: values?.volumeIsRemovable ?? false,
            isReadOnly: values?.volumeIsReadOnly ?? false)
        guard location.needsMoving else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Move BerryDB to Applications")
        alert.informativeText = switch location {
        case .diskImage:
            String(localized: """
                BerryDB is running from the disk image it was downloaded in. \
                Ejecting that image quits the app immediately, without saving.

                Drag BerryDB into Applications and open it from there.
                """)
        case .translocated:
            String(localized: """
                macOS is running BerryDB from a temporary read-only copy, which \
                happens the first time a downloaded app is opened outside \
                Applications. That copy can disappear at any time.

                Move BerryDB into Applications and open it from there.
                """)
        default:
            String(localized: """
                BerryDB is running from a volume that can be detached while it \
                is open. If that happens the app quits immediately, without saving.

                Move BerryDB into Applications and open it from there.
                """)
        }
        alert.addButton(withTitle: String(localized: "Move to Applications"))
        alert.addButton(withTitle: String(localized: "Continue Anyway"))

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        moveToApplicationsAndRelaunch(from: bundleURL)
    }

    private func moveToApplicationsAndRelaunch(from source: URL) {
        let destination = URL(fileURLWithPath: "/Applications")
            .appendingPathComponent(source.lastPathComponent)
        let fm = FileManager.default

        // An installed copy already being there is the ordinary case: the user
        // installed it earlier and opened the disk image again by accident.
        // Launch what they already have rather than overwrite it.
        if !fm.fileExists(atPath: destination.path) {
            do {
                try fm.copyItem(at: source, to: destination)
            } catch {
                // Copying can fail for reasons the app cannot fix from here
                // (no permission, disk full). Do not pretend otherwise: put the
                // Finder in front of them with both folders and let them drag.
                NSWorkspace.shared.activateFileViewerSelecting([source])
                return
            }
        }

        NSWorkspace.shared.openApplication(
            at: destination, configuration: NSWorkspace.OpenConfiguration()
        ) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        for filename in filenames {
            let url = URL(fileURLWithPath: filename)
            if url.pathExtension.lowercased() == "sql" {
                WorkspaceViewModel.pendingOpenURLs.append(url)
                NotificationCenter.default.post(name: .berryDBOpenSQLFile, object: url)
            }
        }
        sender.reply(toOpenOrPrint: .success)
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
    /// Bounded at 3s: quitting the app must never hang if an external driver
    /// connection close takes longer than expected. Whichever finishes first wins;
    /// any uncompleted cleanup is abandoned as the process terminates.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Disarm RelaunchWatchdog: this call proves the host actually
        // received and is acting on a real termination request (Cmd-Q, or
        // Sparkle's own install-and-relaunch signal succeeding), so any
        // pending "the relaunch handoff looks stuck" timer is now moot. See
        // AppUpdater.swift's RelaunchWatchdog doc comment.
        updater.cancelPendingRelaunchWatchdog()

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
