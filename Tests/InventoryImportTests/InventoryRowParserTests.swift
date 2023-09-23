import XCTest
import TestSupport
@testable import InventoryImport

final class InventoryRowParserTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("parser-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func parse(
        _ csv: String,
        schema: InventorySchema = .standard,
        rowsPerChunk: Int = 262_144,
        readBufferSize: Int = 4 << 20
    ) throws -> [RowChunk] {
        let url = folder.appendingPathComponent("\(UUID().uuidString).csv.gz")
        let writer = try GzipDeflateWriter(url: url)
        try writer.write(csv)
        try writer.finish()
        let parser = InventoryRowParser(schema: schema, rowsPerChunk: rowsPerChunk, readBufferSize: readBufferSize)
        var chunks: [RowChunk] = []
        try parser.parse(stream: try GzipInflateStream(url: url), fileIndex: 7) { chunks.append($0) }
        return chunks
    }

    private func key(_ chunk: RowChunk, _ row: Int) -> String {
        chunk.withKey(row) { String(decoding: $0, as: UTF8.self) }
    }

    func testParsesFieldsSkipsAndFlags() throws {
        let csv = """
        "b","snapshots/1/a.jpg","v","true","false","23115","2026-02-16T12:16:56.000Z","e","STANDARD","false","",""
        "b","old/version.jpg","v","false","false","10","2026-02-16T12:16:56.000Z","e","STANDARD","false","",""
        "b","deleted.jpg","v","true","true","","2026-02-16T12:16:56.000Z","e","","false","",""
        "b","dir%20one/f%25.jpg","v","true","false","0","2025-01-01T00:00:00.000Z","e","DEEP_ARCHIVE","false","",""
        "b","weird ""quoted"" key","v","true","false","5","2025-01-01T00:00:00.000Z","e","GLACIER_IR","false","",""
        "b","bad-size","v","true","false","abc","2025-01-01T00:00:00.000Z","e","STANDARD","false","",""

        """
        let chunks = try parse(csv)
        XCTAssertEqual(chunks.count, 1)
        let chunk = chunks[0]
        XCTAssertEqual(chunk.fileIndex, 7)
        XCTAssertEqual(chunk.count, 3)
        XCTAssertEqual(chunk.skippedNonCurrent, 1)
        XCTAssertEqual(chunk.skippedDeleteMarkers, 1)
        XCTAssertEqual(chunk.parseErrors, 1)
        XCTAssertEqual(key(chunk, 0), "snapshots/1/a.jpg")
        XCTAssertEqual(chunk.sizes[0], 23115)
        XCTAssertEqual(chunk.storageClass[0], 0)
        XCTAssertEqual(chunk.lastModified[0], 1_771_244_216)
        XCTAssertFalse(chunk.needsDecoding[0])
        XCTAssertEqual(key(chunk, 1), "dir%20one/f%25.jpg")
        XCTAssertTrue(chunk.needsDecoding[1])
        XCTAssertEqual(chunk.storageClass[1], 6)
        XCTAssertEqual(key(chunk, 2), "weird \"quoted\" key")
        XCTAssertEqual(chunk.storageClass[2], 4)
    }

    func testReducedSchemaAndCRLF() throws {
        let schema = try InventorySchema(fileSchema: "Bucket, Key, Size")
        let chunks = try parse("\"b\",\"a\",\"1\"\r\n\"b\",\"c\",\"2\"\r\n", schema: schema)
        XCTAssertEqual(chunks[0].count, 2)
        XCTAssertEqual(chunks[0].lastModified, [0, 0])
        XCTAssertEqual(chunks[0].storageClass, [7, 7])
        XCTAssertEqual(key(chunks[0], 1), "c")
    }

    func testChunkAndReadBufferBoundaries() throws {
        let rows = (0..<1000).map {
            "\"b\",\"key/\(String(format: "%05d", $0))/name.jpg\",\"v\",\"true\",\"false\",\"\($0)\",\"2026-01-01T00:00:00.000Z\",\"e\",\"STANDARD_IA\",\"false\",\"\",\"\"\n"
        }

        let chunks = try parse(rows.joined(), rowsPerChunk: 300, readBufferSize: 100)
        XCTAssertEqual(chunks.map { $0.count }, [300, 300, 300, 100])
        XCTAssertEqual(chunks.map { $0.chunkIndex }, [0, 1, 2, 3])
        XCTAssertEqual(key(chunks[3], 99), "key/00999/name.jpg")
        XCTAssertEqual(chunks[3].sizes[99], 999)
        XCTAssertGreaterThan(chunks.reduce(0) { $0 + $1.compressedBytesDelta }, 0)
    }

    func testEmptyFileEmitsOneEmptyChunk() throws {
        let chunks = try parse("")
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].count, 0)
    }

    func testFastDateParserMatchesFoundation() throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let samples = [
            "2000-02-29T23:59:59.000Z",
            "2024-02-29T00:00:00.000Z",
            "1999-12-31T23:59:59.000Z",
            "2026-09-12T03:40:00.000Z",
            "1970-01-01T00:00:00.000Z",
            "2100-03-01T12:00:00.000Z"
        ]

        for sample in samples {
            let expected = UInt32(formatter.date(from: sample)!.timeIntervalSince1970)
            let parsed = Array(sample.utf8).withUnsafeBufferPointer { InventoryRowParser.parseISO8601Seconds($0) }
            XCTAssertEqual(parsed, expected, sample)
        }

        XCTAssertNil(Array("not a date".utf8).withUnsafeBufferPointer { InventoryRowParser.parseISO8601Seconds($0) })
        XCTAssertEqual(InventoryRowParser.daysFromCivil(year: 1970, month: 1, day: 1), 0)
        XCTAssertEqual(InventoryRowParser.daysFromCivil(year: 2000, month: 3, day: 1), 11_017)
    }

    func testExtractFieldHelper() {
        let row = Array("\"b\",\"a,b\",\"3\"".utf8)
        XCTAssertEqual(InventoryRowParser.extractField(row: row, column: 1).map { String(decoding: $0, as: UTF8.self) }, "a,b")
        XCTAssertEqual(InventoryRowParser.extractField(row: row, column: 2).map { String(decoding: $0, as: UTF8.self) }, "3")
        XCTAssertNil(InventoryRowParser.extractField(row: row, column: 3))
    }
}
