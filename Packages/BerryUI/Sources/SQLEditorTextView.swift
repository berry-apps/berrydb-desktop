import AppKit
import BerryCore
import SwiftUI

/// SQL editor text view (ED-01/02) — M2 slice: NSTextView with a lightweight
/// lexical highlighter. The view is deliberately isolated behind this file so
/// the CodeEditSourceEditor/tree-sitter upgrade (docs/architecture/03 §2)
/// swaps one representable without touching the rest of the editor UI.
struct SQLEditorTextView: NSViewRepresentable {
    @Binding var text: String
    let onCursorMove: (Int) -> Void
    /// Reports the full selection so the Run action can honor it (docs/ui).
    var onSelectionChange: ((NSRange) -> Void)?
    let onRunCurrent: (NSRange?) -> Void
    let onRunAll: () -> Void
    /// One-shot format trigger (ED-08): when this value changes, pretty-print in
    /// place, preserving the caret/selection.
    var formatRequestID: Int = 0
    /// One-shot ⌘/ trigger (docs/ui) — toggles line comments on the selection.
    var commentToggleRequestID: Int = 0
    /// Completion source (ED-03): (script, utf16Cursor) → popup rows, already
    /// ranked and dialect-quoted by the caller.
    var completionItems: ((String, Int) -> [CompletionItem])?
    /// Called when this editor takes keyboard focus (ui.md 01 §4) so the
    /// workspace can activate its split pane.
    var onFocus: (() -> Void)?
    /// One-shot: when true, this editor grabs keyboard focus (docs/ui/03) so a
    /// freshly split/opened pane gets the caret. `onDidFocus` clears it.
    var pendingFocus = false
    /// (ED-07) Applied once, alongside `pendingFocus`, to pre-select a saved-
    /// query snippet's placeholder instead of just placing the caret.
    var pendingSelection: NSRange?
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
        wireCallbacks(textView)
        context.coordinator.textView = textView
        context.coordinator.wirePopup(into: textView)

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        textView.string = text
        context.coordinator.lastFormatID = formatRequestID
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
        wireCallbacks(textView)
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
        if context.coordinator.lastFormatID != formatRequestID {
            context.coordinator.lastFormatID = formatRequestID
            context.coordinator.performFormat()
        }
        if context.coordinator.lastCommentToggleID != commentToggleRequestID {
            context.coordinator.lastCommentToggleID = commentToggleRequestID
            context.coordinator.performToggleComment()
        }
        grabFocusIfNeeded(textView)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.popup.hide()
    }

    /// Point the text view's run/focus callbacks at the CURRENT representable, so
    /// they never keep a stale `session`/`document` from the first render (ED-04).
    private func wireCallbacks(_ textView: RunnableTextView) {
        textView.onRunCurrent = { [weak textView] in
            guard let textView else { return }
            let selection = textView.selectedRange()
            onRunCurrent(selection.length > 0 ? selection : nil)
        }
        textView.onRunAll = onRunAll
        textView.onBecomeFirstResponder = onFocus
    }

    /// Move keyboard focus to this editor when a new pane/tab requested it
    /// (docs/ui/03). Deferred until the view is in a window; clears the request
    /// once focus lands so it only fires once.
    private func grabFocusIfNeeded(_ textView: NSTextView) {
        guard pendingFocus else { return }
        let selection = pendingSelection
        DispatchQueue.main.async { [weak textView] in
            guard let textView, let window = textView.window else { return }
            window.makeFirstResponder(textView)
            if let selection, selection.location + selection.length <= (textView.string as NSString).length {
                textView.setSelectedRange(selection)
            }
            onDidFocus?()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        // Refreshed on every updateNSView so the completion source and callbacks
        // never go stale (e.g. suggestions captured before the schema loaded).
        fileprivate var parent: SQLEditorTextView
        weak var textView: NSTextView?
        /// Coalesces re-highlighting: re-lexing the whole document on every
        /// keystroke stalls typing, so we debounce until the user pauses.
        private var highlightTask: Task<Void, Never>?
        /// Last-seen value of the parent's format trigger (ED-08).
        var lastFormatID = 0
        /// Last-seen value of the ⌘/ trigger (docs/ui).
        var lastCommentToggleID = 0
        /// Previous document length, to tell insertion from deletion for
        /// auto-completion (ui.md 01 §5).
        var lastTextLength = 0

        init(_ parent: SQLEditorTextView) {
            self.parent = parent
        }

        /// Pretty-print in place (ED-08): the selection when one exists, else the
        /// whole document. Runs through `insertText` so it's a single undo step
        /// and the caret/selection stays put instead of jumping to the top.
        func performFormat() {
            guard let textView else { return }
            let selection = textView.selectedRange()
            if selection.length > 0 {
                let original = (textView.string as NSString).substring(with: selection)
                let formatted = SQLFormatter.format(original)
                if textView.shouldChangeText(in: selection, replacementString: formatted) {
                    textView.replaceCharacters(in: selection, with: formatted)
                    textView.didChangeText()
                }
                let newRange = NSRange(location: selection.location, length: (formatted as NSString).length)
                textView.setSelectedRange(newRange)
                textView.scrollRangeToVisible(newRange)
            } else {
                let caret = selection.location
                let whole = NSRange(location: 0, length: (textView.string as NSString).length)
                let formatted = SQLFormatter.format(textView.string)
                if textView.shouldChangeText(in: whole, replacementString: formatted) {
                    textView.replaceCharacters(in: whole, with: formatted)
                    textView.didChangeText()
                }
                let location = min(caret, (formatted as NSString).length)
                let caretRange = NSRange(location: location, length: 0)
                textView.setSelectedRange(caretRange)
                textView.scrollRangeToVisible(caretRange)
            }
            parent.text = textView.string
            highlight(textView)
        }

        /// Toggle `-- ` comments on the lines covered by the selection (⌘/,
        /// docs/ui). Replaces only the touched line block, so it's one undo
        /// step and the rest of the document keeps its state.
        func performToggleComment() {
            guard let textView else { return }
            let full = textView.string as NSString
            let selection = textView.selectedRange()
            let lineRange = full.lineRange(for: selection)
            let result = SQLCommentToggler.toggle(textView.string, selection: selection)
            let newBlock = (result.text as NSString).substring(with: result.selection)
            if textView.shouldChangeText(in: lineRange, replacementString: newBlock) {
                textView.replaceCharacters(in: lineRange, with: newBlock)
                textView.didChangeText()
            }
            textView.setSelectedRange(result.selection)
            parent.text = textView.string
            highlight(textView)
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
            parent.onSelectionChange?(textView.selectedRange())
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

        private static let keywordRegex: NSRegularExpression = {
            let pattern = "\\b(" + CompletionProvider.keywords
                .flatMap { $0.split(separator: " ").map(String.init) }
                .uniqued()
                .joined(separator: "|")
                + ")\\b"
            return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        }()
        private static let stringRegex = try! NSRegularExpression(pattern: "'(?:[^']|'')*'")
        private static let commentRegex = try! NSRegularExpression(
            pattern: "--[^\\n]*|/\\*(?:.|\\n)*?\\*/"
        )
        private static let numberRegex = try! NSRegularExpression(pattern: "\\b\\d+(?:\\.\\d+)?\\b")

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
            apply(Self.numberRegex, .systemPurple)
            apply(Self.keywordRegex, .systemBlue)
            apply(Self.stringRegex, .systemRed)
            apply(Self.commentRegex, .systemGreen)
            storage.endEditing()
        }
    }
}

