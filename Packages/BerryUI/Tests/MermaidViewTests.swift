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
        let onProxy: (ScrollViewProxy) -> Void
        var body: some View {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        Color.clear.frame(height: 3000).id("top")
                        MermaidBlock(source: sample).id("diagram")
                        Color.clear.frame(height: 3000).id("bottom")
                    }
                }
                .frame(width: 500, height: 300)
                .onAppear { onProxy(proxy) }
            }
        }
    }

    @Test func diagramMeasuresItsRealHeightEvenWhenFirstLaidOutAtZeroSize() async throws {
        var proxy: ScrollViewProxy?
        let hosting = NSHostingView(rootView: Harness(onProxy: { proxy = $0 }))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)

        for _ in 0..<10 { try await Task.sleep(nanoseconds: 50_000_000) }
        proxy?.scrollTo("diagram", anchor: .center)
        for _ in 0..<60 { try await Task.sleep(nanoseconds: 50_000_000) }

        let webView = try #require(findWebView(hosting))
        #expect(webView.frame.height > 100, "diagram stuck at the near-zero measurement floor: \(webView.frame.height)")
    }
}
