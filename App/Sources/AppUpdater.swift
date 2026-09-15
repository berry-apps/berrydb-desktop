import AppKit
import Foundation

/// Auto-update entry point. Sparkle is a binary
/// framework that only works from a signed `.app` bundle, so the default
/// SwiftPM build (tests, `swift run`, the size guard) ships WITHOUT it and the
/// menu is a no-op. A release build adds the Sparkle SPM product (see
/// deploy/README.md) — `canImport(Sparkle)` then compiles the real updater and
/// the `.app`-bundle guard activates it.
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
}

/// No-op updater for dev / unsigned builds — the app can't self-update outside
/// a signed release, so the menu action just does nothing.
@MainActor
final class NoopUpdater: UpdaterControlling {
    var canCheckForUpdates: Bool { false }
    func startIfNeeded() {}
    func checkForUpdates() {}
}

#if canImport(Sparkle)
import Sparkle

@MainActor
final class SparkleUpdater: UpdaterControlling {
    // startingUpdater: false — don't spin Sparkle up in the same instant as
    // applicationDidFinishLaunching. Auto-starting it there spawns the
    // updater/XPC helpers from a still-quarantined bundle, which makes
    // Gatekeeper re-scan them on first run and can surface a scary "could
    // not verify" prompt. `AppDelegate` starts it a few seconds later
    // instead (see `UpdaterAutoStart`), and the "Check for Updates…" menu
    // item can also start it on demand via `checkForUpdates()`.
    private let controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
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
