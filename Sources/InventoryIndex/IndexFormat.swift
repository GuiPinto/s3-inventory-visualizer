import Foundation

public enum IndexFormat {
    public static let formatVersion: UInt32 = 2
    public static let folderName = ".s3-inventory-index"
    public static let namesPerBlock = 4096
    public static let storageClassSlots = 8
    public static let directoryCapacity = 256_000_000
    public static let columnHeaderSize = 64
    public static let columnMagic: [UInt8] = Array("S3VZCOL1".utf8)
    public static let rootDirectory: UInt32 = 0
    public static let noParent: UInt32 = UInt32.max

    /// Seven boundaries produce eight age buckets; the last bucket is everything older.
    public static let ageBucketDays: [UInt32] = [30, 90, 180, 365, 730, 1095, 1825]
}

public enum IndexFiles {
    public static let manifest = "index.json"
    public static let directoryParent = "directory.parent.u32"
    public static let directoryDepth = "directory.depth.u8"
    public static let directorySubtreeDirectoryCount = "directory.subtreeDirectoryCount.u32"
    public static let directoryChildCount = "directory.childCount.u32"
    public static let directoryFileStart = "directory.fileStart.u64"
    public static let directorySubtreeFileCount = "directory.subtreeFileCount.u64"
    public static let directorySubtreeBytes = "directory.subtreeBytes.u64"
    public static let directoryOwnFileCount = "directory.ownFileCount.u32"
    public static let directoryOwnBytes = "directory.ownBytes.u64"
    public static let directoryNameOffset = "directory.nameOffset.u64"
    public static let directoryNameLength = "directory.nameLength.u16"
    public static let directoryNames = "directory.names.bytes"
    public static let directoryBytesByStorageClass = "directory.bytesByStorageClass.u64x8"
    public static let directoryDominantExtension = "directory.dominantExtension.u16"
    public static let directoryAgeWeightedBytes = "directory.ageWeightedBytes.u64"
    public static let directoryChildListStart = "directory.childListStart.u32"
    public static let directoryChildrenBySize = "directory.childrenBySize.u32"
    /// The subtree bytes of each entry in `childrenBySize`, so the layout reads them sequentially
    /// instead of chasing scattered directory identifiers.
    public static let directoryChildrenBySizeBytes = "directory.childrenBySizeBytes.u64"
    public static let fileSize = "file.size.u64"
    public static let fileLastModified = "file.lastModified.u32"
    public static let fileStorageClass = "file.storageClass.u8"
    public static let fileExtension = "file.extension.u16"
    public static let fileNameBlocks = "file.names.blocks"
    public static let fileNameData = "file.names.data"
}

public enum IndexError: Error, Equatable {
    case incompleteIndex(URL)
    case badColumnHeader(String)
    case elementSizeMismatch(String, expected: Int, found: Int)
    case systemCall(String, errno: Int32)
    case manifestMismatch(String)
}
