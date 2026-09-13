import Foundation

public struct OwnFilesSelection: Equatable {
    public var fileIndices: [UInt64]
    public var sizes: [UInt64]
    public var threshold: UInt64
    public var ownBytes: UInt64
    public var ownFileCount: UInt64
    public var selectedBytes: UInt64

    public init(
        fileIndices: [UInt64],
        sizes: [UInt64],
        threshold: UInt64,
        ownBytes: UInt64,
        ownFileCount: UInt64,
        selectedBytes: UInt64
    ) {
        self.fileIndices = fileIndices
        self.sizes = sizes
        self.threshold = threshold
        self.ownBytes = ownBytes
        self.ownFileCount = ownFileCount
        self.selectedBytes = selectedBytes
    }

    /// Sizes are descending, so the kept prefix ends at the first entry below the new threshold.
    public func narrowed(to newThreshold: UInt64) -> OwnFilesSelection {
        guard newThreshold > threshold else { return self }
        var low = 0
        var end = sizes.count

        while low < end {
            let middle = (low + end) / 2

            if sizes[middle] >= newThreshold {
                low = middle + 1
            } else {
                end = middle
            }
        }

        let keptSizes = Array(sizes[0..<low])
        return OwnFilesSelection(
            fileIndices: Array(fileIndices[0..<low]),
            sizes: keptSizes,
            threshold: newThreshold,
            ownBytes: ownBytes,
            ownFileCount: ownFileCount,
            selectedBytes: keptSizes.reduce(0, +)
        )
    }
}

public final class OwnFilesCache {
    private let reader: IndexReader
    private let capacity: Int
    private let lock = NSLock()
    private var entries: [UInt32: (selection: OwnFilesSelection, lastUse: UInt64)] = [:]
    private var useCounter: UInt64 = 0

    public init(reader: IndexReader, capacity: Int = 256) {
        self.reader = reader
        self.capacity = max(1, capacity)
    }

    public func ownFiles(of directory: UInt32, atLeast threshold: UInt64) -> OwnFilesSelection {
        // Every own file is at most the directory's whole own-file total, so when that total is already
        // below the threshold no file can pass it. The totals are stored in the index, which turns the
        // common deep-tree case from a scan of every own file into two column reads.
        let ownBytes = reader.directories.ownBytes(directory)

        if ownBytes < threshold {
            return OwnFilesSelection(
                fileIndices: [],
                sizes: [],
                threshold: threshold,
                ownBytes: ownBytes,
                ownFileCount: UInt64(reader.directories.ownFileCount(directory)),
                selectedBytes: 0
            )
        }

        lock.lock()
        useCounter += 1

        if let cached = entries[directory], cached.selection.threshold <= threshold {
            entries[directory] = (cached.selection, useCounter)
            lock.unlock()
            return cached.selection.narrowed(to: threshold)
        }

        lock.unlock()
        let computed = compute(directory: directory, threshold: threshold)
        lock.lock()

        if entries[directory] == nil, entries.count >= capacity,
           let victim = entries.min(by: { $0.value.lastUse < $1.value.lastUse }) {
            entries.removeValue(forKey: victim.key)
        }

        entries[directory] = (computed, useCounter)
        lock.unlock()
        return computed
    }

    private func compute(directory: UInt32, threshold: UInt64) -> OwnFilesSelection {
        let sizes = reader.fileSize.buffer
        var selected: [(size: UInt64, index: UInt64)] = []
        var ownBytes: UInt64 = 0
        var ownFileCount: UInt64 = 0

        for range in reader.directories.ownFileRanges(directory) {
            ownFileCount += range.upperBound - range.lowerBound
            var index = Int(range.lowerBound)
            let end = Int(range.upperBound)

            while index < end {
                let size = sizes[index]
                ownBytes &+= size

                if size >= threshold {
                    selected.append((size, UInt64(index)))
                }

                index += 1
            }
        }

        selected.sort { $0.size != $1.size ? $0.size > $1.size : $0.index < $1.index }
        var selectedBytes: UInt64 = 0

        for entry in selected {
            selectedBytes &+= entry.size
        }

        return OwnFilesSelection(
            fileIndices: selected.map { $0.index },
            sizes: selected.map { $0.size },
            threshold: threshold,
            ownBytes: ownBytes,
            ownFileCount: ownFileCount,
            selectedBytes: selectedBytes
        )
    }

    /// Bounded min-heap selection over the directory's own files.
    public func largestOwnFiles(of directory: UInt32, count: Int) -> OwnFilesSelection {
        let sizes = reader.fileSize.buffer
        var heap: [(size: UInt64, index: UInt64)] = []
        heap.reserveCapacity(max(count, 1) + 1)

        func precedes(_ left: (size: UInt64, index: UInt64), _ right: (size: UInt64, index: UInt64)) -> Bool {
            left.size != right.size ? left.size < right.size : left.index > right.index
        }

        func siftUp(_ start: Int) {
            var child = start

            while child > 0 {
                let parent = (child - 1) / 2

                if precedes(heap[child], heap[parent]) {
                    heap.swapAt(child, parent)
                    child = parent
                } else {
                    break
                }
            }
        }

        func siftDown(_ start: Int) {
            var parent = start

            while true {
                let left = 2 * parent + 1
                let right = left + 1
                var smallest = parent

                if left < heap.count && precedes(heap[left], heap[smallest]) {
                    smallest = left
                }

                if right < heap.count && precedes(heap[right], heap[smallest]) {
                    smallest = right
                }

                if smallest == parent {
                    break
                }

                heap.swapAt(parent, smallest)
                parent = smallest
            }
        }

        var ownBytes: UInt64 = 0
        var ownFileCount: UInt64 = 0

        for range in reader.directories.ownFileRanges(directory) {
            ownFileCount += range.upperBound - range.lowerBound

            for index in Int(range.lowerBound)..<Int(range.upperBound) {
                let candidate = (size: sizes[index], index: UInt64(index))
                ownBytes &+= candidate.size

                if heap.count < count {
                    heap.append(candidate)
                    siftUp(heap.count - 1)
                } else if count > 0 && precedes(heap[0], candidate) {
                    heap[0] = candidate
                    siftDown(0)
                }
            }
        }

        heap.sort { $0.size != $1.size ? $0.size > $1.size : $0.index < $1.index }
        return OwnFilesSelection(
            fileIndices: heap.map { $0.index },
            sizes: heap.map { $0.size },
            threshold: heap.last?.size ?? 0,
            ownBytes: ownBytes,
            ownFileCount: ownFileCount,
            selectedBytes: heap.reduce(0) { $0 &+ $1.size }
        )
    }
}
