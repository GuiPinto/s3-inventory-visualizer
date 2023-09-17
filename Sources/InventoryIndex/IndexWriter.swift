import Foundation

public final class IndexWriter {
    public let folder: URL

    public let directoryParent: SparseMappedColumn<UInt32>
    public let directoryDepth: SparseMappedColumn<UInt8>
    public let directorySubtreeDirectoryCount: SparseMappedColumn<UInt32>
    public let directoryChildCount: SparseMappedColumn<UInt32>
    public let directoryFileStart: SparseMappedColumn<UInt64>
    public let directorySubtreeFileCount: SparseMappedColumn<UInt64>
    public let directorySubtreeBytes: SparseMappedColumn<UInt64>
    public let directoryOwnFileCount: SparseMappedColumn<UInt32>
    public let directoryOwnBytes: SparseMappedColumn<UInt64>
    public let directoryNameOffset: SparseMappedColumn<UInt64>
    public let directoryNameLength: SparseMappedColumn<UInt16>

    /// Index is `directoryIdentifier * IndexFormat.storageClassSlots + slot`.
    public let directoryBytesByStorageClass: SparseMappedColumn<UInt64>
    public let directoryDominantExtension: SparseMappedColumn<UInt16>
    public let directoryAgeWeightedBytes: SparseMappedColumn<UInt64>

    public let directoryNames: ColumnWriter<UInt8>
    public let fileSize: ColumnWriter<UInt64>
    public let fileLastModified: ColumnWriter<UInt32>
    public let fileStorageClass: ColumnWriter<UInt8>
    public let fileExtension: ColumnWriter<UInt16>
    public let fileNameBlocks: ColumnWriter<NameBlockEntry>
    public let fileNameData: ColumnWriter<UInt8>

    public init(folder: URL, directoryCapacity: Int = IndexFormat.directoryCapacity) throws {
        self.folder = folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: folder.appendingPathComponent(IndexFiles.manifest).path) {
            throw IndexError.manifestMismatch("index folder already contains a finished index: \(folder.path)")
        }

        func url(_ name: String) -> URL {
            folder.appendingPathComponent(name)
        }

        directoryParent = try SparseMappedColumn(url: url(IndexFiles.directoryParent), capacity: directoryCapacity)
        directoryDepth = try SparseMappedColumn(url: url(IndexFiles.directoryDepth), capacity: directoryCapacity)
        directorySubtreeDirectoryCount = try SparseMappedColumn(url: url(IndexFiles.directorySubtreeDirectoryCount), capacity: directoryCapacity)
        directoryChildCount = try SparseMappedColumn(url: url(IndexFiles.directoryChildCount), capacity: directoryCapacity)
        directoryFileStart = try SparseMappedColumn(url: url(IndexFiles.directoryFileStart), capacity: directoryCapacity)
        directorySubtreeFileCount = try SparseMappedColumn(url: url(IndexFiles.directorySubtreeFileCount), capacity: directoryCapacity)
        directorySubtreeBytes = try SparseMappedColumn(url: url(IndexFiles.directorySubtreeBytes), capacity: directoryCapacity)
        directoryOwnFileCount = try SparseMappedColumn(url: url(IndexFiles.directoryOwnFileCount), capacity: directoryCapacity)
        directoryOwnBytes = try SparseMappedColumn(url: url(IndexFiles.directoryOwnBytes), capacity: directoryCapacity)
        directoryNameOffset = try SparseMappedColumn(url: url(IndexFiles.directoryNameOffset), capacity: directoryCapacity)
        directoryNameLength = try SparseMappedColumn(url: url(IndexFiles.directoryNameLength), capacity: directoryCapacity)
        directoryBytesByStorageClass = try SparseMappedColumn(
            url: url(IndexFiles.directoryBytesByStorageClass),
            capacity: directoryCapacity * IndexFormat.storageClassSlots
        )
        directoryDominantExtension = try SparseMappedColumn(url: url(IndexFiles.directoryDominantExtension), capacity: directoryCapacity)
        directoryAgeWeightedBytes = try SparseMappedColumn(url: url(IndexFiles.directoryAgeWeightedBytes), capacity: directoryCapacity)
        directoryNames = try ColumnWriter(url: url(IndexFiles.directoryNames))
        fileSize = try ColumnWriter(url: url(IndexFiles.fileSize))
        fileLastModified = try ColumnWriter(url: url(IndexFiles.fileLastModified))
        fileStorageClass = try ColumnWriter(url: url(IndexFiles.fileStorageClass))
        fileExtension = try ColumnWriter(url: url(IndexFiles.fileExtension))
        fileNameBlocks = try ColumnWriter(url: url(IndexFiles.fileNameBlocks))
        fileNameData = try ColumnWriter(url: url(IndexFiles.fileNameData))
    }

    public func finish(directoryCount: Int) throws {
        try directoryParent.finish(count: directoryCount)
        try directoryDepth.finish(count: directoryCount)
        try directorySubtreeDirectoryCount.finish(count: directoryCount)
        try directoryChildCount.finish(count: directoryCount)
        try directoryFileStart.finish(count: directoryCount)
        try directorySubtreeFileCount.finish(count: directoryCount)
        try directorySubtreeBytes.finish(count: directoryCount)
        try directoryOwnFileCount.finish(count: directoryCount)
        try directoryOwnBytes.finish(count: directoryCount)
        try directoryNameOffset.finish(count: directoryCount)
        try directoryNameLength.finish(count: directoryCount)
        try directoryBytesByStorageClass.finish(count: directoryCount * IndexFormat.storageClassSlots)
        try directoryDominantExtension.finish(count: directoryCount)
        try directoryAgeWeightedBytes.finish(count: directoryCount)
        try directoryNames.finish()
        try fileSize.finish()
        try fileLastModified.finish()
        try fileStorageClass.finish()
        try fileExtension.finish()
        try fileNameBlocks.finish()
        try fileNameData.finish()
    }
}
