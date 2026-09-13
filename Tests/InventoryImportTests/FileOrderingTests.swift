import XCTest
import TestSupport
@testable import InventoryImport

final class FileOrderingTests: XCTestCase {
    func testFilesAreSortedByTheirFirstEncodedKey() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ordering-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let rows = ["zeta/1", "alpha/1", "mid dle/1", "alpha/2", "zeta/2", "mid dle/2"].map { FixtureRow(key: $0, size: 1) }
        try FixtureInventory.write(rows: rows, to: folder, fileCount: 3, shuffleManifest: true)
        let source = try InventorySource.load(folder: folder)
        let sorted = try FileOrdering.sortedByFirstKey(source.dataFiles, schema: source.schema)
        let firstKeys = try sorted.map { file in
            try FileOrdering.firstKey(of: file.url, schema: source.schema).map { String(decoding: $0, as: UTF8.self) }
        }

        XCTAssertEqual(firstKeys, ["alpha/1", "mid%20dle/1", "zeta/1"])
    }

    func testEmptyFileHasNoFirstKey() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("empty-\(UUID().uuidString).csv.gz")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try GzipDeflateWriter(url: url)
        try writer.finish()
        XCTAssertNil(try FileOrdering.firstKey(of: url, schema: .standard))
    }
}
