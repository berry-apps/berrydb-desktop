import AppKit
import Foundation

/// Auto-update entry point. The Sparkle SPM product is an unconditional
/// dependency of the `BerryApp` target (see `Package.swift`), so
/// `canImport(Sparkle)` compiles the real `SparkleUpdater` for every build —
/// `swift build`/`swift test`/`swift run` included, not only a packaged
/// release. Whether it's actually *used* at runtime is a separate, deliberate
/// check in `makeUpdater()` below (a real `.app` bundle with `SUFeedURL` set);
/// see its own doc comment. See deploy/README.md.
@MainActor
protocol UpdaterControlling {
    var canCheckForUpdates: Bool { get }

    /// Starts the updater (arming Sparkle's own background-check timer)
    /// WITHOUT triggering a visible check right now. Idempotent — safe to
    /// call more than once per launch. This is what the delayed
    /// auto-start (`UpdaterAutoStart`) calls; `checkForUpdates()` is what the
    /// explicit "Check for Updates…" menu item calls, and additionally shows
    /// UI immediately.
    func startIfNeeded()
    func checkForUpdates()

    /// Called from `applicationShouldTerminate` — the earliest point a real
    /// termination (a normal Cmd-Q, or Sparkle's own install-and-relaunch
    /// signal actually succeeding) is known about. Disarms
    /// `RelaunchWatchdog` before its timeout can fire; a no-op otherwise.
    /// See `RelaunchWatchdog`'s doc comment for why this exists.
    func cancelPendingRelaunchWatchdog()
}

/// No-op updater for dev / unsigned builds — the app can't self-update outside
/// a signed release, so the menu action just does nothing.
@MainActor
final class NoopUpdater: UpdaterControlling {
    var canCheckForUpdates: Bool { false }
    func startIfNeeded() {}
    func checkForUpdates() {}
    func cancelPendingRelaunchWatchdog() {}
}

/// Bounded wait for "Install and Relaunch" to actually terminate the host.
///
/// Sparkle's install/relaunch handoff (see `Sparkle/InstallerProgress/
/// InstallerProgressAppController.m` in the framework source,
/// `-sendTerminationSignal`) signals the running host to quit from a
/// separate, out-of-process helper by calling `-[NSRunningApplication
/// terminate]` — an Apple Event (`kAEQuitApplication`) sent across process
/// boundaries, not an in-process API call BerryDB's own code ever sees. That
/// call has no return-value/error handling in Sparkle itself, and unlike the
/// two earlier phases of the same handoff (agent-connection and
/// extraction-start both have their own ~7s timeouts inside Sparkle), there
/// is no timeout anywhere in Sparkle's source for "host was asked to quit,
/// now wait for it to actually die" — if that Apple Event is silently
/// dropped for any reason (observed once, root cause not confirmed from this
/// environment — see AppUpdater tests / PR description), the two Sparkle
/// helper processes (`Autoupdate`, the install-progress agent) sit blocked
/// on `mach_msg` forever with no user-visible error.
///
/// This does not fix that delivery problem — it cannot, since it lives
/// entirely in Sparkle's own out-of-process helpers, outside code this app
/// controls. It bounds the *symptom*: if the host is still alive
/// `Self.timeout` seconds after Sparkle told it a relaunch is imminent
/// (`SPUUpdaterDelegate.updaterWillRelaunchApplication`), something has gone
/// wrong, and the user gets a visible, actionable alert instead of an
/// indefinite silent hang.
///
/// The `schedule` closure is injected (same pattern as `UpdaterAutoStart`)
/// so the timing decision — arm once per relaunch attempt, cancel on a real
/// termination, never let a stale timer outlive a cancel — can be tested
/// without waiting in real time.
@MainActor
final class RelaunchWatchdog {
    /// Generous relative to the observed case (extraction completed in ~2s;
    /// this app's own `applicationShouldTerminate` bounds its cleanup at
    /// 3s) so a slow disk during the actual bundle swap doesn't trip a false
    /// alarm, while still being short enough that a genuine hang surfaces
    /// well before a user gives up and force-quits by hand. Not verified
    /// against a real slow-disk relaunch — this environment cannot drive a
    /// signed update end-to-end (see PR description).
    static let timeout: TimeInterval = 20

