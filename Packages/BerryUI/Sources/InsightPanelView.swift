import BerryGraph
import SwiftUI

/// Insight Panel: shows the offline analyzers'
/// findings grouped by severity. Each finding can reveal its table in the
/// sidebar, and — when it carries a `suggestedSQL` — open that fix in a new
/// editor tab, where it still goes through preview + DangerGuard (N1). Nothing
/// runs automatically.
struct InsightPanelView: View {
    let load: () async -> [Insight]
 /// Yesterday's-to-today digest — a stale snapshot (up to
    /// ~20h old) computed once per day from the same analyzers as `load`,
    /// nil until the first one has been generated for this profile.
    let dailyReview: () -> DailyReviewSummary?
    let onReveal: (String) -> Void
    let onOpenSQL: (String) -> Void
 /// Records that the user applied/dismissed an insight — id is
    /// `Insight.id`, stable across refreshes so repeat feedback accumulates.
    let onApply: (String) -> Void
    let onDismissInsight: (String) -> Void
    let onClose: () -> Void

    @State private var insights: [Insight] = []
    @State private var summary: DailyReviewSummary?
    @State private var isLoading = false

    private let order: [Insight.Severity] = [.critical, .warning, .info]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("Database Insights")).font(.headline)
                if !insights.isEmpty { architectureScoreBadge }
                Spacer()
                if isLoading { ProgressView().controlSize(.small) }
                Button { Task { await refresh() } } label: {
                    Label(L("Refresh"), systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
                Button(L("Close")) { onClose() }
            }
            .padding()
            if let summary {
                Divider()
                dailyReviewSection(summary)
            }
            Divider()
            content
        }
        .task { await refresh() }
    }

 /// Database Architecture Score — computed live from
    /// the same `insights` this panel already loaded, not a separate fetch.
    /// Deliberately just Overall/Schema/Index/Performance: those are the only
    /// categories with any real analyzer behind them (see
    /// `ArchitectureScoreCalculator`'s doc comment for why Security/Storage/
    /// Maintainability aren't fabricated as separate numbers).
    private var architectureScoreBadge: some View {
        let score = ArchitectureScoreCalculator.score(insights)
        return Text("\(score.overall)/100")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(scoreColor(score.overall))
            .help(architectureScoreHelp(score))
    }

    private func scoreColor(_ value: Int) -> Color {
        switch value {
        case 90...: .green
        case 70..<90: .yellow
        default: .red
        }
    }

    private func architectureScoreHelp(_ score: ArchitectureScore) -> String {
        "\(L("Schema")): \(score.schema)/100 · \(L("Index")): \(score.index)/100 · \(L("Performance")): \(score.performance)/100"
    }

    private func refresh() async {
        isLoading = true
        insights = await load()
        summary = dailyReview()
        isLoading = false
    }

 /// today's health snapshot — same severities as the list below,
    /// just pre-bucketed as of the last time it was generated.
    private func dailyReviewSection(_ summary: DailyReviewSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Today's Summary")).font(.subheadline.weight(.semibold))
            HStack(spacing: 16) {
                countBadge(summary.criticalCount, severity: .critical)
                countBadge(summary.warningCount, severity: .warning)
                countBadge(summary.infoCount, severity: .info)
            }
            ForEach(summary.topInsightTitles, id: \.self) { title in
                Text("• \(title)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func countBadge(_ count: Int, severity: Insight.Severity) -> some View {
        Label("\(count)", systemImage: icon(severity))
            .font(.callout.weight(.medium))
            .foregroundStyle(color(severity))
    }

    @ViewBuilder private var content: some View {
        if insights.isEmpty {
            ContentUnavailableView(
                L("No insights"),
                systemImage: isLoading ? "hourglass" : "checkmark.seal",
                description: Text(isLoading
                    ? L("Analyzing schema and recent queries…")
                    : L("Connect and refresh the schema to analyze it."))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(order, id: \.self) { severity in
                    let group = insights.filter { $0.severity == severity }
                    if !group.isEmpty {
                        Section(sectionTitle(severity, count: group.count)) {
                            ForEach(group) { row($0) }
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func row(_ insight: Insight) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon(insight.severity)).foregroundStyle(color(insight.severity))
                Text(insight.title).font(.body.weight(.semibold))
            }
            Text(insight.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                if let name = insight.targetName {
                    Button {
                        onReveal(name)
                    } label: {
                        Label(L("Reveal"), systemImage: "arrow.right.circle")
                    }
                }
                if let sql = insight.suggestedSQL {
                    Button {
                        onApply(insight.id)
                        onOpenSQL(sql)
                    } label: {
                        Label(L("Open Fix in Editor"), systemImage: "curlybraces.square")
                    }
                }
                Spacer()
                Button {
                    onDismissInsight(insight.id)
                    insights.removeAll { $0.id == insight.id }
                } label: {
                    Label(L("Dismiss"), systemImage: "xmark.circle")
                }
                .help(L("Don't show this again"))
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(.vertical, 4)
    }

    private func sectionTitle(_ severity: Insight.Severity, count: Int) -> String {
        let name = switch severity {
        case .critical: L("Critical")
        case .warning: L("Warnings")
        case .info: L("Suggestions")
        }
        return "\(name) (\(count))"
    }

    private func icon(_ severity: Insight.Severity) -> String {
        switch severity {
        case .critical: "exclamationmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "lightbulb"
        }
    }

    private func color(_ severity: Insight.Severity) -> Color {
        switch severity {
        case .critical: .red
        case .warning: .orange
        case .info: .blue
        }
    }
}
