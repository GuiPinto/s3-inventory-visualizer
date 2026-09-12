import XCTest
@testable import InventoryIndex

final class NameBlockTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("names-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func rawBlock(_ names: [String]) -> [UInt8] {
        var raw: [UInt8] = []

        for name in names {
            Array(name.utf8).withUnsafeBufferPointer { NameBlockCodec.appendName($0, to: &raw) }
        }

        return raw
    }

    func testEncodeDecodeRoundTripWithAwkwardNames() throws {
        let names = ["", "photo.jpg", String(repeating: "x", count: 1024), "ünïcödé ✓.mp4", "a\nb"]
        let raw = rawBlock(names)
        let compressed = NameBlockCodec.encode(raw: raw)
        let decoded = compressed.withUnsafeBytes { NameBlockCodec.decode(compressed: $0, rawLength: raw.count) }
        XCTAssertEqual(decoded, raw)
        let block = DecodedNameBlock(raw: raw)
        XCTAssertEqual(block.nameCount, 5)
        XCTAssertEqual(block.name(at: 0), [])
        XCTAssertEqual(String(decoding: block.name(at: 3), as: UTF8.self), "ünïcödé ✓.mp4")
        XCTAssertEqual(block.name(at: 2).count, 1024)
    }

    func testIncompressibleBlockStillRoundTrips() throws {
        var generator = SystemRandomNumberGenerator()
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        let names = (0..<100).map { _ in String((0..<40).map { _ in alphabet.randomElement(using: &generator)! }) }
        let raw = rawBlock(names)
        let compressed = NameBlockCodec.encode(raw: raw)
        let decoded = compressed.withUnsafeBytes { NameBlockCodec.decode(compressed: $0, rawLength: raw.count) }
        XCTAssertEqual(decoded, raw)
    }

    func testCacheResolvesFilesAcrossBlockBoundaries() throws {
        let allNames = (0..<(IndexFormat.namesPerBlock + 5)).map { "file-\($0).dat" }
        let blocksWriter = try ColumnWriter<NameBlockEntry>(url: folder.appendingPathComponent(IndexFiles.fileNameBlocks))
        let dataWriter = try ColumnWriter<UInt8>(url: folder.appendingPathComponent(IndexFiles.fileNameData))

        for start in stride(from: 0, to: allNames.count, by: IndexFormat.namesPerBlock) {
            let slice = Array(allNames[start..<min(start + IndexFormat.namesPerBlock, allNames.count)])
            let raw = rawBlock(slice)
            let compressed = NameBlockCodec.encode(raw: raw)
            blocksWriter.append(NameBlockEntry(
                offset: UInt64(dataWriter.count),
                compressedLength: UInt32(compressed.count),
                rawLength: UInt32(raw.count)
            ))
            compressed.withUnsafeBytes { dataWriter.appendBytes($0) }
        }

        try blocksWriter.finish()
        try dataWriter.finish()
        let cache = NameBlockCache(
            blocks: try MappedColumn(url: folder.appendingPathComponent(IndexFiles.fileNameBlocks)),
            data: try MappedColumn(url: folder.appendingPathComponent(IndexFiles.fileNameData)),
            capacity: 1
        )
        XCTAssertEqual(cache.blockCount, 2)
        XCTAssertEqual(cache.nameString(ofFile: 0), "file-0.dat")
        XCTAssertEqual(cache.nameString(ofFile: 4095), "file-4095.dat")
        XCTAssertEqual(cache.nameString(ofFile: 4096), "file-4096.dat")
        XCTAssertEqual(cache.nameString(ofFile: 4100), "file-4100.dat")
        XCTAssertEqual(cache.nameString(ofFile: 1), "file-1.dat")
        XCTAssertEqual(cache.cachedBlockCount, 1)
    }

    func testStrideOfEntryIsSixteen() {
        XCTAssertEqual(MemoryLayout<NameBlockEntry>.stride, 16)
    }
}
