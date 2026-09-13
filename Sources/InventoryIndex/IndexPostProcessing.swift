import Foundation

public enum IndexPostProcessing {
    /// Writes `directory.childListStart.u32` and `directory.childrenBySize.u32` from the finished directory columns.
    public static func writeChildrenBySize(folder: URL) throws {
        let subtreeDirectoryCount = try MappedColumn<UInt32>(url: folder.appendingPathComponent(IndexFiles.directorySubtreeDirectoryCount))
        let subtreeBytes = try MappedColumn<UInt64>(url: folder.appendingPathComponent(IndexFiles.directorySubtreeBytes))
        let childListStart = try ColumnWriter<UInt32>(url: folder.appendingPathComponent(IndexFiles.directoryChildListStart))
        let childrenBySize = try ColumnWriter<UInt32>(url: folder.appendingPathComponent(IndexFiles.directoryChildrenBySize))
        let childrenBySizeBytes = try ColumnWriter<UInt64>(url: folder.appendingPathComponent(IndexFiles.directoryChildrenBySizeBytes))
        var children: [UInt32] = []

        for id in 0..<subtreeDirectoryCount.count {
            childListStart.append(UInt32(childrenBySize.count))
            children.removeAll(keepingCapacity: true)
            let end = id + 1 + Int(subtreeDirectoryCount[id])
            var child = id + 1

            while child < end {
                children.append(UInt32(child))
                child += 1 + Int(subtreeDirectoryCount[child])
            }

            children.sort { left, right in
                let leftBytes = subtreeBytes[Int(left)]
                let rightBytes = subtreeBytes[Int(right)]
                return leftBytes != rightBytes ? leftBytes > rightBytes : left < right
            }

            for child in children {
                childrenBySize.append(child)
                childrenBySizeBytes.append(subtreeBytes[Int(child)])
            }
        }

        try childListStart.finish()
        try childrenBySize.finish()
        try childrenBySizeBytes.finish()
    }
}
