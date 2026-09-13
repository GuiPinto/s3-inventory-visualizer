import XCTest
import TestSupport
import InventoryImport
@testable import InventoryIndex

final class KeySearchTests: XCTestCase {
    private var folder: URL!
    private var reader: IndexReader!
    private let rows: [FixtureRow] = [
        FixtureRow(key: "assets/acc1/2025/photo-1.jpg", size: 1),
        FixtureRow(key: "assets/acc1/2025/photo-2.jpg", size: 2),
        FixtureRow(key: "assets/acc1/2026/photo-3.jpg", size: 3),
        FixtureRow(key: "assets/acc2/2025/video.mp4", size: 4),
        FixtureRow(key: "assets/accident.txt", size: 5),
        FixtureRow(key: "queue/a/b", size: 6),
        FixtureRow(key: "photo-root.jpg", size: 7),
        FixtureRow(key: "assets/acc1/2025/", size: 0),
    ]

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("search-\(UUID().uuidString)")
        try FixtureInventory.write(rows: rows, to: folder, fileCount: 2)
        let source = try InventorySource.load(folder: folder)
        _ = try ImportPipeline(source: source, outputFolder: IndexReader.indexFolder(forInventory: folder), progress: { _ in }).run()
        reader = try IndexReader(folder: IndexReader.indexFolder(forInventory: folder))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testStartsWith() {
        let search = KeySearch(reader: reader)
        XCTAssertEqual(
            search.startsWith("assets/acc").map { $0.key }.sorted(),
            ["assets/acc1/", "assets/acc2/", "assets/accident.txt"]
        )
        XCTAssertEqual(
            search.startsWith("assets/acc1/2025/photo").map { $0.key }.sorted(),
            ["assets/acc1/2025/photo-1.jpg", "assets/acc1/2025/photo-2.jpg"]
        )
        XCTAssertEqual(
            search.startsWith("assets/acc1/2025/").map { $0.key }.sorted(),
            ["assets/acc1/2025/", "assets/acc1/2025/photo-1.jpg", "assets/acc1/2025/photo-2.jpg"]
        )
        XCTAssertEqual(search.startsWith("photo").map { $0.key }, ["photo-root.jpg"])
        XCTAssertEqual(search.startsWith("nope/x"), [])
        XCTAssertEqual(search.startsWith("").map { $0.key }.sorted(), ["assets/", "photo-root.jpg", "queue/"])
        XCTAssertEqual(search.startsWith("assets/acc", limit: 1).count, 1)
        let hit = search.startsWith("assets/acc2/2025/video.mp4")[0]
        XCTAssertEqual(hit.fileIndex.map { reader.key(ofFile: $0) }, "assets/acc2/2025/video.mp4")
        XCTAssertEqual(hit.directoryId, reader.directories.lookup(path: "assets/acc2/2025"))
    }

    func testContains() {
        let search = KeySearch(reader: reader)
        var progressValues: [Double] = []
        let hits = search.contains("photo", progress: { progressValues.append($0) }, isCancelled: { false })!
        XCTAssertEqual(
            hits.map { $0.key }.sorted(),
            [
                "assets/acc1/2025/photo-1.jpg",
                "assets/acc1/2025/photo-2.jpg",
                "assets/acc1/2026/photo-3.jpg",
                "photo-root.jpg"
            ]
        )
        XCTAssertEqual(
            search.contains("acc1", progress: { _ in }, isCancelled: { false })!.map { $0.key }.sorted(),
            ["assets/acc1/"]
        )
        XCTAssertEqual(search.contains("2025", limit: 2, progress: { _ in }, isCancelled: { false })!.count, 2)
        XCTAssertEqual(progressValues.last, 1.0)
    }
}
