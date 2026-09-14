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
    func checkForUpdates()
}

/// No-op updater for dev / unsigned builds — the app can't self-update outside
/// a signed release, so the menu action just does nothing.
@MainActor
final class NoopUpdater: UpdaterControlling {
    var canCheckForUpdates: Bool { false }
    func checkForUpdates() {}
}

#if canImport(Sparkle)
import Sparkle

@MainActor
final class SparkleUpdater: UpdaterControlling {
    // startingUpdater: false — don't spin Sparkle up at launch. Auto-starting it
    // spawns the updater/XPC helpers from a still-quarantined bundle, which
    // makes Gatekeeper re-scan them on first run and can surface a scary
    // "could not verify" prompt. Start it lazily on the first explicit check.
    private let controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
    )
    private var started = false

    var canCheckForUpdates: Bool { started && controller.updater.canCheckForUpdates }

    func checkForUpdates() {
        if !started {
            controller.startUpdater()
            started = true
        }
        controller.checkForUpdates(nil)
    }
}
#endif

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
