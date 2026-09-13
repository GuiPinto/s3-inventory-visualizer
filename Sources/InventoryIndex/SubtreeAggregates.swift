import Foundation

public struct ExtensionBreakdownEntry: Equatable {
    public var extensionId: UInt16
    public var bytes: UInt64
    public var files: UInt64
}

public struct ExtensionBreakdown: Equatable {
    public var entries: [ExtensionBreakdownEntry]
    public var otherBytes: UInt64
    public var otherFiles: UInt64
    public var totalBytes: UInt64
    public var totalFiles: UInt64
}

public struct AgeBreakdown: Equatable {
    public var bucketBytes: [UInt64]
    public var bucketFiles: [UInt64]
}

public final class SubtreeAggregates {
    private let reader: IndexReader
    private let lock = NSLock()
    private var extensionCache: [UInt32: ExtensionBreakdown] = [:]
    private var ageCache: [UInt32: AgeBreakdown] = [:]
    private let cacheCapacity: Int

    public init(reader: IndexReader, cacheCapacity: Int = 64) {
        self.reader = reader
        self.cacheCapacity = max(cacheCapacity, 1)
    }

    public static func ageBucket(ageDays: UInt64) -> Int {
        for (bucket, boundary) in IndexFormat.ageBucketDays.enumerated() where ageDays < UInt64(boundary) {
            return bucket
        }

        return IndexFormat.ageBucketDays.count
    }

    private func slices(for directory: UInt32) -> [Range<Int>] {
        let range = reader.directories.subtreeFileRange(directory)
        let count = Int(range.upperBound - range.lowerBound)

        guard count > 0 else { return [] }
        let workers = max(1, min(ProcessInfo.processInfo.activeProcessorCount, count / 65_536 + 1))
        let sliceLength = count / workers + 1
        return (0..<workers).compactMap { worker in
            let start = Int(range.lowerBound) + worker * sliceLength

            guard start < Int(range.upperBound) else { return nil }
            return start..<min(start + sliceLength, Int(range.upperBound))
        }
    }

    public func extensionBreakdown(of directory: UInt32, isCancelled: () -> Bool) -> ExtensionBreakdown? {
        lock.lock()

        if let cached = extensionCache[directory] {
            lock.unlock()
            return cached
        }

        lock.unlock()
        let slices = slices(for: directory)
        let slotCount = 65_536
        var partialBytes = [[UInt64]](repeating: [], count: slices.count)
        var partialFiles = [[UInt64]](repeating: [], count: slices.count)
        var cancelled = false
        let sizes = reader.fileSize.buffer
        let extensions = reader.fileExtension.buffer
        let resultLock = NSLock()

        if !slices.isEmpty {
            withoutActuallyEscaping(isCancelled) { isCancelled in
                DispatchQueue.concurrentPerform(iterations: slices.count) { sliceIndex in
                    var bytes = [UInt64](repeating: 0, count: slotCount)
                    var files = [UInt64](repeating: 0, count: slotCount)

                    for index in slices[sliceIndex] {
                        if index & 0xFFFFF == 0 && isCancelled() {
                            resultLock.lock()
                            cancelled = true
                            resultLock.unlock()
                            return
                        }

                        let slot = Int(extensions[index])
                        bytes[slot] &+= sizes[index]
                        files[slot] += 1
                    }

                    resultLock.lock()
                    partialBytes[sliceIndex] = bytes
                    partialFiles[sliceIndex] = files
                    resultLock.unlock()
                }
            }
        }

        if cancelled {
            return nil
        }

        var totalBytes = [UInt64](repeating: 0, count: slotCount)
        var totalFiles = [UInt64](repeating: 0, count: slotCount)

        for (bytes, files) in zip(partialBytes, partialFiles) where !bytes.isEmpty {
            for slot in 0..<slotCount where files[slot] > 0 {
                totalBytes[slot] &+= bytes[slot]
                totalFiles[slot] += files[slot]
            }
        }

        var entries: [ExtensionBreakdownEntry] = []
        var grandTotalBytes: UInt64 = 0
        var grandTotalFiles: UInt64 = 0

        for slot in 0..<slotCount where totalFiles[slot] > 0 {
            entries.append(ExtensionBreakdownEntry(extensionId: UInt16(slot), bytes: totalBytes[slot], files: totalFiles[slot]))
            grandTotalBytes &+= totalBytes[slot]
            grandTotalFiles += totalFiles[slot]
        }

        entries.sort { left, right in
            left.bytes != right.bytes ? left.bytes > right.bytes : left.extensionId < right.extensionId
        }

        let top = Array(entries.prefix(20))
        var otherBytes: UInt64 = 0
        var otherFiles: UInt64 = 0

        for entry in entries.dropFirst(20) {
            otherBytes &+= entry.bytes
            otherFiles += entry.files
        }

        let breakdown = ExtensionBreakdown(
            entries: top,
            otherBytes: otherBytes,
            otherFiles: otherFiles,
            totalBytes: grandTotalBytes,
            totalFiles: grandTotalFiles
        )
        store(&extensionCache, directory, breakdown)
        return breakdown
    }

    public func ageBreakdown(of directory: UInt32, isCancelled: () -> Bool) -> AgeBreakdown? {
        lock.lock()

        if let cached = ageCache[directory] {
            lock.unlock()
            return cached
        }

        lock.unlock()
        let slices = slices(for: directory)
        let bucketCount = IndexFormat.ageBucketDays.count + 1
        var partial = [(bytes: [UInt64], files: [UInt64])](repeating: ([], []), count: slices.count)
        var cancelled = false
        let sizes = reader.fileSize.buffer
        let modified = reader.fileLastModified.buffer
        let inventoryTimestamp = reader.manifest.inventoryTimestamp
        let resultLock = NSLock()

        if !slices.isEmpty {
            withoutActuallyEscaping(isCancelled) { isCancelled in
                DispatchQueue.concurrentPerform(iterations: slices.count) { sliceIndex in
                    var bytes = [UInt64](repeating: 0, count: bucketCount)
                    var files = [UInt64](repeating: 0, count: bucketCount)

                    for index in slices[sliceIndex] {
                        if index & 0xFFFFF == 0 && isCancelled() {
                            resultLock.lock()
                            cancelled = true
                            resultLock.unlock()
                            return
                        }

                        let time = modified[index]
                        let ageDays: UInt64 = (time == 0 || time >= inventoryTimestamp)
                            ? 0 : UInt64(inventoryTimestamp - time) / 86_400
                        let bucket = SubtreeAggregates.ageBucket(ageDays: ageDays)
                        bytes[bucket] &+= sizes[index]
                        files[bucket] += 1
                    }

                    resultLock.lock()
                    partial[sliceIndex] = (bytes, files)
                    resultLock.unlock()
                }
            }
        }

        if cancelled {
            return nil
        }

        var breakdown = AgeBreakdown(
            bucketBytes: [UInt64](repeating: 0, count: bucketCount),
            bucketFiles: [UInt64](repeating: 0, count: bucketCount)
        )

        for part in partial where !part.bytes.isEmpty {
            for bucket in 0..<bucketCount {
                breakdown.bucketBytes[bucket] &+= part.bytes[bucket]
                breakdown.bucketFiles[bucket] += part.files[bucket]
            }
        }

        store(&ageCache, directory, breakdown)
        return breakdown
    }

    private func store<Value>(_ cache: inout [UInt32: Value], _ directory: UInt32, _ value: Value) {
        lock.lock()

        if cache.count >= cacheCapacity, let victim = cache.keys.first {
            cache.removeValue(forKey: victim)
        }

        cache[directory] = value
        lock.unlock()
    }
}
