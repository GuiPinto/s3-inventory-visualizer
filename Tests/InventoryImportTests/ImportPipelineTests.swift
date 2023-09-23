import XCTest
import TestSupport
import InventoryIndex
@testable import InventoryImport

final class ImportPipelineTests: XCTestCase {
    private var folder: URL!
    private var output: URL { folder.appendingPathComponent(IndexFormat.folderName) }

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("pipeline-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func rows(count: Int) -> [FixtureRow] {
        var result: [FixtureRow] = []
        result.reserveCapacity(count)

        for index in 0..<count {
            let extensionName: String = index % 3 == 0 ? "jpg" : "mp4"
            let serial: String = String(format: "%06d", index)
            let key: String = "assets/" + String(index % 13) + "/" + String(index % 5) + "/item-" + serial + "." + extensionName
            let size = UInt64(index * 37 % 1000)
            let lastModified: String = index % 2 == 0 ? "2026-01-01T00:00:00.000Z" : "2024-06-15T12:00:00.000Z"
            let storageClass: String = index % 4 == 0 ? "DEEP_ARCHIVE" : "STANDARD"
            result.append(FixtureRow(key: key, size: size, lastModified: lastModified, storageClass: storageClass))
        }

        return result
    }

    func testEndToEndImportMatchesReference() throws {
        let rows = rows(count: 5000) + TreeBuilderTests.awkwardRows
        try FixtureInventory.write(rows: rows, to: folder, fileCount: 6, shuffleManifest: true)
        let source = try InventorySource.load(folder: folder)
        var options = ImportOptions()
        options.threadCount = 3
        options.rowsPerChunk = 100
        options.maximumRowsInFlight = 250
        var progressEvents: [ImportProgress] = []
        let progressLock = NSLock()
        let pipeline = ImportPipeline(source: source, outputFolder: output, options: options) { event in
            progressLock.lock()
            progressEvents.append(event)
            progressLock.unlock()
        }

        let manifest = try pipeline.run()
        let reader = try IndexReader(folder: output)
        let reference = ReferenceTree.build(rows: rows, inventoryTimestamp: source.inventoryTimestamp)
        XCTAssertEqual(indexMismatches(reader: reader, reference: reference, inventoryTimestamp: source.inventoryTimestamp), [])
        XCTAssertEqual(manifest.counts.fileCount, UInt64(reference.filesInKeyOrder.count))
        XCTAssertEqual(manifest.counts.directoryCount, reference.directoriesInPreOrder.count)
        XCTAssertEqual(manifest.counts.skippedNonCurrent, 1)
        XCTAssertEqual(manifest.counts.skippedDeleteMarkers, 1)
        XCTAssertEqual(manifest.source.sourceBucket, "fixture-bucket")
        XCTAssertEqual(manifest.source.manifestFileCount, 6)
        XCTAssertEqual(manifest.extensionPalette.first.map { manifest.extensionNames[Int($0)] }, "mp4")
        XCTAssertEqual(progressEvents.last?.phase, .finished)
        XCTAssertTrue(progressEvents.contains { $0.phase == .importing })
    }

    func testCancelRemovesPartialOutput() throws {
        try FixtureInventory.write(rows: rows(count: 20_000), to: folder, fileCount: 4)
        let source = try InventorySource.load(folder: folder)
        var options = ImportOptions()
        options.rowsPerChunk = 50
        options.progressInterval = 0
        var pipeline: ImportPipeline!
        pipeline = ImportPipeline(source: source, outputFolder: output, options: options) { progress in
            if progress.phase == .importing && progress.rowsConsumed > 0 {
                pipeline.cancel()
            }
        }

        XCTAssertThrowsError(try pipeline.run()) { error in
            guard case ImportError.cancelled = error else { return XCTFail("wrong error \(error)") }
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testMissingDataFileFailsUnlessAllowed() throws {
        try FixtureInventory.write(rows: rows(count: 300), to: folder, fileCount: 3)
        let dataFiles = try FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent("data"), includingPropertiesForKeys: nil)
        try FileManager.default.removeItem(at: dataFiles[0])
        let source = try InventorySource.load(folder: folder)
        XCTAssertThrowsError(try ImportPipeline(source: source, outputFolder: output, progress: { _ in }).run()) { error in
            guard case ImportError.missingDataFiles(let names) = error else { return XCTFail("wrong error \(error)") }
            XCTAssertEqual(names, [dataFiles[0].lastPathComponent])
        }

        var options = ImportOptions()
        options.allowMissingDataFiles = true
        let manifest = try ImportPipeline(source: source, outputFolder: output, options: options, progress: { _ in }).run()
        XCTAssertEqual(manifest.missingDataFiles, [dataFiles[0].lastPathComponent])
        XCTAssertTrue(manifest.isPartial)
        XCTAssertGreaterThan(manifest.counts.fileCount, 0)
    }

    func testOverlappingFilesAbort() throws {
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("data"), withIntermediateDirectories: true)

        for (name, keys) in [("one.csv.gz", ["a/1", "c/1"]), ("two.csv.gz", ["b/1", "d/1"])] {
            let writer = try GzipDeflateWriter(url: folder.appendingPathComponent("data/\(name)"))

            for key in keys {
                try writer.write(FixtureInventory.csvRow(
                    FixtureRow(key: key, size: 1),
                    bucket: "b",
                    schemaColumns: InventorySchema.defaultColumns
                ))
            }

            try writer.finish()
        }

        let source = try InventorySource.load(folder: folder)
        XCTAssertThrowsError(try ImportPipeline(source: source, outputFolder: output, progress: { _ in }).run()) { error in
            guard case ImportError.notKeySorted = error else { return XCTFail("wrong error \(error)") }
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testRefusesToOverwriteWithoutOption() throws {
        try FixtureInventory.write(rows: rows(count: 10), to: folder)
        let source = try InventorySource.load(folder: folder)
        _ = try ImportPipeline(source: source, outputFolder: output, progress: { _ in }).run()
        XCTAssertThrowsError(try ImportPipeline(source: source, outputFolder: output, progress: { _ in }).run()) { error in
            guard case ImportError.outputExists = error else { return XCTFail("wrong error \(error)") }
        }

        var options = ImportOptions()
        options.overwriteExistingIndex = true
        _ = try ImportPipeline(source: source, outputFolder: output, options: options, progress: { _ in }).run()
    }
}
