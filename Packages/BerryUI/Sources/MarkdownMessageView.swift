import AppKit
import SwiftUI

/// Renders an assistant message as native views — headings, paragraphs with
/// inline markdown (**bold**/*italic*/`code`/links), code blocks, lists, and
/// mermaid diagrams (Wave C). Blocks come from `ChatMarkdown.parse`.
struct MarkdownMessageView: View {
    let text: String
    // Whether THIS message is still the one actively streaming — see the
    // `onChange(of: isStreaming)` below for why this matters.
    var isStreaming: Bool = false
    /// AI-34: opens a mermaid block's diagram as its own zoomable tab.
    var onOpenMermaidInTab: (String) -> Void = { _ in }
    // Cached so `body` re-evaluating for reasons unrelated to THIS message's
    // text (e.g. another turn streaming in — @Observable invalidates the
    // whole transcript array on every token) doesn't re-run the full parse.
    // Without this, every token in a long reply re-parsed every message in
    // the conversation from scratch, which reads as the reply lagging behind
    // the incoming text the longer the conversation gets.
    @State private var blocks: [ChatBlock] = []
    // Coalesces the re-parse triggered by each streamed delta so a long reply
    // doesn't re-parse its whole accumulated text from scratch on every
    // token (quadratic in the final message length). The first parse (empty
    // `blocks`) still runs immediately so there's no blank-state flash.
    //
    // Throttle, not debounce: schedules at most one reparse per ~100ms
    // window instead of resetting the delay on every single token. A plain
    // debounce (cancel + reschedule on each delta) starves forever once
    // tokens arrive faster than the round-trips between them ever leave a
    // 100ms gap — nothing renders incrementally, and the whole reply only
    // appears in one pop once `isStreaming` flips false below. `latestText`
    // is `@State` (backed by storage that survives this view's per-render
    // struct being recreated) specifically so the already-scheduled Task can
    // read whatever text arrived most recently when it fires, not whatever
    // `text` happened to be at the exact instant it was scheduled.
    //
    // Removing this throttle is what produced the reported "stream time
    // compounds the longer it runs" hang: `ChatMarkdown.parse` rescans the
    // whole accumulated string, so parsing per token is quadratic in final
    // length. A 191-event reasoning trace (docs/tests/crash.md) saturated the
    // MainActor badly enough that the client was still draining buffered
    // events 14s after the backend had already sent `message.complete`.
    @State private var pendingParse: Task<Void, Never>?
    @State private var latestText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: text, initial: true) { _, newText in
            latestText = newText
            guard isStreaming else {
                pendingParse?.cancel()
                pendingParse = nil
                blocks = ChatMarkdown.parse(newText)
                return
            }
            guard !blocks.isEmpty else {
                blocks = ChatMarkdown.parse(newText)
                return
            }
            guard pendingParse == nil else { return }
            pendingParse = Task {
                // nanoseconds, not Task.sleep(for:) — the latter crashes in
                // release builds (this exact file/line: docs/tests/crash.md,
                // EXC_CRASH/SIGABRT, "freed pointer was not the last
                // allocation" in swift_task_dealloc) when multiple modules
                // in the same binary generate different Clock-generic
                // specializations of it — confirmed upstream Swift runtime
                // bug (swiftlang/swift#86204, #84793), not our logic.
                // Task.sleep(nanoseconds:) isn't generic over Clock, so
                // there's nothing to collide.
                try? await Task.sleep(nanoseconds: 100_000_000)
                pendingParse = nil
                guard !Task.isCancelled else { return }
                blocks = ChatMarkdown.parse(latestText)
            }
        }
        // The throttle above only ever *schedules* a reparse of whatever
        // `text` was at the time of the last delta — it never guarantees one
        // lands with the true final text (e.g. a coalesced SwiftUI update
        // cycle right at the end of the stream). The moment streaming ends is
        // an unambiguous signal that `text` is final (`isStreaming` only flips
        // false in AISession.runTurn's defer, after every delta has been
        // applied), so force an immediate reparse here rather than trusting
        // the timer — this is what previously read as "the bubble doesn't show
        // the whole reply, but Copy has it all" (Copy reads `turn.text`
        // directly, bypassing `blocks`).
        .onChange(of: isStreaming) { _, streaming in
            guard !streaming else { return }
            pendingParse?.cancel()
            blocks = ChatMarkdown.parse(text)
        }
    }

    @ViewBuilder
    private func blockView(_ block: ChatBlock) -> some View {
        switch block {
        case let .heading(level, text):
            Text(inline(text))
                .font(.system(size: headingSize(level), weight: .semibold))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .paragraph(text):
            Text(inline(text))
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .code(language, code):
            CodeBlockView(language: language, code: code)
        case let .mermaid(source):
            MermaidBlock(source: source, onOpenInTab: onOpenMermaidInTab)
        case let .bulletList(items):
            listView(items) { _ in Text("•").foregroundStyle(.secondary) }
        case let .orderedList(startIndex, items):
            listView(items) { index in
                Text("\(startIndex + index).").foregroundStyle(.secondary).monospacedDigit()
            }
        case let .table(header, rows):
            MarkdownTableView(header: header, rows: rows)
        case .divider:
            Divider()
                .padding(.vertical, 4)
        }
    }

    private func listView(_ items: [String], marker: @escaping (Int) -> some View) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    marker(index).font(.callout)
                    Text(inline(item)).font(.callout).textSelection(.enabled)
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 17
        case 2: 15
        default: 13
        }
    }

    /// Inline-only markdown so a paragraph's **bold**/`code`/links render but its
    /// line breaks survive; falls back to plain text on a parse error.
    private func inline(_ markdown: String) -> AttributedString {
        (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(markdown)
    }
}

/// A fenced code block: language badge, a monospace body that scrolls sideways
/// instead of forcing the panel wide, and its own copy button.
struct CodeBlockView: View {
    let language: String?
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                CopyButton(text: code, help: L("Copy code"))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }
}

/// A GFM table rendered as a native grid; its copy button yields tab-separated
/// values so it pastes cleanly into a spreadsheet.
struct MarkdownTableView: View {
    let header: [String]
    let rows: [[String]]

    private var tsv: String {
        ([header] + rows).map { $0.joined(separator: "\t") }.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                CopyButton(text: tsv, help: L("Copy table"))
            }
            .padding(.horizontal, 8)
            .padding(.top, 5)
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        ForEach(header.indices, id: \.self) { column in
                            Text(header[column]).font(.callout.weight(.semibold)).textSelection(.enabled)
                        }
                    }
                    Divider().gridCellColumns(max(header.count, 1))
                    ForEach(rows.indices, id: \.self) { row in
                        GridRow {
                            ForEach(header.indices, id: \.self) { column in
                                Text(column < rows[row].count ? rows[row][column] : "")
                                    .font(.callout)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }
}

/// One-tap copy with a brief checkmark confirmation. Reused by every block that
/// carries copyable content (code, table, mermaid) and by the whole message.
struct CopyButton: View {
    let text: String
    var help: String = ""
    @State private var copied = false

    var body: some View {
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            copied = true
            Task {
                // nanoseconds, not Task.sleep(for:) — see the throttle Task
                // above for why (a confirmed Swift runtime crash, not a
                // style choice).
                try? await Task.sleep(nanoseconds: 1_400_000_000)
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 10))
        }
        .buttonStyle(.plain)
        .foregroundStyle(copied ? Color.green : .secondary)
        .help(help.isEmpty ? L("Copy") : help)
    }
}
