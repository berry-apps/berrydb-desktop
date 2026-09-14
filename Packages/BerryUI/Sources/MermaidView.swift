import SwiftUI
import WebKit

/// Renders a ```mermaid diagram offline in a WKWebView. mermaid.min.js is bundled
/// (Sources/Resources), so there is no network at runtime. The rendered height is
/// measured and fed back so the block sizes to its content instead of a fixed box.
struct MermaidBlock: View {
    let source: String
 /// opens this diagram as its own workspace tab — the compact chat
    /// block stays fixed-size/non-interactive; zoom lives in the tab instead
 /// (tab, not a modal, matching the house
    /// convention every other former-sheet tool already follows).
    var onOpenInTab: (String) -> Void = { _ in }
    @Environment(\.colorScheme) private var colorScheme
    @State private var height: CGFloat = 44

    var body: some View {
        MermaidWebView(source: source, isDark: colorScheme == .dark, height: $height)
            .frame(height: height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08), lineWidth: 1))
            // Copy + open-in-tab (top-right), matching code/table blocks.
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 2) {
                    Button { onOpenInTab(source) } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(.borderless)
                    .focusEffectDisabled()
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .help(L("Open in Tab"))

                    CopyButton(text: source, help: L("Copy diagram source"))
                }
                .padding(6)
            }
    }
}

/// Forwards scroll-wheel events straight to the responder chain instead of
/// letting WKWebView consume them for its own (unused, since the inline
/// block has `overflow:hidden` and no scroll content) internal scrolling —
/// without this, the diagram intercepted every scroll gesture that passed
/// over it, so scrolling the chat transcript stalled mid-diagram.
private final class NonScrollingWKWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

