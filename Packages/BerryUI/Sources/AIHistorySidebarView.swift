import BerryAI
import SwiftUI

/// Past-conversations panel (AI-21) that slides in from the right (the AI panel
/// is a right-hand inspector) over the whole panel body, under the header.
/// Replaces the old dropdown menu so old threads are actually
/// reachable: relative timestamps, per-row delete, and infinite scroll (keyset
/// paging in the controller). Opening a different thread is blocked while the
/// assistant is streaming (§6) — reopening the active one is fine.
struct AIHistorySidebarView: View {
    @Bindable var controller: AIPanelController
    @Binding var isPresented: Bool

    /// Set when the user taps another thread mid-stream; auto-clears after ~2s.
    @State private var streamingBlocked = false
    /// The thread currently being opened — set synchronously in `open(_:)`,
    /// before any `Task` is created, so the tapped row shows a spinner
    /// instantly instead of looking unresponsive while its `Task` waits for
    /// a possibly-busy MainActor's turn (which otherwise reads as "clicking
    /// a conversation needs multiple clicks").
    @State private var openingThreadID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("Conversation history"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            if streamingBlocked {
                banner
            }

            if controller.threads.isEmpty {
                Text(L("No saved conversations"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 40)
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.background)
    }

    private var banner: some View {
        Label(L("The assistant is replying — wait for it to finish to open another conversation."), systemImage: "hourglass")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BerryTheme.bento.opacity(0.6))
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(controller.threads) { thread in
                    row(thread)
                }
                // Infinite scroll (AI-21): the next keyset page (20 records) loads
                // automatically as this footer scrolls into view — no button.
                if controller.hasMoreThreads {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .onAppear { Task { await controller.loadMoreThreads() } }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func row(_ thread: AIThreadSummary) -> some View {
        let isActive = controller.aiSession?.currentThreadID == thread.id
        return HStack(spacing: 8) {
            Button {
                open(thread)
            } label: {
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(thread.title)
                                .font(.callout)
                                .lineLimit(1)
                            if isActive {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.tint)
                            }
                        }
                        Text(Date(timeIntervalSince1970: thread.updatedAt), format: .relative(presentation: .named))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if openingThreadID == thread.id {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .focusEffectDisabled()
            .disabled(openingThreadID != nil)

            Button {
                Task { await controller.deleteThread(thread.id) }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .focusEffectDisabled()
            .help(L("Delete conversation"))
            .accessibilityLabel(L("Delete conversation"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// Open the tapped thread and dismiss. Blocked mid-stream unless it's the
    /// already-active thread (§6) — otherwise flash the banner instead.
    /// `openingThreadID` is set here, directly on the tap's call stack,
    /// before the `Task` — see its declaration for why.
    private func open(_ thread: AIThreadSummary) {
        guard openingThreadID == nil else { return }
        let isActive = controller.aiSession?.currentThreadID == thread.id
        guard !controller.isStreaming || isActive else {
            streamingBlocked = true
            Task {
                // nanoseconds, not Task.sleep(for:) — confirmed Swift
                // runtime crash risk in release builds (swiftlang/swift#86204,
                // #84793; docs/tests/crash.md), not a style choice.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                streamingBlocked = false
            }
            return
        }
        openingThreadID = thread.id
        Task {
            await controller.openThread(thread.id)
            openingThreadID = nil
            isPresented = false
        }
    }
}
