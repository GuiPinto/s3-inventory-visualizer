import Foundation

public struct IndexManifest: Codable, Equatable {
    public struct SourceIdentity: Codable, Equatable {
        public var sourceBucket: String
        public var manifestCreationTimestamp: String?
        public var manifestFileCount: Int
        public var manifestTotalBytes: Int64
        public var manifestMD5: String?

        public init(
            sourceBucket: String,
            manifestCreationTimestamp: String?,
            manifestFileCount: Int,
            manifestTotalBytes: Int64,
            manifestMD5: String?
        ) {
            self.sourceBucket = sourceBucket
            self.manifestCreationTimestamp = manifestCreationTimestamp
            self.manifestFileCount = manifestFileCount
            self.manifestTotalBytes = manifestTotalBytes
            self.manifestMD5 = manifestMD5
        }
    }

    public struct Counts: Codable, Equatable {
        public var directoryCount: Int = 0
        public var fileCount: UInt64 = 0
        public var totalBytes: UInt64 = 0
        public var skippedNonCurrent: Int = 0
        public var skippedDeleteMarkers: Int = 0
        public var rowParseErrors: Int = 0

        public init(
            directoryCount: Int = 0,
            fileCount: UInt64 = 0,
            totalBytes: UInt64 = 0,
            skippedNonCurrent: Int = 0,
            skippedDeleteMarkers: Int = 0,
            rowParseErrors: Int = 0
        ) {
            self.directoryCount = directoryCount
            self.fileCount = fileCount
            self.totalBytes = totalBytes
            self.skippedNonCurrent = skippedNonCurrent
            self.skippedDeleteMarkers = skippedDeleteMarkers
            self.rowParseErrors = rowParseErrors
        }
    }

    public var formatVersion: Int
    public var createdAt: Date
    public var importDurationSeconds: Double
    public var appVersion: String
    public var source: SourceIdentity
    public var counts: Counts
    public var missingDataFiles: [String]
    public var storageClassNames: [String]
    public var extensionNames: [String]
    public var extensionPalette: [UInt16]
    public var schemaColumns: [String]
    public var inventoryTimestamp: UInt32

    public var isPartial: Bool { !missingDataFiles.isEmpty }

    public static func empty(sourceBucket: String, inventoryTimestamp: UInt32) -> IndexManifest {
        IndexManifest(
            formatVersion: Int(IndexFormat.formatVersion),
            createdAt: Date(),
            importDurationSeconds: 0,
            appVersion: "1.0.0",
            source: SourceIdentity(
                sourceBucket: sourceBucket,
                manifestCreationTimestamp: nil,
                manifestFileCount: 0,
                manifestTotalBytes: 0,
                manifestMD5: nil
            ),
            counts: Counts(),
            missingDataFiles: [],
            storageClassNames: StorageClass.names,
            extensionNames: [""],
            extensionPalette: [],
            schemaColumns: [],
            inventoryTimestamp: inventoryTimestamp
        )
    }

    public static func load(from folder: URL) throws -> IndexManifest {
        let url = folder.appendingPathComponent(IndexFiles.manifest)

        guard FileManager.default.fileExists(atPath: url.path) else { throw IndexError.incompleteIndex(folder) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(IndexManifest.self, from: Data(contentsOf: url))
    }

    public func save(to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: folder.appendingPathComponent(IndexFiles.manifest), options: .atomic)
    }

    /// The `maximum` extension ids with the most bytes, excluding id 0 and the overflow id.
    public static func extensionPalette(from bytesByExtension: [UInt16: UInt64], maximum: Int = 15) -> [UInt16] {
        bytesByExtension
            .filter { $0.key != 0 && $0.key != ExtensionDictionary.otherIdentifier }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(maximum)
            .map { $0.key }
    }
}
