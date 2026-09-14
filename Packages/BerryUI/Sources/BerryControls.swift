import AppKit
import SwiftUI

/// Reusable macOS-native building blocks that carry the language:
/// vibrancy backgrounds, compact buttons with smooth hover, Bento cards, and a
/// hairline divider that lights up on hover for panel resizing. Presentation
/// only — no app logic.

// MARK: - Vibrancy background

/// Semi-transparent system material for sidebars/panels — matches the OS
/// vibrancy instead of a flat opaque fill.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

// MARK: - Compact button (22–24px, 6px radius, 150–200ms hover)

struct CompactButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        CompactButtonBody(configuration: configuration, prominent: prominent)
    }

    struct CompactButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(BerryTheme.Typeface.ui(13, .medium))
                .foregroundStyle(prominent ? Color.white : Color.primary)
                .frame(height: BerryTheme.Metric.control)
                .padding(.horizontal, BerryTheme.Space.md)
                .background(fill, in: RoundedRectangle(cornerRadius: BerryTheme.Radius.control))
                .contentShape(RoundedRectangle(cornerRadius: BerryTheme.Radius.control))
 // Fade when disabled so it's distinct from enabled.
                .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
                .onHover { hovering = $0 }
                .animation(BerryTheme.Motion.hover, value: hovering)
                .animation(BerryTheme.Motion.hover, value: configuration.isPressed)
        }

        private var fill: Color {
            if prominent {
                return BerryTheme.accent.opacity(hovering ? 0.9 : 1)
            }
            return hovering || configuration.isPressed ? BerryTheme.hover : .clear
        }
    }
}

extension ButtonStyle where Self == CompactButtonStyle {
    /// Compact neutral button for toolbars/grids.
    static var compact: CompactButtonStyle { CompactButtonStyle() }
    /// Compact accent button for the primary action (Run SQL).
    static var compactRun: CompactButtonStyle { CompactButtonStyle(prominent: true) }
}

// MARK: - Icon action button

/// Small icon action button with a smooth rounded hover fill and no accent
/// background — the shared look for header and editor exec clusters. With
/// `showsLabel` the button widens to fit its title (label mode).
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 13
    var showsLabel = false
    /// True while the action this button triggers is the current workspace
    /// state (its tab is focused, its panel is open, …) — same accent-tint
    /// fill the tab strip uses for the selected tab (`EditorTabView.resultTab`).
    var isActive = false

    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, size: size, showsLabel: showsLabel, isActive: isActive)
    }

    struct IconButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let size: CGFloat
        let showsLabel: Bool
        let isActive: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: size))
                // Custom button styles don't auto-dim when disabled — fade the
 // icon so disabled vs enabled is obvious.
                .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.3)
                .padding(.horizontal, showsLabel ? 6 : 0)
                .frame(minWidth: 24)
                .frame(height: 20)
                .background(
                    isActive ? BerryTheme.accent.opacity(0.16)
                        : ((hovering && isEnabled) || configuration.isPressed ? BerryTheme.hover : .clear),
                    in: RoundedRectangle(cornerRadius: BerryTheme.Radius.control)
                )
                .contentShape(RoundedRectangle(cornerRadius: BerryTheme.Radius.control))
                .onHover { hovering = $0 }
                .animation(BerryTheme.Motion.hover, value: hovering)
        }
    }
}

extension ButtonStyle where Self == IconButtonStyle {
    /// Icon-only action button (Run, History, …) — no accent fill, hover only.
    static var iconAction: IconButtonStyle { IconButtonStyle() }
}

/// Label style for action buttons that shows the icon always and the title only
/// in label mode: users can switch between compact icons and
/// icon + text without the views changing shape logic.
struct IconOrTitledLabelStyle: LabelStyle {
    var showsTitle: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            if showsTitle {
                configuration.title
                    .font(BerryTheme.Typeface.ui(11.5, .medium))
            }
        }
    }
}

// MARK: - Bento card

private struct BentoCard: ViewModifier {
    var padding: CGFloat = BerryTheme.Space.md

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(BerryTheme.bento, in: RoundedRectangle(cornerRadius: BerryTheme.Radius.bento))
    }
}

extension View {
    /// Wrap content in a neutral Bento box (8px radius, soft gray fill) so it
 /// reads as distinct from the data grid.
    func bentoCard(padding: CGFloat = BerryTheme.Space.md) -> some View {
        modifier(BentoCard(padding: padding))
    }
}

// MARK: - Hover row highlight

private struct HoverHighlight: ViewModifier {
    var cornerRadius: CGFloat
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                hovering ? BerryTheme.hover : .clear,
                in: RoundedRectangle(cornerRadius: cornerRadius)
            )
            .onHover { hovering = $0 }
            .animation(BerryTheme.Motion.hover, value: hovering)
    }
}

extension View {
    /// Smooth background highlight on hover for rows, chips, and icon buttons
 /// `cornerRadius` matches the host shape (0 for full-width rows).
    func hoverHighlight(cornerRadius: CGFloat = 0) -> some View {
        modifier(HoverHighlight(cornerRadius: cornerRadius))
    }
}

// MARK: - Resize divider

/// A 1px neutral divider that turns macOS-blue on hover — the handle between
/// split panels. `axis` is the divider's own orientation.
struct HoverDivider: View {
    var axis: Axis = .vertical
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(hovering ? BerryTheme.accent : BerryTheme.hairline)
            .frame(
                width: axis == .vertical ? BerryTheme.Metric.hairline : nil,
                height: axis == .horizontal ? BerryTheme.Metric.hairline : nil
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(BerryTheme.Motion.hover, value: hovering)
    }
}
