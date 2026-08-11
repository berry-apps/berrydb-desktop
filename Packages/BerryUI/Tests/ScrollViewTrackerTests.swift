import AppKit
import SwiftUI
import Testing

@testable import BerryUI

/// Reported live: right after submitting a prompt, the transcript stopped
/// auto-scrolling to the new turns. The diagnostic log showed
/// `isPinnedToBottom -> false` firing repeatedly within the same fraction of
/// a second, with erratic, non-monotonic `distanceToBottom` values (content
/// layout churn from the two new turns being appended, not a human scroll
/// gesture) — right after a `send()` that had just reset `isPinnedToBottom`
/// to `true`.
///
/// Root cause: `ScrollViewTracker.Coordinator.onScrollBoundsChanged` treated
/// ANY bounds change as user-driven scrolling whenever `NSApp.currentEvent`
/// — a global "last dispatched event" reference, not scoped to this specific
/// notification or to whether a scroll session is actually in progress —
/// happened to report `.scrollWheel`/`.leftMouseDragged`. A burst of
/// content-growth-driven bounds-change notifications (submitting a prompt
/// appends the user's turn + an empty assistant placeholder, both laid out
/// over several frames) hit this on every single one, and if the global
/// current event was stale-matching a scroll type, each of those incorrectly
/// unpinned the view.
///
/// The reliable signal for "is a live scroll session actually in progress"
/// already exists: `NSScrollView.willStartLiveScrollNotification`/
/// `didEndLiveScrollNotification`, tracked via `isUserScrolling`. The fix
/// requires that flag to already be true before trusting the global current
/// event to (re-)confirm/extend scrolling — it no longer originates a scroll
/// session on its own from a bounds change alone.
@MainActor
@Suite("ScrollViewTracker.Coordinator — user-scroll detection")
struct ScrollViewTrackerCoordinatorTests {
    private func makeFarFromBottomScrollView() -> NSScrollView {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let documentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 2000))
        scrollView.documentView = documentView
        // Scrolled to the very top: content is 2000pt tall, visible 200pt —
        // far (1800pt) from the 45pt "near bottom" threshold.
        scrollView.contentView.bounds = NSRect(x: 0, y: 0, width: 400, height: 200)
        return scrollView
    }

    private func makeCoordinator(
        isPinnedToBottom: Binding<Bool>, on scrollView: NSScrollView
    ) -> ScrollViewTracker.Coordinator {
        let tracker = ScrollViewTracker(isPinnedToBottom: isPinnedToBottom)
        let coordinator = tracker.makeCoordinator()
        coordinator.setup(scrollView: scrollView, tracker: tracker)
        return coordinator
    }

    /// The exact reported bug, reproduced directly: no live scroll session
    /// ever started, but the global current event looks like scrolling. Must
    /// NOT unpin.
    @Test func aBoundsChangeWithNoLiveScrollSessionNeverUnpinsEvenIfTheGlobalCurrentEventLooksLikeScrolling() async {
        var isPinnedToBottom = true
        let binding = Binding(get: { isPinnedToBottom }, set: { isPinnedToBottom = $0 })
        let scrollView = makeFarFromBottomScrollView()
        let coordinator = makeCoordinator(isPinnedToBottom: binding, on: scrollView)
        // Simulates the bug precisely: the global "current event" happens to
        // be a stale scroll-wheel-shaped event, with no
        // `willStartLiveScrollNotification` ever posted for this scroll view.
        coordinator.currentEventType = { .scrollWheel }

        NotificationCenter.default.post(
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )
        // The unpin write (if it happens) is dispatched via
        // `DispatchQueue.main.async` — give the main queue a turn to drain it
        // before asserting.
        try? await Task.sleep(for: .milliseconds(50))

        #expect(
            isPinnedToBottom,
            "a bounds change with no live scroll session in progress must never unpin, regardless of the global current event"
        )
        #expect(coordinator.isUserScrolling == false)
    }

    /// The behavior this whole mechanism exists for must survive: a REAL
    /// live-scroll session (started via the reliable AppKit notification)
    /// still unpins on a bounds change far from the bottom.
    @Test func aBoundsChangeDuringARealLiveScrollSessionStillUnpins() async {
        var isPinnedToBottom = true
        let binding = Binding(get: { isPinnedToBottom }, set: { isPinnedToBottom = $0 })
        let scrollView = makeFarFromBottomScrollView()
        let coordinator = makeCoordinator(isPinnedToBottom: binding, on: scrollView)
        coordinator.currentEventType = { .scrollWheel }

        NotificationCenter.default.post(
            name: NSScrollView.willStartLiveScrollNotification, object: scrollView
        )
        #expect(coordinator.isUserScrolling, "a real live-scroll notification must still mark scrolling in progress")

        NotificationCenter.default.post(
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )
        try? await Task.sleep(for: .milliseconds(50))

        #expect(isPinnedToBottom == false, "a genuine live scroll away from the bottom must still unpin")
    }

    /// Scrolling back down to the bottom (whether or not it was ever really
    /// "user" scrolling) always re-pins — the near-bottom threshold branch
    /// doesn't depend on `isUserScrolling` at all, and this test pins that.
    @Test func aBoundsChangeNearTheBottomAlwaysRepinsRegardlessOfScrollSource() async {
        var isPinnedToBottom = false
        let binding = Binding(get: { isPinnedToBottom }, set: { isPinnedToBottom = $0 })
        let scrollView = makeFarFromBottomScrollView()
        let coordinator = makeCoordinator(isPinnedToBottom: binding, on: scrollView)
        coordinator.currentEventType = { nil }

        // Move to within the 45pt "near bottom" threshold: content 2000,
        // visible 200 -> bottom is at y=1800; land at y=1760 (40pt away).
        scrollView.contentView.bounds = NSRect(x: 0, y: 1760, width: 400, height: 200)
        NotificationCenter.default.post(
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )
        try? await Task.sleep(for: .milliseconds(50))

        #expect(isPinnedToBottom)
    }

    /// `didEndLiveScrollNotification` must reset `isUserScrolling` so a
    /// LATER content-growth bounds change (with no new live-scroll session)
    /// doesn't keep incorrectly unpinning after the user's real scroll
    /// gesture has already ended.
    @Test func endingALiveScrollResetsUserScrollingSoALaterBoundsChangeDoesNotUnpinAgain() async {
        var isPinnedToBottom = true
        let binding = Binding(get: { isPinnedToBottom }, set: { isPinnedToBottom = $0 })
        let scrollView = makeFarFromBottomScrollView()
        let coordinator = makeCoordinator(isPinnedToBottom: binding, on: scrollView)
        coordinator.currentEventType = { .scrollWheel }

        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
        #expect(coordinator.isUserScrolling == false)

        isPinnedToBottom = true
        NotificationCenter.default.post(
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )
        try? await Task.sleep(for: .milliseconds(50))

        #expect(isPinnedToBottom, "content growth after a scroll gesture has ended must not unpin again")
    }

    /// Reported live: `send()` resetting `isPinnedToBottom = true` and
    /// scrolling immediately still wasn't enough — a real (if brief)
    /// scroll-wheel gesture right around submit time left
    /// `willStartLiveScrollNotification`'s session still open
    /// (`isUserScrolling == true`), so the very next content-growth bounds
    /// change (the two new turns being laid out) read as "user scrolled
    /// away" per the ALREADY-correct rule from the earlier fix in this file
    /// — undoing the explicit scroll moments after it happened.
    /// `forceScrollToBottom()` is the fix: an explicit submit cancels
    /// whatever scroll session was in progress, not just resets the pinned
    /// flag.
    @Test func forceScrollToBottomCancelsAnInProgressLiveScrollSoTheNextBoundsChangeDoesNotReUnpin() async {
        var isPinnedToBottom = false
        let binding = Binding(get: { isPinnedToBottom }, set: { isPinnedToBottom = $0 })
        let scrollView = makeFarFromBottomScrollView()
        let coordinator = makeCoordinator(isPinnedToBottom: binding, on: scrollView)
        coordinator.currentEventType = { .scrollWheel }

        // A real scroll session is genuinely in progress — e.g. the tail of
        // a gesture that happened right before the user hit send.
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        #expect(coordinator.isUserScrolling)

        // The explicit submit action.
        coordinator.forceScrollToBottom()
        #expect(coordinator.isUserScrolling == false)
        #expect(isPinnedToBottom, "forceScrollToBottom must pin immediately, not just cancel the scroll session")

        // The new turns being laid out fires more bounds-change
        // notifications, still with a scroll-shaped global current event —
        // must NOT re-unpin now that the scroll session was cancelled.
        NotificationCenter.default.post(
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )
        try? await Task.sleep(for: .milliseconds(50))

        #expect(isPinnedToBottom, "content growth right after an explicit submit must not re-unpin")
    }
}
