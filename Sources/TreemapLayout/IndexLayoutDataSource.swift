import Foundation
import InventoryIndex

public final class IndexLayoutDataSource: LayoutDataSource {
    public let reader: IndexReader
    public let ownFilesCache: OwnFilesCache

    public init(reader: IndexReader, ownFilesCache: OwnFilesCache) {
        self.reader = reader
        self.ownFilesCache = ownFilesCache
    }

    public func subtreeBytes(of directory: UInt32) -> UInt64 {
        reader.directories.subtreeBytes(directory)
    }

    public func subtreeFileCount(of directory: UInt32) -> UInt64 {
        reader.directories.subtreeFileCount(directory)
    }

    public func subtreeDirectoryCount(of directory: UInt32) -> UInt32 {
        reader.directories.subtreeDirectoryCount(directory)
    }

    public func childrenBySize(of directory: UInt32) -> [UInt32] {
        reader.directories.childrenBySize(directory)
    }

    public func withChildrenBySize<R>(of directory: UInt32, _ body: (UnsafeBufferPointer<UInt32>) -> R) -> R {
        reader.directories.withChildrenBySize(directory, body)
    }

    public func withChildrenBySizeAndBytes<R>(
        of directory: UInt32,
        _ body: (UnsafeBufferPointer<UInt32>, UnsafeBufferPointer<UInt64>) -> R
    ) -> R {
        reader.directories.withChildrenBySizeAndBytes(directory, body)
    }

    public func ownFiles(of directory: UInt32, atLeast threshold: UInt64) -> OwnFilesSelection {
        ownFilesCache.ownFiles(of: directory, atLeast: threshold)
    }

    public func largestOwnFiles(of directory: UInt32, count: Int) -> OwnFilesSelection {
        ownFilesCache.largestOwnFiles(of: directory, count: count)
    }

    public func directoryAttributes(_ id: UInt32) -> DirectoryLeafAttributes {
        let ageSeconds = reader.directories.averageAgeDays(id) * 86_400
        let time = max(0, Double(reader.manifest.inventoryTimestamp) - ageSeconds)
        return DirectoryLeafAttributes(
            storageClass: reader.directories.dominantStorageClass(id),
            extensionId: reader.directories.dominantExtension(id),
            timeSeconds: UInt32(time)
        )
    }

    public func fileAttributes(_ index: UInt64) -> FileLeafAttributes {
        let position = Int(index)
        return FileLeafAttributes(
            storageClass: reader.fileStorageClass[position],
            extensionId: reader.fileExtension[position],
            lastModified: reader.fileLastModified[position]
        )
    }

    public func directoryName(_ id: UInt32) -> String {
        reader.directories.name(id)
    }
}
