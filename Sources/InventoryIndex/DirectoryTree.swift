import Foundation

public struct DirectoryTree {
    let parentColumn: MappedColumn<UInt32>
    let depthColumn: MappedColumn<UInt8>
    let subtreeDirectoryCountColumn: MappedColumn<UInt32>
    let childCountColumn: MappedColumn<UInt32>
    let fileStartColumn: MappedColumn<UInt64>
    let subtreeFileCountColumn: MappedColumn<UInt64>
    let subtreeBytesColumn: MappedColumn<UInt64>
    let ownFileCountColumn: MappedColumn<UInt32>
    let ownBytesColumn: MappedColumn<UInt64>
    let nameOffsetColumn: MappedColumn<UInt64>
    let nameLengthColumn: MappedColumn<UInt16>
    let namesColumn: MappedColumn<UInt8>
    let bytesByStorageClassColumn: MappedColumn<UInt64>
    let dominantExtensionColumn: MappedColumn<UInt16>
    let ageWeightedBytesColumn: MappedColumn<UInt64>
    let childListStartColumn: MappedColumn<UInt32>
    let childrenBySizeColumn: MappedColumn<UInt32>
    let childrenBySizeBytesColumn: MappedColumn<UInt64>

    public var count: Int { parentColumn.count }

    @inline(__always) public func parent(_ id: UInt32) -> UInt32 { parentColumn[Int(id)] }
    @inline(__always) public func depth(_ id: UInt32) -> UInt8 { depthColumn[Int(id)] }
    @inline(__always) public func subtreeDirectoryCount(_ id: UInt32) -> UInt32 { subtreeDirectoryCountColumn[Int(id)] }
    @inline(__always) public func childCount(_ id: UInt32) -> UInt32 { childCountColumn[Int(id)] }
    @inline(__always) public func fileStart(_ id: UInt32) -> UInt64 { fileStartColumn[Int(id)] }
    @inline(__always) public func subtreeFileCount(_ id: UInt32) -> UInt64 { subtreeFileCountColumn[Int(id)] }
    @inline(__always) public func subtreeBytes(_ id: UInt32) -> UInt64 { subtreeBytesColumn[Int(id)] }
    @inline(__always) public func ownFileCount(_ id: UInt32) -> UInt32 { ownFileCountColumn[Int(id)] }
    @inline(__always) public func ownBytes(_ id: UInt32) -> UInt64 { ownBytesColumn[Int(id)] }
    @inline(__always) public func dominantExtension(_ id: UInt32) -> UInt16 { dominantExtensionColumn[Int(id)] }
    @inline(__always) public func ageWeightedBytes(_ id: UInt32) -> UInt64 { ageWeightedBytesColumn[Int(id)] }

    public func bytesByStorageClass(_ id: UInt32) -> [UInt64] {
        let base = Int(id) * IndexFormat.storageClassSlots
        return Array(bytesByStorageClassColumn.buffer[base..<(base + IndexFormat.storageClassSlots)])
    }

    public func dominantStorageClass(_ id: UInt32) -> UInt8 {
        let base = Int(id) * IndexFormat.storageClassSlots
        var best = 0

        for slot in 1..<IndexFormat.storageClassSlots
        where bytesByStorageClassColumn[base + slot] > bytesByStorageClassColumn[base + best] {
            best = slot
        }

        return UInt8(best)
    }

    public func averageAgeDays(_ id: UInt32) -> Double {
        let bytes = subtreeBytes(id)
        return bytes == 0 ? 0 : Double(ageWeightedBytes(id)) / Double(bytes)
    }

    public func withNameBytes<R>(_ id: UInt32, _ body: (UnsafeBufferPointer<UInt8>) -> R) -> R {
        let start = Int(nameOffsetColumn[Int(id)])
        let length = Int(nameLengthColumn[Int(id)])
        return body(UnsafeBufferPointer(rebasing: namesColumn.buffer[start..<(start + length)]))
    }

    public func name(_ id: UInt32) -> String {
        withNameBytes(id) { String(decoding: $0, as: UTF8.self) }
    }

