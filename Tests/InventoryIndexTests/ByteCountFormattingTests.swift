import XCTest
@testable import InventoryIndex

final class ByteCountFormattingTests: XCTestCase {
    func testBinaryUnits() {
        XCTAssertEqual(formatByteCount(0, units: .binary), "0 B")
        XCTAssertEqual(formatByteCount(512, units: .binary), "512 B")
        XCTAssertEqual(formatByteCount(1536, units: .binary), "1.5 KiB")
        XCTAssertEqual(formatByteCount(869_012_548_707_428, units: .binary), "790.4 TiB")
    }

    func testDecimalUnits() {
        XCTAssertEqual(formatByteCount(1_500_000, units: .decimal), "1.5 MB")
        XCTAssertEqual(formatByteCount(869_012_548_707_428, units: .decimal), "869.0 TB")
    }

    func testCountsUseGroupingSeparators() {
        XCTAssertEqual(formatCount(1_119_935_804), "1,119,935,804")
    }
}
