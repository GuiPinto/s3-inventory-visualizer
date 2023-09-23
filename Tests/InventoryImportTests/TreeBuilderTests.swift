import XCTest
import TestSupport
import InventoryIndex
@testable import InventoryImport

final class TreeBuilderTests: XCTestCase {
    private var folder: URL!
    private let inventoryTimestamp: UInt32 = 1_767_225_600

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("builder-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    static let awkwardRows: [FixtureRow] = [
        FixtureRow(key: "a/b/c.txt", size: 10, lastModified: "2025-06-01T00:00:00.000Z", storageClass: "STANDARD"),
        FixtureRow(key: "a/b/c/x", size: 20, lastModified: "2024-06-01T00:00:00.000Z", storageClass: "STANDARD_IA"),
        FixtureRow(key: "a/b/d", size: 30, storageClass: "DEEP_ARCHIVE"),
        FixtureRow(key: "dir one/f%.jpg", size: 40, storageClass: "GLACIER_IR"),
        FixtureRow(key: "folder/", size: 0, storageClass: "STANDARD"),
        FixtureRow(key: "a//b", size: 5, storageClass: "REDUCED_REDUNDANCY"),
        FixtureRow(key: "deep/1/2/3/4/5/6/7/8/leaf.MP4", size: 6_000_000_000,
                   lastModified: "2020-01-01T00:00:00.000Z", storageClass: "STANDARD_IA"),
        FixtureRow(key: "root-file.png", size: 7, storageClass: "STANDARD"),
        FixtureRow(key: String(repeating: "k", count: 1000) + "/n.jpg", size: 8, storageClass: "STANDARD"),
        FixtureRow(key: "zero.bin", size: 0, storageClass: "STANDARD"),
        FixtureRow(key: "old.jpg", size: 99, storageClass: "STANDARD", isLatest: false),
        FixtureRow(key: "gone.jpg", size: 0, storageClass: "", isLatest: true, isDeleteMarker: true),
        FixtureRow(key: "photos/2026/a.jpg", size: 100, storageClass: "STANDARD"),
        FixtureRow(key: "photos/2026/b.JPG", size: 200, storageClass: "STANDARD"),
        FixtureRow(key: "photos/2026/c.mp4", size: 250, storageClass: "STANDARD_IA"),
    ]

    private func build(rows: [FixtureRow], rowsPerChunk: Int = 4) throws -> (IndexReader, TreeBuilderSummary) {
        let writer = try IndexWriter(folder: folder, directoryCapacity: 1000)
        let sink = SynchronousNameBlockWriter(blocks: writer.fileNameBlocks, data: writer.fileNameData)
        let builder = TreeBuilder(
            writer: writer,
            inventoryTimestamp: inventoryTimestamp,
            nameBlockConsumer: sink,
            fileNames: ["fixture.csv.gz"]
        )

        for chunk in FixtureInventory.makeChunks(rows: rows, rowsPerChunk: rowsPerChunk) {
            try builder.consume(chunk)
        }

        let summary = try builder.finish()
        try IndexPostProcessing.writeChildrenBySize(folder: folder)
        var manifest = IndexManifest.empty(sourceBucket: "fixture", inventoryTimestamp: inventoryTimestamp)
        manifest.counts.directoryCount = summary.directoryCount
        manifest.counts.fileCount = summary.fileCount
        manifest.extensionNames = summary.extensionNames
        try manifest.save(to: folder)
        return (try IndexReader(folder: folder), summary)
    }

    func testAwkwardRowsMatchReference() throws {
        let (reader, summary) = try build(rows: TreeBuilderTests.awkwardRows)
        let reference = ReferenceTree.build(rows: TreeBuilderTests.awkwardRows, inventoryTimestamp: inventoryTimestamp)
        XCTAssertEqual(indexMismatches(reader: reader, reference: reference, inventoryTimestamp: inventoryTimestamp), [])
        XCTAssertEqual(summary.skippedNonCurrent, 1)
        XCTAssertEqual(summary.skippedDeleteMarkers, 1)
        XCTAssertEqual(summary.fileCount, 13)
        let percentIndex = reference.filesInKeyOrder.firstIndex { $0.key == "dir one/f%.jpg" }!
        XCTAssertEqual(reader.key(ofFile: UInt64(percentIndex)), "dir one/f%.jpg")
        XCTAssertEqual(reader.directories.lookup(path: "deep/1/2/3/4/5/6/7/8").map { reader.directories.depth($0) }, 9)
        let directoryA = reader.directories.lookup(path: "a")!
        let emptySegmentChildren = reader.directories.childrenInKeyOrder(directoryA).filter { reader.directories.name($0).isEmpty }
        XCTAssertEqual(emptySegmentChildren.count, 1, "the empty segment of a//b is its own directory")
        XCTAssertEqual(reader.directories.ownFileCount(emptySegmentChildren[0]), 1)
    }

