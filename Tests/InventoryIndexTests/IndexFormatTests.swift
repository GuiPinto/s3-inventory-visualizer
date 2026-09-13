import XCTest
@testable import InventoryIndex

final class IndexFormatTests: XCTestCase {
    func testConstantsMatchSpec() {
        XCTAssertEqual(IndexFormat.folderName, ".s3-inventory-index")
        XCTAssertEqual(IndexFormat.namesPerBlock, 4096)
        XCTAssertEqual(IndexFormat.storageClassSlots, 8)
        XCTAssertEqual(IndexFormat.columnMagic.count, 8)
        XCTAssertEqual(IndexFormat.ageBucketDays.count, 7)
    }
}
