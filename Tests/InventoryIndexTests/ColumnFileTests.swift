import XCTest
@testable import InventoryIndex

final class ColumnFileTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("column-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testSequentialWriteThenMappedRead() throws {
        let url = folder.appendingPathComponent("values.u64")
        let writer = try ColumnWriter<UInt64>(url: url, bufferSize: 100)

        for value in 0..<1000 {
            writer.append(UInt64(value) * 7)
        }

        try writer.finish()
        let column = try MappedColumn<UInt64>(url: url)
        XCTAssertEqual(column.count, 1000)
        XCTAssertEqual(column[0], 0)
        XCTAssertEqual(column[999], 999 * 7)
        XCTAssertEqual(Array(column.buffer[10..<13]), [70, 77, 84])
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int
        XCTAssertEqual(size, IndexFormat.columnHeaderSize + 1000 * 8)
    }

    func testByteColumnAppendBytes() throws {
        let url = folder.appendingPathComponent("names.bytes")
        let writer = try ColumnWriter<UInt8>(url: url)
        let text = Array("hello, world".utf8)
        text.withUnsafeBytes { writer.appendBytes($0) }
        try writer.finish()
        let column = try MappedColumn<UInt8>(url: url)
        XCTAssertEqual(String(decoding: column.buffer, as: UTF8.self), "hello, world")
    }

    func testSparseColumnTruncatesToCount() throws {
        let url = folder.appendingPathComponent("sparse.u32")
        let sparse = try SparseMappedColumn<UInt32>(url: url, capacity: 1_000_000)
        sparse[0] = 1
        sparse[5] = 55
        sparse[999] = 9999
        try sparse.finish(count: 1000)
        let column = try MappedColumn<UInt32>(url: url)
        XCTAssertEqual(column.count, 1000)
        XCTAssertEqual(column[5], 55)
        XCTAssertEqual(column[999], 9999)
        XCTAssertEqual(column[1], 0)
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int
        XCTAssertEqual(size, IndexFormat.columnHeaderSize + 1000 * 4)
    }

    func testElementSizeMismatchIsDetected() throws {
        let url = folder.appendingPathComponent("values.u32")
        let writer = try ColumnWriter<UInt32>(url: url)
        writer.append(1)
        try writer.finish()
        XCTAssertThrowsError(try MappedColumn<UInt64>(url: url)) { error in
            guard case IndexError.elementSizeMismatch = error else { return XCTFail("wrong error \(error)") }
        }
    }

    func testBadMagicIsDetected() throws {
        let url = folder.appendingPathComponent("garbage.u8")
        try Data(repeating: 0x41, count: 128).write(to: url)
        XCTAssertThrowsError(try MappedColumn<UInt8>(url: url)) { error in
            guard case IndexError.badColumnHeader = error else { return XCTFail("wrong error \(error)") }
        }
    }

    func testStructElements() throws {
        struct Pair { var left: UInt64; var right: UInt32; var padding: UInt32 }
        let url = folder.appendingPathComponent("pairs.bin")
        let writer = try ColumnWriter<Pair>(url: url)
        writer.append(Pair(left: 1, right: 2, padding: 0))
        writer.append(Pair(left: 3, right: 4, padding: 0))
        try writer.finish()
        let column = try MappedColumn<Pair>(url: url)
        XCTAssertEqual(column.count, 2)
        XCTAssertEqual(column[1].left, 3)
        XCTAssertEqual(column[1].right, 4)
    }
}
