import SwiftUI

/// Shared query result container component for both SQL and NoSQL/Mongo tab views.
/// Handles empty state, tab bar switching, and collapsible result pane.
struct QueryResultContainerView<HeaderActions: View, Content: View>: View {
    let isEmpty: Bool
    @Binding var isCollapsed: Bool
    @ViewBuilder let tabs: () -> AnyView
    @ViewBuilder let headerActions: () -> HeaderActions
    @ViewBuilder let content: () -> Content

    init(
        isEmpty: Bool,
        isCollapsed: Binding<Bool>,
        @ViewBuilder tabs: @escaping () -> AnyView,
        @ViewBuilder headerActions: @escaping () -> HeaderActions = { EmptyView() },
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.isEmpty = isEmpty
        self._isCollapsed = isCollapsed
        self.tabs = tabs
        self.headerActions = headerActions
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            resultTabBar
            if !isCollapsed {
                Divider()
                if isEmpty {
                    ContentUnavailableView(
                        L("No results yet"),
                        systemImage: "play.circle",
                        description: Text(L("⌘R runs every statement in the editor"))
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    content()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private var resultTabBar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "tablecells")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(L("Results"))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
            }
            .padding(.trailing, 4)
            
            ScrollView(.horizontal, showsIndicators: false) {
                tabs()
            }
            Spacer(minLength: 8)
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)
                .frame(width: 20, height: 16)
                .help(L("Drag to resize"))
            Spacer(minLength: 8)
            if !isCollapsed {
                headerActions()
            }
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.75)) {
                    isCollapsed.toggle()
                }
            } label: {
                Image(systemName: isCollapsed ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isCollapsed ? L("Expand results") : L("Collapse results"))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.bar)
    }
}
