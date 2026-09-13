import Foundation
import InventoryIndex

public protocol RawNameBlockConsumer: AnyObject {
    func consume(rawBlock: [UInt8], nameCount: Int) throws

    func finish() throws
}

public final class SynchronousNameBlockWriter: RawNameBlockConsumer {
    private let blocks: ColumnWriter<NameBlockEntry>
    private let data: ColumnWriter<UInt8>

    public init(blocks: ColumnWriter<NameBlockEntry>, data: ColumnWriter<UInt8>) {
        self.blocks = blocks
        self.data = data
    }

    public func consume(rawBlock: [UInt8], nameCount: Int) throws {
        let compressed = NameBlockCodec.encode(raw: rawBlock)
        blocks.append(NameBlockEntry(
            offset: UInt64(data.count),
            compressedLength: UInt32(compressed.count),
            rawLength: UInt32(rawBlock.count)
        ))
        compressed.withUnsafeBytes { data.appendBytes($0) }
    }

    public func finish() throws {}
}

public struct TreeBuilderSummary {
    public var directoryCount: Int
    public var fileCount: UInt64
    public var totalBytes: UInt64
    public var rootExtensionBytes: [UInt16: UInt64]
    public var extensionNames: [String]
    public var skippedNonCurrent: Int
    public var skippedDeleteMarkers: Int
    public var parseErrors: Int
}

public final class TreeBuilder {
    private struct OpenDirectory {
        var identifier: UInt32
        var parentIdentifier: UInt32
        var depth: UInt8
        var nameOffset: UInt64
        var name: [UInt8]
        var childCount: UInt32 = 0
        var subtreeDirectoryCount: UInt32 = 0
        var fileStart: UInt64
        var subtreeFileCount: UInt64 = 0
        var subtreeBytes: UInt64 = 0
        var ownFileCount: UInt32 = 0
        var ownBytes: UInt64 = 0
        var bytesByStorageClass = [UInt64](repeating: 0, count: IndexFormat.storageClassSlots)
        var ageWeightedBytes: UInt64 = 0
        var extensionBytes: [UInt16: UInt64] = [:]
        var lastClosedChildName: [UInt8]?
    }

