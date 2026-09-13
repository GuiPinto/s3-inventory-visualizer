import XCTest
@testable import InventoryImport

final class OrderedChunkQueueTests: XCTestCase {
    private func chunk(_ file: Int, _ index: Int, rows: Int) -> RowChunk {
        var chunk = RowChunk(fileIndex: file, chunkIndex: index, capacity: rows)

        for row in 0..<rows {
            Array("f\(file)/c\(index)/r\(row)".utf8).withUnsafeBufferPointer {
                chunk.appendRow(key: $0, size: 1, lastModified: 0, storageClass: 0)
            }
        }

        return chunk
    }

    func testDeliversInFileAndChunkOrderUnderBackpressure() throws {
        let queue = OrderedChunkQueue(fileCount: 3, maximumRowsInFlight: 5)
        let group = DispatchGroup()

        for file in [2, 0, 1] {
            DispatchQueue.global().async(group: group) {
                for index in 0..<4 {
                    try? queue.enqueue(self.chunk(file, index, rows: 3))
                }

                queue.markFileComplete(file)
            }
        }

        var delivered: [(Int, Int)] = []

        while let next = try queue.dequeueNext() {
            delivered.append((next.fileIndex, next.chunkIndex))
        }

        group.wait()
        XCTAssertEqual(delivered.map { $0.0 }, [0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2])
        XCTAssertEqual(delivered.map { $0.1 }, [0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3])
        XCTAssertEqual(queue.completedFilesDelivered, 3)
    }

    func testCancelWakesConsumer() throws {
        let queue = OrderedChunkQueue(fileCount: 1, maximumRowsInFlight: 10)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { queue.cancel() }
        XCTAssertThrowsError(try queue.dequeueNext()) { error in
            guard case ImportError.cancelled = error else { return XCTFail("wrong error \(error)") }
        }
    }
}
