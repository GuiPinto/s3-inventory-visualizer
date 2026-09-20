import XCTest
@testable import TreemapLayout

final class SquarifyTests: XCTestCase {
    private func assertNoOverlapAndInside(_ rects: [LayoutRect], _ bounds: LayoutRect) {
        for rect in rects {
            XCTAssertGreaterThanOrEqual(rect.x, bounds.x - 1e-6)
            XCTAssertGreaterThanOrEqual(rect.y, bounds.y - 1e-6)
            XCTAssertLessThanOrEqual(rect.x + rect.width, bounds.x + bounds.width + 1e-6)
            XCTAssertLessThanOrEqual(rect.y + rect.height, bounds.y + bounds.height + 1e-6)
        }

        for (position, first) in rects.enumerated() where first.area > 0 {
            for second in rects[(position + 1)...] where second.area > 0 {
                let overlapWidth = min(first.x + first.width, second.x + second.width) - max(first.x, second.x)
                let overlapHeight = min(first.y + first.height, second.y + second.height) - max(first.y, second.y)
                XCTAssertFalse(overlapWidth > 1e-6 && overlapHeight > 1e-6, "rects \(first) and \(second) overlap")
            }
        }
    }

    private func assertRectEqual(
        _ actual: LayoutRect,
        _ expected: LayoutRect,
        accuracy: Double = 1e-9,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: accuracy, file: file, line: line)
    }

    func testSingleItemFillsRect() {
        let rect = LayoutRect(x: 10, y: 20, width: 300, height: 100)
        let rects = Squarify.layout(weights: [42], in: rect)
        XCTAssertEqual(rects.count, 1)
        assertRectEqual(rects[0], rect, accuracy: 1e-6)
    }

    func testAreasAreProportionalAndOrderPreserved() {
        let rect = LayoutRect(x: 0, y: 0, width: 400, height: 100)
        let rects = Squarify.layout(weights: [300, 100], in: rect)
        XCTAssertEqual(rects[0].area, 30_000, accuracy: 1e-6)
        XCTAssertEqual(rects[1].area, 10_000, accuracy: 1e-6)
        XCTAssertEqual(rects[0].x, 0)
        assertNoOverlapAndInside(rects, rect)
    }

    func testFourEqualWeightsInSquareAreSquares() {
        let rect = LayoutRect(x: 0, y: 0, width: 200, height: 200)
        let rects = Squarify.layout(weights: [1, 1, 1, 1], in: rect)

        for cell in rects {
            XCTAssertEqual(cell.width, 100, accuracy: 1e-6)
            XCTAssertEqual(cell.height, 100, accuracy: 1e-6)
        }

        assertNoOverlapAndInside(rects, rect)
    }

    func testManyDescendingWeightsCoverTheRect() {
        let rect = LayoutRect(x: 5, y: 7, width: 1000, height: 600)
        let weights = (1...60).map { Double(61 - $0) * Double(61 - $0) }
        let rects = Squarify.layout(weights: weights, in: rect)
        XCTAssertEqual(rects.count, 60)
        XCTAssertEqual(rects.reduce(0) { $0 + $1.area }, rect.area, accuracy: 1e-3)
        assertNoOverlapAndInside(rects, rect)
        let worstAspect = rects.map { max($0.width / $0.height, $0.height / $0.width) }.max()!
        XCTAssertLessThan(worstAspect, 8, "squarified rows keep aspect ratios reasonable")
    }

    func testZeroWeightsAndZeroTotal() {
        let rect = LayoutRect(x: 0, y: 0, width: 100, height: 100)
        let rects = Squarify.layout(weights: [10, 0, 0], in: rect)
        assertRectEqual(rects[0], rect, accuracy: 1e-6)
        XCTAssertEqual(rects[1].area, 0)
        XCTAssertEqual(Squarify.layout(weights: [0, 0], in: rect).map { $0.area }, [0, 0])
        XCTAssertEqual(Squarify.layout(weights: [], in: rect), [])
    }
}
