# Chat command dropdown

## Problem

The chat composer (`AIPanelView`'s `composer`) already supports one hidden
slash command, `/report <message>` (handled by a hardcoded
`hasPrefix("/report ")` check in `AISession.send(_:)`). Nothing in the UI
tells the user it exists, or how to use it. There's no registry — adding a
second command today means another hardcoded prefix check with no
discoverability.

## Goal

Typing `/` as the first character of the composer shows a dropdown of
built-in commands (name + usage + description), filterable as the user keeps
typing, navigable by mouse (hover/click) or arrow keys (↑ ↓), accepted with
Enter/Tab, dismissed with Escape. Adding a future command should mean adding
one registry entry (for discovery) plus whatever small dispatch code that
command's behavior actually needs — not a UI change.

Scope for this pass: wire up the existing `/report` command only. No new
commands are being added.

## Non-goals

- No general-purpose "command framework" with declarative handler closures.
  Each command's dispatch logic is still hand-written in `AISession.send(_:)`
  — the registry only drives *discovery* (the dropdown), not *execution*.
  With exactly one real command, a handler-registration abstraction would be
  speculative.
- No fuzzy matching — prefix matching on the command name is enough for a
  short, hand-curated list.
- No persistence/settings for commands (e.g. user-defined commands). Out of
  scope.

## Architecture

Two layers, kept separate:

1. **Registry (data)** — `ChatCommand` + `ChatCommands.all`, in `BerryAI`
   (business-logic package, no SwiftUI dependency). Pure metadata: what
   commands exist, their usage hint, their description. Testable in
   isolation.
2. **Dispatch (behavior)** — unchanged in spirit: `AISession.send(_:)` still
   has one `hasPrefix` branch per command. The registry does not drive
   dispatch; it only drives what the dropdown *shows*. This keeps the two
   concerns independent — a command can be listed without existing yet
   (during development) and dispatch code never has to reverse-engineer
   behavior from data.

UI is a third, separate layer (BerryUI), consuming the registry to render
and consuming keyboard/mouse input to drive selection — it does not know
about `AISession` internals.

## Components

### `ChatCommand` / `ChatCommands` (new file: `Packages/BerryAI/Sources/ChatCommand.swift`)

```swift
public struct ChatCommand: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name: String        // "report"
    public let usageHint: String   // "/report {message}"
    public let description: String // "File a bug report from this conversation."
}

public enum ChatCommands {
    public static let all: [ChatCommand] = [
        ChatCommand(name: "report", usageHint: "/report {message}",
                    description: "File a bug report from this conversation."),
    ]

    /// Commands whose name starts with `query` (case-insensitive), for the
    /// composer's dropdown. Empty query matches everything.
    public static func matching(_ query: String) -> [ChatCommand] {
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.lowercased().hasPrefix(query.lowercased()) }
    }
}
```

Adding a second command later: append one `ChatCommand` to `all`, plus
whatever `hasPrefix` branch that command's behavior needs in
`AISession.send(_:)`. No UI file changes required for discovery to work.

### `AIPanelController` (existing file: `Packages/BerryUI/Sources/AIPanelController.swift`)

New derived state, computed from the existing `draft` property (no new
source of truth):

```swift
/// The text after "/" while the composer is in command-palette mode, or nil
/// when it isn't (draft doesn't start with "/", or a space has been typed —
/// meaning the user is now typing the command's argument, not searching).
public var commandQuery: String? {
    guard draft.hasPrefix("/"), !draft.dropFirst().contains(" ") else { return nil }
    return String(draft.dropFirst())
}
public var matchingCommands: [ChatCommand] { ChatCommands.matching(commandQuery ?? "") }
```

`selectedCommandIndex` is *not* added here — see `AIPanelView` below. It's
transient view-selection state, not session/business state, so it follows
the same placement as `promptFieldFocused` (`@FocusState` on the view) and
`QuickOpenView`'s own `@State private var selectedID` — both existing
precedents keep this kind of state in the view, not the controller.

### `CommandSuggestionsView` (new file: `Packages/BerryUI/Sources/CommandSuggestionsView.swift`)

Small, docked dropdown — not a floating/caret-anchored popup (unlike
`CompletionPopup`'s `NSPanel`, which is overkill for a fixed-position,
start-of-line list). Row styling follows `QuickOpenView`'s existing
`Button`-per-row pattern (explicitly not `List(selection:)` — see that
file's doc comment on why: a competing tap handler on `List` rows is a
known bug class in this codebase).

```swift
struct CommandSuggestionsView: View {
    let commands: [ChatCommand]
    let selectedIndex: Int
    let onSelect: (ChatCommand) -> Void

    var body: some View {
        // VStack of Buttons: usageHint (monospaced) + description (secondary,
        // smaller). Selected row gets Color.accentColor.opacity(0.15)
        // background, same treatment as QuickOpenView.
    }
}
```

### `AIPanelView.composer` (existing file: `Packages/BerryUI/Sources/AIPanelView.swift`)

- New view-local state: `@State private var selectedCommandIndex = 0` and `@State private var commandPaletteDismissed = false`, following the same placement as `promptFieldFocused` right above.
- Overlay `CommandSuggestionsView` above the `TextField` (`.overlay(alignment: .top)` with a negative y-offset, or a `VStack` wrapping the existing composer — exact layout decided during implementation) when `controller.commandQuery != nil && !controller.matchingCommands.isEmpty && !commandPaletteDismissed`.
- `.onChange(of: controller.commandQuery)` resets `selectedCommandIndex = 0` and `commandPaletteDismissed = false` (mirrors `QuickOpenView`'s `.onChange(of: query) { selectedID = items.first?.id }`).
- Add `.onKeyPress` handlers on the composer, active only while the dropdown is showing, mirroring `QuickOpenView` exactly (same four keys, nothing extra):
  - `.upArrow` / `.downArrow` → move `selectedCommandIndex` (clamped, not wrapping — matches `QuickOpenView.moveSelection`).
  - `.return` → accept the highlighted command: set `draft = "/\(command.name) "`, keep focus in the field. (`QuickOpenView` doesn't bind Tab either — matching that, not adding a new key binding here.)
  - `.escape` → sets `commandPaletteDismissed = true`. Does not clear `draft`.
- Existing `.onSubmit(send)` behavior is unaffected when the dropdown isn't showing (normal message send).

## Data flow

1. User types `/` as the first character → `commandQuery == ""` → dropdown shows all commands (today: just `/report`).
2. User keeps typing (`/rep`) → `commandQuery == "rep"` → `matchingCommands` narrows via `ChatCommands.matching`.
3. Arrow keys move `selectedCommandIndex` within `matchingCommands`.
4. Enter or a mouse click on a row → `draft = "/report "` → `commandQuery` becomes `nil` (draft now contains a space) → dropdown closes, cursor stays in the field for the user to type the report message → existing `.onSubmit`/send path handles it exactly as `/report <message>` does today.
5. Escape → dropdown hides without touching `draft` (`commandPaletteDismissed = true`).
6. Backspacing back to `/` (or clearing and retyping `/`) reopens it — any change to `commandQuery` resets `commandPaletteDismissed` to `false`.

## Error handling

Client-side only, no network calls in this feature. The only edge case is
an empty `matchingCommands` (query matches nothing) — dropdown simply
doesn't render (same as `QuickOpenView`'s "No matches" state, or simpler:
just hide the overlay entirely rather than showing an empty box).

## Testing

- `ChatCommands.matching(_:)` — pure function, unit-tested in
  `BerryAITests` (new `ChatCommandTests.swift`): empty query returns all,
  a prefix match narrows correctly, a non-matching query returns empty,
  case-insensitivity.
- Selection-index movement (clamping at both ends) — pure function,
  extracted and unit-tested the same way `QuickOpenView`'s equivalent isn't
  currently unit-tested directly but the underlying `QuickOpenItem.filter`
  is (`QuickOpenItemTests.swift`); mirror that split here: filtering logic
  tested, view layout not.
- `CommandSuggestionsView` and the `.onKeyPress` wiring in `AIPanelView`
  itself are SwiftUI view code — not meaningfully unit-testable (consistent
  with how `QuickOpenView`'s row rendering has no test coverage either).
  Verified by `swift build` + manual reasoning, same as the License sheet
  loading-indicator change made earlier this session.

## Rollout

Single change, no migration, no feature flag — this is purely additive UI
behavior gated on typing `/` as the first character, which currently does
nothing special, so there's no existing behavior to preserve or fall back
to.