    func testManyFilesCrossNameBlockBoundary() throws {
        var rows: [FixtureRow] = []

        for index in 0..<(IndexFormat.namesPerBlock * 2 + 17) {
            rows.append(FixtureRow(key: "bulk/\(index % 7)/item-\(String(format: "%06d", index)).dat", size: UInt64(index)))
        }

        let (reader, _) = try build(rows: rows, rowsPerChunk: 1000)
        let reference = ReferenceTree.build(rows: rows, inventoryTimestamp: inventoryTimestamp)
        XCTAssertEqual(indexMismatches(reader: reader, reference: reference, inventoryTimestamp: inventoryTimestamp), [])
        XCTAssertEqual(reader.names.blockCount, 3)
    }

    /// Regression for a production finding: S3 Inventory orders rows by the DECODED key.
    /// "...2021.png" precedes "...2021%402x.png" because '.' (0x2E) < '@' (0x40), even though the
    /// encoded bytes would order them the other way, since '%' is 0x25.
    func testDecodedKeyOrderIsAccepted() throws {
        let writer = try IndexWriter(folder: folder, directoryCapacity: 100)
        let sink = SynchronousNameBlockWriter(blocks: writer.fileNameBlocks, data: writer.fileNameData)
        let builder = TreeBuilder(
            writer: writer,
            inventoryTimestamp: inventoryTimestamp,
            nameBlockConsumer: sink,
            fileNames: ["one.csv.gz"]
        )
        var chunk = RowChunk(fileIndex: 0, chunkIndex: 0, capacity: 2)

        for encodedKey in ["calendars/email/footer-2021.png", "calendars/email/footer-2021%402x.png"] {
            Array(encodedKey.utf8).withUnsafeBufferPointer {
                chunk.appendRow(key: $0, size: 1, lastModified: 0, storageClass: 0)
            }
        }

        XCTAssertNoThrow(try builder.consume(chunk))
        let summary = try builder.finish()
        try IndexPostProcessing.writeChildrenBySize(folder: folder)
        var manifest = IndexManifest.empty(sourceBucket: "fixture", inventoryTimestamp: inventoryTimestamp)
        manifest.counts.fileCount = summary.fileCount
        manifest.extensionNames = summary.extensionNames
        try manifest.save(to: folder)
        let reader = try IndexReader(folder: folder)
        XCTAssertEqual(reader.key(ofFile: 0), "calendars/email/footer-2021.png")
        XCTAssertEqual(reader.key(ofFile: 1), "calendars/email/footer-2021@2x.png")
    }

    func testUnsortedInputAborts() throws {
        let writer = try IndexWriter(folder: folder, directoryCapacity: 100)
        let sink = SynchronousNameBlockWriter(blocks: writer.fileNameBlocks, data: writer.fileNameData)
        let builder = TreeBuilder(
            writer: writer,
            inventoryTimestamp: inventoryTimestamp,
            nameBlockConsumer: sink,
            fileNames: ["one.csv.gz"]
        )
        var chunk = RowChunk(fileIndex: 0, chunkIndex: 0, capacity: 2)
        Array("b/1".utf8).withUnsafeBufferPointer { chunk.appendRow(key: $0, size: 1, lastModified: 0, storageClass: 0) }
        Array("a/1".utf8).withUnsafeBufferPointer { chunk.appendRow(key: $0, size: 1, lastModified: 0, storageClass: 0) }
        XCTAssertThrowsError(try builder.consume(chunk)) { error in
            guard case ImportError.notKeySorted(let file, let previous, let key) = error else {
                return XCTFail("wrong error \(error)")
            }

            XCTAssertEqual(file, "one.csv.gz")
            XCTAssertEqual(previous, "b/1")
            XCTAssertEqual(key, "a/1")
        }
    }

    func testReenteredDirectoryAborts() throws {
        let writer = try IndexWriter(folder: folder, directoryCapacity: 100)
        let sink = SynchronousNameBlockWriter(blocks: writer.fileNameBlocks, data: writer.fileNameData)
        let builder = TreeBuilder(
            writer: writer,
            inventoryTimestamp: inventoryTimestamp,
            nameBlockConsumer: sink,
            fileNames: ["one.csv.gz"]
        )
        var chunk = RowChunk(fileIndex: 0, chunkIndex: 0, capacity: 2)

        for key in ["a/b/x", "a/y"] {
            Array(key.utf8).withUnsafeBufferPointer { chunk.appendRow(key: $0, size: 1, lastModified: 0, storageClass: 0) }
        }

        try builder.consume(chunk)
        builder.resetOrderingCheckForTesting()
        var second = RowChunk(fileIndex: 0, chunkIndex: 1, capacity: 1)
        Array("a/b/z".utf8).withUnsafeBufferPointer { second.appendRow(key: $0, size: 1, lastModified: 0, storageClass: 0) }
        XCTAssertThrowsError(try builder.consume(second)) { error in
            if case ImportError.notKeySorted = error {
                return
            }

            if case ImportError.directoryReentered = error {
                return
            }

            XCTFail("wrong error \(error)")
        }
    }
}
