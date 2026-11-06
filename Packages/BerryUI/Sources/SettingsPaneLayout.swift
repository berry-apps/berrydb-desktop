import Foundation

/// The size every Settings tab lays itself out at. The Settings window
/// takes the size of the tab it shows, so two tabs of different sizes make
/// the window grow and shrink on every switch and the content jumps with
/// it; one shared size keeps the window still and only swaps the content.
enum SettingsPaneLayout {
    static let width: CGFloat = 560
    static let height: CGFloat = 560
}
