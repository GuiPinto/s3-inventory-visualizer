import XCTest
@testable import InventoryImport

final class GzipStreamsTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("gzip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func readAll(_ url: URL, chunk: Int) throws -> [UInt8] {
        let stream = try GzipInflateStream(url: url, bufferSize: 777)
        var result: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: chunk)

        while true {
            let produced = try buffer.withUnsafeMutableBufferPointer { try stream.read(into: $0) }

            if produced == 0 {
                break
            }

            result.append(contentsOf: buffer[0..<produced])
        }

        return result
    }

    func testRoundTripWithSmallReadBuffers() throws {
        let url = folder.appendingPathComponent("round.csv.gz")
        let text = (0..<50_000).map { "\"bucket\",\"key/\($0)/file.jpg\",\"\($0 * 13)\"\n" }.joined()
        let writer = try GzipDeflateWriter(url: url)
        try writer.write(text)
        try writer.finish()
        let bytes = try readAll(url, chunk: 1000)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), text)
    }

    func testInteroperatesWithSystemGzip() throws {
        let plain = folder.appendingPathComponent("plain.txt")
        try "hello gzip\nsecond line\n".write(to: plain, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-k", plain.path]
        try process.run()
        process.waitUntilExit()
        let bytes = try readAll(folder.appendingPathComponent("plain.txt.gz"), chunk: 4096)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "hello gzip\nsecond line\n")
    }

    func testTruncatedFileThrowsCorruptGzip() throws {
        let url = folder.appendingPathComponent("full.gz")
        let writer = try GzipDeflateWriter(url: url)
        try writer.write(String(repeating: "abcdefgh\n", count: 100_000))
        try writer.finish()
        let data = try Data(contentsOf: url)
        let truncated = folder.appendingPathComponent("truncated.gz")
        try data.prefix(data.count / 2).write(to: truncated)
        XCTAssertThrowsError(try readAll(truncated, chunk: 4096)) { error in
            guard case ImportError.corruptGzip = error else { return XCTFail("wrong error \(error)") }
        }
    }

    func testCompressedBytesReadTracksInput() throws {
        let url = folder.appendingPathComponent("count.gz")
        let writer = try GzipDeflateWriter(url: url)
        try writer.write(String(repeating: "x", count: 10_000))
        try writer.finish()
        let stream = try GzipInflateStream(url: url)
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while try buffer.withUnsafeMutableBufferPointer({ try stream.read(into: $0) }) > 0 {}
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int64
        XCTAssertEqual(stream.compressedBytesRead, size)
    }
}
