import BerryDriverKit
import Testing

@testable import BerryUI

@MainActor
@Suite("Visualize Result")
struct VisualizeResultViewTests {
    @Test func extractsLabelValuePairsAcrossNumericRepresentations() {
        let rows: [[BerryValue]] = [
            [.text("US"), .int(120)],
            [.text("VN"), .double(45.5)],
            [.text("FR"), .decimal("30.25")],
        ]

        let points = VisualizeResultView.points(rows: rows, xColumn: 0, yColumn: 1)

        #expect(points == [
            .init(x: "US", y: 120),
            .init(x: "VN", y: 45.5),
            .init(x: "FR", y: 30.25),
        ])
    }

    @Test func skipsRowsWithoutANumericYValueRatherThanPlottingZero() {
        let rows: [[BerryValue]] = [
            [.text("US"), .int(120)],
            [.text("VN"), .text("not a number")],
            [.text("FR"), .null],
        ]

        let points = VisualizeResultView.points(rows: rows, xColumn: 0, yColumn: 1)

        #expect(points == [.init(x: "US", y: 120)])
    }

    @Test func skipsRowsShorterThanTheSelectedColumns() {
        let rows: [[BerryValue]] = [
            [.text("US")], // missing the Y column entirely
            [.text("VN"), .int(45)],
        ]

        let points = VisualizeResultView.points(rows: rows, xColumn: 0, yColumn: 1)

        #expect(points == [.init(x: "VN", y: 45)])
    }
}
