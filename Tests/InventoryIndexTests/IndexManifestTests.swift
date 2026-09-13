import XCTest
@testable import InventoryIndex

final class IndexManifestTests: XCTestCase {
    func testRoundTripThroughFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("manifest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var manifest = IndexManifest.empty(sourceBucket: "bucket", inventoryTimestamp: 1_700_000_000)
        manifest.counts.fileCount = 42
        manifest.extensionNames = ["", "jpg"]
        manifest.extensionPalette = [1]
        try manifest.save(to: folder)
        let loaded = try IndexManifest.load(from: folder)
        XCTAssertEqual(loaded.counts.fileCount, 42)
        XCTAssertEqual(loaded.extensionPalette, [1])
        XCTAssertEqual(loaded.source.sourceBucket, "bucket")
        XCTAssertEqual(loaded.storageClassNames, StorageClass.names)
    }

    func testMissingManifestIsIncompleteIndex() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString)")
        XCTAssertThrowsError(try IndexManifest.load(from: folder)) { error in
            guard case IndexError.incompleteIndex = error else { return XCTFail("wrong error \(error)") }
        }
    }

    func testExtensionPaletteTakesLargestByBytesExcludingNoExtension() {
        let bytes: [UInt16: UInt64] = [0: 1_000_000, 3: 10, 7: 500, 9: 20]
        XCTAssertEqual(IndexManifest.extensionPalette(from: bytes, maximum: 2), [7, 9])
        XCTAssertEqual(IndexManifest.extensionPalette(from: bytes), [7, 9, 3])
    }
}
