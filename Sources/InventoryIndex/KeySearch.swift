import Foundation

public struct SearchHit: Equatable {
    public var fileIndex: UInt64?
    public var directoryId: UInt32
    public var key: String

    public init(fileIndex: UInt64?, directoryId: UInt32, key: String) {
        self.fileIndex = fileIndex
        self.directoryId = directoryId
        self.key = key
    }
}

public final class KeySearch {
    private let reader: IndexReader

    public init(reader: IndexReader) { self.reader = reader }

    /// Walks the tree to the directory named before the last "/", then scans its children and own files.
    /// Decoded keys are not in strict byte order, so a binary search over them is not valid.
    public func startsWith(_ query: String, limit: Int = 10_000) -> [SearchHit] {
        let tree = reader.directories
        let lastSlash = query.lastIndex(of: "/")
        let directoryPath = lastSlash.map { String(query[..<$0]) } ?? ""
        let nameText = lastSlash.map { String(query[query.index(after: $0)...]) } ?? query
        let namePrefix = Array(nameText.utf8)

        guard let directory = tree.lookup(path: directoryPath) else { return [] }
        var hits: [SearchHit] = []
        let prefixPath = directory == IndexFormat.rootDirectory ? "" : tree.path(directory) + "/"

        for child in tree.childrenInKeyOrder(directory) where hits.count < limit {
            let matches = tree.withNameBytes(child) { bytes -> Bool in
                guard bytes.count >= namePrefix.count else { return false }
                return namePrefix.withUnsafeBufferPointer { prefix in
                    prefix.count == 0 || memcmp(bytes.baseAddress!, prefix.baseAddress!, prefix.count) == 0
                }
            }

            if matches {
                hits.append(SearchHit(fileIndex: nil, directoryId: child, key: prefixPath + tree.name(child) + "/"))
            }
        }

        for range in tree.ownFileRanges(directory) {
            var index = range.lowerBound

            while index < range.upperBound && hits.count < limit {
                let matches = reader.names.withName(ofFile: index) { bytes -> Bool in
                    guard bytes.count >= namePrefix.count else { return false }
                    return namePrefix.withUnsafeBufferPointer { prefix in
                        prefix.count == 0 || memcmp(bytes.baseAddress!, prefix.baseAddress!, prefix.count) == 0
                    }
                }

                if matches {
                    hits.append(SearchHit(
                        fileIndex: index,
                        directoryId: directory,
                        key: prefixPath + reader.names.nameString(ofFile: index)
                    ))
                }

                index += 1
            }
        }

        return hits
    }

    /// Parallel scan over every name block and every directory name. Returns nil when cancelled.
    public func contains(
        _ needle: String,
        limit: Int = 10_000,
        progress: @escaping (Double) -> Void,
        isCancelled: @escaping () -> Bool
    ) -> [SearchHit]? {
        let needleBytes = Array(needle.utf8)

        guard !needleBytes.isEmpty else { return [] }
        let tree = reader.directories
        let blockCount = reader.names.blockCount
        let workerCount = max(1, min(ProcessInfo.processInfo.activeProcessorCount, max(blockCount, 1)))
        let lock = NSLock()
        var fileHits: [UInt64] = []
        var blocksDone = 0
        var cancelled = false

        func matches(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
            guard bytes.count >= needleBytes.count, let base = bytes.baseAddress else { return false }
            return needleBytes.withUnsafeBufferPointer { needle in
                memmem(base, bytes.count, needle.baseAddress!, needle.count) != nil
            }
        }

        if blockCount > 0 {
            DispatchQueue.concurrentPerform(iterations: workerCount) { worker in
                var local: [UInt64] = []
                var block = worker

                while block < blockCount {
                    if isCancelled() {
                        lock.lock()
                        cancelled = true
                        lock.unlock()
                        return
                    }

                    lock.lock()
                    let enough = fileHits.count + local.count >= limit
                    lock.unlock()

                    if enough {
                        break
                    }

                    let decoded = reader.names.decodeBlockUncached(block)

                    for position in 0..<decoded.nameCount where decoded.withName(at: position, matches) {
                        local.append(UInt64(block * IndexFormat.namesPerBlock + position))
                    }

                    lock.lock()
                    blocksDone += 1
                    let fraction = Double(blocksDone) / Double(blockCount)
                    lock.unlock()

                    if block % 64 == 0 {
                        progress(fraction * 0.9)
                    }

                    block += workerCount
                }

                lock.lock()
                fileHits.append(contentsOf: local)
                lock.unlock()
            }
        }

        if cancelled {
            return nil
        }

        var hits: [SearchHit] = []

        if tree.count > 1 {
            for directory in 1..<UInt32(tree.count) where hits.count < limit {
                if isCancelled() {
                    return nil
                }

                if tree.withNameBytes(directory, matches) {
                    hits.append(SearchHit(fileIndex: nil, directoryId: directory, key: tree.path(directory) + "/"))
                }
            }
        }

        for fileIndex in fileHits.sorted().prefix(max(0, limit - hits.count)) {
            hits.append(SearchHit(
                fileIndex: fileIndex,
                directoryId: reader.directory(ofFile: fileIndex),
                key: reader.key(ofFile: fileIndex)
            ))
        }

        progress(1.0)
        return hits
    }
}
