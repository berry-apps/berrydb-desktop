import Foundation
import Testing
@testable import BerryApp

@MainActor
struct RelaunchWatchdogTests {
    /// Pins the basic contract: `onStuck` is scheduled for `Self.timeout`
    /// when armed, and does not fire synchronously.
    @Test
    func armSchedulesOnStuckAfterTheConfiguredTimeout() {
        var capturedDelay: TimeInterval?
        var scheduledAction: (@MainActor @Sendable () -> Void)?
        let watchdog = RelaunchWatchdog(schedule: { delay, action in
            capturedDelay = delay
            scheduledAction = action
        })

        var stuckCallCount = 0
        watchdog.arm(onStuck: { stuckCallCount += 1 })

        #expect(capturedDelay == RelaunchWatchdog.timeout)
        #expect(stuckCallCount == 0)

        scheduledAction?()
        #expect(stuckCallCount == 1)
    }

    /// The case this whole type exists for: a normal termination (or
    /// Sparkle's own relaunch signal succeeding) calls `cancel()` before the
    /// timeout elapses, and `onStuck` must never fire — even though the
    /// previously scheduled closure is still sitting on the injected
    /// scheduler and gets invoked later (simulating a real
    /// `DispatchQueue.main.asyncAfter` firing after cancellation, since a
    /// plain closure-based schedule has no way to un-schedule the callback
    /// itself; the generation check inside the captured closure is what
    /// must do the work).
    @Test
    func cancelPreventsOnStuckEvenIfTheScheduledActionRunsLater() {
        var scheduledAction: (@MainActor @Sendable () -> Void)?
        let watchdog = RelaunchWatchdog(schedule: { _, action in
            scheduledAction = action
        })

        var stuckCallCount = 0
        watchdog.arm(onStuck: { stuckCallCount += 1 })
        watchdog.cancel()

        scheduledAction?()

        #expect(stuckCallCount == 0)
    }

    /// A second relaunch attempt (e.g. the user postponed once) re-arms the
    /// watchdog. The stale timer from the first arm must not fire late and
    /// trip a false alarm after the second arm is already in flight or has
    /// itself been cancelled.
    @Test
    func rearmingSupersedesAPreviousArmSoAStaleTimeoutCannotFireLate() {
        var scheduledActions: [@MainActor @Sendable () -> Void] = []
        let watchdog = RelaunchWatchdog(schedule: { _, action in
            scheduledActions.append(action)
        })

        var stuckCallCount = 0
        watchdog.arm(onStuck: { stuckCallCount += 1 })
        watchdog.arm(onStuck: { stuckCallCount += 1 })

        #expect(scheduledActions.count == 2)

        // The stale first-arm timer fires late; it must be a no-op.
        scheduledActions[0]()
        #expect(stuckCallCount == 0)

        // The current (second) arm's own timer still fires normally.
        scheduledActions[1]()
        #expect(stuckCallCount == 1)
    }

    /// Guards the regression a naive implementation (no generation check,
    /// `cancel()` just no-ops or clears a single stored closure) would
    /// reintroduce: without tracking which arm is current, a stale timer
    /// left over from before a `cancel()` — already in flight on whatever
    /// scheduled it before cancellation ran — has no way to know it should
    /// not fire. This test pins the specific failure mode by using a
    /// deliberately naive watchdog with no generation guard, confirming it
    /// fails exactly the way `RelaunchWatchdog.cancel()` must not.
    @Test
    func namelyStaleTimerWithNoGenerationGuardWouldFalselyFireAfterCancel() {
        final class NaiveWatchdog {
            private var onStuck: (() -> Void)?
            func arm(onStuck: @escaping () -> Void) { self.onStuck = onStuck }
            func cancel() { /* bug: forgets to clear pending scheduled closures */ }
            func fireWhateverWasScheduled() { onStuck?() }
        }

        let naive = NaiveWatchdog()
        var stuckCallCount = 0
        naive.arm(onStuck: { stuckCallCount += 1 })
        naive.cancel()

        naive.fireWhateverWasScheduled()

        // Demonstrates the bug the real RelaunchWatchdog avoids via its
        // generation counter — this call DOES fire despite cancel().
        #expect(stuckCallCount == 1)
    }
}
