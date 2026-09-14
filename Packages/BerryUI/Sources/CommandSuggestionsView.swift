import BerryAI
import SwiftUI

/// Dropdown shown above the chat composer while typing a "/" command
///
/// Row style mirrors `QuickOpenView.swift`: plain Buttons, not
/// `List(selection:)` — a competing tap handler on `List` rows is a known
/// bug class in this codebase (see that file's doc comment for why).
struct CommandSuggestionsView: View {
    let commands: [ChatCommand]
    let selectedIndex: Int
    let onSelect: (ChatCommand) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<commands.count, id: \.self) { index in
                    let command = commands[index]
                    Button {
                        onSelect(command)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(command.usageHint)
                                .font(.system(.callout, design: .monospaced))
                            Text(L(String.LocalizationValue(command.description)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
