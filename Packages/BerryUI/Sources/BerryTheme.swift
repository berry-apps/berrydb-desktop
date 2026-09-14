import AppKit
import SwiftUI

/// Design tokens for the macOS-native + Spatial/Bento visual language
/// One source of truth for color,
/// spacing, radius, motion, type, and metrics so every surface stays
/// consistent — no raw hex or magic numbers scattered across views.
public enum BerryTheme {
 // MARK: - Color — dynamic, follows the system Light/Dark setting.

    /// Main canvas: Light #F5F5F7 · Dark #1E1E1E.
    public static let canvas = dynamic(light: 0xF5F5F7, dark: 0x1E1E1E)
    /// Sidebar & panel surface: Light #FFFFFF · Dark #161616.
    public static let panel = dynamic(light: 0xFFFFFF, dark: 0x161616)
    /// Accent (Run / active): macOS blue #007AFF · #0A84FF.
    public static let accent = dynamic(light: 0x007AFF, dark: 0x0A84FF)
    /// Neutral fill for Bento boxes — light gray that reads as a distinct
    /// surface from the data grid without a hard border.
    public static let bento = dynamic(light: 0xF2F2F5, dark: 0x1F1F22)
    /// Subtle hover/press fill for compact controls and grid rows.
    public static let hover = Color.primary.opacity(0.06)
    /// Hairline separators — the system separator, never a heavy border.
    public static let hairline = Color(nsColor: .separatorColor)

    // MARK: - Spacing (dense dashboard scale)

    public enum Space {
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
        public static let xl: CGFloat = 24
    }

    // MARK: - Radius

    public enum Radius {
        /// Compact controls / buttons.
        public static let control: CGFloat = 6
        /// Bento boxes / cards.
        public static let bento: CGFloat = 8
    }

    // MARK: - Metrics

    public enum Metric {
 /// Compact control height (22–24px).
        public static let control: CGFloat = 24
 /// Ultra-thin split/tab header (max 28px).
        public static let splitHeader: CGFloat = 28
        public static let hairline: CGFloat = 1
    }

 // MARK: - Motion (smooth 150–200ms, never abrupt)

    public enum Motion {
        public static let hover: Animation = .easeInOut(duration: 0.18)
        public static let panel: Animation = .easeInOut(duration: 0.22)
    }

 // MARK: - Type (SF Pro Text for UI, SF Mono for code/data)

    public enum Typeface {
        /// UI label/button/title — the system font is SF Pro Text.
        public static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight)
        }

        /// SQL editor + data cells — SF Mono for perfect column alignment.
        public static func mono(_ size: CGFloat) -> Font {
            .system(size: size, design: .monospaced)
        }

 // Compact-but-legible scale — the system default (13pt) reads
        // a touch large for a dense DB tool, so lists/sidebar use these.
        /// Sidebar rows (connections, tables, views) — 12pt.
        public static let sidebarRow = Font.system(size: 12)
        /// Sidebar section headers — 11pt, semibold.
        public static let sidebarSection = Font.system(size: 11, weight: .semibold)
    }

    // MARK: - Helpers

    /// A color that resolves to `light`/`dark` per the current appearance.
    static func dynamic(light: Int, dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(rgb: isDark ? dark : light)
        })
    }
}

private extension NSColor {
    convenience init(rgb: Int) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}
