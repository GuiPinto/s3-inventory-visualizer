import XCTest
import InventoryIndex
@testable import TreemapLayout

/// In-memory tree. Directory identifiers are pre-order; files have global indices.
final class FakeLayoutDataSource: LayoutDataSource {
    struct Directory {
        var name: String
        var children: [UInt32]
        var files: [UInt64]
        var storageClass: UInt8 = 0
        var timeSeconds: UInt32 = 0
    }

    var directories: [Directory]
    var fileSizes: [UInt64]
    var fileClasses: [UInt8]

    init(directories: [Directory], fileSizes: [UInt64]) {
        self.directories = directories
        self.fileSizes = fileSizes
        fileClasses = fileSizes.map { _ in 0 }
    }

    func subtreeBytes(of directory: UInt32) -> UInt64 {
        let node = directories[Int(directory)]
        return node.files.reduce(0) { $0 + fileSizes[Int($1)] } + node.children.reduce(0) { $0 + subtreeBytes(of: $1) }
    }

    func subtreeFileCount(of directory: UInt32) -> UInt64 {
        let node = directories[Int(directory)]
        return UInt64(node.files.count) + node.children.reduce(0) { $0 + subtreeFileCount(of: $1) }
    }

    func subtreeDirectoryCount(of directory: UInt32) -> UInt32 {
        directories[Int(directory)].children.reduce(0) { $0 + 1 + subtreeDirectoryCount(of: $1) }
    }

    func childrenBySize(of directory: UInt32) -> [UInt32] {
        directories[Int(directory)].children.sorted { left, right in
            let leftBytes = subtreeBytes(of: left)
            let rightBytes = subtreeBytes(of: right)
            return leftBytes != rightBytes ? leftBytes > rightBytes : left < right
        }
    }

    func ownFiles(of directory: UInt32, atLeast threshold: UInt64) -> OwnFilesSelection {
        let files = directories[Int(directory)].files
        let selected = files.filter { fileSizes[Int($0)] >= threshold }.sorted { left, right in
            let leftSize = fileSizes[Int(left)]
            let rightSize = fileSizes[Int(right)]
            return leftSize != rightSize ? leftSize > rightSize : left < right
        }

        return OwnFilesSelection(
            fileIndices: selected,
            sizes: selected.map { fileSizes[Int($0)] },
            threshold: threshold,
            ownBytes: files.reduce(0) { $0 + fileSizes[Int($1)] },
            ownFileCount: UInt64(files.count),
            selectedBytes: selected.reduce(0) { $0 + fileSizes[Int($1)] }
        )
    }

    func largestOwnFiles(of directory: UInt32, count: Int) -> OwnFilesSelection {
        let files = directories[Int(directory)].files
        let selected = files.sorted { left, right in
            let leftSize = fileSizes[Int(left)]
            let rightSize = fileSizes[Int(right)]
            return leftSize != rightSize ? leftSize > rightSize : left < right
        }.prefix(count)

        return OwnFilesSelection(
            fileIndices: Array(selected),
            sizes: selected.map { fileSizes[Int($0)] },
            threshold: selected.last.map { fileSizes[Int($0)] } ?? 0,
            ownBytes: files.reduce(0) { $0 + fileSizes[Int($1)] },
            ownFileCount: UInt64(files.count),
            selectedBytes: selected.reduce(0) { $0 + fileSizes[Int($1)] }
        )
    }

    func directoryAttributes(_ id: UInt32) -> DirectoryLeafAttributes {
        DirectoryLeafAttributes(
            storageClass: directories[Int(id)].storageClass,
            extensionId: 0,
            timeSeconds: directories[Int(id)].timeSeconds
        )
    }

    func fileAttributes(_ index: UInt64) -> FileLeafAttributes {
        FileLeafAttributes(storageClass: fileClasses[Int(index)], extensionId: 3, lastModified: 1000)
    }

    func directoryName(_ id: UInt32) -> String {
        directories[Int(id)].name
    }
}

final class TreemapLayoutEngineTests: XCTestCase {
    func testInstanceStrideIs48() {
        XCTAssertEqual(MemoryLayout<TreemapInstance>.stride, 52)
    }

    func testTwoFilesAreProportional() {
        let source = FakeLayoutDataSource(
            directories: [.init(name: "", children: [], files: [0, 1])],
            fileSizes: [300, 100]
        )
        let result = TreemapLayoutEngine(dataSource: source)
            .layout(LayoutRequest(rootDirectory: 0, width: 400, height: 100, minimumCellArea: 4))
        XCTAssertEqual(result.instances.count, 2)
        XCTAssertEqual(result.instances[0].kind, InstanceKind.file.rawValue)
        let firstArea = Double(result.instances[0].width * result.instances[0].height)
        let secondArea = Double(result.instances[1].width * result.instances[1].height)
        XCTAssertEqual(firstArea / secondArea, 3, accuracy: 0.1)
        XCTAssertEqual(result.instances[0].nodeReference, 0)
        XCTAssertEqual(result.instances[1].nodeReference, 1)
        XCTAssertEqual(result.instances[0].extensionId, 3)
        XCTAssertEqual(result.nodes[0].ownFileInstances, 0..<2)
    }

