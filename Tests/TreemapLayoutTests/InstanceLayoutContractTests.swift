import XCTest
@testable import TreemapLayout

/// The Metal struct in App/Sources/Treemap/Shaders.metal must match TreemapInstance byte for byte.
final class InstanceLayoutContractTests: XCTestCase {
    func testFieldOffsets() {
        XCTAssertEqual(MemoryLayout<TreemapInstance>.stride, 52)
        XCTAssertEqual(MemoryLayout<TreemapInstance>.offset(of: \.x), 0)
        XCTAssertEqual(MemoryLayout<TreemapInstance>.offset(of: \.sxx), 16)
        XCTAssertEqual(MemoryLayout<TreemapInstance>.offset(of: \.directoryId), 32)
        XCTAssertEqual(MemoryLayout<TreemapInstance>.offset(of: \.nodeReference), 36)
        XCTAssertEqual(MemoryLayout<TreemapInstance>.offset(of: \.timeSeconds), 40)
        XCTAssertEqual(MemoryLayout<TreemapInstance>.offset(of: \.extensionId), 44)
        XCTAssertEqual(MemoryLayout<TreemapInstance>.offset(of: \.storageClassId), 46)
        XCTAssertEqual(MemoryLayout<TreemapInstance>.offset(of: \.kind), 47)
        XCTAssertEqual(MemoryLayout<TreemapInstance>.offset(of: \.groupId), 48)
    }
}
