import BerryAI
import BerryCore
import SwiftUI

/// The per-connection AI panel (docs/architecture/09 §1/§5). A right-hand
/// inspector column: chat transcript, streaming reply, inline SQL approval
/// (§6), the AI-06/AI-07 switches, and token usage (AI-08). All safety lives in
/// the controller + BerryAI — this is presentation only.
struct AIPanelView: View {
    @Bindable var controller: AIPanelController
    /// Opens the license sheet from the unlicensed / quota-exceeded state.
    var onUpgrade: () -> Void
    var onClose: (() -> Void)? = nil
    /// On-device model opt-in (AI-20). Read by AIPanelController.send() too.
    @AppStorage("berry.ai.onDevice") private var useOnDeviceModel = false
    /// AI Database Coach (docs/feature/07 §16) — how the assistant explains
    /// things; empty means "let the server pick its own default register".
    /// Read directly by `AIClient` (via `AIPanelController.bind()`) using the
    /// same key, not routed through the controller.
    @AppStorage("berry.ai.detailLevel") private var detailLevel = ""
    /// TM-13/14: the user's chosen AI model ("{provider_id}/{model_id}"), or
    /// empty to let the server pick its own default role — same pattern as
    /// `detailLevel` above, read directly by `AIClient` via `bind()`.
    @AppStorage("berry.ai.model") private var selectedModel = ""
    /// Past-conversations sidebar (AI-21) overlaid on the body, under the header.
    @State private var showHistory = false
    /// Restored when a stream finishes (AI-08) — otherwise the composer loses
    /// keyboard focus and the next message needs an extra click to type.
    @FocusState private var promptFieldFocused: Bool
    /// Selection state for the "/" command dropdown — view-local like
    /// `promptFieldFocused` above, not session state (see the design spec).
    @State private var selectedCommandIndex = 0
    @State private var commandPaletteDismissed = false
    /// Selection state for the `@{...}` mention dropdown (AI-32,
    /// docs/draft/09.md) — same shape as the "/" state above, kept separate
    /// since the two triggers/palettes are otherwise unrelated.
    @State private var selectedMentionIndex = 0
    @State private var mentionPaletteDismissed = false
    @State private var clarificationAnswer = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ZStack {
                content
                if showHistory {
                    AIHistorySidebarView(controller: controller, isPresented: $showHistory)
                        .transition(.move(edge: .trailing))
                }
            }
        }
        .frame(minWidth: 300)
        .background(.background)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.callout)
                .foregroundStyle(.tint)
            Text(verbatim: "BerryDB Assistant")
                .font(.subheadline.weight(.semibold))
            Spacer()
            if controller.availability == .ready {
                historyToggle
                Button {
                    controller.newChat()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.borderless)
                .focusEffectDisabled()
                .disabled(!controller.canChangeThread)
                .help(L("New chat"))
                .accessibilityLabel(L("New chat"))
                settingsMenu
            }
            if let onClose {
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.borderless)
                .help(L("Close"))
                .accessibilityLabel(L("Close"))
            }
        }
        .frame(height: 30)          // compact, aligned inspector header (docs/ui)
        .padding(.horizontal, 12)
        .background(.bar)
    }

    /// Toggles the past-conversations sidebar (AI-21). Refreshes the list each
    /// time it opens so recent chats show up.
    private var historyToggle: some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) { showHistory.toggle() }
            if showHistory { Task { await controller.refreshThreads() } }
        } label: {
            Image(systemName: showHistory ? "xmark" : "clock.arrow.circlepath")
        }
        .buttonStyle(.borderless)
        .focusEffectDisabled()
        .disabled(!controller.canChangeThread)
        .help(L("Conversation history"))
        .accessibilityLabel(L("Conversation history"))
    }

    private var settingsMenu: some View {
        Menu {
            // On-device model (AI-20) — only offered when Apple Intelligence is
            // ready on this Mac; runs the chat locally, no backend/network.
            if AppleFoundationProvider.isAvailable() {
                Toggle(L("Use on-device model (Apple Intelligence)"), isOn: $useOnDeviceModel)
                Divider()
            }
            Toggle(L("Auto-run safe SELECTs"), isOn: $controller.autoApproveSelects)
            Toggle(L("Allow sending sample rows"), isOn: $controller.allowSampleRows)
            Divider()
            // AI Database Coach (docs/feature/07 §16) — explain-level register,
            // a global preference (not per-connection).
            Picker(L("Explain like I'm…"), selection: $detailLevel) {
                Text(L("Default")).tag("")
                Text(L("a beginner")).tag("beginner")
                Text(L("an intermediate developer")).tag("intermediate")
                Text(L("an advanced developer")).tag("advanced")
                Text(L("a DBA")).tag("dba")
            }
            if !controller.mcpAllowlist.isEmpty {
                Divider()
                Menu(L("MCP servers")) {
                    ForEach(controller.mcpAllowlist, id: \.id) { server in
                        Toggle(server.name, isOn: Binding(
                            get: { controller.enabledMCPServers.contains(server.id) },
                            set: { controller.setMCPServer(server.id, enabled: $0) }
                        ))
                    }
                }
            }
            Divider()
            Button(L("Turn AI off for this connection")) {
                controller.enabledForConnection = false
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(L("AI settings"))
    }

    @ViewBuilder
    private var content: some View {
        switch controller.availability {
        case .noConnection:
            unavailable(
                L("No connection"),
                systemImage: "bolt.horizontal.circle",
                message: L("Connect to a database to use the AI assistant.")
            )
        case .unlicensed:
            unlicensed
        case .disabledForConnection:
            disabledForConnection
        case .needsConsent:
            consent
        case .ready:
            chat
        }
    }

    // MARK: - Gates

    private var unlicensed: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(.tint)
            Text(L("AI needs a trial or license")).font(.headline)
            Text(L("BerryDB itself is free — start a free trial to use the AI assistant, billed as pay-as-you-go credit."))
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(L("Get started"), action: onUpgrade).buttonStyle(.borderedProminent)
        }
        .padding(24).frame(maxHeight: .infinity)
    }

    private var disabledForConnection: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles.slash").font(.largeTitle).foregroundStyle(.secondary)
            Text(L("AI is off for this connection")).font(.headline)
            if controller.isProduction {
                Text(L("This connection is labelled production, so AI is off by default."))
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Button(L("Turn AI on…")) { controller.enabledForConnection = true }
                .buttonStyle(.bordered)
        }
        .padding(24).frame(maxHeight: .infinity)
    }

    private var consent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L("Before you start"), systemImage: "hand.raised")
                .font(.headline)
            Text(L("The assistant sends your schema (table and column names), the database type, and your questions to BerryDB's AI service. Row data is never sent unless you turn on sample rows. Any SQL the assistant proposes runs only after you approve it."))
                .font(.callout).foregroundStyle(.secondary)
            if controller.isProduction {
                Label(L("This is a production connection — review every statement carefully."), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            Button(L("I understand — enable AI")) {
                controller.giveConsentAndEnable()
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding(20).frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Chat

    /// True while any card with a `.keyboardShortcut(.defaultAction)` primary
    /// action (approval/MCP-approval/report-draft/clarification/report/
    /// confirmed-report) is showing above the composer — see the Send
    /// button's own `.keyboardShortcut` below for why this matters.
    private var hasCompetingReturnShortcutCard: Bool {
        controller.pendingApproval != nil
            || controller.pendingMCPApproval != nil
            || controller.pendingReportDraft != nil
            || controller.pendingClarification != nil
            || controller.pendingReport != nil
            || controller.confirmedReportDraft != nil
    }

    private var chat: some View {
        VStack(spacing: 0) {
            transcript
            if let approval = controller.pendingApproval {
                Divider()
                approvalCard(approval)
            } else if let mcp = controller.pendingMCPApproval {
                Divider()
                mcpApprovalCard(mcp)
            } else if let reportDraft = controller.pendingReportDraft {
                Divider()
                reportDraftCard(reportDraft)
            } else if let clarification = controller.pendingClarification {
                Divider()
                clarificationCard(clarification)
            } else if let report = controller.pendingReport {
                Divider()
                reportCard(report)
            } else if let confirmed = controller.confirmedReportDraft {
                Divider()
                confirmedReportCard(confirmed)
            } else if case .submitted = controller.reportSubmissionState {
                Divider()
                reportSubmittedBar
            } else if case let .failed(failure) = controller.reportSubmissionState {
                // The 403 paths drop the confirmed card with it, so the reason
                // it vanished has to be said somewhere (Task 12).
                Divider()
                errorBar(reportSubmissionFailureMessage(failure))
            } else if controller.requiresClientUpdate {
                Divider()
                errorBar(L("Update BerryDB to continue using AI."))
            } else if let key = controller.capabilityErrorLocalizationKey {
                Divider()
                errorBar(localizedCapabilityError(key))
            } else if let key = controller.controlDeliveryErrorLocalizationKey {
                Divider()
                errorBar(localizedControlDeliveryError(key))
            } else if let error = controller.lastError {
                Divider()
                errorBar(error)
            } else if controller.balance?.isExhausted == true {
                // Surfaced proactively (not just after a failed submit) so the
                // user isn't left guessing why Send is disabled. Passes the
                // same raw code `errorBar` maps from a failed send, so the
                // message/CTA are identical either way.
                Divider()
                errorBar(controller.balance?.tokenQuota != nil ? "quota_exceeded" : "insufficient_credit")
            }
            Divider()
            composer
            balanceFooter
        }
    }

    /// Scroll-follow anchor id kept pinned to the bottom of the transcript.
    private static let scrollBottomID = "ai-transcript-bottom"
    /// Whether the bottom anchor is currently within the visible viewport —
    /// the standard macOS 14-compatible stand-in for a real scroll-offset API
    /// (`onScrollGeometryChange` needs macOS 15). Set by the anchor's own
    /// `onAppear`/`onDisappear`: true while the user is at/near the bottom
    /// (including right after we've auto-scrolled them there), false the
    /// moment they scroll it out of view to read something earlier. Streamed
    /// text should only yank the view down while this is true — a user who
    /// scrolled up must not get dragged back to the bottom mid-read.
    @State private var isPinnedToBottom = true
    /// Captured from `ScrollViewReader` so `send()` can scroll directly and
    /// synchronously the instant a message is submitted, instead of relying
    /// on a reactive `onChange` + `DispatchQueue.main.async(after:)` that
    /// races against whatever else SwiftUI is doing on the main thread —
    /// reported live as the transcript not scrolling to the new turns for
    /// multiple seconds after submitting in a longer conversation.
    @State private var scrollProxy: ScrollViewProxy?
    /// Captured from `ScrollViewTracker` so `send()` can cancel any
    /// in-progress/residual scroll tracking on an explicit submit — see
    /// `ScrollViewTracker.Coordinator.forceScrollToBottom()`.
    @State private var scrollCoordinator: ScrollViewTracker.Coordinator?

    /// Total streamed length — grows as the answer, plan, work steps, and any
    /// sub-agents stream, plus the turn count, so auto-scroll fires on every
    /// kind of update.
    ///
    /// Deliberately excludes the reasoning trace. This is recomputed on every
    /// single token, and summing `reasoningSteps` made that O(total trace
    /// length) per token — the same quadratic cost that made the panel lag
    /// behind the stream (docs/tests/crash.md). The trace is no longer
    /// rendered either (see `TurnWorkSummary`), so it cannot move the content
    /// height and has nothing to scroll to. `workSteps` is summed by count,
    /// not by narration length, for the same reason: a step's arrival is what
    /// matters, and one bounded sentence cannot grow without bound.
    private var scrollSignal: Int {
        guard let session = controller.aiSession else { return 0 }
        let last = session.transcript.last
        return Self.scrollSignalValue(
            turnCount: session.transcript.count,
            // `.utf8.count`, not `.count`: `String.count` walks the string to
            // find grapheme cluster boundaries, O(current length) — and this
            // property re-evaluates on every token, so that was quadratic in
            // the answer's own length. `.utf8.count` reads the native UTF-8
            // buffer's byte count directly, O(1) — the exact value doesn't
            // matter, only that it changes when the text does.
            answerLength: last?.text.utf8.count ?? 0,
            planLength: last?.plan.utf8.count ?? 0,
            workStepCount: last?.workSteps.count ?? 0,
            subAgentCount: session.subThreads.count,
            subAgentTextLength: 0,
            isToolRunning: controller.runningTool != nil
        )
    }

    /// The pure part of `scrollSignal`, extracted so its cost shape is testable.
    ///
    /// `subAgentTextLength` is accepted and deliberately IGNORED. Summing it was
    /// O(total sub-agent text) on every token — the same shape as the
    /// reasoning-trace sum removed earlier, which is what made the client fall
    /// 14s behind the backend (docs/tests/crash.md). `subAgentCount` covers what
    /// this signal actually needs: a sub-agent appearing changes the content
    /// height enough to re-anchor, and its own text growing does not need to move
    /// the scroll on every character.
    ///
    /// `answerLength` IS included, because the bubble grows as the answer streams
    /// and the anchor genuinely has to follow it. That is one `String.count` on
    /// one turn, not a fold over a collection.
    static func scrollSignalValue(
        turnCount: Int,
        answerLength: Int,
        planLength: Int,
        workStepCount: Int,
        subAgentCount: Int,
        subAgentTextLength: Int,
        isToolRunning: Bool
    ) -> Int {
        _ = subAgentTextLength
        return turnCount
            + answerLength
            + planLength
            + workStepCount
            + subAgentCount
            + (isToolRunning ? 1 : 0)
    }

    /// Whether a turn should present the streaming indicator.
    ///
    /// Extracted from `body` so it can be tested: inline, the condition was
    /// unreachable, and it had a bug nothing could catch — it also required
    /// `runningTool == nil`, which suppressed the indicator for the whole
    /// duration of every tool call. The assumption was that the separate
    /// "Running <tool>…" row covered that, but it does not cover a turn whose
    /// first action is a tool call: no answer text and no settled working block
    /// yet, so the panel showed nothing at all while the turn was plainly
    /// working. Reported as "đang working nhưng không thấy loading".
    ///
    /// A running tool is now irrelevant here. `TurnView` picks the right signal
    /// for the phase — typing indicator before anything arrives, the working
    /// block's live timer once it exists, the answer text once that streams.
    static func isTurnStreaming(sessionIsStreaming: Bool, isLastTurn: Bool) -> Bool {
        sessionIsStreaming && isLastTurn
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    let currentTranscript = controller.aiSession?.transcript ?? []
                    let runningTool = controller.runningTool
                    if currentTranscript.isEmpty {
                        Text(L("Ask about your schema, or ask the assistant to write a query."))
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 40)
                    }
                    ForEach(currentTranscript) { turn in
                        turnView(for: turn, in: currentTranscript)
                        // Nest each turn's sub-agents right under it (06 §6).
                        ForEach(controller.aiSession?.subThreads(for: turn.id) ?? []) { sub in
                            subAgentCard(sub)
                        }
                    }
                    if let tool = runningTool {
                        Label(L("Running \(tool)…"), systemImage: "gearshape.2")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    // Anchor we keep pinned to the bottom as content streams in
                    Color.clear.frame(height: 1).id(Self.scrollBottomID)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .background(ScrollViewTracker(
                    isPinnedToBottom: $isPinnedToBottom,
                    onCoordinatorReady: { scrollCoordinator = $0 }
                ))
            }
            .onAppear {
                scrollProxy = proxy
                // A queued message (AI-08) getting its own bubble once the
                // previous turn finishes is the same "new turn just
                // appeared" moment as an explicit send — see
                // `scrollToBottomImmediately`'s doc comment.
                controller.onTurnAdmitted = { scrollToBottomImmediately(reason: "queued message drained") }
            }
            // One signal covers streamed text, the plan pass, reasoning stream,
            // and sub-agents, so this fires on every streamed token.
            // Gated on `isPinnedToBottom`: once the user scrolls up to read
            // something earlier, streamed tokens must not yank them back down.
            .onChange(of: scrollSignal) {
                guard isPinnedToBottom else { return }
                DispatchQueue.main.async {
                    proxy.scrollTo(Self.scrollBottomID, anchor: .bottom)
                }
            }
            // Submitting a prompt appends two turns at once (the user's and an
            // empty assistant placeholder), and the panel has to land on them.
            // `scrollSignal` does move — `transcript.count` grows — but a single
            // `main.async` hop fires before the new rows have been laid out, so it
            // scrolls to where the bottom USED to be. The count is watched
            // separately with a post-layout hop, rather than delaying every
            // streamed token by the same amount.
            .onChange(of: controller.aiSession?.transcript.count) { _, newCount in
                // Diagnostic-only, chasing a live report that submitting a
                // prompt doesn't scroll to the new turns — no behavior
                // change. Read `/tmp/berrydb-diagnostics.log` (or
                // `berrydb-diagnostics-tests.log` under test) after
                // reproducing.
                DiagnosticLog.default.event(
                    "scroll: transcript.count changed",
                    detail: "count=\(newCount ?? -1) isPinnedToBottom=\(isPinnedToBottom)"
                )
                guard isPinnedToBottom else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    DiagnosticLog.default.event("scroll: scrollTo(bottom) fired from transcript.count")
                    proxy.scrollTo(Self.scrollBottomID, anchor: .bottom)
                }
            }
            // Expanding or collapsing a working block changes the content height
            // without changing any text, so nothing in `scrollSignal` moves and
            // the panel kept the old offset — leaving the newest content off
            // screen after a manual toggle. `TurnWorkSummary` owns that state
            // privately, so it reports the change up instead.
            .onChange(of: controller.workingBlockLayoutGeneration) {
                guard isPinnedToBottom else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    proxy.scrollTo(Self.scrollBottomID, anchor: .bottom)
                }
            }
            // When user scrolls back down to the bottom, isPinnedToBottom flips
            // to true -> immediately jump to bottom and resume auto-scrolling.
            .onChange(of: isPinnedToBottom) { _, pinned in
                guard pinned else { return }
                DispatchQueue.main.async {
                    proxy.scrollTo(Self.scrollBottomID, anchor: .bottom)
                }
            }
            // When thinking stream completes and response text starts arriving,
            // TurnWorkSummary collapses. Scroll to bottom after the collapse layout pass.
            .onChange(of: controller.aiSession?.transcript.last?.text.isEmpty) {
                guard isPinnedToBottom else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    proxy.scrollTo(Self.scrollBottomID, anchor: .bottom)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Sub-agent (docs/agents/architecture/06 §6)

    private func subAgentCard(_ sub: SubAgentTranscript) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(L("Sub-agent"), systemImage: "arrow.triangle.branch")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            if !sub.tools.isEmpty {
                Text(sub.tools.joined(separator: " · "))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Text(sub.text.isEmpty ? " " : sub.text)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(BerryTheme.bento.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(BerryTheme.accent.opacity(0.3)))
        .padding(.leading, 16)
    }

    // MARK: - Inline approval (§6)

    private func approvalCard(_ approval: AIPanelController.PendingApproval) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L("The assistant wants to run this SQL"), systemImage: "play.rectangle")
                .font(.subheadline.weight(.semibold))
            if let note = dangerNote(approval.danger) {
                Label(note, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(approval.sql)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            .frame(maxHeight: 120)
            HStack {
                Spacer()
                Button(L("Deny")) { controller.resolveApproval(false) }
                    .keyboardShortcut(.cancelAction)
                // Only offered on an already-safe statement (e.g. a batch of
                // SELECTs prompting one by one) — writes/DDL never get this
                // shortcut, matching DangerGuard's "always ask" rule for them.
                if !approval.isDangerous {
                    Button(L("Run All Safe")) {
                        controller.resolveApproval(true, trustRemainingSafeThisTurn: true)
                    }
                    .help(L("Run this and every other safe statement in this turn without asking again."))
                }
                Button(approval.isDangerous ? L("Run anyway") : L("Run")) {
                    controller.resolveApproval(true)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(approval.isDangerous ? .red : .accentColor)
            }
        }
        .bentoCard()
        .padding(.horizontal, BerryTheme.Space.md)
        .padding(.bottom, BerryTheme.Space.sm)
    }

    private func mcpApprovalCard(_ approval: AIPanelController.PendingMCPApproval) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L("An MCP server wants to run a tool"), systemImage: "shippingbox")
                .font(.subheadline.weight(.semibold))
            Text("\(approval.serverID) · \(approval.toolName)")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(approval.argumentsJSON)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            .frame(maxHeight: 120)
            HStack {
                Spacer()
                Button(L("Deny")) { controller.resolveMCPApproval(false) }
                    .keyboardShortcut(.cancelAction)
                Button(L("Trust server")) { controller.resolveMCPApproval(true, trustServer: true) }
                Button(L("Run")) { controller.resolveMCPApproval(true) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .bentoCard()
        .padding(.horizontal, BerryTheme.Space.md)
        .padding(.bottom, BerryTheme.Space.sm)
    }

    /// Task 4.1's pre-refinement consent card: shown the moment `/report` is
    /// typed, before any network call. `report.description`/text stays on
    /// this device unless the user consents — the post-hoc `reportCard`
    /// below (once the agent has actually drafted a report) is a separate,
    /// already-existing step.
    private func reportDraftCard(_ draft: AISession.PendingReportDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L("Refine this report with AI?"), systemImage: "exclamationmark.bubble")
                .font(.subheadline.weight(.semibold))
            Text(L("BerryDB will send this text to the AI service to turn it into a clear report. It's processed transiently for refinement only — nothing is stored on the server until you approve the final report."))
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(draft.text)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            .frame(maxHeight: 120)
            Toggle(L("Attach recent conversation for context"), isOn: Binding(
                get: { draft.attachContext },
                set: { controller.updateReportDraftAttachContext($0) }
            ))
            .font(.caption)
            HStack {
                Spacer()
                Button(L("Cancel")) {
                    controller.resolveReportDraft(confirmed: false, attachContext: draft.attachContext)
                }
                .keyboardShortcut(.cancelAction)
                Button(L("Refine with AI")) {
                    controller.resolveReportDraft(confirmed: true, attachContext: draft.attachContext)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .bentoCard()
        .padding(.horizontal, BerryTheme.Space.md)
        .padding(.bottom, BerryTheme.Space.sm)
    }

    /// The agent's canonical draft, reviewed and — since Task 11 — editable
    /// before confirming. Confirming sends exactly this text's digest and
    /// mints a `report_ready_token`; it does not submit the report (that's
    /// gated on the token in Task 12), so the label says "Confirm", not "Send".
    private func reportCard(_ report: AISession.PendingReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L("Review this report"), systemImage: "exclamationmark.bubble")
                .font(.subheadline.weight(.semibold))
            TextEditor(text: Binding(
                get: { report.description },
                set: { controller.updateReportDescription($0) }
            ))
            .font(.system(.callout, design: .monospaced))
            .scrollContentBackground(.hidden)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            .frame(maxHeight: 120)
            .disabled(controller.isInteractionResolving)
            Toggle(L("Attach recent conversation for context"), isOn: Binding(
                get: { report.attachContext },
                set: { controller.updateReportAttachContext($0) }
            ))
            .font(.caption)
            .disabled(controller.isInteractionResolving)
            if report.attachContext {
                reportContextScope
            }
            HStack {
                Spacer()
                Button(L("Cancel")) {
                    controller.resolveReport(confirmed: false, attachContext: report.attachContext)
                }
                .keyboardShortcut(.cancelAction)
                .disabled(controller.isInteractionResolving)
                Button(L("Confirm Report")) {
                    controller.resolveReport(confirmed: true, attachContext: report.attachContext)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(controller.isInteractionResolving || !canConfirmReport(report))
            }
        }
        .bentoCard()
        .padding(.horizontal, BerryTheme.Space.md)
        .padding(.bottom, BerryTheme.Space.sm)
        // The scope has to exist before it can be reviewed, and it has to be
        // reviewed before it can be consented to (Task 12).
        .task(id: report.attachContext) {
            guard report.attachContext else { return }
            controller.prepareReportContextSummary()
        }
    }

    /// Confirming with context attached is only possible once the summary
    /// that context consists of has actually been fetched and shown — the
    /// confirmation binds those exact bytes.
    private func canConfirmReport(_ report: AISession.PendingReport) -> Bool {
        !report.attachContext || controller.reportContextSummary != nil
    }

    /// What "attach recent conversation" actually means, in the words that
    /// will be submitted. Model-authored text, so never routed through `L()`.
    @ViewBuilder
    private var reportContextScope: some View {
        if let summary = controller.reportContextSummary {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("This summary will be attached:"))
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    Text(summary)
                        .font(.caption)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                .frame(maxHeight: 90)
            }
        } else if controller.reportContextSummaryUnavailable {
            Label(
                L("Couldn't prepare the conversation summary. Try again, or send the report without it."),
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption).foregroundStyle(.secondary)
        } else {
            Label(L("Preparing the conversation summary…"), systemImage: "clock")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// The confirmed draft (Task 11): still editable, showing whether its
    /// `report_ready_token` currently matches what's displayed. Editing the
    /// text or the attach-context choice invalidates the token immediately
    /// (recomputed live — see `AISession.reportReadyToken`). Submitting
    /// (Task 12) is a deliberate action here and only here — becoming ready
    /// never sends anything by itself.
    private func confirmedReportCard(_ draft: AISession.ConfirmedReportDraft) -> some View {
        let isReady = controller.reportReadyToken != nil
        let isSubmitting = controller.reportSubmissionState == .submitting
        return VStack(alignment: .leading, spacing: 8) {
            Label(
                isReady ? L("Report ready to send") : L("Report changed since it was confirmed"),
                systemImage: isReady ? "checkmark.seal" : "exclamationmark.triangle"
            )
            .font(.subheadline.weight(.semibold))
            TextEditor(text: Binding(
                get: { draft.text },
                set: { controller.updateConfirmedReportDraftText($0) }
            ))
            .font(.system(.callout, design: .monospaced))
            .scrollContentBackground(.hidden)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            .frame(maxHeight: 120)
            .disabled(isSubmitting)
            Toggle(L("Attach recent conversation for context"), isOn: Binding(
                get: { draft.includeContext },
                set: { controller.updateConfirmedReportDraftAttachContext($0) }
            ))
            .font(.caption)
            .disabled(isSubmitting)
            if draft.includeContext, let summary = draft.conversationSummary {
                // Exactly the bytes that were consented to, still on show
                // right up to the moment they are sent.
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("This summary will be attached:"))
                        .font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        Text(summary)
                            .font(.caption)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    .frame(maxHeight: 90)
                }
            }
            if case let .failed(failure) = controller.reportSubmissionState {
                Label(reportSubmissionFailureMessage(failure), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(L("Dismiss")) {
                    controller.dismissConfirmedReportDraft()
                }
                .disabled(isSubmitting)
                Button(isSubmitting ? L("Sending…") : L("Send Report")) {
                    controller.submitConfirmedReport()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!isReady || isSubmitting)
            }
        }
        .bentoCard()
        .padding(.horizontal, BerryTheme.Space.md)
        .padding(.bottom, BerryTheme.Space.sm)
    }

    /// The submitted acknowledgement (Task 12). Shown once the confirmed card
    /// is gone, so the flow visibly ends somewhere instead of the card just
    /// disappearing.
    private var reportSubmittedBar: some View {
        HStack {
            Label(L("Report sent."), systemImage: "checkmark.seal")
                .font(.caption)
            Spacer()
            Button(L("Dismiss")) { controller.dismissConfirmedReportDraft() }
                .buttonStyle(.plain)
                .font(.caption)
        }
        .padding(.horizontal, BerryTheme.Space.md)
        .padding(.vertical, BerryTheme.Space.sm)
    }

    /// Bounded, local wording for every refusal `/v1/agent/report` can
    /// answer with. Backend refusal bodies are never rendered verbatim.
    private func reportSubmissionFailureMessage(
        _ failure: AISession.ReportSubmissionFailure
    ) -> String {
        switch failure {
        case .reviewExpired:
            return L("Your review of this report expired. Please confirm it again.")
        case .notReady:
            return L("This report is no longer ready to send. Please confirm it again.")
        case .alreadySubmitted:
            return L("This report was already sent.")
        case .tooLarge:
            return L("This report is too large to send. Shorten it and try again.")
        case .unavailable:
            return L("Couldn't reach the AI service. Try sending again.")
        case .notAuthorized:
            return L("Your session has expired or is not authorized (401).")
        case .clientError:
            return L("BerryDB couldn't send this report.")
        }
    }

    private func clarificationCard(_ clarification: AISession.PendingClarification) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L("Clarification needed"), systemImage: "questionmark.bubble")
                .font(.subheadline.weight(.semibold))
            Text(clarification.question)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let reason = clarification.reason, !reason.isEmpty {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !clarification.choices.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(clarification.choices, id: \.self) { choice in
                            Button(choice) {
                                clarificationAnswer = ""
                                controller.resolveClarification(.answer(choice))
                            }
                            .buttonStyle(.bordered)
                            .disabled(controller.isInteractionResolving)
                        }
                    }
                }
            }
            if clarification.allowFreeText {
                TextField(L("Your answer"), text: $clarificationAnswer)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        let answer = clarificationAnswer
                        clarificationAnswer = ""
                        controller.resolveClarification(.answer(answer))
                    }
                    .disabled(controller.isInteractionResolving)
            }
            HStack {
                Button(L("Cancel")) {
                    clarificationAnswer = ""
                    controller.resolveClarification(
                        .cancel(displayText: L("Cancel"))
                    )
                }
                .keyboardShortcut(.cancelAction)
                .disabled(controller.isInteractionResolving)
                Button(L("Decline")) {
                    clarificationAnswer = ""
                    controller.resolveClarification(.decline(displayText: L("Decline")))
                }
                .disabled(controller.isInteractionResolving)
                Spacer()
                if clarification.allowFreeText {
                    Button(L("Answer")) {
                        let answer = clarificationAnswer
                        clarificationAnswer = ""
                        controller.resolveClarification(.answer(answer))
                    }
                    .disabled(clarificationAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        controller.isInteractionResolving
                            || clarificationAnswer
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .isEmpty
                    )
                }
            }
        }
        .bentoCard()
        .padding(.horizontal, BerryTheme.Space.md)
        .padding(.bottom, BerryTheme.Space.sm)
    }

    private func errorBar(_ error: String) -> some View {
        let displayError = switch error {
        case "agent_step_limit":
            L("The assistant reached its tool-step limit. Try a more specific request.")
        case "invalid_interaction_contract":
            L("The AI interaction could not be verified.")
        case "insufficient_credit":
            L("Your AI credit balance is empty.")
        case "quota_exceeded":
            L("AI token quota exhausted for this billing period.")
        case "trial_reactivation_required":
            L("Your trial predates email-based usage tracking. Sign out and start a new trial to keep using AI.")
        default:
            error
        }
        return HStack(spacing: 8) {
            Label(displayError, systemImage: "xmark.octagon.fill")
                .font(.caption).foregroundStyle(.red)
            Spacer()
            CopyButton(text: displayError, help: L("Copy error"))
            if error == "insufficient_credit" {
                Button(L("Add Credit"), action: onUpgrade).controlSize(.small)
            } else if error == "trial_reactivation_required" {
                Button(L("Open License"), action: onUpgrade).controlSize(.small)
            } else if error.localizedCaseInsensitiveContains("quota") {
                Button(L("Upgrade"), action: onUpgrade).controlSize(.small)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func localizedCapabilityError(_ key: String) -> String {
        switch key {
        case "The local AI capability set is invalid.":
            return L("The local AI capability set is invalid.")
        case "An AI capability is not available.":
            return L("An AI capability is not available.")
        case "Update BerryDB to continue using AI.":
            return L("Update BerryDB to continue using AI.")
        default:
            return L("AI capability negotiation failed.")
        }
    }

    private func localizedControlDeliveryError(_ key: String) -> String {
        switch key {
        case "Your response may have been received, so BerryDB will not send it again automatically.":
            return L("Your response may have been received, so BerryDB will not send it again automatically.")
        case "This AI request expired. Ask the agent to try again.":
            return L("This AI request expired. Ask the agent to try again.")
        case "The saved AI request could not be restored safely.":
            return L("The saved AI request could not be restored safely.")
        default:
            return L("The result may have been received, so BerryDB stopped safely instead of sending it twice.")
        }
    }

    // MARK: - Composer + quota

    private var isCommandPaletteShowing: Bool {
        controller.commandQuery != nil && !commandPaletteDismissed && !controller.matchingCommands.isEmpty
    }

    /// AI-32: mirrors `isCommandPaletteShowing`. In practice mutually
    /// exclusive with it — `commandQuery` requires the draft to *start* with
    /// "/" with no space anywhere yet, while typing "@{" past that point
    /// already means a space came first — but each check stands on its own
    /// rather than assuming the other's state.
    private var isMentionPaletteShowing: Bool {
        controller.artifactMentionQuery != nil && !mentionPaletteDismissed && !controller.matchingMentions.isEmpty
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isCommandPaletteShowing {
                CommandSuggestionsView(
                    commands: controller.matchingCommands,
                    selectedIndex: selectedCommandIndex,
                    onSelect: acceptCommand
                )
            }
            if isMentionPaletteShowing {
                ArtifactMentionSuggestionsView(
                    items: controller.matchingMentions,
                    selectedIndex: selectedMentionIndex,
                    onSelect: acceptMention
                )
            }
            editingMessageStrip
            queuedMessagesStrip
            HStack(alignment: .bottom, spacing: 8) {
                TextField(L("Ask the assistant…"), text: $controller.draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .onSubmit(send)
                    .focused($promptFieldFocused)
                    // Deliberately not disabled for a pending approval/
                    // interaction/exhausted quota: AISession.send already
                    // queues correctly in every one of those states (same as
                    // it does mid-stream, above) and shows the real error
                    // from the backend if a send genuinely can't proceed —
                    // pre-blocking the composer on a client-side guess about
                    // what might fail meant a stale or wrong guess could
                    // strand the user with no way to even attempt sending and
                    // no error to explain why.
                    .onChange(of: controller.isStreaming) { _, isStreaming in
                        // Only steal focus back if it isn't already here — forcing
                        // it unconditionally (even when the field is already
                        // focused) re-triggers macOS's default "select all on
                        // focus" behavior, which can silently select-then-clobber
                        // whatever the user is already mid-typing for their next
                        // message the instant an earlier turn ends (especially
                        // disruptive when a turn fails almost immediately, e.g.
                        // an unreachable backend, since this can then fire
                        // repeatedly in quick succession).
                        if !isStreaming, !promptFieldFocused { promptFieldFocused = true }
                    }
                // Kept visible (not swapped for a ProgressView) while streaming:
                // AISession.send already queues a turn typed during an active
                // stream (shown in queuedMessagesStrip below, not as a
                // transcript bubble until it actually runs), running it the
                // moment the current one finishes — swapping this out for a
                // spinner removed the only way to trigger that except Enter,
                // making a click-to-send user think a new prompt couldn't be
                // sent until the reply finished. The transcript's own
                // TypingIndicator already carries the "still streaming" cue.
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(L("Send"))
                // Without this, a click while the composer TextField has focus
                // gets consumed resigning first responder instead of firing the
                // button — same quirk the other buttons in this file already
                // work around; this one was missing it (first click "does
                // nothing", second click actually sends).
                .focusEffectDisabled()
                // A second, independent path to the same send() as the
                // TextField's .onSubmit above — `axis: .vertical` TextFields
                // are documented to be inconsistent about firing onSubmit on
                // plain Return (it's the multi-line-growing mode, so some
                // platform/state combinations treat Return as a newline
                // instead), which read as "sometimes Enter just doesn't send".
                // A Button's .keyboardShortcut is a separate, well-established
                // AppKit-backed mechanism, so this closes the gap regardless
                // of which one macOS actually honors for a given keypress. Not
                // a double-send risk even if both fire for one Return: send()
                // clears the draft synchronously via prepareSend(), and a
                // second call finds an already-empty draft and no-ops
                // (AIPanelController.prepareSend()).
                // Safe alongside the command/mention palettes too — send()
                // itself redirects to acceptHighlightedCommand()/
                // acceptHighlightedMention() first when either is showing,
                // before this would ever reach the network.
                //
                // Only bound while no interaction card is showing: every
                // approval/report/clarification card below also binds its
                // primary action to `.keyboardShortcut(.defaultAction)` (the
                // same physical Return key), and SwiftUI doesn't define which
                // of two live shortcuts for the same key wins — pressing
                // Return while typing a new message could silently trigger
                // "Run"/"Confirm Report"/"Answer" instead of sending. The
                // TextField's .onSubmit above still covers Return in that
                // state; only the extra shortcut fallback is withheld.
                .keyboardShortcut(hasCompetingReturnShortcutCard ? nil : KeyboardShortcut(.return, modifiers: []))
                .disabled(controller.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(10)
        .onChange(of: controller.commandQuery) { _, _ in
            selectedCommandIndex = 0
            commandPaletteDismissed = false
        }
        .onChange(of: controller.artifactMentionQuery) { _, _ in
            selectedMentionIndex = 0
            mentionPaletteDismissed = false
        }
        .onKeyPress(.upArrow) { moveCommandSelection(by: -1) }
        .onKeyPress(.upArrow) { moveMentionSelection(by: -1) }
        .onKeyPress(.downArrow) { moveCommandSelection(by: 1) }
        .onKeyPress(.downArrow) { moveMentionSelection(by: 1) }
        .onKeyPress(.escape) { dismissCommandPalette() }
        .onKeyPress(.escape) { dismissMentionPalette() }
        .onKeyPress(.return) { acceptHighlightedCommand() }
        .onKeyPress(.return) { acceptHighlightedMention() }
    }

    /// Shown above the composer while editing a past message (AI-35) instead
    /// of drafting a new one, so it's clear Send will replace that message
    /// rather than append a new turn.
    @ViewBuilder
    private var editingMessageStrip: some View {
        if controller.editingMessageID != nil {
            HStack(spacing: 4) {
                Label(L("Editing message"), systemImage: "pencil")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L("Cancel")) {
                    controller.editingMessageID = nil
                    controller.draft = ""
                }
                .buttonStyle(.borderless)
                .focusEffectDisabled()
                .font(.caption)
            }
            .padding(.horizontal, 4)
        }
    }

    /// Messages typed while a turn/interaction was in flight — pinned above
    /// the input as a compact list, not as transcript bubbles, so the user
    /// can see something is waiting without it reading like it already sent.
    /// Each queued message is reduced to its first non-blank line so a long
    /// or multi-line prompt doesn't blow up this strip's height.
    @ViewBuilder
    private var queuedMessagesStrip: some View {
        let messages = controller.queuedMessages
        if !messages.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                // Enumerates `messages` itself (not a `compactMap`'d preview
                // list) so each row's index always matches what
                // `removeQueuedMessage(at:)` expects — a preview-only list
                // would drop indices for any (should-never-happen) blank
                // queued message and silently misalign the rest.
                ForEach(Array(messages.enumerated()), id: \.offset) { index, message in
                    if let preview = Self.queuedMessagePreview(message) {
                        HStack(spacing: 4) {
                            Label(preview, systemImage: "clock")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer()
                            Button {
                                controller.removeQueuedMessage(at: index)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .focusable(false)
                            .focusEffectDisabled()
                            .help(L("Remove from queue"))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }
    }

    /// First non-blank, trimmed line of a queued message, or `nil` for a
    /// message that's entirely whitespace/blank lines (shouldn't normally
    /// happen — `AISession.send` already trims and rejects an empty
    /// message before queuing — but never render a blank strip row for one).
    private static func queuedMessagePreview(_ message: String) -> String? {
        for line in message.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// Returns `.ignored` whenever the palette isn't showing, so plain
    /// arrow-key cursor movement / Escape / Enter-to-send in the composer
    /// are completely unaffected when the user isn't typing a "/" command.
    private func moveCommandSelection(by delta: Int) -> KeyPress.Result {
        guard isCommandPaletteShowing else { return .ignored }
        let count = controller.matchingCommands.count
        selectedCommandIndex = max(0, min(count - 1, selectedCommandIndex + delta))
        return .handled
    }

    private func dismissCommandPalette() -> KeyPress.Result {
        guard isCommandPaletteShowing else { return .ignored }
        commandPaletteDismissed = true
        return .handled
    }

    private func acceptHighlightedCommand() -> KeyPress.Result {
        guard isCommandPaletteShowing, selectedCommandIndex < controller.matchingCommands.count else { return .ignored }
        acceptCommand(controller.matchingCommands[selectedCommandIndex])
        return .handled
    }

    private func acceptCommand(_ command: ChatCommand) {
        controller.draft = "/\(command.name) "
        promptFieldFocused = true
    }

    private func moveMentionSelection(by delta: Int) -> KeyPress.Result {
        guard isMentionPaletteShowing else { return .ignored }
        let count = controller.matchingMentions.count
        selectedMentionIndex = max(0, min(count - 1, selectedMentionIndex + delta))
        return .handled
    }

    private func dismissMentionPalette() -> KeyPress.Result {
        guard isMentionPaletteShowing else { return .ignored }
        mentionPaletteDismissed = true
        return .handled
    }

    private func acceptHighlightedMention() -> KeyPress.Result {
        guard isMentionPaletteShowing, selectedMentionIndex < controller.matchingMentions.count else { return .ignored }
        acceptMention(controller.matchingMentions[selectedMentionIndex])
        return .handled
    }

    /// Replaces the trailing "@query" fragment (see
    /// `AIPanelController.artifactMentionQuery`) with the chosen item's
    /// mention text, leaving the rest of the draft untouched — unlike
    /// `acceptCommand`, which overwrites the whole draft (safe there only
    /// because a "/" command always starts at column 0). The inserted text
    /// is still bracketed (`@{Name}`), even though the trigger that opens
    /// the palette is just a bare "@" — the brackets give the model an
    /// unambiguous end to a multi-word name, sent as plain text exactly as
    /// it reads here: no hidden id token. `get_artifact`/`get_schema`/
    /// `search_schema` already let the model resolve a name it needs to act
    /// on, so a fragile resolve-at-send-time step (and the "what if it was
    /// renamed/deleted since" edge cases that come with it) isn't needed for
    /// this to be useful.
    private func acceptMention(_ item: ArtifactMentionItem) {
        guard let atIndex = controller.draft.range(of: "@", options: .backwards)?.lowerBound else { return }
        controller.draft.replaceSubrange(
            atIndex..<controller.draft.endIndex, with: "@{\(item.name)} "
        )
        promptFieldFocused = true
    }

    /// Always present while the panel is usable — a permanent fixture, not
    /// something that comes and goes with `controller.balance`'s load state,
    /// so usage is never just missing from the screen. `bind()` now kicks off
    /// an eager `refreshBalance` as soon as the session is built, so the
    /// "Loading…" row below is normally only visible for a moment right after
    /// connecting, not after every send.
    @ViewBuilder
    private var balanceFooter: some View {
        Divider()
        HStack {
            if let balance = controller.balance {
                if balance.plan == "trial" {
                    // Trial — same flat token-count display as the pre-TM-10
                    // model. (Balance/models are always present now too, but
                    // this compact footer only has room for the one bar
                    // that's actually gating this account right now; the
                    // License sheet shows all three together.)
                    let tokenQuota = balance.tokenQuota
                    Text(tokenQuota.limit > 0
                        ? L("\(balance.plan) · \(tokenQuota.used)/\(tokenQuota.limit) tokens")
                        : L("\(balance.plan) · Unlimited"))
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    if tokenQuota.limit > 0 {
                        ProgressView(value: Double(tokenQuota.used), total: Double(tokenQuota.limit))
                            .frame(width: 80)
                    }
                } else {
                    // Regular pay-as-you-go account — a dollar balance plus
                    // every selectable model's estimated tokens remaining
                    // (not just the one currently picked for the next
                    // message), so a user can compare models before choosing.
                    let dollars = String(format: "%.2f", Double(balance.balanceMicros) / 1_000_000)
                    let perModel = balance.models
                        .map { "\($0.name): ~\($0.tokensRemaining.formatted(.number.notation(.compactName)))" }
                        .joined(separator: " · ")
                    HStack(spacing: 3) {
                        if balance.lowBalance {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .help(L("Your balance is running low — add more credit soon."))
                        }
                        Text(perModel.isEmpty ? L("$\(dollars) credit") : L("$\(dollars) credit · \(perModel)"))
                            .font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer()
                    if !balance.models.isEmpty {
                        Picker("", selection: $selectedModel) {
                            Text(L("Default model")).tag("")
                            ForEach(balance.models) { model in
                                Text(model.name).tag(model.id)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                    }
                }
            } else {
                Text(L("Loading usage…"))
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    // AI-35: plain methods (an explicitly-`TurnView`-typed builder, plus its
    // helpers) rather than constructing TurnView(...) with all its trailing
    // closures directly inside the transcript ForEach — inline there, it
    // pushed the call past what the type checker would resolve in reasonable
    // time (SwiftUI's "too many arguments/closures in one expression" trap);
    // a plain function with a concrete return type sidesteps it.
    private func turnView(for turn: AITurn, in currentTranscript: [AITurn]) -> TurnView {
        TurnView(
            turn: turn,
            // Only the last turn can still be streaming; drives the
            // "thinking" indicator before the first token arrives.
            isStreaming: Self.isTurnStreaming(
                sessionIsStreaming: controller.aiSession?.isStreaming == true,
                isLastTurn: turn.id == currentTranscript.last?.id
            ),
            onOpenArtifact: { artifactID in controller.openArtifact?(artifactID) },
            onOpenObject: { objectID in controller.openObject?(objectID) },
            onOpenTextInTab: { text in controller.openTextInTab?(text) },
            onOpenMermaidInTab: { source in controller.openMermaidInTab?(source) },
            onLayoutChange: { controller.noteWorkingBlockLayoutChange() },
            // AI-35: edit reuses the exact composer pre-fill pattern
            // `/command`/`@mention` autocomplete already use elsewhere in
            // this file.
            canEditMessages: controller.aiSession?.isStreaming != true,
            siblingIDs: siblingIDs(for: turn),
            onEditMessage: beginEditingMessage,
            onSelectSibling: selectSibling,
            mentionCandidates: { query in controller.mentionCandidates?(query) ?? [] }
        )
    }

    private func siblingIDs(for turn: AITurn) -> [UUID] {
        guard let messageID = turn.messageID else { return [] }
        return controller.aiSession?.siblings(of: messageID) ?? []
    }

    /// Loads a past message back into the composer for editing — the same
    /// pre-fill pattern `/command`/`@mention` autocomplete already use.
    private func beginEditingMessage(_ messageID: UUID) {
        guard let turn = controller.aiSession?.transcript.first(where: { $0.messageID == messageID }) else { return }
        controller.editingMessageID = messageID
        controller.draft = turn.text
        promptFieldFocused = true
    }

    private func selectSibling(_ messageID: UUID) {
        Task { await controller.aiSession?.selectSibling(messageID: messageID) }
    }

    private func send() {
        if isCommandPaletteShowing {
            _ = acceptHighlightedCommand()
            return
        }
        if isMentionPaletteShowing {
            _ = acceptHighlightedMention()
            return
        }
        // prepareSend() runs synchronously, on this same MainActor call stack
        // (the button/onSubmit action), so both the draft clearing and the
        // user's own transcript bubble (via AISession.admitSend) show up the
        // instant Enter/Send fires — neither waits for a new Task to get a
        // turn on the MainActor, which a previous turn still streaming (a
        // state write per SSE delta) or any other MainActor work can hold up
        // unpredictably. Only the actual network dispatch needs the Task.
        guard let prepared = controller.prepareSend() else { return }
        // Sending is an explicit "I want to watch what happens next" signal —
        // resume auto-scroll even if the user had scrolled up to read
        // something earlier in this same conversation, same as most chat
        // apps. Otherwise a turn from before they scrolled up would leave
        // `isPinnedToBottom` false indefinitely, and the new turn/response
        // would stream in below the fold with no auto-scroll at all until
        // they happened to scroll back down manually.
        scrollToBottomImmediately(reason: "send()")
        Task(priority: .userInitiated) { await controller.send(prepared) }
    }

    /// Scrolls to the newest turn(s) directly and synchronously — called
    /// from `send()`, and from `controller.onTurnAdmitted` (wired below) for
    /// a queued message (AI-08) getting its own bubble once the previous
    /// turn finishes streaming. Both are "a new turn just appeared, watch
    /// what happens next" moments; neither should wait on the reactive
    /// `onChange(of: transcript.count)` + `DispatchQueue
    /// .main.asyncAfter(0.05)` path — that fixed delay races against
    /// whatever else SwiftUI is doing on the main thread for the rest of the
    /// same update cycle (laying out the new turn(s), plus everything
    /// already in a longer conversation), and lost badly enough in a live
    /// report to leave the transcript unscrolled for multiple seconds.
    ///
    /// Cancels any in-progress/residual scroll tracking first — reported
    /// live: a real (if brief/residual) scroll gesture caught mid-flight by
    /// `ScrollViewTracker` right around this call left `isUserScrolling`
    /// true for a bit longer, so `checkBottomState` re-unpinned the view
    /// again moments after this function's own scroll, undoing it. An
    /// explicit new turn overrides that unambiguously. `withAnimation` does
    /// double duty: it lets SwiftUI settle the new row's layout as part of
    /// the same transaction this scroll targets, rather than scrolling to an
    /// anchor that hasn't been positioned yet.
    private func scrollToBottomImmediately(reason: String) {
        DiagnosticLog.default.event("scroll: \(reason) resetting isPinnedToBottom", detail: "wasAlready=\(isPinnedToBottom)")
        scrollCoordinator?.forceScrollToBottom()
        isPinnedToBottom = true
        withAnimation {
            scrollProxy?.scrollTo(Self.scrollBottomID, anchor: .bottom)
        }
    }

    // MARK: - Helpers

    private func unavailable(_ title: String, systemImage: String, message: String) -> some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(message))
            .frame(maxHeight: .infinity)
    }

    /// A short warning for the approval card. Nil for a safe statement.
    private func dangerNote(_ level: DangerLevel) -> String? {
        switch level {
        case .safe:
            nil
        case let .confirm(reason):
            reasonText(reason)
        case let .typedConfirm(objectName, reason):
            "\(reasonText(reason)) (\(objectName))"
        }
    }

    private func reasonText(_ reason: DangerReason) -> String {
        switch reason {
        case .updateWithoutWhere: L("UPDATE without a WHERE clause")
        case .deleteWithoutWhere: L("DELETE without a WHERE clause")
        case .writeOnProduction: L("Writes to a production database")
        case .dropOnProduction: L("DROP on a production database")
        case .truncateOnProduction: L("TRUNCATE on a production database")
        case .deleteData: L("Deletes data")
        case .dropObject: L("Drops an object")
        case .truncateTable: L("Empties a table")
        case .deleteBatch(let count): L("Contains \(count) data-deleting statements")
        }
    }
}

struct TurnView: View {
    let turn: AITurn
    /// This turn is the live one and no token has landed yet → show the
    /// "thinking" indicator instead of an empty bubble (which read as a dark box).
    var isStreaming = false
    /// AI-31 (docs/draft/09.md): opens the artifact a chip below the bubble
    /// links to — `WorkspaceViewModel.openArtifact(id:)` via `AIPanelController`.
    var onOpenArtifact: (UUID) -> Void = { _ in }
    /// AI-32: opens the table/view a linkified `@{Name}` mention in the
    /// user's own bubble resolved to — `WorkspaceViewModel.selectObject(id:)`.
    var onOpenObject: (String) -> Void = { _ in }
    /// docs/feature/09: Cmd-click on a working-block action's payload.
    var onOpenTextInTab: (String) -> Void = { _ in }
    /// AI-34: opens a mermaid diagram in the answer bubble (or a step's
    /// narration) as its own zoomable tab.
    var onOpenMermaidInTab: (String) -> Void = { _ in }
    /// Forwarded from the working block when it expands/collapses.
    var onLayoutChange: () -> Void = {}
    /// AI-35: false while anything in the session is streaming — editing
    /// truncates the transcript, which has no defined meaning mid-stream
    /// (there's no cancellation path for the stream that's still writing to
    /// the very turns being truncated).
    var canEditMessages = true
    /// Every version of this (user) turn's message, oldest first — nav shows
    /// only when this has more than one entry.
    var siblingIDs: [UUID] = []
    /// Opens the composer pre-filled with this message's text, editing it in
    /// place instead of drafting a new send.
    var onEditMessage: (UUID) -> Void = { _ in }
    /// Switches the active version at this turn's fork point.
    var onSelectSibling: (UUID) -> Void = { _ in }

    /// The answer renders as soon as there is any of it — it types out again.
    ///
    /// This used to be withheld until `workDuration` landed, to satisfy
    /// docs/feature/09 §block response ("chỉ xuất hiện khi working done"). The
    /// real reason that gate was needed is that narration and the answer both
    /// arrived as `message.delta`: showing text early meant showing narration
    /// that then jumped into a sub-block. Narration now has its own
    /// `progress.note` channel (berrydb-api's `note_progress`), so `turn.text`
    /// is only ever the answer and there is nothing to hide.
    ///
    /// §block response is still honoured in the part that matters — the working
    /// block collapses to "Worked for Xs" when the turn settles — but its
    /// literal reading cost streaming, which reads worse than the flicker it
    /// avoided.
    var showsResponseText: Bool {
        !turn.text.isEmpty
    }

    /// Whether this turn has a working block at all.
    var hasWorkingBlock: Bool {
        turn.hadToolCall || turn.hadReasoning || !turn.workSteps.isEmpty
    }
    /// AI-32: resolves an `@{Name}` mention's exact name against the same
    /// candidate list the composer's autocomplete used, so an already-sent
    /// bubble can re-derive which artifact/object (if any) it points to.
    var mentionCandidates: (String) -> [ArtifactMentionItem] = { _ in [] }

    var body: some View {
        switch turn.role {
        case .user:
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 4) {
                    Spacer()
                    if let messageID = turn.messageID, siblingIDs.count > 1,
                       let index = siblingIDs.firstIndex(of: messageID) {
                        siblingNav(currentIndex: index, ids: siblingIDs)
                    }
                    if canEditMessages, let messageID = turn.messageID {
                        Button { onEditMessage(messageID) } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)
                        .focusEffectDisabled()
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .help(L("Edit Message"))
                    }
                    CopyButton(text: turn.text, help: L("Copy message"))
                    Text(L("You"))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)

                // AI-35: markdown, same as the assistant bubble — pre-process
                // `@{mention}` spans into markdown link syntax first so
                // `MarkdownMessageView`'s AttributedString(markdown:) parse
                // turns them into real links (AI-32 stays working); the
                // openURL handler below is unchanged, just re-scoped to wrap
                // this instead of a plain Text.
                MarkdownMessageView(text: styledMessageMarkdown(turn.text), onOpenMermaidInTab: onOpenMermaidInTab)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .foregroundStyle(.white) // Always white text on accent background for high contrast
                    .background(
                        LinearGradient(
                            colors: [BerryTheme.accent, BerryTheme.accent.opacity(0.85)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                    .environment(\.openURL, OpenURLAction { url in
                        guard url.scheme == Self.mentionURLScheme, let host = url.host else { return .discarded }
                        guard let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                            .queryItems?.first(where: { $0.name == "id" })?.value
                        else { return .discarded }
                        switch host {
                        case "artifact":
                            guard let uuid = UUID(uuidString: id) else { return .discarded }
                            onOpenArtifact(uuid)
                        case "object":
                            onOpenObject(id)
                        default:
                            return .discarded
                        }
                        return .handled
                    })
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(BerryTheme.accent)
                    Text(L("Assistant"))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    if !turn.text.isEmpty {
                        Spacer()
                        // Copy the whole reply (raw markdown), next to the per-block copies.
                        CopyButton(text: turn.text, help: L("Copy message"))
                    }
                }
                .padding(.horizontal, 4)

                if !turn.plan.isEmpty {
                    DisclosureGroup {
                        Text(turn.plan)
                            .font(.system(size: 11))
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    } label: {
                        Label(L("Plan"), systemImage: "list.bullet.rectangle")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 10).fill(BerryTheme.bento.opacity(0.5)))
                }

                // `.id(turn.id)` below is load-bearing. `TurnWorkSummary` holds
                // `@State` (`isExpanded`, seeded from `duration`), and SwiftUI
                // reuses state for whatever view occupies the same position in a
                // container. Inside this conditional the blocks of two different
                // turns occupy that position in sequence, so a new turn's block
                // was being handed the previous turn's state — reported as an
                // already-finished turn showing "Worked for Xs" while the new one
                // was still reasoning. Tying identity to the turn forces fresh
                // state per turn.
                // Grouped so the animation modifiers below cover both: a
                // turn whose first round narrates in plain prose instead of
                // calling `note_progress` streams that prose live into
                // `turn.text` (the plain-chat fast path has no way to know
                // yet that a tool call is coming), then has it retroactively
                // moved into the working block's step narration the instant
                // the first tool call arrives (`AISession`'s `.toolCall`
                // case) — `hasWorkingBlock` and `showsResponseText` flip
                // together in that same instant, replacing this whole
                // section's content in one step. Reported live: without an
                // animation tied to that transition, the typing indicator
                // reappearing and the working block appearing read as the
                // dots "jumping" onto the working block's content instead of
                // a contained transition in their own row.
                Group {
                    if hasWorkingBlock {
                        TurnWorkSummary(
                            steps: turn.workSteps,
                            duration: turn.workDuration,
                            workStartedAt: turn.workStartedAt,
                            onOpenArtifact: onOpenArtifact,
                            onOpenTextInTab: onOpenTextInTab,
                            onOpenMermaidInTab: onOpenMermaidInTab,
                            onLayoutChange: onLayoutChange
                        )
                        .id(turn.id)
                    }

                    if !showsResponseText {
                        // Before the first token, or still working: a live pulse,
                        // never an empty filled bubble.
                        if isStreaming { TypingIndicator() }
                    } else {
                        MarkdownMessageView(text: turn.text, isStreaming: isStreaming, onOpenMermaidInTab: onOpenMermaidInTab)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        // No pulse beside text that is already arriving.
                        //
                        // This used to render one here so a turn between tool rounds
                        // did not look finished — necessary when the bubble was
                        // withheld until the turn settled, since visible text meant
                        // the turn was over. The answer streams now, so the text
                        // typing out IS the progress signal, and the working block
                        // above still ticks "Working… Ns" for the tool rounds.
                        // Reported as an indicator that never went away: it outlived
                        // the answer whenever `isStreaming` had not yet flipped.
                    }
                }
                .animation(.easeInOut(duration: 0.15), value: hasWorkingBlock)
                .animation(.easeInOut(duration: 0.15), value: showsResponseText)

                if !turn.artifactRefs.isEmpty {
                    artifactChips
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// One chip per artifact this turn's tool calls touched (AI-31) — a
    /// sibling of the bubble, not a `ChatBlock` case: unlike mermaid/table,
    /// which are parsed out of the model's own markdown text, an artifact ref
    /// is structured data already known at tool-call time (`AISession`'s
    /// `recordArtifactRef`), so it doesn't belong in that text parser.
    private var artifactChips: some View {
        HStack(spacing: 6) {
            ForEach(Array(turn.artifactRefs.enumerated()), id: \.offset) { _, ref in
                Button {
                    // Logged at the click site too, so "no artifact entry at
                    // all" in the log distinguishes a chip whose action never
                    // fires from one whose lookup failed downstream.
                    DiagnosticLog.default.event(
                        "artifact chip clicked",
                        detail: "id=\(ref.artifactID.uuidString) kind=\(ref.kind) title=\(ref.title)"
                    )
                    onOpenArtifact(ref.artifactID)
                } label: {
                    Label(ref.title, systemImage: ref.kind.systemImage)
                        .font(.caption2)
                        .lineLimit(1)
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(BerryTheme.bento.opacity(0.5)))
                .help(L("Open \(ref.title)"))
            }
        }
        .padding(.horizontal, 4)
    }

    /// Matches `AIPanelView.acceptMention`'s insertion format exactly
    /// (`@{item.name} `) — braces delimit a possibly multi-word name.
    private static let mentionRegex = try! NSRegularExpression(pattern: "@\\{([^{}]+)\\}")
    private static let mentionURLScheme = "berrydb-mention"

    /// Re-resolves an already-sent `@{Name}` span against the same candidate
    /// list the composer's autocomplete used, by exact (not substring) name
    /// match — a bubble only stored the literal text, not which item was
    /// chosen, so this is the only way to tell "does this still point to
    /// something" when the turn is displayed. Nil (no match — renamed,
    /// deleted, or never resolved) leaves the mention as plain text.
    func resolveMention(_ name: String) -> ArtifactMentionItem? {
        mentionCandidates(name).first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    func mentionURL(for item: ArtifactMentionItem) -> URL? {
        var components = URLComponents()
        components.scheme = Self.mentionURLScheme
        switch item {
        case .artifact(let artifact):
            components.host = "artifact"
            components.queryItems = [URLQueryItem(name: "id", value: artifact.id.uuidString)]
        case .object(let object):
            components.host = "object"
            components.queryItems = [URLQueryItem(name: "id", value: object.id)]
        }
        return components.url
    }

    /// Renders a user's own message, turning any `@{Name}` span that still
    /// resolves to a live artifact/object into a clickable, brace-stripped
    /// link (docs/draft/09.md) — an unresolved mention (renamed/deleted since
    /// it was sent) is left exactly as typed, braces and all.
    func styledMessageText(_ text: String) -> AttributedString {
        let nsText = text as NSString
        let matches = Self.mentionRegex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return AttributedString(text) }

        var result = AttributedString()
        var cursor = 0
        for match in matches {
            let fullRange = match.range
            let nameRange = match.range(at: 1)
            if fullRange.location > cursor {
                result += AttributedString(nsText.substring(with: NSRange(location: cursor, length: fullRange.location - cursor)))
            }
            let name = nameRange.location == NSNotFound ? "" : nsText.substring(with: nameRange)
            if let item = resolveMention(name), let url = mentionURL(for: item) {
                // `Text` renders a `.link` run in the system link/tint color by
                // default, which on this accent-colored bubble background is
                // nearly indistinguishable from the bubble itself — force it
                // back to the same white as the rest of the bubble's text and
                // rely on the underline alone to signal "clickable".
                var linkText = AttributedString("@\(name)")
                linkText.link = url
                linkText.foregroundColor = .white
                linkText.underlineStyle = .single
                result += linkText
            } else {
                result += AttributedString(nsText.substring(with: fullRange))
            }
            cursor = fullRange.location + fullRange.length
        }
        if cursor < nsText.length {
            result += AttributedString(nsText.substring(with: NSRange(location: cursor, length: nsText.length - cursor)))
        }
        return result
    }

    /// Same `@{Name}` resolution as `styledMessageText`, but emits markdown
    /// link syntax instead of building an `AttributedString` directly — for
    /// `MarkdownMessageView`, whose `inline(_:)` already turns `[text](url)`
    /// into a real `.link` run via `AttributedString(markdown:)`. Feeding it
    /// raw `@{Name}` (rather than pre-resolving it here) would either leak
    /// the braces as literal text or need its own mention-aware parser — this
    /// keeps mention resolution in exactly one place (AI-32).
    func styledMessageMarkdown(_ text: String) -> String {
        let nsText = text as NSString
        let matches = Self.mentionRegex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }

        var result = ""
        var cursor = 0
        for match in matches {
            let fullRange = match.range
            let nameRange = match.range(at: 1)
            if fullRange.location > cursor {
                result += nsText.substring(with: NSRange(location: cursor, length: fullRange.location - cursor))
            }
            let name = nameRange.location == NSNotFound ? "" : nsText.substring(with: nameRange)
            if let item = resolveMention(name), let url = mentionURL(for: item) {
                result += "[@\(name)](\(url.absoluteString))"
            } else {
                result += nsText.substring(with: fullRange)
            }
            cursor = fullRange.location + fullRange.length
        }
        if cursor < nsText.length {
            result += nsText.substring(with: NSRange(location: cursor, length: nsText.length - cursor))
        }
        return result
    }

    /// `‹ i/N ›` version nav for a user turn with more than one edited
    /// variant at its fork point (AI-35).
    @ViewBuilder
    private func siblingNav(currentIndex: Int, ids: [UUID]) -> some View {
        HStack(spacing: 2) {
            Button { onSelectSibling(ids[max(0, currentIndex - 1)]) } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(currentIndex == 0)

            Text("\(currentIndex + 1)/\(ids.count)")
                .monospacedDigit()

            Button { onSelectSibling(ids[min(ids.count - 1, currentIndex + 1)]) } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(currentIndex == ids.count - 1)
        }
        .buttonStyle(.borderless)
        .focusEffectDisabled()
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(.secondary)
    }
}

/// One turn's whole "working" activity (docs/feature/09) — one sub-block per
/// completed round, under a single collapse. Live-ticking "Working… Ns"
/// header while active, "Worked for Xs" once `duration` lands.
///
/// The body is `steps` only. A reasoning-mode model's raw chain-of-thought
/// used to be rendered here too, on the theory that it was free progress
/// text — but §body asks for a bounded description of each action, which the
/// trace is not, and rendering it was the dominant cost in the panel:
/// re-joining every prior step per render, then re-parsing the whole
/// accumulated string through `ChatMarkdown.parse` per token. Quadratic, and
/// with 191 reasoning events in one turn (docs/tests/crash.md) it saturated
/// the MainActor until the client ran ~14s behind a finished backend. The
/// description now comes from `AIWorkStep.narration`, which the model is
/// asked for explicitly and which every provider produces.
///
/// Expand/collapse is a PURE function of current state (`autoExpanded`),
/// not event-driven `@State` transitions — the round-boundary reset
/// (`AITurn.text` is replaced wholesale with a new round's first chunk,
/// never observably passing through "empty") means there is no reliable
/// edge to hook an `onChange` on for "this round's content just started."
///
/// The condition is simply "has the work settled": expanded until
/// `duration` lands from `message.complete`, collapsed after. It used to
/// also collapse as soon as narration text existed, on the assumption that
/// visible text was what replaced the working block on screen — but
/// `TurnView.showsResponseText` now withholds the bubble until that same
/// `duration` arrives (docs/feature/09 §block response), so text can exist
/// while still hidden and collapsing on it would leave the turn blank. Using
/// one signal for both also retires the narration/answer flicker the old
/// two-signal form could not avoid.
struct TurnWorkSummary: View {
    let steps: [AIWorkStep]
    let duration: TimeInterval?
    let workStartedAt: Date?
    var onOpenArtifact: (UUID) -> Void = { _ in }
    var onOpenTextInTab: (String) -> Void = { _ in }
    var onOpenMermaidInTab: (String) -> Void = { _ in }
    /// Called when this block expands or collapses, so the transcript can
    /// re-anchor its scroll — the height changed but no text did.
    var onLayoutChange: () -> Void = {}

    @State private var isExpanded: Bool

    init(
        steps: [AIWorkStep], duration: TimeInterval?, workStartedAt: Date?,
        onOpenArtifact: @escaping (UUID) -> Void = { _ in },
        onOpenTextInTab: @escaping (String) -> Void = { _ in },
        onOpenMermaidInTab: @escaping (String) -> Void = { _ in },
        onLayoutChange: @escaping () -> Void = {}
    ) {
        self.steps = steps
        self.duration = duration
        self.workStartedAt = workStartedAt
        self.onOpenArtifact = onOpenArtifact
        self.onOpenTextInTab = onOpenTextInTab
        self.onOpenMermaidInTab = onOpenMermaidInTab
        self.onLayoutChange = onLayoutChange
        _isExpanded = State(initialValue: duration == nil)
    }

    var autoExpanded: Bool {
        duration == nil
    }

    /// Whether this block's own turn has finished working. Drives the header's
    /// "Working… Ns" vs "Worked for Xs", and is exposed so that choice is
    /// testable per turn — a new turn showing the previous turn's settled label
    /// was reported, and the header alone gives nothing to assert on.
    var isSettled: Bool {
        duration != nil
    }

    var hasBody: Bool {
        !steps.isEmpty
    }

    var body: some View {
        Group {
            // No round has completed yet, so there is no sub-block to show —
            // a plain line, not a disclosure that opens onto nothing.
            if hasBody {
                DisclosureGroup(isExpanded: $isExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        // `id: \.id`, not `\.offset`: `AIWorkStep` has a
                        // stable identity precisely so removing one (e.g. a
                        // preview-only step dropped once its text promotes
                        // into the answer, see `AIWorkBlock.promoteProvisionalText`)
                        // does not reshuffle every later step's positional
                        // identity — the same `swift_task_dealloc` crash
                        // shape as PR #108(b), just triggered by array
                        // mutation instead of a per-step `isStreaming` flip.
                        ForEach(steps, id: \.id) { step in
                            WorkStepRow(
                                step: step,
                                // A property of the TURN, never of a step or
                                // its position (PR #108(b): keying this on
                                // index/count let opening a new step flip an
                                // EARLIER step's flag true→false→true,
                                // crashing `MarkdownMessageView`'s per-row
                                // throttle Task from being recreated too
                                // fast). Every row in a turn reads the same
                                // value, which can therefore only ever
                                // settle once, never flip back.
                                isStreaming: !isSettled,
                                onOpenArtifact: onOpenArtifact,
                                onOpenTextInTab: onOpenTextInTab,
                                onOpenMermaidInTab: onOpenMermaidInTab
                            )
                        }
                    }
                    .padding(.top, 3)
                } label: { header }
            } else {
                header
            }
        }
        // Reported live, again, after the TurnView-level fix for the block
        // appearing/disappearing (PR #118): with the block already visible,
        // a SECOND tool-call round appends a new step to `steps` with no
        // animation of its own here — an instant height change that snapped
        // whatever sits below this block (the typing indicator, in
        // TurnView) straight to its new position, reading as the dots
        // "jumping out of their row" even though the dots themselves never
        // moved. Keyed on `steps.count`, not `steps` itself: a step's
        // `provisionalText` grows on every streamed token, and animating
        // that per character would reintroduce the per-token cost this
        // project has repeatedly had to rip back out (CLAUDE.md "Performance
        // is not covered by tests"). Count only changes once per round.
        .animation(.easeInOut(duration: 0.15), value: steps.count)
        .padding(.leading, 8)
        .padding(.vertical, 2)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(width: 2)
        }
        .onChange(of: autoExpanded) { _, newValue in isExpanded = newValue }
        // Report the height change upward: the panel cannot observe this
        // `@State`, and a toggle moves no text, so without this its scroll
        // position went stale and left new content off screen.
        .onChange(of: isExpanded) { _, _ in onLayoutChange() }
    }

    @ViewBuilder
    private var header: some View {
        if let duration {
            Text(settledLabel(duration))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        } else if let workStartedAt {
            // Pure string formatting off `context.date` each tick — no
            // Task/MainActor work, so this can't feed the app's known
            // MainActor-congestion failure class.
            TimelineView(.periodic(from: workStartedAt, by: 1)) { context in
                Text(workingLabel(elapsed: context.date.timeIntervalSince(workStartedAt)))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(L("Working…"))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private func workingLabel(elapsed: TimeInterval) -> String {
        "\(L("Working…")) \(Self.elapsedLabel(elapsed))"
    }

    private func settledLabel(_ duration: TimeInterval) -> String {
        "\(L("Worked")) \(Self.elapsedLabel(duration))"
    }

    /// `mm:ss` below an hour, `h:mm:ss` past it (docs/feature/09.md's mock:
    /// `00:18`, `1:01:01`) — digits need no localization, unlike the old
    /// "Working… 5s"/"5m 3s" word-based phrasing this replaces. The same
    /// formatter backs both the live "Working" header and the settled
    /// "Worked" one, so the number reads continuously across the collapse
    /// rather than switching phrasing at the exact moment it stops moving.
    static func elapsedLabel(_ interval: TimeInterval) -> String {
        let totalSeconds = max(0, Int(interval.rounded()))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

/// One step's sub-block (docs/feature/09): un-narrated preview prose (if
/// this step is still buffering `message.delta` text, see
/// `AIWorkBlock.appendProvisionalText`) above its natural-language
/// description, followed by the action badge(s) for the tool(s) that ran —
/// description first, action after, matching the Codex working-block layout
/// in docs/feature/09.md ("Mô tả... hành động thực hiện"). A step with a
/// tool call but no narration (e.g. a lone `run_sql` with nothing to say
/// about it — the accepted gap when the model skips `note_progress`; see
/// the plan's decision not to synthesize one) still shows its action row
/// alone.
struct WorkStepRow: View {
    let step: AIWorkStep
    /// A property of the TURN (see `TurnWorkSummary`'s call site), never of
    /// this step or its position — threaded through so `MarkdownMessageView`'s
    /// reparse throttle engages for a still-open step's narration the same
    /// way it does for the main answer bubble.
    var isStreaming = false
    var onOpenArtifact: (UUID) -> Void = { _ in }
    var onOpenTextInTab: (String) -> Void = { _ in }
    var onOpenMermaidInTab: (String) -> Void = { _ in }

    /// The button's action, named so a test can exercise the wiring without
    /// driving SwiftUI. `body` calls exactly this.
    func openArtifact(_ id: UUID) {
        onOpenArtifact(id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Un-narrated `message.delta` prose this step is still
            // buffering (docs/feature/09: "đang working thì description
            // phải ở trong block working chứ") — rendered above the real
            // narration since prose always precedes a round's own note
            // within the stream, not after it.
            if !step.provisionalText.isEmpty {
                MarkdownMessageView(text: step.provisionalText, isStreaming: isStreaming, onOpenMermaidInTab: onOpenMermaidInTab)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !step.narration.isEmpty {
                MarkdownMessageView(text: step.narration, isStreaming: isStreaming, onOpenMermaidInTab: onOpenMermaidInTab)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // One row per action, expandable into its inputs/outputs
            // (docs/feature/09's `Search … Completed` block with its
            // bullets). Every tool call publishes an action the instant it
            // starts (`AIWorkBlock.toolCallStarted`), so a step with no
            // narration and no actions can't happen from a real tool call —
            // only from a bare `progress.note` with nothing following it,
            // which correctly renders narration alone, nothing here.
            ForEach(Array(step.actions.enumerated()), id: \.offset) { _, action in
                ActionRow(action: action, onOpenInTab: onOpenTextInTab)
            }
            // What this step actually produced, openable. Previously the row
            // ended at the action badge above — inert `Label` text — so a user
            // clicking the action that created a tab got no response at all
            // (docs/feature/09). A step with no artifact renders nothing here
            // rather than a dead affordance.
            ForEach(Array(step.artifactRefs.enumerated()), id: \.offset) { _, ref in
                Button {
                    openArtifact(ref.artifactID)
                } label: {
                    Label(ref.title, systemImage: ref.kind.systemImage)
                        .font(.system(size: 9, weight: .semibold))
                        .lineLimit(1)
                }
                .buttonStyle(.link)
                .help(L("Open \(ref.title)"))
            }
        }
    }
}

/// One action inside a sub-block: friendly label + status on the right, and — if
/// the tool reported any — an expandable list of the inputs it ran with and what
/// came back (docs/feature/09's `Search … Completed` with its bullets).
///
/// An action with no detail is rendered as a plain row, NOT a disclosure. A
/// disclosure that opens onto nothing is what the user reported as "Reading
/// schema / Analyzing queries không click được": it looked interactive and
/// wasn't.
struct ActionRow: View {
    let action: AIToolAction
    /// Cmd-click target: hands the action's full argument to the workspace to
    /// open as a tab.
    var onOpenInTab: (String) -> Void = { _ in }
    @State private var isExpanded = false
    @State private var isInspecting = false

    /// What a click should do, as a value. `@State` has no storage outside a
    /// rendered view tree, so a method that flipped `isInspecting` could not be
    /// asserted on from a test — this returns the decision instead, and `body`
    /// applies it. The branch is worth testing because both gestures share one
    /// hit target: getting it wrong silently collapses them into whichever
    /// branch was written last.
    enum Gesture: Equatable { case none, inspect, openInTab(String) }

    func gesture(commandHeld: Bool) -> Gesture {
        guard action.isInspectable, let payload = action.payload else { return .none }
        return commandHeld ? .openInTab(payload) : .inspect
    }

    var body: some View {
        if action.hasDetail || action.isInspectable {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 2) {
                    if action.isInspectable { payloadPreview }
                    detailList(action.inputs)
                    if !action.outputs.isEmpty {
                        Text(L("Result"))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                        detailList(action.outputs)
                    }
                }
                .padding(.top, 2)
            } label: { header }
        } else {
            header
        }
    }

    /// One truncated line of what ran/was written/was read. Click inspects the
    /// whole thing in a popover; Cmd-click opens it as a tab instead — the same
    /// pair of gestures a link uses elsewhere in the app, so it needs no
    /// explanatory chrome beyond the tooltip.
    @ViewBuilder
    private var payloadPreview: some View {
        let payload = action.payload ?? ""
        Button {
            switch gesture(commandHeld: NSEvent.modifierFlags.contains(.command)) {
            case .none: break
            case .inspect: isInspecting = true
            case let .openInTab(text): onOpenInTab(text)
            }
        } label: {
            Text(Self.oneLine(payload))
                .font(.system(size: 9, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .foregroundStyle(BerryTheme.accent)
        .help(L("Click to view, Cmd-click to open in a tab"))
        .popover(isPresented: $isInspecting, arrowEdge: .bottom) {
            payloadPopover(payload)
        }
    }

    private func payloadPopover(_ payload: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(AIToolDisplay.label(for: action.name))
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                CopyButton(text: payload, help: L("Copy"))
            }
            ScrollView {
                Text(payload)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(L("Open in a tab")) {
                isInspecting = false
                onOpenInTab(payload)
            }
            .buttonStyle(.link)
            .font(.system(size: 10))
        }
        .padding(12)
        .frame(width: 420, height: 260)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Label(
                AIToolDisplay.label(for: action.name),
                systemImage: AIToolDisplay.systemImage(for: action.name)
            )
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(BerryTheme.accent)
            Spacer()
            Text(statusText)
                .font(.system(size: 9))
                .foregroundStyle(action.status == .completed ? Color.secondary : Color.red)
        }
    }

    /// Localized here rather than in `AIToolAction.statusLabel`, which is in
    /// BerryAI and must stay display-language-neutral.
    private var statusText: String {
        switch action.status {
        case .running: return L("Running")
        case .completed: return L("Completed")
        case .denied: return L("Denied")
        case .failed: return L("Failed")
        }
    }

    /// Collapses whitespace so a multi-line statement still previews as one
    /// readable line rather than showing only its first (often `SELECT`) word.
    private static func oneLine(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func detailList(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Text("• \(item)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Raw tool name → a short, friendly action label + icon for the working
/// block's sub-blocks (docs/feature/09) — display-only, never touches
/// dispatch/policy (the registry stays server-authoritative,
/// docs/architecture/07 §2). Names mirror `berrydb-api/src/ai/
/// tool_registry.rs`'s `builtin_descriptors`; an unmapped/newer tool name
/// (a client that hasn't shipped a matching entry yet) falls back to the
/// raw name and a generic gear icon rather than hiding the sub-block.
private enum AIToolDisplay {
    private static let byName: [String: (label: String, systemImage: String)] = [
        "get_schema": (L("Reading schema"), "list.bullet.rectangle"),
        "propose_sql": (L("Drafting SQL"), "pencil"),
        "propose_query": (L("Drafting query"), "pencil"),
        "run_sql": (L("Running SQL"), "bolt"),
        "get_sample_rows": (L("Sampling rows"), "tablecells"),
        "read_current_tab": (L("Reading tab"), "doc.text"),
        "get_open_tabs": (L("Reading tabs"), "doc.on.doc"),
        "run_tab_statements": (L("Running statements"), "bolt"),
        "explain_query": (L("Explaining query"), "text.magnifyingglass"),
        "create_debug_tab": (L("Creating tab"), "plus.rectangle"),
        "get_stats": (L("Analyzing stats"), "chart.bar"),
        "graph_query": (L("Querying graph"), "point.3.connected.trianglepath.dotted"),
        "preview_migration": (L("Reviewing migration"), "arrow.triangle.branch"),
        "simulate_impact": (L("Analyzing impact"), "bolt.badge.a"),
        "get_daily_review": (L("Reading review"), "doc.text.magnifyingglass"),
        "get_ui_state": (L("Reading UI state"), "macwindow"),
        "query_ui_graph": (L("Querying UI"), "point.3.connected.trianglepath.dotted"),
        "search_conversation": (L("Searching history"), "magnifyingglass"),
        "search_schema": (L("Searching schema"), "magnifyingglass"),
        "get_slow_queries": (L("Analyzing queries"), "tortoise"),
        "perform_ui_action": (L("Navigating UI"), "cursorarrow.click"),
        "list_skills": (L("Listing skills"), "list.bullet"),
        "load_skill": (L("Loading skill"), "puzzlepiece"),
        "get_artifact": (L("Reading artifact"), "doc"),
        "get_artifact_overview": (L("Reading artifact"), "doc"),
        "read_artifact_chunk": (L("Reading artifact"), "doc"),
    ]

    static func label(for toolName: String) -> String { byName[toolName]?.label ?? toolName }
    static func systemImage(for toolName: String) -> String { byName[toolName]?.systemImage ?? "gearshape" }
}

/// Shared pulsing dot row: `TypingIndicator` uses it before the first token,
/// `TurnView` also renders it bare (no bubble/label) below text from an
/// earlier round while the turn is still going — otherwise a turn that
/// already has text renders nothing during a tool-call round trip, which
/// reads as "done" when more is actually coming.
/// One dot of the streaming pulse.
///
/// `Circle` has no intrinsic size — it fills whatever space is proposed. The
/// original wrote `.frame(...)` first and `.foregroundStyle`/`.opacity` after,
/// and those re-propose the parent's size to the shape underneath, so each dot
/// grew to fill the panel width and spilled out of its container. Sizing has to
/// be the OUTERMOST modifier here.
///
/// `phase` is a plain 0...1 value from wall-clock time (`PulsingDots`
/// below), not an `Animation.repeatForever()` — see that type's doc comment.
struct PulsingDot: View {
    let phase: Double
    let diameter: CGFloat = 6

    private var opacity: Double {
        0.25 + 0.75 * (0.5 + 0.5 * sin(phase * 2 * .pi))
    }

    var body: some View {
        Circle()
            .fill(Color.secondary)
            .opacity(opacity)
            .frame(width: diameter, height: diameter)
            .fixedSize()
    }
}

/// `Animation.repeatForever()` can misbehave when its host view is
/// inserted/removed while an ancestor's own `.animation(value:)` transaction
/// is active — which happens whenever this row appears or disappears, since
/// `TurnView` wraps that transition in one. Driving the pulse from
/// `TimelineView(.animation)` instead (same technique `TurnWorkSummary`'s
/// elapsed-time label uses) sidesteps it: no `Animation` object here for an
/// ambient transaction to catch.
private struct PulsingDots: View {
    var body: some View {
        TimelineView(.animation) { context in
            let phase = context.date.timeIntervalSinceReferenceDate / 0.6
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    PulsingDot(phase: phase - Double(index) * (0.2 / 0.6))
                }
            }
        }
        .fixedSize()
    }
}

/// Deterministic local feedback shown before any network preflight returns.
/// The text follows the app locale; it does not influence the model's language.
struct TypingIndicator: View {
    var body: some View {
        HStack(spacing: 10) {
            PulsingDots()
            Text(L("Preparing response…"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .accessibilityLabel(L("Preparing response…"))
    }
}

/// Listens to NSScrollView bounds notifications to accurately track whether the user is
/// pinned near the bottom (distanceToBottom <= 40px), avoiding false-positive off-screen triggers
/// when streamed content expands the document view.
struct ScrollViewTracker: NSViewRepresentable {
    @Binding var isPinnedToBottom: Bool
    /// Hands the coordinator back to the parent view once, so an explicit
    /// user action outside this view's own closure (`AIPanelView.send()`)
    /// can call `Coordinator.forceScrollToBottom()` directly — see its doc
    /// comment.
    var onCoordinatorReady: (Coordinator) -> Void = { _ in }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        onCoordinatorReady(context.coordinator)
        DispatchQueue.main.async {
            if let scrollView = view.enclosingScrollView {
                context.coordinator.setup(scrollView: scrollView, tracker: self)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let scrollView = nsView.enclosingScrollView {
                context.coordinator.setup(scrollView: scrollView, tracker: self)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// `@MainActor` because every member touches MainActor-only AppKit state —
    /// `NSScrollView.contentView`/`documentView`, `NSApp.currentEvent`, and the
    /// `isPinnedToBottom` binding. Without it the compiler emitted 24 warnings
    /// here (all of `warn.md`), each correctly pointing out a cross-actor read;
    /// the annotation is what the diagnostics' own notes asked for, not a
    /// suppression. The `@objc` notification selectors and `Timer` callback are
    /// already delivered on the main run loop, so nothing changes at runtime.
    @MainActor
    final class Coordinator: NSObject {
        private weak var scrollView: NSScrollView?
        private var tracker: ScrollViewTracker?
        private(set) var isUserScrolling = false
        private var userScrollTimer: Timer?
        /// Test seam — `NSApp.currentEvent` cannot be posed as any particular
        /// value from a test (it reflects whatever the real event queue last
        /// dispatched, which is `nil`/unpredictable under `swift test`'s
        /// headless run loop), so this defaults to the real API in
        /// production and lets a test substitute a fixed value instead.
        var currentEventType: () -> NSEvent.EventType? = { NSApp.currentEvent?.type }

        func setup(scrollView: NSScrollView, tracker: ScrollViewTracker) {
            self.tracker = tracker
            guard self.scrollView !== scrollView else { return }
            self.scrollView = scrollView

            let nc = NotificationCenter.default
            nc.removeObserver(self)

            nc.addObserver(
                self,
                selector: #selector(onWillStartLiveScroll(_:)),
                name: NSScrollView.willStartLiveScrollNotification,
                object: scrollView
            )
            nc.addObserver(
                self,
                selector: #selector(onDidEndLiveScroll(_:)),
                name: NSScrollView.didEndLiveScrollNotification,
                object: scrollView
            )
            nc.addObserver(
                self,
                selector: #selector(onScrollBoundsChanged(_:)),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
        }

        /// Called from an explicit user action (submitting a prompt) that
        /// unambiguously means "take me to the bottom, watch what happens
        /// next" — cancels whatever scroll-tracking state was in progress,
        /// including residual/momentum scrolling from a gesture that ended
        /// just before the action. Reported live: `send()` resetting
        /// `isPinnedToBottom = true` and scrolling immediately wasn't
        /// enough on its own — a real `willStartLiveScrollNotification`
        /// fired shortly before submitting (the tail of an earlier scroll
        /// gesture) left `isUserScrolling` genuinely true for a bit longer,
        /// so `checkBottomState` correctly-per-its-own-logic unpinned the
        /// view again moments after the explicit scroll, undoing it.
        func forceScrollToBottom() {
            isUserScrolling = false
            userScrollTimer?.invalidate()
            userScrollTimer = nil
            tracker?.isPinnedToBottom = true
        }

        @objc private func onWillStartLiveScroll(_ notification: Notification) {
            isUserScrolling = true
        }

        @objc private func onDidEndLiveScroll(_ notification: Notification) {
            isUserScrolling = false
            checkBottomState()
        }

        @objc private func onScrollBoundsChanged(_ notification: Notification) {
            // `isUserScrolling` must already be true — set reliably by
            // `onWillStartLiveScroll` — before this extends/refreshes it.
            // `NSApp.currentEvent` is a global "last dispatched event"
            // reference, not scoped to this specific bounds-change
            // notification or to whether a scroll session is actually
            // happening on THIS scroll view; using it alone to ORIGINATE
            // `isUserScrolling = true` let a burst of content-growth-driven
            // bounds changes (e.g. the two new turns a `send()` appends,
            // laid out over several frames) get misread as user scrolling
            // whenever the stale global event happened to look scroll-shaped
            // — reported live as the transcript no longer auto-scrolling
            // right after submitting a prompt. This only ever keeps an
            // ALREADY-real scroll session's timer alive through continued
            // bounds changes; it never starts one.
            if isUserScrolling, let eventType = currentEventType(),
               eventType == .scrollWheel || eventType == .leftMouseDragged {
                userScrollTimer?.invalidate()
                // `Timer`'s closure is `@Sendable`, so it cannot touch this
                // MainActor-isolated instance directly even though the timer
                // fires on the main run loop. Hop explicitly.
                userScrollTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.isUserScrolling = false
                    }
                }
            }
            checkBottomState()
        }

        private func checkBottomState() {
            guard let scrollView = scrollView,
                  let documentView = scrollView.documentView,
                  let tracker = tracker else { return }

            let visibleHeight = scrollView.contentView.bounds.height
            let contentHeight = documentView.bounds.height
            let currentY = scrollView.contentView.bounds.origin.y

            let distanceToBottom = contentHeight - (currentY + visibleHeight)

            if distanceToBottom <= 45 {
                if !tracker.isPinnedToBottom {
                    // Diagnostic-only, chasing a live report that submitting
                    // a prompt doesn't scroll to the new turns — logged only
                    // on the actual false->true transition, not every call
                    // (this fires on every scroll-view bounds change,
                    // including ones content growth causes while streaming).
                    DiagnosticLog.default.event(
                        "scroll: isPinnedToBottom -> true (checkBottomState)",
                        detail: "distanceToBottom=\(Int(distanceToBottom))"
                    )
                    DispatchQueue.main.async {
                        tracker.isPinnedToBottom = true
                    }
                }
            } else if isUserScrolling {
                if tracker.isPinnedToBottom {
                    DiagnosticLog.default.event(
                        "scroll: isPinnedToBottom -> false (checkBottomState, user scrolled)",
                        detail: "distanceToBottom=\(Int(distanceToBottom))"
                    )
                    DispatchQueue.main.async {
                        tracker.isPinnedToBottom = false
                    }
                }
            }
        }

        // `deinit` stays nonisolated, so it cannot read the MainActor-isolated
        // `userScrollTimer`. It does not need to: the timer is non-repeating
        // and captures `self` weakly, so the run loop's reference outlives this
        // object at worst until one 0.3s fire that finds `self == nil` and does
        // nothing before the timer invalidates itself. No retain cycle, no
        // callback into freed memory.
        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}
