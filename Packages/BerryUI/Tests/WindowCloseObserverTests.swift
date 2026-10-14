import AppKit
import SwiftUI
import Testing

@testable import BerryUI

@MainActor
@Suite("Window close observer")
struct WindowCloseObserverTests {
    /// The workspace's teardown hangs on this: AppKit posts
    /// `NSWindow.willCloseNotification` for the window the observer's view
    /// sits in, whether the user or the app closes it.
    @Test func closingTheWindowRunsTheActionOnce() async throws {
        var closes = 0
        let hosting = NSHostingView(rootView: Color.clear.background(WindowCloseObserver { closes += 1 }))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        // Never ordered on screen, as in the other window tests; closing a
        // window that was never shown still posts the notification.
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        #expect(closes == 0)

        window.close()
        #expect(closes == 1)

        // Another window closing is not this one's close.
        let other = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        other.isReleasedWhenClosed = false
        other.close()
        #expect(closes == 1)
    }
}