    public func path(_ id: UInt32) -> String {
        var segments: [String] = []
        var current = id

        while current != IndexFormat.rootDirectory && current != IndexFormat.noParent {
            segments.append(name(current))
            current = parent(current)
        }

        return segments.reversed().joined(separator: "/")
    }

    public func subtreeRange(_ id: UInt32) -> Range<UInt32> {
        id..<(id + 1 + subtreeDirectoryCount(id))
    }

    /// The child of `ancestor` whose subtree holds `id`, or nil when `id` sits outside that subtree
    /// or is `ancestor` itself. One step per level, so it costs the depth difference and no more.
    public func child(of ancestor: UInt32, containing id: UInt32) -> UInt32? {
        guard id != ancestor, subtreeRange(ancestor).contains(id) else { return nil }
        var current = id

        while true {
            let above = parent(current)

            guard above != IndexFormat.noParent else { return nil }

            if above == ancestor {
                return current
            }

            current = above
        }
    }

    public func subtreeFileRange(_ id: UInt32) -> Range<UInt64> {
        let start = fileStart(id)
        return start..<(start + subtreeFileCount(id))
    }

    public func childrenInKeyOrder(_ id: UInt32) -> [UInt32] {
        var result: [UInt32] = []
        result.reserveCapacity(Int(childCount(id)))
        let end = id + 1 + subtreeDirectoryCount(id)
        var child = id + 1

        while child < end {
            result.append(child)
            child += 1 + subtreeDirectoryCount(child)
        }

        return result
    }

    public func childrenBySize(_ id: UInt32) -> [UInt32] {
        let start = Int(childListStartColumn[Int(id)])
        return Array(childrenBySizeColumn.buffer[start..<(start + Int(childCount(id)))])
    }

    /// The children sorted by size, as a view into the memory map. Avoids one array copy per layout node.
    public func withChildrenBySize<R>(_ id: UInt32, _ body: (UnsafeBufferPointer<UInt32>) -> R) -> R {
        let start = Int(childListStartColumn[Int(id)])
        let end = start + Int(childCount(id))
        return body(UnsafeBufferPointer(rebasing: childrenBySizeColumn.buffer[start..<end]))
    }

    /// The children sorted by size together with their subtree byte counts, both contiguous.
    public func withChildrenBySizeAndBytes<R>(
        _ id: UInt32,
        _ body: (UnsafeBufferPointer<UInt32>, UnsafeBufferPointer<UInt64>) -> R
    ) -> R {
        let start = Int(childListStartColumn[Int(id)])
        let end = start + Int(childCount(id))
        return body(
            UnsafeBufferPointer(rebasing: childrenBySizeColumn.buffer[start..<end]),
            UnsafeBufferPointer(rebasing: childrenBySizeBytesColumn.buffer[start..<end])
        )
    }

    /// Own files are the gaps between the children's subtree file ranges, in key order.
    public func ownFileRanges(_ id: UInt32) -> [Range<UInt64>] {
        var ranges: [Range<UInt64>] = []
        var cursor = fileStart(id)
        let end = cursor + subtreeFileCount(id)

        for child in childrenInKeyOrder(id) {
            let childStart = fileStart(child)

            if childStart > cursor {
                ranges.append(cursor..<childStart)
            }

            cursor = childStart + subtreeFileCount(child)
        }

        if end > cursor {
            ranges.append(cursor..<end)
        }

        return ranges
    }

    /// Exact segment walk from the root. "" is the root. A trailing "/" is ignored.
    public func lookup(path: String) -> UInt32? {
        var current = IndexFormat.rootDirectory
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path

        if trimmed.isEmpty {
            return current
        }

        for segment in trimmed.split(separator: "/", omittingEmptySubsequences: false) {
            let segmentBytes = Array(segment.utf8)
            var found: UInt32?

            for child in childrenInKeyOrder(current) {
                let matches = withNameBytes(child) { bytes -> Bool in
                    guard bytes.count == segmentBytes.count else { return false }
                    return segmentBytes.withUnsafeBufferPointer { bytes.elementsEqual($0) }
                }

                if matches {
                    found = child
                    break
                }
            }

            guard let next = found else { return nil }
            current = next
        }

        return current
    }
}