private struct MermaidWebView: NSViewRepresentable {
    let source: String
    let isDark: Bool
    @Binding var height: CGFloat
 /// the tab preview passes `true` so the page scrolls instead of
    /// clipping once `zoom` scales the diagram past the viewport; the inline
    /// chat block leaves this `false` and never calls `setZoom`, so its
    /// existing fixed-to-content sizing is untouched.
    var zoomable = false
    var zoom: Double = 1
    /// Reports zoom changes driven from inside the page — trackpad pinch or a
    /// middle-mouse drag — back to SwiftUI, so the tab's percentage label and
    /// +/- disabled state stay in sync with gestures that never go through
    /// the buttons at all. `nil` for the inline chat block, which never
    /// zooms.
    var onZoomChanged: ((Double) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "sizeChanged")
        config.userContentController.add(context.coordinator, name: "zoomChanged")
        // Only the zoomable tab variant wants the wheel itself (pan,
        // ctrlKey-pinch zoom) — see NonScrollingWKWebView above.
        let webView = zoomable
            ? WKWebView(frame: .zero, configuration: config)
            : NonScrollingWKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground") // sit on the SwiftUI surface
        render(webView, context: context)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Reassigned on every update (not just at creation): `onZoomChanged`
        // is a fresh closure each time `MermaidTabView.body` re-evaluates,
        // and the coordinator is otherwise only built once per view identity.
        context.coordinator.onZoomChanged = onZoomChanged
        guard context.coordinator.lastSource != source || context.coordinator.lastDark != isDark else {
            guard zoomable, context.coordinator.lastZoom != zoom else { return }
            context.coordinator.lastZoom = zoom
            webView.evaluateJavaScript("window.mermaidSetZoom && window.mermaidSetZoom(\(zoom))")
            return
        }
        render(webView, context: context)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "sizeChanged")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "zoomChanged")
    }

    private func render(_ webView: WKWebView, context: Context) {
        context.coordinator.lastSource = source
        context.coordinator.lastDark = isDark
        context.coordinator.lastZoom = zoom
        context.coordinator.onZoomChanged = onZoomChanged
        webView.loadHTMLString(Self.html(source: source, isDark: isDark, zoomable: zoomable, zoom: zoom), baseURL: nil)
    }

    /// mermaid.min.js read once and reused; empty if the resource is missing.
    private static let mermaidJS: String = {
        guard let url = berryModuleBundle.url(forResource: "mermaid.min", withExtension: "js"),
              let js = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return js
    }()

    private static func htmlEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func html(source: String, isDark: Bool, zoomable: Bool, zoom: Double) -> String {
 // the tab preview pans by dragging the diagram itself instead
        // of scrolling the page — overflow stays hidden (no scrollbar
        // chrome) in both modes, and `.mermaid` is absolutely centered so
        // mouse-drag / trackpad-wheel deltas can move it with a translate.
        // The inline chat block (zoomable=false) never runs any of this —
        // `mermaidSetZoom` is never called there — so its original
        // flow-based centering/auto-height-via-scrollHeight is untouched.
        let bodyStyle = zoomable ? "overflow:hidden; height:100%; cursor:grab;" : "overflow:hidden;"
        let mermaidStyle = zoomable
            ? "position:absolute; top:50%; left:50%;"
            : "display:flex; justify-content:center;"
        // Mermaid's `useMaxWidth` default shrinks the SVG to fit its
        // container — wanted for the inline chat block, but it made the
        // tab's "100%" already-shrunk, so a large diagram read as tiny even
        // at max zoom. Render at native size in the tab instead;
        // `fitToWindowScript` below then picks a sensible initial zoom.
        let svgStyle = zoomable ? ".mermaid svg { max-width: none !important; }" : ""
        // Bounds must match MermaidTabView.minZoom/maxZoom (Swift) — gesture-
        // driven zoom has no other source of truth to clamp against.
        let interactionScript = zoomable ? """
              let panX = 0, panY = 0, lastX = 0, lastY = 0;
              let panDragging = false, zoomDragging = false;
              const minZoom = 0.1, maxZoom = 5.0;
              const applyTransform = () => {
                el.style.transform = 'translate(-50%,-50%) translate(' + panX + 'px,' + panY + 'px) scale(' + zoomLevel + ')';
              };
              // Echoes a gesture-driven zoom change back to Swift so the
              // toolbar's percentage label / +/- disabled state don't go
              // stale — the buttons aren't the only thing changing zoomLevel
              // anymore.
              const notifyZoomChanged = () => {
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.zoomChanged) {
                  window.webkit.messageHandlers.zoomChanged.postMessage(zoomLevel);
                }
              };
              document.body.addEventListener('mousedown', (e) => {
                lastX = e.clientX; lastY = e.clientY;
                if (e.button === 1) {
                  // Middle-mouse drag zooms instead of panning: up = in, down = out.
                  zoomDragging = true;
                  e.preventDefault();
                } else {
                  panDragging = true;
                  document.body.style.cursor = 'grabbing';
                }
              });
              window.addEventListener('mousemove', (e) => {
                if (panDragging) {
                  panX += e.clientX - lastX; panY += e.clientY - lastY;
                  lastX = e.clientX; lastY = e.clientY;
                  applyTransform();
                } else if (zoomDragging) {
                  const dy = lastY - e.clientY;
                  lastX = e.clientX; lastY = e.clientY;
                  zoomLevel = Math.min(maxZoom, Math.max(minZoom, zoomLevel + dy * 0.01));
                  applyTransform();
                  notifyZoomChanged();
                }
              });
              window.addEventListener('mouseup', () => {
                panDragging = false; zoomDragging = false;
                document.body.style.cursor = 'grab';
              });
              // Trackpad two-finger pan arrives as wheel deltas in WKWebView
              // (no touch events on macOS) — overflow:hidden means the page
              // never natively scrolls, so this is what actually moves it.
              // A two-finger PINCH arrives as a wheel event too, but with
              // ctrlKey set — the platform convention Safari/Chrome both use
              // to tell "pinch to zoom" apart from "two-finger scroll" when
              // neither fires a real touch/gesture event inside a WKWebView.
              document.body.addEventListener('wheel', (e) => {
                e.preventDefault();
                if (e.ctrlKey) {
                  zoomLevel = Math.min(maxZoom, Math.max(minZoom, zoomLevel - e.deltaY * 0.01));
                  applyTransform();
                  notifyZoomChanged();
                } else {
                  panX -= e.deltaX; panY -= e.deltaY;
                  applyTransform();
                }
              }, { passive: false });
              window.mermaidSetZoom = (z) => { zoomLevel = z; applyTransform(); };
            """ : """
              window.mermaidSetZoom = (z) => {
                zoomLevel = z;
                if (el) el.style.transform = 'scale(' + z + ')';
              };
            """
        // Runs once, right after the SVG is rendered at its native size
        // (`svgStyle` above), before any zoom is applied — so this measures
        // real content size, not an already-scaled one. Only ever zooms OUT
        // to fit a large diagram; a diagram smaller than the viewport keeps
        // the caller-provided initial `zoom` (typically 100%) instead of
        // being force-enlarged.
        let fitToWindowScript = zoomable ? """
            {
              const svg = el.querySelector('svg');
              if (svg) {
                const rect = svg.getBoundingClientRect();
                if (rect.width > 0 && rect.height > 0) {
                  const fit = Math.max(minZoom, Math.min(1, (window.innerWidth - 40) / rect.width, (window.innerHeight - 40) / rect.height));
                  if (fit < 1) { zoomLevel = fit; notifyZoomChanged(); }
                }
              }
            }
            """ : ""
        // securityLevel:strict — the diagram source comes from the model, so no
        // click handlers / raw HTML in labels.
        return """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <style>
          html,body { margin:0; padding:8px; background:transparent;
                      \(bodyStyle)
                      font-family:-apple-system,system-ui,sans-serif; }
          .mermaid { \(mermaidStyle) transform-origin:center center; }
          \(svgStyle)
          .err { color:#e5534b; font:12px/1.4 ui-monospace,monospace; white-space:pre-wrap; }
        </style>
        <script>\(mermaidJS)</script>
        </head><body>
        <div class="mermaid">\(htmlEscape(source))</div>
        <script>
          let zoomLevel = \(zoom);
          const el = document.querySelector('.mermaid');
          \(interactionScript)
          const reportHeight = () => {
            const h = Math.ceil(document.body.scrollHeight) + 4;
            window.webkit.messageHandlers.sizeChanged.postMessage(h);
          };
          // A block inside a LazyVStack can have `loadHTMLString` fire
          // while AppKit has only given it a 0x0 frame (SwiftUI lays out
          // on a later pass) — mermaid renders against that zero-width
          // viewport, and a one-shot measurement would stick forever even
          // after the real frame arrives. Re-measure on every resize instead.
          new ResizeObserver(reportHeight).observe(document.body);
          mermaid.initialize({ startOnLoad:false, theme:"\(isDark ? "dark" : "default")", securityLevel:"strict" });
          (async () => {
            try { await mermaid.run(); }
            catch (e) { document.body.innerHTML = '<div class="err">'+ ((e && e.message) || e) +'</div>'; }
            \(fitToWindowScript)
            if (window.mermaidSetZoom) window.mermaidSetZoom(zoomLevel);
            reportHeight();
          })();
        </script>
        </body></html>
        """
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        let height: Binding<CGFloat>
        var lastSource = ""
        var lastDark = false
        var lastZoom: Double = 1
        var onZoomChanged: ((Double) -> Void)?

        init(height: Binding<CGFloat>) { self.height = height }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let value = message.body as? Double else { return }
            switch message.name {
            case "sizeChanged":
                height.wrappedValue = max(CGFloat(value), 24)
            case "zoomChanged":
                // Set before calling back out so the next `updateNSView`
                // (triggered by the `zoom` state this callback updates) sees
                // `lastZoom == zoom` already and skips re-sending it to the
                // page it just came from.
                lastZoom = value
                onZoomChanged?(value)
            default:
                break
            }
        }
    }
}