    private let schedule: (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void
    private var armedGeneration = 0

    init(
        schedule: @escaping (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void = { delay, action in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
        }
    ) {
        self.schedule = schedule
    }

    /// Arms the watchdog for one relaunch attempt. `onStuck` fires after
    /// `Self.timeout` unless `cancel()` runs first. Re-arming (the user
    /// postpones once, then installs again) bumps the generation so a
    /// still-pending timer from an earlier arm can't fire after the new one
    /// — only the most recent arm's timeout is ever live.
    func arm(onStuck: @escaping @MainActor @Sendable () -> Void) {
        armedGeneration += 1
        let generation = armedGeneration
        schedule(Self.timeout) { [weak self] in
            guard let self, self.armedGeneration == generation else { return }
            onStuck()
        }
    }

    /// Disarms whatever is currently armed. Safe to call when nothing is
    /// armed (every ordinary app quit calls this via
    /// `UpdaterControlling.cancelPendingRelaunchWatchdog()`).
    func cancel() {
        armedGeneration += 1
    }
}

#if canImport(Sparkle)
import Sparkle

/// `SPUUpdaterDelegate` implementation whose only job is arming/disarming
/// `RelaunchWatchdog`. Kept separate from `SparkleUpdater` so the one method
/// that actually needs to import and conform to Sparkle's ObjC delegate
/// protocol is isolated from the rest of the updater-control logic — see
/// `RelaunchWatchdog`'s doc comment for why this exists.
@MainActor
final class SparkleRelaunchWatchdogDelegate: NSObject, SPUUpdaterDelegate {
    private let watchdog: RelaunchWatchdog
    private let onStuck: @MainActor @Sendable () -> Void

    init(watchdog: RelaunchWatchdog = RelaunchWatchdog(), onStuck: @escaping @MainActor @Sendable () -> Void) {
        self.watchdog = watchdog
        self.onStuck = onStuck
    }

    // Fires immediately before Sparkle's out-of-process helper asks the host
    // to quit (see `SPUCoreBasedUpdateDriver.installerWillFinishInstallationAndRelaunch:`
    // in the framework source) — the right moment to start counting.
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        watchdog.arm(onStuck: onStuck)
    }

    func cancelPendingRelaunchWatchdog() {
        watchdog.cancel()
    }
}

@MainActor
final class SparkleUpdater: UpdaterControlling {
    private let relaunchWatchdogDelegate = SparkleRelaunchWatchdogDelegate(
        onStuck: SparkleUpdater.presentStuckRelaunchAlert
    )

    // startingUpdater: false — don't spin Sparkle up in the same instant as
    // applicationDidFinishLaunching. Auto-starting it there spawns the
    // updater/XPC helpers from a still-quarantined bundle, which makes
    // Gatekeeper re-scan them on first run and can surface a scary "could
    // not verify" prompt. `AppDelegate` starts it a few seconds later
    // instead (see `UpdaterAutoStart`), and the "Check for Updates…" menu
    // item can also start it on demand via `checkForUpdates()`.
    //
    // updaterDelegate: relaunchWatchdogDelegate — arms/disarms
    // `RelaunchWatchdog` around the install/relaunch handoff (see
    // `RelaunchWatchdog`'s doc comment). userDriverDelegate stays nil: the
    // default `SPUStandardUserDriver` UI (progress bar, alerts) is
    // unchanged; only the delegate hook for the relaunch handoff is added.
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: relaunchWatchdogDelegate, userDriverDelegate: nil
    )
    private var started = false

    var canCheckForUpdates: Bool { started && controller.updater.canCheckForUpdates }

    func startIfNeeded() {
        guard !started else { return }
        controller.startUpdater()
        started = true
    }

