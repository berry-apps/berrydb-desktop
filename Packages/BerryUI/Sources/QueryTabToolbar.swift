import SwiftUI

/// Shared "new query tab" toolbar shell (#2): the Run/
/// Stop button pattern, spacing, padding, and background are identical
/// across every connection type's query tab (SQL/Mongo/Qdrant) — only the
/// connection-type-specific extras (Explain/Format for SQL, mode picker/Save
/// for Qdrant) differ, injected via `leading`/`trailing`. That split mirrors
/// what was actually asked: one shared component for opening/running a new
/// query tab, with per-connection-type logic staying separate.
struct QueryTabToolbar<Leading: View, Trailing: View>: View {
    let canRun: Bool
    let isRunning: Bool
    let isProduction: Bool
    let onRun: () -> Void
    let onStop: () -> Void
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    @AppStorage("berry.showButtonLabels") private var showButtonLabels = false

    init(
        canRun: Bool,
        isRunning: Bool,
        isProduction: Bool,
        onRun: @escaping () -> Void,
        onStop: @escaping () -> Void,
        @ViewBuilder leading: @escaping () -> Leading = { EmptyView() },
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.canRun = canRun
        self.isRunning = isRunning
        self.isProduction = isProduction
        self.onRun = onRun
        self.onStop = onStop
        self.leading = leading
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 3) {
            Button(action: onRun) {
                Label(L("Run"), systemImage: "play.fill")
            }
            .buttonStyle(IconButtonStyle(showsLabel: showButtonLabels))
            .labelStyle(IconOrTitledLabelStyle(showsTitle: showButtonLabels))
            .disabled(!canRun)
            .help(Text(L("Run")) + Text(verbatim: "  ⌘R"))

            if isRunning {
                ProgressView().controlSize(.small)
                Button(action: onStop) {
                    Label(L("Stop"), systemImage: "stop.fill")
                }
                .buttonStyle(IconButtonStyle(showsLabel: showButtonLabels))
                .labelStyle(IconOrTitledLabelStyle(showsTitle: showButtonLabels))
                .help(L("Stop"))
            }

            leading()
            Spacer()
            trailing()
            if isProduction { ProductionBadge() }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.bar)
    }
}