    private let writer: IndexWriter
    private let inventoryTimestamp: UInt32
    private let nameBlockConsumer: RawNameBlockConsumer
    private let fileNames: [String]
    private let extensions = ExtensionDictionary()
    private var stack: [OpenDirectory] = []
    private var nextDirectoryIdentifier: UInt32 = 1
    private var nextFileIndex: UInt64 = 0
    private var currentDirectoryPath: [UInt8] = []
    private let previousKeyBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: InventoryRowParser.maximumRowLength)
    private var previousKeyLength = -1
    private let decodedKeyBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: InventoryRowParser.maximumRowLength)
    private var rawNameBlock: [UInt8] = []
    private var namesInBlock = 0
    private var rootExtensionBytes: [UInt16: UInt64] = [:]
    private var totalBytes: UInt64 = 0
    private var skippedNonCurrent = 0
    private var skippedDeleteMarkers = 0
    private var parseErrors = 0
    private var finished = false
    private var segmentRanges: [Range<Int>] = []

    public init(writer: IndexWriter, inventoryTimestamp: UInt32, nameBlockConsumer: RawNameBlockConsumer, fileNames: [String]) {
        self.writer = writer
        self.inventoryTimestamp = inventoryTimestamp
        self.nameBlockConsumer = nameBlockConsumer
        self.fileNames = fileNames
        stack = [OpenDirectory(
            identifier: IndexFormat.rootDirectory,
            parentIdentifier: IndexFormat.noParent,
            depth: 0,
            nameOffset: 0,
            name: [],
            fileStart: 0
        )]
        rawNameBlock.reserveCapacity(IndexFormat.namesPerBlock * 80)
        segmentRanges.reserveCapacity(16)
    }

    deinit {
        previousKeyBuffer.deallocate()
        decodedKeyBuffer.deallocate()
    }

    /// Test hook: forget the previous key so a later chunk can exercise the directory re-entry check.
    public func resetOrderingCheckForTesting() {
        previousKeyLength = -1
    }

    public func consume(_ chunk: RowChunk) throws {
        skippedNonCurrent += chunk.skippedNonCurrent
        skippedDeleteMarkers += chunk.skippedDeleteMarkers
        parseErrors += chunk.parseErrors
        let fileName = chunk.fileIndex < fileNames.count ? fileNames[chunk.fileIndex] : "file \(chunk.fileIndex)"
        for row in 0..<chunk.count {
            try chunk.withKey(row) { rawKey in
                guard let rawBase = rawKey.baseAddress, rawKey.count > 0 else { return }

                // S3 Inventory sorts by the DECODED key, not the percent-encoded one. Verified against the
                // production census: "...2021.png" precedes "...2021%402x.png" because '.' (0x2E) < '@' (0x40),
                // while the encoded bytes would order them the other way ('%' is 0x25).
                var key = rawKey

                if chunk.needsDecoding[row] {
                    let decodedLength = TreeBuilder.decodePercentEncoding(rawKey, into: decodedKeyBuffer)
                    key = UnsafeBufferPointer(start: decodedKeyBuffer, count: decodedLength)
                }

                guard let keyBase = key.baseAddress else { return }

                if previousKeyLength >= 0 {
                    let commonLength = min(previousKeyLength, key.count)
                    let comparison = commonLength == 0 ? 0 : memcmp(previousKeyBuffer, keyBase, commonLength)
                    let isGreater = comparison < 0 || (comparison == 0 && key.count > previousKeyLength)

                    guard isGreater else {
                        let previous = String(decoding: UnsafeBufferPointer(start: previousKeyBuffer, count: previousKeyLength), as: UTF8.self)
                        throw ImportError.notKeySorted(
                            file: fileName,
                            previousKey: previous,
                            key: String(decoding: key, as: UTF8.self)
                        )
                    }
                }

                try addFile(
                    key: key,
                    size: chunk.sizes[row],
                    lastModified: chunk.lastModified[row],
                    storageClass: chunk.storageClass[row]
                )
                previousKeyBuffer.update(from: keyBase, count: key.count)
                previousKeyLength = key.count
                _ = rawBase
            }
        }
    }

    /// `%XX` becomes the byte; '+' stays '+'; a malformed escape is copied literally. Returns the decoded length.
    public static func decodePercentEncoding(_ source: UnsafeBufferPointer<UInt8>, into destination: UnsafeMutablePointer<UInt8>) -> Int {
        func hexValue(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: return byte - 48
            case 65...70: return byte - 55
            case 97...102: return byte - 87
            default: return nil
            }
        }

        var read = 0
        var written = 0

        while read < source.count {
            if source[read] == UInt8(ascii: "%"), read + 2 < source.count,
               let high = hexValue(source[read + 1]), let low = hexValue(source[read + 2]) {
                destination[written] = high << 4 | low
                read += 3
            } else {
                destination[written] = source[read]
                read += 1
            }

            written += 1
        }

        return written
    }

    private func addFile(key: UnsafeBufferPointer<UInt8>, size: UInt64, lastModified: UInt32, storageClass: UInt8) throws {
        var slashIndex = key.count - 1

        while slashIndex >= 0 && key[slashIndex] != UInt8(ascii: "/") {
            slashIndex -= 1
        }

        let directoryPart = UnsafeBufferPointer(rebasing: key[0..<max(slashIndex, 0)])
        let basename = UnsafeBufferPointer(rebasing: key[(slashIndex + 1)..<key.count])
        var sameDirectory = directoryPart.count == currentDirectoryPath.count

        if sameDirectory && !directoryPart.isEmpty {
            sameDirectory = currentDirectoryPath.withUnsafeBufferPointer {
                memcmp($0.baseAddress!, directoryPart.baseAddress!, directoryPart.count) == 0
            }
        }

        if !sameDirectory {
            try moveToDirectory(directoryPart, hasDirectoryPart: slashIndex >= 0)
        }

        try appendFile(basename: basename, size: size, lastModified: lastModified, storageClass: storageClass)
    }

    private func moveToDirectory(_ directoryPart: UnsafeBufferPointer<UInt8>, hasDirectoryPart: Bool) throws {
        segmentRanges.removeAll(keepingCapacity: true)

        if hasDirectoryPart {
            var start = 0

            for index in 0...directoryPart.count {
                if index == directoryPart.count || directoryPart[index] == UInt8(ascii: "/") {
                    segmentRanges.append(start..<index)
                    start = index + 1
                }
            }
        }

        var matchedLevels = 0

        while matchedLevels < segmentRanges.count && matchedLevels + 1 < stack.count {
            let segment = segmentRanges[matchedLevels]
            let name = stack[matchedLevels + 1].name

            guard name.count == segment.count else { break }
            var equal = true

            if segment.count > 0 {
                equal = name.withUnsafeBufferPointer {
                    memcmp($0.baseAddress!, directoryPart.baseAddress! + segment.lowerBound, segment.count) == 0
                }
            }

            if !equal {
                break
            }

            matchedLevels += 1
        }

        while stack.count > matchedLevels + 1 {
            try closeTopDirectory()
        }

        for index in matchedLevels..<segmentRanges.count {
            try pushDirectory(UnsafeBufferPointer(rebasing: directoryPart[segmentRanges[index]]))
        }

        currentDirectoryPath = Array(directoryPart)
    }

    private func pushDirectory(_ segment: UnsafeBufferPointer<UInt8>) throws {
        let parentIndex = stack.count - 1

        if let lastClosed = stack[parentIndex].lastClosedChildName, lastClosed.elementsEqual(segment) {
            throw ImportError.directoryReentered(path: String(decoding: currentDirectoryPath, as: UTF8.self) + "/" + String(
                decoding: segment,
                as: UTF8.self
            ))
        }

        guard nextDirectoryIdentifier < UInt32.max else { throw ImportError.tooManyFiles }
        let identifier = nextDirectoryIdentifier
        nextDirectoryIdentifier += 1
        let nameOffset = UInt64(writer.directoryNames.count)

        if segment.count > 0 {
            writer.directoryNames.appendBytes(UnsafeRawBufferPointer(segment))
        }

        let parentDepth = stack[parentIndex].depth
        stack.append(OpenDirectory(
            identifier: identifier,
            parentIdentifier: stack[parentIndex].identifier,
            depth: parentDepth == 255 ? 255 : parentDepth + 1,
            nameOffset: nameOffset,
            name: Array(segment),
            fileStart: nextFileIndex
        ))
    }

    private func closeTopDirectory() throws {
        let directory = stack.removeLast()
        let id = Int(directory.identifier)
        writer.directoryParent[id] = directory.parentIdentifier
        writer.directoryDepth[id] = directory.depth
        writer.directorySubtreeDirectoryCount[id] = directory.subtreeDirectoryCount
        writer.directoryChildCount[id] = directory.childCount
        writer.directoryFileStart[id] = directory.fileStart
        writer.directorySubtreeFileCount[id] = directory.subtreeFileCount
        writer.directorySubtreeBytes[id] = directory.subtreeBytes
        writer.directoryOwnFileCount[id] = directory.ownFileCount
        writer.directoryOwnBytes[id] = directory.ownBytes
        writer.directoryNameOffset[id] = directory.nameOffset
        writer.directoryNameLength[id] = UInt16(directory.name.count)
        let base = id * IndexFormat.storageClassSlots

        for slot in 0..<IndexFormat.storageClassSlots {
            writer.directoryBytesByStorageClass[base + slot] = directory.bytesByStorageClass[slot]
        }

        writer.directoryDominantExtension[id] = TreeBuilder.dominant(directory.extensionBytes)
        writer.directoryAgeWeightedBytes[id] = directory.ageWeightedBytes

        guard !stack.isEmpty else {
            rootExtensionBytes = directory.extensionBytes
            totalBytes = directory.subtreeBytes
            return
        }

        let parentIndex = stack.count - 1
        stack[parentIndex].childCount += 1
        stack[parentIndex].subtreeDirectoryCount += directory.subtreeDirectoryCount + 1
        stack[parentIndex].subtreeFileCount += directory.subtreeFileCount
        stack[parentIndex].subtreeBytes += directory.subtreeBytes

        for slot in 0..<IndexFormat.storageClassSlots {
            stack[parentIndex].bytesByStorageClass[slot] += directory.bytesByStorageClass[slot]
        }

        stack[parentIndex].ageWeightedBytes += directory.ageWeightedBytes

        if stack[parentIndex].extensionBytes.count < directory.extensionBytes.count {
            var merged = directory.extensionBytes

            for (key, value) in stack[parentIndex].extensionBytes {
                merged[key, default: 0] += value
            }

            stack[parentIndex].extensionBytes = merged
        } else {
            for (key, value) in directory.extensionBytes {
                stack[parentIndex].extensionBytes[key, default: 0] += value
            }
        }

        stack[parentIndex].lastClosedChildName = directory.name
    }

    private static func dominant(_ extensionBytes: [UInt16: UInt64]) -> UInt16 {
        var bestKey: UInt16 = 0
        var bestValue: UInt64 = 0
        var found = false

        for (key, value) in extensionBytes {
            if !found || value > bestValue || (value == bestValue && key < bestKey) {
                bestKey = key
                bestValue = value
                found = true
            }
        }

        return found ? bestKey : 0
    }

    private func appendFile(basename: UnsafeBufferPointer<UInt8>, size: UInt64, lastModified: UInt32, storageClass: UInt8) throws {
        guard nextFileIndex < UInt64(UInt32.max) else { throw ImportError.tooManyFiles }
        let extensionIdentifier = extensions.identifier(forBasename: basename)
        writer.fileSize.append(size)
        writer.fileLastModified.append(lastModified)
        writer.fileStorageClass.append(storageClass)
        writer.fileExtension.append(extensionIdentifier)
        NameBlockCodec.appendName(basename, to: &rawNameBlock)
        namesInBlock += 1

        if namesInBlock == IndexFormat.namesPerBlock {
            try flushNameBlock()
        }

        let ageDays: UInt64 = (lastModified == 0 || lastModified >= inventoryTimestamp)
            ? 0 : UInt64(inventoryTimestamp - lastModified) / 86_400
        let top = stack.count - 1
        stack[top].ownFileCount += 1
        stack[top].ownBytes += size
        stack[top].subtreeFileCount += 1
        stack[top].subtreeBytes += size
        stack[top].bytesByStorageClass[Int(storageClass & 7)] += size
        stack[top].ageWeightedBytes &+= size &* ageDays
        stack[top].extensionBytes[extensionIdentifier, default: 0] += size
        nextFileIndex += 1
    }

    private func flushNameBlock() throws {
        let block = rawNameBlock
        rawNameBlock = []
        rawNameBlock.reserveCapacity(IndexFormat.namesPerBlock * 80)
        let count = namesInBlock
        namesInBlock = 0
        try nameBlockConsumer.consume(rawBlock: block, nameCount: count)
    }

    public func finish() throws -> TreeBuilderSummary {
        precondition(!finished, "finish called twice")
        finished = true

        while !stack.isEmpty {
            try closeTopDirectory()
        }

        if namesInBlock > 0 {
            try flushNameBlock()
        }

        try nameBlockConsumer.finish()
        let directoryCount = Int(nextDirectoryIdentifier)
        try writer.finish(directoryCount: directoryCount)
        return TreeBuilderSummary(
            directoryCount: directoryCount,
            fileCount: nextFileIndex,
            totalBytes: totalBytes,
            rootExtensionBytes: rootExtensionBytes,
            extensionNames: extensions.names,
            skippedNonCurrent: skippedNonCurrent,
            skippedDeleteMarkers: skippedDeleteMarkers,
            parseErrors: parseErrors
        )
    }
}
