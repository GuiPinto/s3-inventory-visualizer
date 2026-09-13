import XCTest
import TestSupport
import InventoryImport
@testable import InventoryIndex

final class SubtreeAggregatesTests: XCTestCase {
    private var folder: URL!
    private var reader: IndexReader!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("aggregates-\(UUID().uuidString)")
        let extensionNames = ["jpg", "mp4", "png", "pdf", "zip"]
        let dates = [
            "2025-12-20T00:00:00.000Z",
            "2025-10-01T00:00:00.000Z",
            "2025-05-01T00:00:00.000Z",
            "2024-06-01T00:00:00.000Z",
            "2020-01-01T00:00:00.000Z"
        ]
        var rows: [FixtureRow] = []

        for index in 0..<2000 {
            let key = "tree/" + String(index % 7) + "/file-" + String(index) + "." + extensionNames[index % 5]
            rows.append(FixtureRow(key: key, size: UInt64(index + 1), lastModified: dates[index % 5]))
        }

        rows.append(FixtureRow(key: "elsewhere/x.jpg", size: 999_999))
        try FixtureInventory.write(rows: rows, to: folder, fileCount: 3, creationTimestampMilliseconds: 1_767_225_600_000)
        let source = try InventorySource.load(folder: folder)
        _ = try ImportPipeline(source: source, outputFolder: IndexReader.indexFolder(forInventory: folder), progress: { _ in }).run()
        reader = try IndexReader(folder: IndexReader.indexFolder(forInventory: folder))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testExtensionBreakdown() {
        let aggregates = SubtreeAggregates(reader: reader)
        let tree = reader.directories.lookup(path: "tree")!
        let breakdown = aggregates.extensionBreakdown(of: tree, isCancelled: { false })!
        XCTAssertEqual(breakdown.totalFiles, 2000)
        XCTAssertEqual(breakdown.totalBytes, UInt64((1...2000).reduce(0, +)))
        XCTAssertEqual(breakdown.entries.count, 5)
        let names = breakdown.entries.map { reader.manifest.extensionNames[Int($0.extensionId)] }
        XCTAssertEqual(names.first, "zip", "index % 5 == 4 carries the largest sizes")
        XCTAssertEqual(breakdown.entries.map { $0.files }, [400, 400, 400, 400, 400])
        XCTAssertEqual(breakdown.otherBytes, 0)
    }

    func testAgeBreakdown() {
        let aggregates = SubtreeAggregates(reader: reader)
        let tree = reader.directories.lookup(path: "tree")!
        let breakdown = aggregates.ageBreakdown(of: tree, isCancelled: { false })!
        XCTAssertEqual(breakdown.bucketFiles.reduce(0, +), 2000)
        XCTAssertEqual(breakdown.bucketFiles[0], 400)
        XCTAssertEqual(breakdown.bucketFiles[2], 400)
        XCTAssertEqual(breakdown.bucketFiles[3], 400)
        XCTAssertEqual(breakdown.bucketFiles[4], 400)
        XCTAssertEqual(breakdown.bucketFiles[7], 400)
        XCTAssertEqual(SubtreeAggregates.ageBucket(ageDays: 0), 0)
        XCTAssertEqual(SubtreeAggregates.ageBucket(ageDays: 30), 1)
        XCTAssertEqual(SubtreeAggregates.ageBucket(ageDays: 1825), 7)
    }
}