    func checkForUpdates() {
        startIfNeeded()
        controller.checkForUpdates(nil)
    }

    func cancelPendingRelaunchWatchdog() {
        relaunchWatchdogDelegate.cancelPendingRelaunchWatchdog()
    }

    /// Shown when `RelaunchWatchdog` trips: the host is still alive well
    /// after Sparkle's helper should have asked it to quit. Quitting now
    /// re-runs this app's own `applicationShouldTerminate` path, which ends
    /// the process — Sparkle's helpers watch for the host process actually
    /// exiting via a kernel process-exit notification (`kqueue`/`NOTE_EXIT`
    /// in `Autoupdate`, KVO on `NSRunningApplication.isTerminated` in the
    /// install-progress agent — see `Sparkle/Autoupdate/
    /// TerminationListener.m` and `Sparkle/InstallerProgress/
    /// InstallerProgressAppController.m` in the framework source), not for
    /// the specific Apple Event that failed to arrive. Once the process
    /// actually exits, whichever helper is still waiting proceeds with the
    /// swap/relaunch exactly as if the normal signal had succeeded.
    private static func presentStuckRelaunchAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Update Installer Isn't Responding")
        alert.informativeText = String(localized: """
            BerryDB asked its update installer to restart the app, but it hasn't \
            responded. The installer may still be waiting for BerryDB to quit — \
            quitting now can let it finish; otherwise check for the update again \
            after quitting.
            """)
        alert.addButton(withTitle: String(localized: "Quit Now"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        NSApp.terminate(nil)
    }
}
#endif

/// Starts the updater's own background-check timer once per launch, a few
/// seconds after `applicationDidFinishLaunching`, so a session that never
/// opens "Check for Updates…" still eventually has the Sparkle timer armed.
/// The actual `DispatchQueue.main.asyncAfter` call is injected via
/// `schedule` so the scheduling *decision* (call `startIfNeeded()`, once,
/// after `delay`) can be tested without waiting in real time and without the
/// real Sparkle framework — see `UpdaterAutoStartTests`.
@MainActor
struct UpdaterAutoStart {
    /// Long enough to be well clear of the exact instant of
    /// `applicationDidFinishLaunching`, where `SparkleUpdater`'s own doc
    /// comment explains that starting Sparkle collides with Gatekeeper's
    /// quarantine re-scan of the updater/XPC helper binaries and can surface
    /// a scary "could not verify" prompt; short enough that it still happens
    /// early in the same session rather than risking never firing (e.g. the
    /// user quits before a longer delay would elapse). `startIfNeeded()`
    /// shows no UI, so the exact value is not user-visible either way.
    static let delay: TimeInterval = 4

    let schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void

    init(
        schedule: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, action in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
        }
    ) {
        self.schedule = schedule
    }

    func run(updater: any UpdaterControlling) {
        schedule(Self.delay) {
            updater.startIfNeeded()
        }
    }
}

/// Real Sparkle updater from a signed `.app` whose Info.plist actually
/// carries a feed URL; a no-op everywhere else.
///
/// `scripts/run.sh` packages even a plain debug dev build into a real
/// `dist/BerryDB.app` (so Dock/Force-Quit show the right icon) — the
/// `.app`-extension check alone can't tell that apart from a signed release,
/// but `make_app.sh` only ever writes `SUFeedURL` when `SU_PUBLIC_ED_KEY` is
/// set (a real release build). Without this second check, a dev build's
/// `checkForUpdates()` reached real Sparkle with no feed configured and
/// crashed with "You must specify the URL of the appcast as the SUFeedURL
/// key…" instead of silently no-op'ing like every other dev/unsigned build.
@MainActor
func makeUpdater() -> any UpdaterControlling {
    #if canImport(Sparkle)
    if Bundle.main.bundleURL.pathExtension == "app",
       let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
       !feedURL.isEmpty {
        return SparkleUpdater()
    }
    #endif
    return NoopUpdater()
}