/// NSTextView that turns ⌘↩ / ⇧⌘↩ into run actions (ED-04) and routes
/// navigation keys to the completion popup while it is open (docs/ui spec).
final class RunnableTextView: NSTextView {
    var onRunCurrent: (() -> Void)?
    var onRunAll: (() -> Void)?
    /// Set when the user accepts a completion so the editor doesn't immediately
    /// re-open the popup on the resulting text change (docs/ui/03).
    var didAcceptCompletion = false
    /// The coordinator's floating completion popup; keys route here when open.
    weak var completionPopup: CompletionPopupController?
    /// ⌃Space — show the popup regardless of the typed-length threshold.
    var onManualComplete: (() -> Void)?
    /// Fires when this editor takes keyboard focus, so the workspace can mark its
    /// pane active — clicking/typing into a split pane must make it the focused
    /// one (ui.md 01 §4), which a SwiftUI tap gesture can't see through the
    /// AppKit text view.
    var onBecomeFirstResponder: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            // Defer so we don't mutate observable state mid responder-change.
            DispatchQueue.main.async { [weak self] in self?.onBecomeFirstResponder?() }
        }
        return became
    }

    override func resignFirstResponder() -> Bool {
        completionPopup?.hide()
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            completionPopup?.hide()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func mouseDown(with event: NSEvent) {
        // Clicking back into the text dismisses the suggestions.
        completionPopup?.hide()
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        // Keyboard-first popup interaction (docs/ui spec): arrows navigate,
        // ↩/⇥ accept, ⎋ dismisses; everything else keeps typing (live filter).
        if let popup = completionPopup, popup.isVisible {
            switch event.keyCode {
            case 125: popup.moveSelection(by: 1); return    // ↓
            case 126: popup.moveSelection(by: -1); return   // ↑
            case 36, 48:                                    // ↩ / ⇥
                if popup.acceptSelected() { return }
            case 53: popup.hide(); return                   // ⎋
            default: break
            }
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // performKeyEquivalent reaches every text view in the window, not just
        // the focused one. In a split each pane has its own editor, so only the
        // one the user is typing in may claim the run shortcuts — otherwise ⌘R
        // could fire the wrong pane. When no editor is focused the event falls
        // through to the Query menu (⌘R runs the focused pane there).
        guard window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        let isReturn = event.keyCode == 36   // kVK_Return
        if isReturn, event.modifierFlags.contains(.command) {
            if event.modifierFlags.contains(.shift) {
                onRunAll?()
            } else {
                onRunCurrent?()
            }
            return true
        }
        // ⌘R → run the current statement (ED-04), same action as ⌘↩.
        if event.keyCode == 15, // kVK_ANSI_R
           event.modifierFlags.contains(.command),
           !event.modifierFlags.contains(.shift) {
            onRunCurrent?()
            return true
        }
        // ⌃Space → completion popup (ED-03).
        if event.keyCode == 49, event.modifierFlags.contains(.control) {   // kVK_Space
            onManualComplete?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

extension Sequence where Element: Hashable {
    /// Order-preserving dedupe.
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
