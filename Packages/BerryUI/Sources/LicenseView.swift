import AppKit
import BerryAI
import BerryLicense
import SwiftUI

/// License management sheet (M5): shows the current entitlement, activates a
/// key, starts a trial, and lists server-driven plans. Wired to
/// `LicenseManager`; all verification is offline (N4).
struct LicenseView: View {
    @Bindable var license: LicenseManager

    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var restoreEmail = ""
    @State private var trialEmail = ""
    @State private var working: WorkingAction?
    @State private var isAddingCredit = false
    @State private var customTopupAmount = ""
    @State private var balance: AIPanelController.Balance?

    /// Seeded from the AI panel's own already-cached balance (when there is
    /// one) so the sheet doesn't start blank every time it's reopened —
    /// `balance` above is fresh `@State` on each presentation, and this
    /// sheet's own poll can take a moment (cold TLS handshake, or the
    /// provider being slow) to land its first value. This is a one-time
    /// snapshot at open, not a live binding; the `.task` poll below takes
    /// over immediately after.
    init(license: LicenseManager, initialBalance: AIPanelController.Balance? = nil) {
        self.license = license
        _balance = State(initialValue: initialBalance)
    }

    /// Which of the three actions below is in flight — tracked per-button
    /// (rather than one shared flag) so the spinner replaces the label of
    /// the button the user actually pressed instead of appearing as a
    /// separate caption elsewhere on the sheet, easy to miss during the
    /// first request's cold TLS handshake.
    private enum WorkingAction: Equatable {
        case activate, restore, trial
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    statusCard
                    lowBalanceBanner
                    if (!license.status.isEntitled && !isAppleIntelligenceActive) || isTrialOrGrace {
                        activateSection
                    }
                    subscribedPlanBanner
                    addCreditSection
                    donateSection
                    if let error = license.lastError {
                        Label(licenseErrorMessage(error), systemImage: "exclamationmark.circle")
                            .font(.callout)
                            .foregroundStyle(.red)
                            // Reported: no way to copy this text to report a
                            // bug — Label isn't selectable by default.
                            .textSelection(.enabled)
                    }
                }
                .padding(16)
            }
            // The three usage bars added real height — a fixed 560pt sheet
            // now needs a scroll to see all of them, which reads as
            // "hidden" rather than just below the fold. Per docs/ui/01,
            // sheets should fit their content rather than lean on
            // scrolling to hide overflow.
            .scrollDisabled(true)
            Divider()
            footer
        }
        .frame(width: 520, height: 760)
        .task {
            // Pull a subscription already granted to this device (e.g. the
            // post-checkout poll timed out or the app was reopened after paying).
            await license.syncFromBackend()
        }
        .task {
            // Live usage while the sheet stays open, not just a one-time
            // snapshot on appear — polls the same endpoint the AI panel
            // does, at the same cadence, so the three usage bars actually
            // move as the user spends tokens elsewhere in the app.
            while !Task.isCancelled {
                await refreshBalance()
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
    }

    /// Trial usage and per-model tokens-remaining (TM-13) — same
    /// `GET /v1/ai/balance` the AI panel footer polls, fetched here too so
    /// this sheet shows the up-to-date breakdown without needing the panel
    /// open, and right after a topup completes.
    ///
    /// Only assigns `balance` on a *successful* fetch (mirrors
    /// `AIPanelController.refreshBalance`, PR #86) — this sheet polls every
    /// 15s while open, so a single transient failure (a slow network, or the
    /// backend briefly overloaded) used to null out `balance` and blank the
    /// whole three-bar usage section until the next poll succeeded.
    private func refreshBalance() async {
        guard let token = LicenseManager.apiToken() else { return }
        guard let fetched = await AIPanelController.Balance.fetch(token: token, backendURL: LicenseManager.backendURL()) else { return }
        balance = fetched
    }

    private var isTrialOrGrace: Bool {
        switch license.status {
        case .trial, .grace: true
        default: false
        }
    }

    /// True only when Apple Intelligence access is what's active here — a
    /// real license/trial always takes precedence in the status display.
    private var isAppleIntelligenceActive: Bool {
        guard case .none = license.status else { return false }
        return AppleIntelligenceAccess.isGranted && AppleFoundationProvider.isAvailable()
    }

    /// An admin-granted comp entitlement (Pro/Intelligence are no longer
    /// sold, TM-10, but remain valid as manually-granted plans) — distinct
    /// from "topup", the plan a device's own token is upgraded to in place
    /// once it buys AI credit (TM-11 gap-fix), which isn't a subscription at
    /// all and gets its own balance display below instead of this banner.
    private var isSubscribedPaid: Bool {
        if case .active(let plan, _) = license.status, plan != "topup" { return true }
        return false
    }

    private var header: some View {
        HStack {
            Image(systemName: "key.fill")
            Text(L("BerryDB License")).font(.headline)
            Spacer()
            if isAppleIntelligenceActive {
                Label(L("Active"), systemImage: "apple.intelligence")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Label(license.status.shortLabel, systemImage: license.status.systemImage)
                    .font(.caption)
                    .foregroundStyle(license.status.tint)
            }
        }
        .padding(12)
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(statusTitle).font(.title3).fontWeight(.semibold)
            Text(statusDetail).font(.callout).foregroundStyle(.secondary)
            // Blank for a legacy trial issued before email became mandatory
            // (`trial_reactivation_required`) — nothing to show until it
            // re-activates with one.
            if let email = license.payload?.email, !email.isEmpty {
                Label(email, systemImage: "envelope")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            (isAppleIntelligenceActive ? Color.green : license.status.tint).opacity(0.10),
            in: RoundedRectangle(cornerRadius: 10)
        )
    }

    private var statusTitle: String {
        if isAppleIntelligenceActive { return L("Active") }
        return switch license.status {
        case .none: L("Not activated")
        case .trial: L("Free trial")
        case .active(let plan, _): plan == "topup" ? L("AI credit") : L("\(plan.capitalized) plan")
        case .grace: L("Renewal needed")
        case .trialExpired: L("Trial ended")
        case .fallback: L("Fallback mode")
        }
    }

    private var statusDetail: String {
        if isAppleIntelligenceActive { return L("Free with Apple Intelligence — runs entirely on this Mac, no payment needed.") }
        return switch license.status {
        case .none: L("Start a free trial or enter a license key to unlock everything.")
        case .trial(let days): L("\(days) days left in your trial.")
        // "topup" (TM-11 gap-fix) has a ~10-year expiry so it keeps
        // authorizing indefinitely — "Active — 3650 days remaining" would
        // read as an obvious bug, not a feature.
        case .active(let plan, let days):
            plan == "topup" ? L("Pay-as-you-go — top up any time below.") : L("Active — \(days) days remaining.")
        case .grace(_, let over): L("Expired \(over) days ago. You're in the grace period — renew soon.")
        case .trialExpired: L("Your free trial has ended. Add AI credit below, or activate a license key, to keep using AI.")
        case .fallback(let version): L("Running local-only features of \(version). AI is off.")
        }
    }

    private var activateSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Activate")).font(.subheadline).fontWeight(.semibold)
            HStack {
                TextField(L("License key"), text: $key)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                Button {
                    beginWork(.activate)
                    Task { await finishWork { await license.activate(key: key.trimmingCharacters(in: .whitespaces)) } }
                } label: {
                    workingLabel(L("Activate"), while: .activate)
                }
                .buttonStyle(.borderedProminent)
                .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || working != nil)
            }
            // Restore a Paddle purchase by the email used at checkout — the
            // fallback when the checkout didn't bind this device (10 §2).
            HStack {
                TextField(L("Purchase email"), text: $restoreEmail)
                    .textFieldStyle(.roundedBorder)
                Button {
                    beginWork(.restore)
                    Task { await finishWork { await license.restorePurchase(email: restoreEmail.trimmingCharacters(in: .whitespaces)) } }
                } label: {
                    workingLabel(L("Restore Purchase"), while: .restore)
                }
                .disabled(restoreEmail.trimmingCharacters(in: .whitespaces).isEmpty || working != nil)
            }
            if case .none = license.status {
                // Required server-side (email_required) so trial usage/cost
                // is attributable and admin can disable/cap a specific
                // trial account — no longer a fully anonymous grant.
                HStack {
                    TextField(L("Email"), text: $trialEmail)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        beginWork(.trial)
                        Task { await finishWork { await license.startTrial(email: trialEmail.trimmingCharacters(in: .whitespaces)) } }
                    } label: {
                        if working == .trial {
                            ProgressView().controlSize(.small)
                        } else {
                            Label(L("Start Free Trial"), systemImage: "gift")
                        }
                    }
                    .disabled(working != nil || !trialEmail.trimmingCharacters(in: .whitespaces).contains("@"))
                }
                // Apple Intelligence access is additional, not a replacement
                // for the real trial above — a Mac that has it still needs a
                // way to reach cloud AI (a different model, or just because
                // the user wants it), so this offers the free local option
                // alongside the real trial rather than hiding it.
                if AppleFoundationProvider.isAvailable() {
                    HStack {
                        Button {
                            AppleIntelligenceAccess.grant(email: trialEmail.trimmingCharacters(in: .whitespaces))
                        } label: {
                            Label(L("Use Free On-Device Instead"), systemImage: "apple.intelligence")
                        }
                        .disabled(!trialEmail.trimmingCharacters(in: .whitespaces).contains("@"))
                        Text(L("This Mac supports Apple Intelligence — skip the trial and run AI on-device for free."))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// A button label that swaps for an inline spinner while `action` is the
    /// one running, so the loading state sits exactly where the user is
    /// already looking instead of a separate caption elsewhere on the sheet.
    @ViewBuilder
    private func workingLabel(_ text: String, while action: WorkingAction) -> some View {
        if working == action {
            ProgressView().controlSize(.small)
        } else {
            Text(text)
        }
    }

    /// Both billing periods used to collapse to the "pro" tier in the
    /// license, so this couldn't tell monthly from yearly — that's moot now
    /// (TM-10 removed both), this only fires for an admin-granted comp plan.
    @ViewBuilder
    private var subscribedPlanBanner: some View {
        if isSubscribedPaid {
            Label(L("You're subscribed to the Pro plan."), systemImage: "checkmark.seal.fill")
                .font(.caption).foregroundStyle(.green)
        }
    }

    private static let topupPresetsCents = [200, 500, 1000, 2000]

    /// TM-11/14: pay-as-you-go AI credit — presets plus a free-form amount
    /// (min $2, enforced server-side against the admin-configured minimum).
    /// Tapping a preset opens its checkout immediately, mirroring the old
    /// single-tap "Subscribe" button; the custom field needs its own
    /// confirm since the amount isn't known ahead of a tap.
    private var addCreditSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Add AI credit")).font(.subheadline).fontWeight(.semibold)
            Text(L("BerryDB is free to use. You only pay for the AI you actually use, billed at cost plus a small margin — BerryDB hosts and manages the AI infrastructure for you."))
                .font(.caption).foregroundStyle(.secondary)

            usageBreakdown

            HStack(spacing: 6) {
                ForEach(Self.topupPresetsCents, id: \.self) { cents in
                    Button(formattedUSD(cents)) { startTopup(amountCents: cents) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isAddingCredit || license.isAwaitingTopup)
                }
                TextField(L("Custom amount"), text: $customTopupAmount)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                Button(L("Add Credit")) { startTopup(amountCents: customTopupAmountCents) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isAddingCredit || license.isAwaitingTopup || customTopupAmountCents < 200)
            }

            if isAddingCredit || license.isAwaitingTopup {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small)
                    Text(license.isAwaitingTopup ? L("Waiting for payment…") : L("Opening checkout…"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }

    /// A status bar for the low-balance signal (`balance.lowBalance`, `main.rs
    /// ai_balance` — true once the balance drops below the admin-configured
    /// minimum top-up): shown prominently near the top of the sheet, not
    /// buried in `usageBreakdown`, so it reads as a real heads-up rather than
    /// just another usage figure.
    @ViewBuilder
    private var lowBalanceBanner: some View {
        if let balance, balance.lowBalance {
            Label(L("Your balance is running low — add more credit to keep using AI."), systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    /// Three usage bars together, always: trial (frozen once converted —
    /// see the server's `BalanceResponse.token_quota` doc comment), and one
    /// per selectable model, each used/total sourced from lifetime topup
    /// credit (0/0 for an account that's never topped up — e.g. still on
    /// trial). Unlike the AI panel's picker-driven footer (which only shows
    /// whichever bar is currently relevant), this sheet has room to show
    /// all three so a user switching between models can compare at a glance.
    @ViewBuilder
    private var usageBreakdown: some View {
        if let balance {
            VStack(alignment: .leading, spacing: 10) {
                if let totalUsed = balance.totalTokensUsed {
                    Text(L("Used so far: \(totalUsed.formatted(.number.notation(.compactName))) tokens"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                trialUsageRow(balance.tokenQuota)
                if let totalBudgetUsedPercent = balance.totalBudgetUsedPercent {
                    totalBudgetUsageRow(totalBudgetUsedPercent)
                }
                ForEach(balance.models) { model in
                    modelUsageRow(model)
                }
            }
        }
    }

    /// One combined %, unlike `modelUsageRow` below (each bar priced at a
    /// *different* model's own selling rate) — mixing flash+pro usage makes
    /// those individually misleading about how much of the account's actual
    /// credit is left, since every model draws down this same shared balance.
    private func totalBudgetUsageRow(_ percent: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(L("Total budget used")).font(.caption).fontWeight(.medium)
                Spacer()
                Text(L("\(percent.formatted(.number.precision(.fractionLength(1))))%"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            ProgressView(value: percent, total: 100)
                .tint(percent >= 90 ? .red : nil)
        }
    }

    private func trialUsageRow(_ quota: AIPanelController.Balance.TokenQuota) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(L("Free trial")).font(.caption).fontWeight(.medium)
                Spacer()
                Text(quota.limit > 0
                    ? L("\(quota.used)/\(quota.limit) tokens")
                    : L("\(quota.used) tokens (unlimited)"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if quota.limit > 0 {
                ProgressView(value: Double(quota.used), total: Double(quota.limit))
            }
        }
    }

    private func modelUsageRow(_ model: AIPanelController.Balance.Model) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(model.name).font(.caption).fontWeight(.medium)
                Spacer()
                Text(L("\(model.tokensUsed.formatted(.number.notation(.compactName)))/\(model.tokensTotal.formatted(.number.notation(.compactName))) tokens"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            ProgressView(value: Double(model.tokensUsed), total: Double(max(model.tokensTotal, 1)))
        }
    }

    private var customTopupAmountCents: Int {
        Int(((Double(customTopupAmount) ?? 0) * 100).rounded())
    }

    private func formattedUSD(_ cents: Int) -> String {
        "$\(cents / 100)"
    }

    /// Opens a Paddle checkout for `amountCents` and starts polling for the
    /// webhook to land (`LicenseManager.awaitTopup`). Unlike Subscribe's
    /// checkout URL (known ahead of time from `/v1/pricing`), the topup URL
    /// only exists after this network round-trip, so `beginAwaitingTopup`
    /// can't run before it the way Subscribe's does — `isAddingCredit` gives
    /// the instant tap feedback in the meantime.
    private func startTopup(amountCents: Int) {
        isAddingCredit = true
        Task {
            defer { isAddingCredit = false }
            guard let url = await license.startTopup(amountCents: amountCents) else { return }
            NSWorkspace.shared.open(url)
            license.beginAwaitingTopup()
            Task {
                await license.awaitTopup()
                await refreshBalance()
            }
        }
    }

    /// TM-09: a plain external link, no in-app payment flow — purely a
    /// goodwill/support option, independent of AI credit/usage entirely.
    private var donateSection: some View {
        HStack {
            Text(L("Enjoying BerryDB? Support the project."))
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button(L("Telegram")) {
                NSWorkspace.shared.open(URL(string: "https://t.me/berryecosystem")!)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Button(L("Donate")) {
                NSWorkspace.shared.open(URL(string: "https://ko-fi.com/dautay")!)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(10)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }

    private var footer: some View {
        HStack {
            if license.canSignOut || AppleIntelligenceAccess.isGranted {
                Button(role: .destructive) {
                    license.clear()
                    AppleIntelligenceAccess.revoke()
                } label: {
                    Label(L("Sign Out"), systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
            Spacer()
            Button(L("Done")) { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    /// Runs on the button tap's own call stack, before the `Task` that does
    /// the actual work is even created — so the spinner/disabled state (both
    /// driven by `working`) shows up instantly regardless of how busy the
    /// MainActor is at that moment. Setting `working` *inside* an `async`
    /// function that's only reached via `Task { await ... }` (the previous
    /// shape here) delays it by however long that Task waits for its turn —
    /// under MainActor congestion the click looks like it did nothing, which
    /// reads as "needs multiple clicks" (docs/architecture — see the AI
    /// composer's admitSend/beginTurn split for the same fix applied there).
    private func beginWork(_ which: WorkingAction) {
        working = which
    }

    private func finishWork(_ action: @escaping () async -> Void) async {
        await action()
        working = nil
        if license.lastError == nil { key = "" }
    }
}
