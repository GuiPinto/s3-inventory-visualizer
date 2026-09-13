import XCTest
import TestSupport
import InventoryImport
@testable import InventoryIndex

final class OwnFilesCacheTests: XCTestCase {
    private var folder: URL!
    private var reader: IndexReader!
    private var rows: [FixtureRow] = []

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ownfiles-\(UUID().uuidString)")
        var generator = SystemRandomNumberGenerator()
        rows = (0..<300).map { index in
            FixtureRow(key: "big/file-\(String(format: "%04d", index)).bin", size: UInt64.random(in: 0...5000, using: &generator))
        }

        rows += (0..<40).map { index in
            FixtureRow(key: "big/sub\(index % 4)/inner-\(index).bin", size: UInt64(index) * 100)
        }

        rows += [FixtureRow(key: "big/zzz-last.bin", size: 4999), FixtureRow(key: "other/x", size: 1)]
        try FixtureInventory.write(rows: rows, to: folder, fileCount: 2)
        let source = try InventorySource.load(folder: folder)
        _ = try ImportPipeline(source: source, outputFolder: IndexReader.indexFolder(forInventory: folder), progress: { _ in }).run()
        reader = try IndexReader(folder: IndexReader.indexFolder(forInventory: folder))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func expectedOwnFiles(threshold: UInt64) -> [(String, UInt64)] {
        rows.filter { $0.key.hasPrefix("big/") && !$0.key.hasPrefix("big/sub") && $0.size >= threshold }
            .sorted { left, right in
                left.size != right.size ? left.size > right.size
                    : FixtureInventory.encodeKey(left.key) < FixtureInventory.encodeKey(right.key)
            }

            .map { (String($0.key.dropFirst(4)), $0.size) }
    }

    func testThresholdSelectionMatchesBruteForce() throws {
        let cache = OwnFilesCache(reader: reader)
        let big = reader.directories.lookup(path: "big")!
        let selection = cache.ownFiles(of: big, atLeast: 2500)
        let expected = expectedOwnFiles(threshold: 2500)
        XCTAssertEqual(selection.fileIndices.map { reader.names.nameString(ofFile: $0) }, expected.map { $0.0 })
        XCTAssertEqual(selection.sizes, expected.map { $0.1 })
        XCTAssertEqual(selection.ownFileCount, 301)
        let allOwnBytes = rows.filter { $0.key.hasPrefix("big/") && !$0.key.hasPrefix("big/sub") }.reduce(UInt64(0)) { $0 + $1.size }
        XCTAssertEqual(selection.ownBytes, allOwnBytes)
        XCTAssertEqual(selection.selectedBytes, expected.reduce(UInt64(0)) { $0 + $1.1 })
        let narrowed = cache.ownFiles(of: big, atLeast: 4000)
        XCTAssertEqual(narrowed.sizes, expectedOwnFiles(threshold: 4000).map { $0.1 })
        XCTAssertEqual(narrowed, OwnFilesCache(reader: reader).ownFiles(of: big, atLeast: 4000))
        let widened = cache.ownFiles(of: big, atLeast: 0)
        XCTAssertEqual(widened.fileIndices.count, 301)
    }

    func testLargestOwnFiles() throws {
        let cache = OwnFilesCache(reader: reader)
        let big = reader.directories.lookup(path: "big")!
        let largest = cache.largestOwnFiles(of: big, count: 5)
        XCTAssertEqual(largest.sizes, Array(expectedOwnFiles(threshold: 0).prefix(5).map { $0.1 }))
        XCTAssertEqual(
            largest.fileIndices.map { reader.names.nameString(ofFile: $0) },
            Array(expectedOwnFiles(threshold: 0).prefix(5).map { $0.0 })
        )
        let all = cache.largestOwnFiles(of: big, count: 10_000)
        XCTAssertEqual(all.fileIndices.count, 301)
    }

    func testDirectoryWithoutOwnFiles() throws {
        let cache = OwnFilesCache(reader: reader)
        let selection = cache.ownFiles(of: IndexFormat.rootDirectory, atLeast: 0)
        XCTAssertEqual(selection.fileIndices, [])
        XCTAssertEqual(selection.ownFileCount, 0)
    }
}
