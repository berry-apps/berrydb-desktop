import SwiftUI
import WebKit

/// Renders a ```mermaid diagram offline in a WKWebView. mermaid.min.js is bundled
/// (Sources/Resources), so there is no network at runtime. The rendered height is
/// measured and fed back so the block sizes to its content instead of a fixed box.
struct MermaidBlock: View {
    let source: String
    @Environment(\.colorScheme) private var colorScheme
    @State private var height: CGFloat = 44

    var body: some View {
        MermaidWebView(source: source, isDark: colorScheme == .dark, height: $height)
            .frame(height: height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08), lineWidth: 1))
            // Copy the diagram source (top-right), matching code/table blocks.
            .overlay(alignment: .topTrailing) {
                CopyButton(text: source, help: L("Copy diagram source"))
                    .padding(6)
            }
    }
}

private struct MermaidWebView: NSViewRepresentable {
    let source: String
    let isDark: Bool
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "sizeChanged")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground") // sit on the SwiftUI surface
        render(webView, context: context)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.lastSource != source || context.coordinator.lastDark != isDark else { return }
        render(webView, context: context)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "sizeChanged")
    }

    private func render(_ webView: WKWebView, context: Context) {
        context.coordinator.lastSource = source
        context.coordinator.lastDark = isDark
        webView.loadHTMLString(Self.html(source: source, isDark: isDark), baseURL: nil)
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

    private static func html(source: String, isDark: Bool) -> String {
        // securityLevel:strict — the diagram source comes from the model, so no
        // click handlers / raw HTML in labels.
        """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <style>
          html,body { margin:0; padding:8px; background:transparent; overflow:hidden;
                      font-family:-apple-system,system-ui,sans-serif; }
          .mermaid { display:flex; justify-content:center; }
          .err { color:#e5534b; font:12px/1.4 ui-monospace,monospace; white-space:pre-wrap; }
        </style>
        <script>\(mermaidJS)</script>
        </head><body>
        <div class="mermaid">\(htmlEscape(source))</div>
        <script>
          mermaid.initialize({ startOnLoad:false, theme:"\(isDark ? "dark" : "default")", securityLevel:"strict" });
          (async () => {
            try { await mermaid.run(); }
            catch (e) { document.body.innerHTML = '<div class="err">'+ ((e && e.message) || e) +'</div>'; }
            const h = Math.ceil(document.body.scrollHeight) + 4;
            window.webkit.messageHandlers.sizeChanged.postMessage(h);
          })();
        </script>
        </body></html>
        """
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        let height: Binding<CGFloat>
        var lastSource = ""
        var lastDark = false

        init(height: Binding<CGFloat>) { self.height = height }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "sizeChanged", let value = message.body as? Double else { return }
            height.wrappedValue = max(CGFloat(value), 24)
        }
    }
}
