import XCTest
import TestSupport
@testable import InventoryImport

final class InventorySourceTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("source-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testSchemaMapsColumns() throws {
        let schema = try InventorySchema(fileSchema: "Bucket, Key, VersionId, IsLatest, IsDeleteMarker, Size, LastModifiedDate, ETag, StorageClass, IsMultipartUploaded, ReplicationStatus, IntelligentTieringAccessTier")
        XCTAssertEqual(schema.keyColumn, 1)
        XCTAssertEqual(schema.sizeColumn, 5)
        XCTAssertEqual(schema.lastModifiedColumn, 6)
        XCTAssertEqual(schema.storageClassColumn, 8)
        XCTAssertEqual(schema.isLatestColumn, 3)
        XCTAssertEqual(schema.isDeleteMarkerColumn, 4)
        XCTAssertEqual(schema.requiredFieldCount, 9)
        let reduced = try InventorySchema(fileSchema: "Bucket, Key, Size")
        XCTAssertNil(reduced.lastModifiedColumn)
        XCTAssertEqual(reduced.requiredFieldCount, 3)
        XCTAssertThrowsError(try InventorySchema(fileSchema: "Bucket, Size"))
    }

    func testLoadsManifestAndResolvesDataFiles() throws {
        let rows = (0..<10).map { FixtureRow(key: "prefix/file\($0).jpg", size: UInt64($0)) }
        try FixtureInventory.write(rows: rows, to: folder, bucket: "my-bucket", fileCount: 3)
        let source = try InventorySource.load(folder: folder)
        XCTAssertEqual(source.sourceBucket, "my-bucket")
        XCTAssertEqual(source.dataFiles.count, 3)
        XCTAssertEqual(source.missingDataFiles, [])
        XCTAssertEqual(source.creationTimestampMilliseconds, 1_767_225_600_000)
        XCTAssertEqual(source.inventoryTimestamp, 1_767_225_600)
        XCTAssertEqual(source.schema, InventorySchema.standard)
        XCTAssertNotNil(source.manifestMD5)
        XCTAssertEqual(source.totalCompressedBytes, source.dataFiles.reduce(0) { $0 + $1.actualSize })
    }

    func testMissingAndMismatchedFilesAreReported() throws {
        let rows = (0..<10).map { FixtureRow(key: "k\($0)", size: 1) }
        try FixtureInventory.write(rows: rows, to: folder, fileCount: 2)
        let dataFiles = try FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent("data"), includingPropertiesForKeys: nil)
        try FileManager.default.removeItem(at: dataFiles[0])
        try Data([1, 2, 3]).write(to: dataFiles[1])
        let source = try InventorySource.load(folder: folder)
        XCTAssertEqual(source.dataFiles.count, 0)
        XCTAssertEqual(Set(source.missingDataFiles), Set(dataFiles.map { $0.lastPathComponent }))
    }

    func testBareFolderWithoutManifest() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let writer = try GzipDeflateWriter(url: folder.appendingPathComponent("part.csv.gz"))
        try writer.write("\"b\",\"k\",\"v\",\"true\",\"false\",\"1\",\"2026-01-01T00:00:00.000Z\",\"e\",\"STANDARD\",\"false\",\"\",\"\"\n")
        try writer.finish()
        let source = try InventorySource.load(folder: folder)
        XCTAssertNil(source.manifestURL)
        XCTAssertEqual(source.dataFiles.count, 1)
        XCTAssertEqual(source.schema, InventorySchema.standard)
        XCTAssertEqual(source.sourceBucket, folder.lastPathComponent)
    }

    func testNonCSVManifestIsRejected() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "{\"fileFormat\":\"Parquet\",\"sourceBucket\":\"b\",\"fileSchema\":\"Key, Size\",\"files\":[]}"
            .write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try InventorySource.load(folder: folder)) { error in
            guard case ImportError.invalidManifest = error else { return XCTFail("wrong error \(error)") }
        }
    }
}
