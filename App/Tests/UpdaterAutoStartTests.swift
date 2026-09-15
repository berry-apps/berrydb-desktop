import Foundation
import Testing
@testable import BerryApp

/// Records calls instead of touching any real updater (Sparkle or
/// otherwise) — lets us test the launch-time scheduling decision in
/// isolation, per `UpdaterControlling`'s own purpose as a substitution seam.
@MainActor
final class RecordingUpdater: UpdaterControlling {
    private(set) var startIfNeededCallCount = 0
    private(set) var checkForUpdatesCallCount = 0
    private(set) var cancelPendingRelaunchWatchdogCallCount = 0

    var canCheckForUpdates: Bool { false }

    func startIfNeeded() {
        startIfNeededCallCount += 1
    }

    func checkForUpdates() {
        checkForUpdatesCallCount += 1
    }

    func cancelPendingRelaunchWatchdog() {
        cancelPendingRelaunchWatchdogCallCount += 1
    }
}

@MainActor
struct UpdaterAutoStartTests {
    /// Pins the launch-time scheduling decision — call `startIfNeeded()`,
    /// exactly once, after `UpdaterAutoStart.delay` — without depending on
    /// real time or the real Sparkle framework: the scheduler itself is
    /// injected, so the test controls when the delayed action actually runs.
    @Test
    func schedulesStartIfNeededAfterTheConfiguredDelay() {
        let updater = RecordingUpdater()
        var capturedDelay: TimeInterval?
        var scheduledAction: (@MainActor () -> Void)?

        let autoStart = UpdaterAutoStart(schedule: { delay, action in
            capturedDelay = delay
            scheduledAction = action
        })

        autoStart.run(updater: updater)

        // Scheduled, but not run yet — the action must not fire synchronously.
        #expect(capturedDelay == UpdaterAutoStart.delay)
        #expect(updater.startIfNeededCallCount == 0)

        scheduledAction?()

        // Once the delay elapses, it must start the updater's own background
        // timer WITHOUT forcing a visible check — that distinction is the
        // whole point of the fix (see UpdaterControlling.startIfNeeded doc).
        #expect(updater.startIfNeededCallCount == 1)
        #expect(updater.checkForUpdatesCallCount == 0)
    }
}
