import AppKit
import Foundation

/// Auto-update entry point (docs/architecture/10 §3). Sparkle is a binary
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

/// Real Sparkle updater from a signed `.app`; a no-op everywhere else.
@MainActor
func makeUpdater() -> any UpdaterControlling {
    #if canImport(Sparkle)
    if Bundle.main.bundleURL.pathExtension == "app" {
        return SparkleUpdater()
    }
    #endif
    return NoopUpdater()
}
