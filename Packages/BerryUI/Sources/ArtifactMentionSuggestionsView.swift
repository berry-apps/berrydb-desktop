import SwiftUI

/// Dropdown shown above the chat composer while typing an `@{...}` mention
/// sibling of `CommandSuggestionsView`, same row
/// style (plain Buttons, not `List(selection:)` — see that file's doc
/// comment for why), kept as a separate view rather than sharing code since
/// the row content differs (icon + name here, vs. usage hint + description
/// there) and the two triggers are unrelated otherwise.
struct ArtifactMentionSuggestionsView: View {
    let items: [ArtifactMentionItem]
    let selectedIndex: Int
    let onSelect: (ArtifactMentionItem) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<items.count, id: \.self) { index in
                    let item = items[index]
                    Button {
                        onSelect(item)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: item.iconName).frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.name)
                                // An artifact's last-updated time — same-titled
                                // (e.g. never-renamed) artifacts otherwise look
                                // identical in this list.
                                if let subtitleDate = item.subtitleDate {
                                    Text(subtitleDate, format: .relative(presentation: .named))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                        .background(
                            index == selectedIndex ? Color.accentColor.opacity(0.15) : .clear,
                            in: RoundedRectangle(cornerRadius: 4)
                        )
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                }
            }
            .padding(4)
        }
        .frame(maxHeight: 200)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 1))
    }
}
