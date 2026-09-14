import AppKit
import SwiftUI
import Testing
import WebKit
@testable import BerryUI

/// Reported live: a large diagram's preview height "shrank" — really, it
/// never grew past a near-zero floor. Root cause: inside a `LazyVStack`,
/// `MermaidWebView.makeNSView` can call `loadHTMLString` while AppKit has
/// only given the view a 0x0 frame (SwiftUI lays it out on a later pass).
/// Mermaid renders against that zero-width viewport, and since the height
/// was only ever measured once (right after `mermaid.run()`), the tiny
/// result stuck forever even after the real frame arrived — reproduces with
/// plain `WKWebView` too, unrelated to the `NonScrollingWKWebView` scroll
/// fix that was in place when it was reported.
@MainActor
@Suite("Mermaid inline block sizing inside a LazyVStack")
struct MermaidViewTests {
    private static let sample = """
    erDiagram
      USER ||--o{ ORDER : places
      ORDER ||--|{ LINE_ITEM : contains
      PRODUCT ||--o{ LINE_ITEM : "ordered in"
      USER {
        int id
        string name
        string email
      }
      ORDER {
        int id
        int userId
        string status
      }
    """

    private func findWebView(_ view: NSView) -> WKWebView? {
        if let webView = view as? WKWebView { return webView }
        for sub in view.subviews {
            if let found = findWebView(sub) { return found }
        }
        return nil
    }

    private struct Harness: View {
        var body: some View {
            ScrollView {
                LazyVStack(spacing: 0) {
                    MermaidBlock(source: sample).id("diagram")
                }
            }
            .frame(width: 500, height: 300)
        }
    }

    @Test func diagramMeasuresItsRealHeightEvenWhenFirstLaidOutAtZeroSize() async throws {
        let hosting = NSHostingView(rootView: Harness())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = hosting
        // Deliberately NOT ordered on screen. `makeKeyAndOrderFront` put a real
        // window on the developer's display for the length of the run — titled but
        // with no close or resize control, because the style mask omits them — and
        // stole keyboard focus while it was there. `backing: .buffered, defer: false`
        // already allocates the backing store at init, so the view tree has a window
        // and a valid geometry context without being visible, and WebKit still lays
        // the page out — checked by running this test with the window never ordered
        // in. The polling loop below, not this layout call, is what the measurement
        // ultimately waits on.
        hosting.layoutSubtreeIfNeeded()

        for _ in 0..<60 {
            try await Task.sleep(nanoseconds: 50_000_000)
            if let webView = findWebView(hosting), webView.frame.height > 100 {
                break
            }
        }

        let webView = try #require(findWebView(hosting))
        #expect(webView.frame.height > 100, "diagram stuck at the near-zero measurement floor: \(webView.frame.height)")
    }
}
