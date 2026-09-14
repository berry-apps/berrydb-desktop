import CoreGraphics
import Testing

@testable import BerryUI

/// Resizable-split fraction math.
@Suite("SplitMath")
struct SplitMathTests {
    private func approx(_ a: [CGFloat], _ b: [CGFloat]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 0.0001 }
    }

    @Test func equalSplitsSumToOne() {
        #expect(approx(SplitMath.equal(2), [0.5, 0.5]))
        #expect(approx(SplitMath.equal(4), [0.25, 0.25, 0.25, 0.25]))
        #expect(SplitMath.equal(0).isEmpty)
    }

    @Test func normalizeResetsOnCountMismatchAndRescales() {
        // Count mismatch → equal split.
        #expect(approx(SplitMath.normalized([0.9], count: 2), [0.5, 0.5]))
        // Values that don't sum to 1 get rescaled, not discarded.
        #expect(approx(SplitMath.normalized([1, 3], count: 2), [0.25, 0.75]))
    }

    @Test func resizeMovesTheBoundaryAndConservesTotal() {
        let r = SplitMath.resized([0.5, 0.5], divider: 0, delta: 0.2, minFraction: 0.1)
        #expect(approx(r, [0.7, 0.3]))
        #expect(abs(r.reduce(0, +) - 1) < 0.0001)
    }

    @Test func resizeClampsToMinFraction() {
        // A huge drag can't push either pane below minFraction.
        let r = SplitMath.resized([0.5, 0.5], divider: 0, delta: 0.9, minFraction: 0.2)
        #expect(approx(r, [0.8, 0.2]))
        let l = SplitMath.resized([0.5, 0.5], divider: 0, delta: -0.9, minFraction: 0.2)
        #expect(approx(l, [0.2, 0.8]))
    }

    @Test func collapseTogglesBetweenMinAndEqual() {
        let collapsed = SplitMath.collapsed([0.5, 0.5], pane: 0, minFraction: 0.15)
        #expect(approx(collapsed, [0.15, 0.85]))
        // A second collapse on an already-collapsed pane restores the pair.
        let restored = SplitMath.collapsed(collapsed, pane: 0, minFraction: 0.15)
        #expect(approx(restored, [0.5, 0.5]))
    }

    @Test func resizeAndCollapseOnlyTouchTheAdjacentPair() {
        let r = SplitMath.resized([0.3, 0.3, 0.4], divider: 0, delta: 0.1, minFraction: 0.1)
        #expect(approx(r, [0.4, 0.2, 0.4]))   // third pane untouched
        #expect(abs(r.reduce(0, +) - 1) < 0.0001)
    }

    @Test func outOfRangeDividerIsANoOp() {
        #expect(approx(SplitMath.resized([0.5, 0.5], divider: 5, delta: 0.2, minFraction: 0.1), [0.5, 0.5]))
        #expect(approx(SplitMath.collapsed([1.0], pane: 0, minFraction: 0.1), [1.0]))
    }
}
