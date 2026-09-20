import XCTest
@testable import TreemapLayout

final class CushionTests: XCTestCase {
    func testCoefficientsForOneRect() {
        let rect = LayoutRect(x: 10, y: 20, width: 100, height: 50)
        let coefficients = CushionCoefficients().adding(rect: rect, height: 0.75)
        XCTAssertEqual(coefficients.sxx, Float(-4 * 0.75 / 100), accuracy: 1e-6)
        XCTAssertEqual(coefficients.sx, Float(4 * 0.75 * (10 + 110) / 100), accuracy: 1e-5)
        XCTAssertEqual(coefficients.syy, Float(-4 * 0.75 / 50), accuracy: 1e-6)
        XCTAssertEqual(coefficients.sy, Float(4 * 0.75 * (20 + 70) / 50), accuracy: 1e-5)
    }

    func testNestedRectsAccumulateAndLocalize() {
        let outer = LayoutRect(x: 0, y: 0, width: 200, height: 200)
        let inner = LayoutRect(x: 50, y: 50, width: 100, height: 100)
        let level0 = CushionCoefficients().adding(rect: outer, height: CushionCoefficients.height(atLevel: 0))
        let level1 = level0.adding(rect: inner, height: CushionCoefficients.height(atLevel: 1))
        XCTAssertEqual(level1.sxx, level0.sxx + Float(-4 * 0.75 * 0.75 / 100), accuracy: 1e-6)
        let slopeAtCenter = 2 * level1.sxx * 100 + level1.sx
        XCTAssertEqual(slopeAtCenter, 0, accuracy: 1e-4)
        let local = level1.localized(toOriginX: inner.x, y: inner.y)
        XCTAssertEqual(2 * local.sxx * 50 + local.sx, slopeAtCenter, accuracy: 1e-4)
        XCTAssertEqual(CushionCoefficients.height(atLevel: 2), 0.75 * 0.75 * 0.75, accuracy: 1e-12)
    }
}