/// a chat-rendered diagram opened into its own tab (`WorkspaceViewModel
/// .openMermaidDiagram`, `WorkspaceTab.mermaidDiagram`) — the room a small
/// chat bubble can't give, with real zoom controls instead of the compact
/// block's fixed-to-content sizing.
struct MermaidTabView: View {
    let source: String
    @Environment(\.colorScheme) private var colorScheme
    @State private var zoom: Double = 1
    // Fed by the same `sizeChanged` channel `MermaidBlock` uses, but unused
    // here — this view sizes to the pane, not to the diagram's content.
    @State private var contentHeight: CGFloat = 44

    // Must match the JS `minZoom`/`maxZoom` constants in
    // `MermaidWebView.html(...)` — gesture-driven zoom in the web view has no
    // other source of truth to clamp against.
    private static let minZoom = 0.1
    private static let maxZoom = 5.0
    // Multiplicative rather than additive: an additive step that felt right
    // at the old 50-300% range would be a huge jump near the new 10% floor
    // and barely perceptible near the new 500% ceiling.
    private static let stepFactor = 1.25

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Spacer()
                Button { zoom = max(Self.minZoom, zoom / Self.stepFactor) } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .buttonStyle(IconButtonStyle())
                .disabled(zoom <= Self.minZoom)
                .help(L("Zoom Out"))

                Text("\(Int((zoom * 100).rounded()))%")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .frame(minWidth: 36)

                Button { zoom = min(Self.maxZoom, zoom * Self.stepFactor) } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .buttonStyle(IconButtonStyle())
                .disabled(zoom >= Self.maxZoom)
                .help(L("Zoom In"))

                Divider().frame(height: 14).padding(.horizontal, 2)

                Button { zoom = 1 } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(IconButtonStyle())
                .disabled(zoom == 1)
                .help(L("Reset Zoom"))

                Divider().frame(height: 14).padding(.horizontal, 2)

                CopyButton(text: source, help: L("Copy diagram source"))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)

            Divider()

            MermaidWebView(
                source: source, isDark: colorScheme == .dark, height: $contentHeight,
                zoomable: true, zoom: zoom, onZoomChanged: { zoom = $0 }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Load-bearing: without this, the VStack hugs its content instead of
        // claiming the pane, so the WKWebView below gets squeezed down to a
        // tiny AppKit-default size — the diagram then overflows THAT tiny
        // viewport and shows a scrollbar despite visibly empty space around
        // the whole block, causing the diagram height to collapse unnecessarily.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
