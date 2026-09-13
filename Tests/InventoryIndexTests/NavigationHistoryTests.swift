import XCTest
@testable import InventoryIndex

final class NavigationHistoryTests: XCTestCase {
    func testBackForwardAndTruncation() {
        let history = NavigationHistory(root: 0)
        XCTAssertFalse(history.canGoBack)
        history.navigate(to: 5)
        history.navigate(to: 9)
        XCTAssertEqual(history.current, 9)
        XCTAssertEqual(history.goBack(), 5)
        XCTAssertEqual(history.goBack(), 0)
        XCTAssertNil(history.goBack())
        XCTAssertEqual(history.goForward(), 5)
        history.navigate(to: 7)
        XCTAssertFalse(history.canGoForward)
        XCTAssertEqual(history.goBack(), 5)
        history.navigate(to: 5)
        XCTAssertEqual(history.current, 5)
        history.reset(to: 0)
        XCTAssertFalse(history.canGoBack)
    }
}
