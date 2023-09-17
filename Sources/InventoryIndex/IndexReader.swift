import Foundation

public final class IndexReader {
    public let folder: URL
    public let manifest: IndexManifest
    public let directories: DirectoryTree
    public let fileSize: MappedColumn<UInt64>
    public let fileLastModified: MappedColumn<UInt32>
    public let fileStorageClass: MappedColumn<UInt8>
    public let fileExtension: MappedColumn<UInt16>
    public let names: NameBlockCache

    public var fileCount: Int { fileSize.count }

    public static func indexFolder(forInventory folder: URL) -> URL {
        folder.appendingPathComponent(IndexFormat.folderName, isDirectory: true)
    }

    public init(folder: URL) throws {
        self.folder = folder
        manifest = try IndexManifest.load(from: folder)

        func column<Element>(_ name: String) throws -> MappedColumn<Element> {
            try MappedColumn(url: folder.appendingPathComponent(name))
        }

        directories = DirectoryTree(
            parentColumn: try column(IndexFiles.directoryParent),
            depthColumn: try column(IndexFiles.directoryDepth),
            subtreeDirectoryCountColumn: try column(IndexFiles.directorySubtreeDirectoryCount),
            childCountColumn: try column(IndexFiles.directoryChildCount),
            fileStartColumn: try column(IndexFiles.directoryFileStart),
            subtreeFileCountColumn: try column(IndexFiles.directorySubtreeFileCount),
            subtreeBytesColumn: try column(IndexFiles.directorySubtreeBytes),
            ownFileCountColumn: try column(IndexFiles.directoryOwnFileCount),
            ownBytesColumn: try column(IndexFiles.directoryOwnBytes),
            nameOffsetColumn: try column(IndexFiles.directoryNameOffset),
            nameLengthColumn: try column(IndexFiles.directoryNameLength),
            namesColumn: try column(IndexFiles.directoryNames),
            bytesByStorageClassColumn: try column(IndexFiles.directoryBytesByStorageClass),
            dominantExtensionColumn: try column(IndexFiles.directoryDominantExtension),
            ageWeightedBytesColumn: try column(IndexFiles.directoryAgeWeightedBytes),
            childListStartColumn: try column(IndexFiles.directoryChildListStart),
            childrenBySizeColumn: try column(IndexFiles.directoryChildrenBySize),
            childrenBySizeBytesColumn: try column(IndexFiles.directoryChildrenBySizeBytes)
        )
        fileSize = try column(IndexFiles.fileSize)
        fileLastModified = try column(IndexFiles.fileLastModified)
        fileStorageClass = try column(IndexFiles.fileStorageClass)
        fileExtension = try column(IndexFiles.fileExtension)
        names = NameBlockCache(blocks: try column(IndexFiles.fileNameBlocks), data: try column(IndexFiles.fileNameData))
    }

    /// Hints the kernel to read ahead the columns every treemap layout walks. Safe to call more than once.
    public func prefetchLayoutColumns() {
        directories.subtreeBytesColumn.prefetch()
        directories.subtreeDirectoryCountColumn.prefetch()
        directories.childCountColumn.prefetch()
        directories.childListStartColumn.prefetch()
        directories.childrenBySizeColumn.prefetch()
        directories.childrenBySizeBytesColumn.prefetch()
        directories.fileStartColumn.prefetch()
        directories.subtreeFileCountColumn.prefetch()
        directories.bytesByStorageClassColumn.prefetch()
    }

    /// Deepest directory whose subtree contains the file: binary search on the monotonic `fileStart`, then walk up.
    public func directory(ofFile fileIndex: UInt64) -> UInt32 {
        var low = 0
        var high = directories.count - 1

        while low < high {
            let middle = (low + high + 1) / 2

            if directories.fileStart(UInt32(middle)) <= fileIndex {
                low = middle
            } else {
                high = middle - 1
            }
        }

        var candidate = UInt32(low)

        while candidate != IndexFormat.noParent {
            let start = directories.fileStart(candidate)

            if fileIndex >= start && fileIndex < start + directories.subtreeFileCount(candidate) {
                return candidate
            }

            candidate = directories.parent(candidate)
        }

        return IndexFormat.rootDirectory
    }

    public func key(ofFile fileIndex: UInt64) -> String {
        let directory = self.directory(ofFile: fileIndex)
        let name = names.nameString(ofFile: fileIndex)

        if directory == IndexFormat.rootDirectory {
            return name
        }

        return directories.path(directory) + "/" + name
    }
}