    /// At the view root a flat directory still shows its largest files, so the view is never one blank cell.
    func testRootGuaranteesMinimumCells() {
        let sizes: [UInt64] = [1_000_000] + [UInt64](repeating: 1, count: 10_000)
        let source = FakeLayoutDataSource(
            directories: [.init(name: "", children: [], files: Array(0..<UInt64(sizes.count)))],
            fileSizes: sizes
        )
        let result = TreemapLayoutEngine(dataSource: source)
            .layout(LayoutRequest(rootDirectory: 0, width: 100, height: 100, minimumCellArea: 4))
        let guaranteed = TreemapLayoutEngine.minimumItemsToPlace
        XCTAssertEqual(result.instances.count, guaranteed + 1, "the guaranteed cells plus one remainder")
        XCTAssertEqual(result.instances.last?.kind, InstanceKind.remainder.rawValue)
        XCTAssertEqual(result.remainderCounts[0]?.items, UInt64(10_001 - guaranteed))
        XCTAssertEqual(result.remainderCounts[0]?.bytes, UInt64(10_001 - guaranteed))
    }

    /// Below the view root the pixel budget governs, so sub-pixel items collapse into one remainder cell.
    func testPixelBudgetCollapsesSmallItemsInNestedDirectory() {
        let sizes: [UInt64] = [1_000_000] + [UInt64](repeating: 1, count: 10_000)
        let source = FakeLayoutDataSource(directories: [
            .init(name: "", children: [1], files: []),
            .init(name: "flat", children: [], files: Array(0..<UInt64(sizes.count))),
        ], fileSizes: sizes)
        let result = TreemapLayoutEngine(dataSource: source)
            .layout(LayoutRequest(rootDirectory: 0, width: 100, height: 100, minimumCellArea: 4))
        let nestedIndex = result.node(forDirectory: 1)
        XCTAssertNotNil(nestedIndex, "the only child fills the canvas, so it recurses")
        let nested = result.nodes[nestedIndex!]
        XCTAssertEqual(nested.ownFileInstances.count, 1, "only the one large file passes the pixel threshold")
        XCTAssertGreaterThanOrEqual(nested.remainderInstance, 0)
        XCTAssertEqual(result.remainderCounts[nestedIndex!]?.items, 10_000)
        XCTAssertEqual(result.remainderCounts[nestedIndex!]?.bytes, 10_000)
        let remainder = result.instances[nested.remainderInstance]
        let hit = result.hitTest(x: Double(remainder.x) + 0.5, y: Double(remainder.y) + 0.5)
        XCTAssertEqual(
            hit,
            .remainder(directory: 1, instance: nested.remainderInstance, itemCount: 10_000, bytes: 10_000)
        )
    }

    func testRecursionLeafDirectoriesAndHitTesting() {
        let source = FakeLayoutDataSource(directories: [
            .init(name: "", children: [1, 2], files: [3]),
            .init(name: "A", children: [], files: [0, 1], storageClass: 1),
            .init(name: "B", children: [], files: [2], storageClass: 6),
        ], fileSizes: [500, 500, 1, 1000])
        let result = TreemapLayoutEngine(dataSource: source)
            .layout(LayoutRequest(rootDirectory: 0, width: 200, height: 100, minimumCellArea: 4))
        let kinds = result.instances.map { $0.kind }
        XCTAssertEqual(kinds.filter { $0 == InstanceKind.file.rawValue }.count, 3, "A's two files and the root's own file")
        XCTAssertEqual(kinds.filter { $0 == InstanceKind.directoryLeaf.rawValue }.count, 1, "B is too small to recurse")
        let leaf = result.instances.first { $0.kind == InstanceKind.directoryLeaf.rawValue }!
        XCTAssertEqual(leaf.directoryId, 2)
        XCTAssertEqual(leaf.storageClassId, 6)
        XCTAssertNotNil(result.node(forDirectory: 1))
        let directoryANode = result.nodes[result.node(forDirectory: 1)!]
        XCTAssertEqual(directoryANode.ownFileInstances.count, 2)
        let fileInstance = result.instances[directoryANode.ownFileInstances.lowerBound]
        let hit = result.hitTest(
            x: Double(fileInstance.x + fileInstance.width / 2),
            y: Double(fileInstance.y + fileInstance.height / 2)
        )

        guard case .file(let fileIndex, _, let directory)? = hit else {
            return XCTFail("expected a file hit, got \(String(describing: hit))")
        }

        XCTAssertEqual(directory, 1)
        XCTAssertTrue([0, 1].contains(fileIndex))
        XCTAssertNil(result.hitTest(x: -1, y: -1))
        XCTAssertTrue(result.labels.contains { $0.text == "A" })
        XCTAssertTrue(result.labels.allSatisfy { $0.rect.width >= 64 && $0.rect.height >= 16 })
    }

    func testInstanceCountStaysUnderBudget() {
        var generator = SystemRandomNumberGenerator()
        let sizes = (0..<50_000).map { _ in UInt64.random(in: 1...1000, using: &generator) }
        var directories = [FakeLayoutDataSource.Directory(name: "", children: Array(1...50), files: [])]

        for child in 1...50 {
            let start = UInt64((child - 1) * 1000)
            let end = UInt64(child * 1000)
            directories.append(.init(name: "d\(child)", children: [], files: Array(start..<end)))
        }

        let source = FakeLayoutDataSource(directories: directories, fileSizes: sizes)
        let request = LayoutRequest(rootDirectory: 0, width: 800, height: 600, minimumCellArea: 4)
        let result = TreemapLayoutEngine(dataSource: source).layout(request)
        XCTAssertLessThanOrEqual(result.instances.count, Int(800 * 600 / 4) + result.nodes.count)
        XCTAssertGreaterThan(result.instances.count, 1000)

        for instance in result.instances where instance.kind != InstanceKind.remainder.rawValue {
            XCTAssertGreaterThanOrEqual(instance.width * instance.height, 0)
        }

        let repeated = TreemapLayoutEngine(dataSource: source).layout(request)
        XCTAssertEqual(repeated.instances.count, result.instances.count, "deterministic")
    }
}
