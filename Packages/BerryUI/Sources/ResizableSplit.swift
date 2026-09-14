import AppKit
import SwiftUI

/// Fraction math for a resizable split. Pure and testable — the view
/// only owns the `@State` array and the gestures.
enum SplitMath {
    /// Equal fractions for `count` panes.
    static func equal(_ count: Int) -> [CGFloat] {
        count > 0 ? Array(repeating: 1 / CGFloat(count), count: count) : []
    }

    /// Keep a fractions array valid for `count` panes — reset to equal when the
    /// pane count changed or the values drifted from summing to 1.
    static func normalized(_ values: [CGFloat], count: Int) -> [CGFloat] {
        guard values.count == count, count > 0 else { return equal(count) }
        let sum = values.reduce(0, +)
        guard sum > 0.001, values.allSatisfy({ $0 >= 0 }) else { return equal(count) }
        return values.map { $0 / sum }
    }

    /// Move the boundary between pane `i` and `i+1` by `delta` fraction units,
    /// clamped so neither pane drops below `minFraction`.
    static func resized(_ values: [CGFloat], divider i: Int, delta: CGFloat, minFraction: CGFloat) -> [CGFloat] {
        guard i >= 0, i + 1 < values.count else { return values }
        var result = values
        let pair = result[i] + result[i + 1]
        let lower = min(minFraction, pair / 2)
        var left = result[i] + delta
        left = min(max(left, lower), pair - lower)
        result[i] = left
        result[i + 1] = pair - left
        return result
    }

    /// Double-click collapse: shrink pane `i` to `minFraction`; if it is already
    /// collapsed, restore an equal split of the pair (a toggle).
    static func collapsed(_ values: [CGFloat], pane i: Int, minFraction: CGFloat) -> [CGFloat] {
        guard i >= 0, i + 1 < values.count else { return values }
        var result = values
        let pair = result[i] + result[i + 1]
        let lower = min(minFraction, pair / 2)
        if result[i] <= lower + 0.005 {
            result[i] = pair / 2
            result[i + 1] = pair / 2
        } else {
            result[i] = lower
            result[i + 1] = pair - lower
        }
        return result
    }
}

/// A drag-resizable stack of panes with hover-highlighting 1px dividers
/// drag a boundary to resize, double-click it to collapse the pane
/// before it. Replaces VSplitView/HSplitView so the divider can follow the
/// macOS language (neutral hairline → accent blue on hover).
struct ResizableSplit<Content: View>: View {
    let axis: Axis
    let ids: [String]
    var minExtent: CGFloat = 140
    @ViewBuilder var content: (String) -> Content

    @State private var fractions: [CGFloat] = []
    @State private var dragBase: [CGFloat]?

    /// Grabbable thickness of the divider region; it draws a 1px line centered.
    private let dividerExtent: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let total = axis == .horizontal ? geo.size.width : geo.size.height
            let available = max(total - dividerExtent * CGFloat(max(ids.count - 1, 0)), 1)
            let f = SplitMath.normalized(fractions, count: ids.count)
            let minFraction = min(minExtent / available, 0.9)
            splitStack(available: available, fractions: f, minFraction: minFraction)
        }
        .onAppear(perform: syncCount)
        .onChange(of: ids.count) { syncCount() }
    }

    private func syncCount() {
        if fractions.count != ids.count { fractions = SplitMath.equal(ids.count) }
    }

    @ViewBuilder
    private func splitStack(available: CGFloat, fractions f: [CGFloat], minFraction: CGFloat) -> some View {
        let layout = axis == .horizontal
            ? AnyLayout(HStackLayout(spacing: 0))
            : AnyLayout(VStackLayout(spacing: 0))
        layout {
            ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                content(id)
                    .frame(
                        width: axis == .horizontal ? f[index] * available : nil,
                        height: axis == .vertical ? f[index] * available : nil
                    )
                    .frame(
                        maxWidth: axis == .vertical ? .infinity : nil,
                        maxHeight: axis == .horizontal ? .infinity : nil
                    )
                if index < ids.count - 1 {
                    handle(index: index, available: available, minFraction: minFraction)
                }
            }
        }
    }

    private func handle(index: Int, available: CGFloat, minFraction: CGFloat) -> some View {
        let dividerAxis: Axis = axis == .horizontal ? .vertical : .horizontal
        return HoverDivider(axis: dividerAxis)
            .frame(
                width: dividerAxis == .vertical ? dividerExtent : nil,
                height: dividerAxis == .horizontal ? dividerExtent : nil
            )
            // Fill the 6px grab zone: only a 1px line is drawn, so without this
            // the ~5px around it showed the dark canvas behind — a black gutter
            // beside every pane that multiplied with each split.
            .background(.bar)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    (dividerAxis == .vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if dragBase == nil { dragBase = SplitMath.normalized(fractions, count: ids.count) }
                        guard let base = dragBase else { return }
                        let moved = axis == .horizontal ? value.translation.width : value.translation.height
                        fractions = SplitMath.resized(base, divider: index, delta: moved / available, minFraction: minFraction)
                    }
                    .onEnded { _ in dragBase = nil }
            )
            .onTapGesture(count: 2) {
                fractions = SplitMath.collapsed(
                    SplitMath.normalized(fractions, count: ids.count),
                    pane: index, minFraction: minFraction
                )
            }
    }
}
