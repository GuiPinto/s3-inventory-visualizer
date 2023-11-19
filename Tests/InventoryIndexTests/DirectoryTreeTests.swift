import XCTest
@testable import InventoryIndex

final class DirectoryTreeTests: XCTestCase {
    private var folder: URL!
    private let inventoryTimestamp: UInt32 = 1_767_225_600   // 2026-01-01T00:00:00Z

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tree-\(UUID().uuidString)")
        try writeFixtureIndex()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func writeFixtureIndex() throws {
        let writer = try IndexWriter(folder: folder, directoryCapacity: 16)

        func writeDirectory(
            _ id: Int,
            parent: UInt32,
            depth: UInt8,
            name: String,
            subtreeDirectories: UInt32,
            children: UInt32,
            fileStart: UInt64,
            subtreeFiles: UInt64,
            subtreeBytes: UInt64,
            ownFiles: UInt32,
            ownBytes: UInt64,
            classBytes: [UInt64],
            dominantExtension: UInt16,
            ageWeighted: UInt64
        ) {
            writer.directoryParent[id] = parent
            writer.directoryDepth[id] = depth
            writer.directoryNameOffset[id] = UInt64(writer.directoryNames.count)
            writer.directoryNameLength[id] = UInt16(name.utf8.count)
            Array(name.utf8).withUnsafeBytes { writer.directoryNames.appendBytes($0) }
            writer.directorySubtreeDirectoryCount[id] = subtreeDirectories
            writer.directoryChildCount[id] = children
            writer.directoryFileStart[id] = fileStart
            writer.directorySubtreeFileCount[id] = subtreeFiles
            writer.directorySubtreeBytes[id] = subtreeBytes
            writer.directoryOwnFileCount[id] = ownFiles
            writer.directoryOwnBytes[id] = ownBytes

            for slot in 0..<8 {
                writer.directoryBytesByStorageClass[id * 8 + slot] = classBytes[slot]
            }

            writer.directoryDominantExtension[id] = dominantExtension
            writer.directoryAgeWeightedBytes[id] = ageWeighted
        }

        let ageWeightedRoot: UInt64 = 10 * 365 + 20 * 731
        writeDirectory(
            0,
            parent: IndexFormat.noParent,
            depth: 0,
            name: "",
            subtreeDirectories: 3,
            children: 2,
            fileStart: 0,
            subtreeFiles: 4,
            subtreeBytes: 75,
            ownFiles: 0,
            ownBytes: 0,
            classBytes: [45, 10, 0, 0, 0, 0, 20, 0],
            dominantExtension: 0,
            ageWeighted: ageWeightedRoot
        )
        writeDirectory(
            1,
            parent: 0,
            depth: 1,
            name: "a",
            subtreeDirectories: 1,
            children: 1,
            fileStart: 0,
            subtreeFiles: 3,
            subtreeBytes: 35,
            ownFiles: 2,
            ownBytes: 30,
            classBytes: [5, 10, 0, 0, 0, 0, 20, 0],
            dominantExtension: 0,
            ageWeighted: ageWeightedRoot
        )
        writeDirectory(
            2,
            parent: 1,
            depth: 2,
            name: "b",
            subtreeDirectories: 0,
            children: 0,
            fileStart: 0,
            subtreeFiles: 1,
            subtreeBytes: 5,
            ownFiles: 1,
            ownBytes: 5,
            classBytes: [5, 0, 0, 0, 0, 0, 0, 0],
            dominantExtension: 0,
            ageWeighted: 0
        )
        writeDirectory(
            3,
            parent: 0,
            depth: 1,
            name: "c",
            subtreeDirectories: 0,
            children: 0,
            fileStart: 3,
            subtreeFiles: 1,
            subtreeBytes: 40,
            ownFiles: 1,
            ownBytes: 40,
            classBytes: [40, 0, 0, 0, 0, 0, 0, 0],
            dominantExtension: 0,
            ageWeighted: 0
        )

        let files: [(name: String, size: UInt64, modified: UInt32, storageClass: UInt8)] = [
            ("z", 5, inventoryTimestamp, 0),
            ("x", 10, inventoryTimestamp - 365 * 86400, 1),
            ("y", 20, inventoryTimestamp - 731 * 86400, 6),
            ("w", 40, inventoryTimestamp, 0),
        ]
        var raw: [UInt8] = []

        for file in files {
            writer.fileSize.append(file.size)
            writer.fileLastModified.append(file.modified)
            writer.fileStorageClass.append(file.storageClass)
            writer.fileExtension.append(0)
            Array(file.name.utf8).withUnsafeBufferPointer { NameBlockCodec.appendName($0, to: &raw) }
        }

        let compressed = NameBlockCodec.encode(raw: raw)
        writer.fileNameBlocks.append(NameBlockEntry(offset: 0, compressedLength: UInt32(compressed.count), rawLength: UInt32(raw.count)))
        compressed.withUnsafeBytes { writer.fileNameData.appendBytes($0) }

        try writer.finish(directoryCount: 4)
        try IndexPostProcessing.writeChildrenBySize(folder: folder)
        var manifest = IndexManifest.empty(sourceBucket: "fixture", inventoryTimestamp: inventoryTimestamp)
        manifest.counts.directoryCount = 4
        manifest.counts.fileCount = 4
        manifest.counts.totalBytes = 75
        try manifest.save(to: folder)
    }

