import Foundation

/// Producers push chunks in any order; the consumer receives them in (fileIndex, chunkIndex) order.
/// A producer blocks while `maximumRowsInFlight` is exceeded, unless its chunk belongs to the file the consumer needs next.
public final class OrderedChunkQueue {
    private let condition = NSCondition()
    private var pending: [Int: [Int: RowChunk]] = [:]
    private var completedFiles = Set<Int>()
    private var nextFileIndex = 0
    private var nextChunkIndex = 0
    private var rowsInFlight = 0
    private var cancelled = false
    private let fileCount: Int
    private let maximumRowsInFlight: Int
    private var deliveredFiles = 0

    public var completedFilesDelivered: Int {
        condition.lock()
        defer { condition.unlock() }
        return deliveredFiles
    }

    public init(fileCount: Int, maximumRowsInFlight: Int) {
        self.fileCount = fileCount
        self.maximumRowsInFlight = max(maximumRowsInFlight, 1)
    }

    public func enqueue(_ chunk: RowChunk) throws {
        condition.lock()
        defer { condition.unlock() }

        while !cancelled && rowsInFlight >= maximumRowsInFlight && chunk.fileIndex != nextFileIndex {
            condition.wait()
        }

        if cancelled {
            throw ImportError.cancelled
        }

        pending[chunk.fileIndex, default: [:]][chunk.chunkIndex] = chunk
        rowsInFlight += chunk.count
        condition.broadcast()
    }

    public func markFileComplete(_ fileIndex: Int) {
        condition.lock()
        completedFiles.insert(fileIndex)
        condition.broadcast()
        condition.unlock()
    }

    public func dequeueNext() throws -> RowChunk? {
        condition.lock()
        defer { condition.unlock() }

        while true {
            if cancelled {
                throw ImportError.cancelled
            }

            if nextFileIndex >= fileCount {
                return nil
            }

            if let chunk = pending[nextFileIndex]?.removeValue(forKey: nextChunkIndex) {
                rowsInFlight -= chunk.count
                nextChunkIndex += 1
                condition.broadcast()
                return chunk
            }

            if completedFiles.contains(nextFileIndex) && (pending[nextFileIndex]?.isEmpty ?? true) {
                pending[nextFileIndex] = nil
                nextFileIndex += 1
                nextChunkIndex = 0
                deliveredFiles += 1
                condition.broadcast()
                continue
            }

            condition.wait()
        }
    }

    public func cancel() {
        condition.lock()
        cancelled = true
        condition.broadcast()
        condition.unlock()
    }
}
