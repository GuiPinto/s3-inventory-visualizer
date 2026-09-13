import XCTest
@testable import InventoryIndex

final class StorageClassTests: XCTestCase {
    func testKnownNamesMapToFixedIdentifiers() {
        XCTAssertEqual(StorageClass.identifier(forInventoryName: "STANDARD"), 0)
        XCTAssertEqual(StorageClass.identifier(forInventoryName: "STANDARD_IA"), 1)
        XCTAssertEqual(StorageClass.identifier(forInventoryName: "INTELLIGENT_TIERING"), 2)
        XCTAssertEqual(StorageClass.identifier(forInventoryName: "ONEZONE_IA"), 3)
        XCTAssertEqual(StorageClass.identifier(forInventoryName: "GLACIER_IR"), 4)
        XCTAssertEqual(StorageClass.identifier(forInventoryName: "GLACIER"), 5)
        XCTAssertEqual(StorageClass.identifier(forInventoryName: "DEEP_ARCHIVE"), 6)
    }

    func testUnknownAndEmptyMapToOther() {
        XCTAssertEqual(StorageClass.identifier(forInventoryName: "REDUCED_REDUNDANCY"), 7)
        XCTAssertEqual(StorageClass.identifier(forInventoryName: "EXPRESS_ONEZONE"), 7)
        XCTAssertEqual(StorageClass.identifier(forInventoryName: ""), 7)
        XCTAssertEqual(StorageClass.identifier(forInventoryName: "STANDARD_IAX"), 7)
    }

    func testNamesArrayHasEightEntriesInIdentifierOrder() {
        XCTAssertEqual(StorageClass.names, ["STANDARD", "STANDARD_IA", "INTELLIGENT_TIERING", "ONEZONE_IA",
                                            "GLACIER_IR", "GLACIER", "DEEP_ARCHIVE", "OTHER"])
    }
}