    func testTreeAccessors() throws {
        let reader = try IndexReader(folder: folder)
        let tree = reader.directories
        XCTAssertEqual(tree.count, 4)
        XCTAssertEqual(tree.parent(0), IndexFormat.noParent)
        XCTAssertEqual(tree.parent(2), 1)
        XCTAssertEqual(tree.name(2), "b")
        XCTAssertEqual(tree.path(2), "a/b")
        XCTAssertEqual(tree.path(0), "")
        XCTAssertEqual(tree.childrenInKeyOrder(0), [1, 3])
        XCTAssertEqual(tree.childrenInKeyOrder(1), [2])
        XCTAssertEqual(tree.childrenBySize(0), [3, 1])
        XCTAssertEqual(tree.subtreeRange(1), 1..<3)
        XCTAssertEqual(tree.subtreeFileRange(1), 0..<3)
        XCTAssertEqual(tree.ownFileRanges(1), [1..<3])
        XCTAssertEqual(tree.ownFileRanges(0), [])
        XCTAssertEqual(tree.ownFileRanges(3), [3..<4])
        XCTAssertEqual(tree.lookup(path: "a/b"), 2)
        XCTAssertEqual(tree.lookup(path: ""), 0)
        XCTAssertNil(tree.lookup(path: "a/nope"))
        XCTAssertEqual(tree.bytesByStorageClass(1), [5, 10, 0, 0, 0, 0, 20, 0])
        XCTAssertEqual(tree.dominantStorageClass(1), 6)
        XCTAssertEqual(tree.averageAgeDays(1), Double(10 * 365 + 20 * 731) / 35, accuracy: 0.001)
    }

    func testChildOfAncestorContainingDescendant() throws {
        let reader = try IndexReader(folder: folder)
        let tree = reader.directories
        // The fixture is root 0, with children 1 ("a") and 3 ("c"), and 2 ("b") under 1.
        XCTAssertEqual(tree.child(of: 0, containing: 2), 1)
        XCTAssertEqual(tree.child(of: 0, containing: 1), 1)
        XCTAssertEqual(tree.child(of: 0, containing: 3), 3)
        XCTAssertEqual(tree.child(of: 1, containing: 2), 2)
        XCTAssertNil(tree.child(of: 0, containing: 0))
        XCTAssertNil(tree.child(of: 1, containing: 3))
        XCTAssertNil(tree.child(of: 2, containing: 1))
    }

    func testFileLookups() throws {
        let reader = try IndexReader(folder: folder)
        XCTAssertEqual(reader.key(ofFile: 0), "a/b/z")
        XCTAssertEqual(reader.key(ofFile: 1), "a/x")
        XCTAssertEqual(reader.key(ofFile: 3), "c/w")
        XCTAssertEqual(reader.directory(ofFile: 0), 2)
        XCTAssertEqual(reader.directory(ofFile: 1), 1)
        XCTAssertEqual(reader.directory(ofFile: 2), 1)
        XCTAssertEqual(reader.directory(ofFile: 3), 3)
        XCTAssertEqual(reader.fileSize[2], 20)
        XCTAssertEqual(reader.manifest.counts.fileCount, 4)
    }

    func testMissingManifestMeansIncomplete() throws {
        try FileManager.default.removeItem(at: folder.appendingPathComponent(IndexFiles.manifest))
        XCTAssertThrowsError(try IndexReader(folder: folder)) { error in
            guard case IndexError.incompleteIndex = error else { return XCTFail("wrong error \(error)") }
        }
    }
}
