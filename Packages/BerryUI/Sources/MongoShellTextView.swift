import AppKit
import BerryCore
import SwiftUI

/// Mongo shell editor text view — NSTextView with a lightweight lexical
/// highlighter for `db.collection.method(...)` scripts. Mirrors
/// `SQLEditorTextView`'s structure (see that file) so the completion/run/focus
/// infrastructure stays dialect-agnostic; only the highlighter regexes and the
/// (nonexistent, for a script) format/comment-toggle/run-current plumbing
/// differ.
struct MongoShellTextView: NSViewRepresentable {
    @Binding var text: String
    let onCursorMove: (Int) -> Void
    /// Runs the whole script — a Mongo shell tab has no per-statement "current
    /// selection" concept, so ⌘R and ⇧⌘↩ both land here.
    let onRun: () -> Void
    /// Completion source (ED-03): (script, utf16Cursor) → popup rows, already
    /// ranked by the caller.
    var completionItems: ((String, Int) -> [CompletionItem])?
    /// Called when this editor takes keyboard focus (ui.md 01 §4) so the
    /// workspace can activate its split pane.
    var onFocus: (() -> Void)?
    /// One-shot: when true, this editor grabs keyboard focus (docs/ui/03) so a
    /// freshly split/opened pane gets the caret. `onDidFocus` clears it.
    var pendingFocus = false
    var onDidFocus: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = RunnableTextView()
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.autoresizingMask = [.width]
        // Don't accept drops — otherwise dragging a workspace tab over the editor
        // gets inserted as text; the pane's SwiftUI drop handles tab moves/splits
        // (docs/ui/03). The editor never needs drag-in text.
        textView.unregisterDraggedTypes()
        textView.delegate = context.coordinator
        context.coordinator.wireCallbacks(textView)
        context.coordinator.textView = textView
        context.coordinator.wirePopup(into: textView)

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        textView.string = text
        context.coordinator.lastTextLength = (text as NSString).length
        context.coordinator.highlight(textView)
        grabFocusIfNeeded(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView as? RunnableTextView else { return }
        // Re-wire every update: the run closures capture `session`, which is nil
        // on the first render of a tab built before its connection is live. Left
        // stale, ⌘R (which RunnableTextView claims before the menu, ED-04) fires
        // against a nil session and silently no-ops on those tabs.
        context.coordinator.wireCallbacks(textView)
        if textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(NSRange(
                location: min(selection.location, (text as NSString).length),
                length: 0
            ))
            context.coordinator.lastTextLength = (text as NSString).length
            context.coordinator.highlight(textView)
        }
        grabFocusIfNeeded(textView)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.popup.hide()
    }

    /// Move keyboard focus to this editor when a new pane/tab requested it
    /// (docs/ui/03). Deferred until the view is in a window; clears the request
    /// once focus lands so it only fires once.
    private func grabFocusIfNeeded(_ textView: NSTextView) {
        guard pendingFocus else { return }
        DispatchQueue.main.async { [weak textView] in
            guard let textView, let window = textView.window else { return }
            window.makeFirstResponder(textView)
            onDidFocus?()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        // Refreshed on every updateNSView so the completion source and callbacks
        // never go stale (e.g. suggestions captured before the schema loaded).
        fileprivate var parent: MongoShellTextView
        weak var textView: NSTextView?
        /// Coalesces re-highlighting: re-lexing the whole document on every
        /// keystroke stalls typing, so we debounce until the user pauses.
        private var highlightTask: Task<Void, Never>?
        /// Previous document length, to tell insertion from deletion for
        /// auto-completion (ui.md 01 §5).
        var lastTextLength = 0

        init(_ parent: MongoShellTextView) {
            self.parent = parent
        }

        /// Point the text view's run/focus callbacks at the CURRENT representable, so
        /// they never keep a stale `session`/`document` from the first render (ED-04).
        func wireCallbacks(_ textView: RunnableTextView) {
            textView.onRunCurrent = { [weak self] in self?.parent.onRun() }
            textView.onRunAll = { [weak self] in self?.parent.onRun() }
            textView.onBecomeFirstResponder = { [weak self] in self?.parent.onFocus?() }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            let string = textView.string as NSString
            let inserted = string.length > lastTextLength
            lastTextLength = string.length
            parent.text = textView.string
            scheduleHighlight(textView)

            // Accepting a completion also changes the text — don't immediately
            // re-open the popup on that change (docs/ui/03).
            if let runnable = textView as? RunnableTextView, runnable.didAcceptCompletion {
                runnable.didAcceptCompletion = false
                popup.hide()
                return
            }
            // Refresh on insertion (typing filters live); deleting closes it.
            if inserted {
                updateCompletionPopup(force: false)
            } else {
                popup.hide()
            }
        }

        static func isWordChar(_ c: unichar) -> Bool {
            if c == unichar(UInt8(ascii: "_")) { return true }
            guard let scalar = Unicode.Scalar(c) else { return false }
            return CharacterSet.alphanumerics.contains(scalar)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            parent.onCursorMove(textView.selectedRange().location)
        }

        // MARK: Completion (ED-03) — custom floating popup (docs/ui spec):
        // dark themed rows with icons, blue selection, yellow match highlight,
        // ↑ ↓ ↩ ⇥ ⎋ keyboard navigation routed from the text view.

        let popup = CompletionPopupController()

        deinit {
            Task { @MainActor [popup] in
                popup.hide()
            }
        }

        func wirePopup(into textView: RunnableTextView) {
            textView.completionPopup = popup
            textView.onManualComplete = { [weak self] in
                self?.updateCompletionPopup(force: true)
            }
            popup.onAccept = { [weak self] item in
                self?.acceptCompletion(item)
            }
        }

        /// The identifier token being typed: (start, text). Start is right after
        /// a dot for qualified names ("u.na|" → "na").
        private func currentToken(in textView: NSTextView) -> (start: Int, text: String) {
            let string = textView.string as NSString
            let cursor = min(textView.selectedRange().location, string.length)
            var start = cursor
            while start > 0, Self.isWordChar(string.character(at: start - 1)) { start -= 1 }
            return (start, string.substring(with: NSRange(location: start, length: cursor - start)))
        }

        /// Show/refresh the popup for the token at the caret. Auto mode needs 2+
        /// typed chars or a fresh qualifier dot; ⌃Space (`force`) always shows.
        func updateCompletionPopup(force: Bool) {
            guard let textView, let provider = parent.completionItems else { return }
            let (start, query) = currentToken(in: textView)
            let string = textView.string as NSString
            let afterDot = start > 0 && string.character(at: start - 1) == unichar(UInt8(ascii: "."))
            guard force || afterDot || query.count >= 2 else {
                popup.hide()
                return
            }
            let items = provider(textView.string, textView.selectedRange().location)
            guard !items.isEmpty else {
                popup.hide()
                return
            }
            let anchor = textView.firstRect(
                forCharacterRange: NSRange(location: start, length: 0), actualRange: nil
            )
            popup.show(items: items, query: query, below: anchor)
        }

        /// Replace the in-progress token with the accepted suggestion.
        private func acceptCompletion(_ item: CompletionItem) {
            guard let textView else { return }
            let (start, _) = currentToken(in: textView)
            let cursor = textView.selectedRange().location
            let range = NSRange(location: start, length: cursor - start)
            (textView as? RunnableTextView)?.didAcceptCompletion = true
            if textView.shouldChangeText(in: range, replacementString: item.insert) {
                textView.replaceCharacters(in: range, with: item.insert)
                textView.didChangeText()
            }
        }

        // MARK: Lexical highlighting (M2 slice — tree-sitter swap later)

        private static let mongoMethodRegex: NSRegularExpression = {
            let names = (MongoShellBuiltins.methods.map(\.name) + ["db", "true", "false", "null", "new"]).joined(separator: "|")
            return try! NSRegularExpression(pattern: "\\b(" + names + ")\\b")
        }()
        private static let mongoOperatorRegex = try! NSRegularExpression(pattern: "\\$[A-Za-z]+")
        private static let mongoStringRegex = try! NSRegularExpression(
            pattern: #""(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'"#
        )
        private static let mongoCommentRegex = try! NSRegularExpression(pattern: #"//[^\n]*|/\*(?:.|\n)*?\*/"#)
        private static let mongoNumberRegex = try! NSRegularExpression(pattern: "\\b-?\\d+(?:\\.\\d+)?\\b")

        /// Debounced re-highlight — the latest keystroke wins, so a fast typist
        /// pays for one lex after they pause, not one per character.
        private func scheduleHighlight(_ textView: NSTextView) {
            highlightTask?.cancel()
            highlightTask = Task { [weak self, weak textView] in
                // nanoseconds, not Task.sleep(for:) — confirmed Swift
                // runtime crash risk in release builds (swiftlang/swift#86204,
                // #84793; docs/tests/crash.md), not a style choice.
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled, let self, let textView else { return }
                self.highlight(textView)
            }
        }

        func highlight(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let fullRange = NSRange(location: 0, length: storage.length)
            let text = storage.string as NSString

            storage.beginEditing()
            storage.removeAttribute(.foregroundColor, range: fullRange)
            storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: fullRange)

            func apply(_ regex: NSRegularExpression, _ color: NSColor) {
                regex.enumerateMatches(in: text as String, range: fullRange) { match, _, _ in
                    if let range = match?.range {
                        storage.addAttribute(.foregroundColor, value: color, range: range)
                    }
                }
            }
            apply(Self.mongoNumberRegex, .systemPurple)
            apply(Self.mongoMethodRegex, .systemBlue)
            apply(Self.mongoOperatorRegex, .systemOrange)
            apply(Self.mongoStringRegex, .systemRed)
            apply(Self.mongoCommentRegex, .systemGreen)
            storage.endEditing()
        }
    }
}
