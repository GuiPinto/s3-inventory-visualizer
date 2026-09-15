import Foundation
import CryptoKit

public struct InventorySchema: Equatable {
    public static let defaultColumns = [
        "Bucket",
        "Key",
        "VersionId",
        "IsLatest",
        "IsDeleteMarker",
        "Size",
        "LastModifiedDate",
        "ETag",
        "StorageClass",
        "IsMultipartUploaded",
        "ReplicationStatus",
        "IntelligentTieringAccessTier"
    ]
    public let columnNames: [String]
    public let keyColumn: Int
    public let sizeColumn: Int
    public let lastModifiedColumn: Int?
    public let storageClassColumn: Int?
    public let isLatestColumn: Int?
    public let isDeleteMarkerColumn: Int?

    public var requiredFieldCount: Int {
        let optional = [lastModifiedColumn, storageClassColumn, isLatestColumn, isDeleteMarkerColumn].compactMap { $0 }
        return ([keyColumn, sizeColumn] + optional).max()! + 1
    }

    public init(fileSchema: String) throws {
        let names = fileSchema.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }

        guard let key = names.firstIndex(of: "Key"), let size = names.firstIndex(of: "Size") else {
            throw ImportError.invalidManifest("fileSchema must contain Key and Size, found: \(fileSchema)")
        }

        columnNames = names
        keyColumn = key
        sizeColumn = size
        lastModifiedColumn = names.firstIndex(of: "LastModifiedDate")
        storageClassColumn = names.firstIndex(of: "StorageClass")
        isLatestColumn = names.firstIndex(of: "IsLatest")
        isDeleteMarkerColumn = names.firstIndex(of: "IsDeleteMarker")
    }

    public static let standard = try! InventorySchema(fileSchema: defaultColumns.joined(separator: ", "))
}

public struct InventoryDataFile: Equatable {
    public let url: URL
    public let manifestKey: String
    public let expectedSize: Int64?
    public let actualSize: Int64
}

public struct InventorySource {
    public let folder: URL
    public let manifestURL: URL?
    public let sourceBucket: String
    public let creationTimestampMilliseconds: Int64?
    public let schema: InventorySchema
    public let dataFiles: [InventoryDataFile]
    public let missingDataFiles: [String]
    public let manifestMD5: String?

    public var totalCompressedBytes: Int64 { dataFiles.reduce(0) { $0 + $1.actualSize } }
    public var manifestTotalBytes: Int64 { dataFiles.reduce(0) { $0 + ($1.expectedSize ?? $1.actualSize) } }

    /// Seconds since 1970 for the inventory snapshot; the manifest's creationTimestamp, else now.
    public var inventoryTimestamp: UInt32 {
        if let milliseconds = creationTimestampMilliseconds {
            return UInt32(clamping: milliseconds / 1000)
        }

        return UInt32(clamping: Int64(Date().timeIntervalSince1970))
    }

    public static func load(folder: URL) throws -> InventorySource {
        let manifestURL = folder.appendingPathComponent("manifest.json")

        if FileManager.default.fileExists(atPath: manifestURL.path) {
            return try loadWithManifest(folder: folder, manifestURL: manifestURL)
        }

        return try loadBareFolder(folder: folder)
    }

    private static func fileSize(_ url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return (attributes[.size] as? NSNumber)?.int64Value
    }

    private static func loadWithManifest(folder: URL, manifestURL: URL) throws -> InventorySource {
        let data = try Data(contentsOf: manifestURL)

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ImportError.invalidManifest("manifest.json is not a JSON object")
        }

        guard (object["fileFormat"] as? String)?.uppercased() == "CSV" else {
            throw ImportError.invalidManifest("fileFormat must be CSV")
        }

        guard let fileSchema = object["fileSchema"] as? String else {
            throw ImportError.invalidManifest("fileSchema missing")
        }

        let schema = try InventorySchema(fileSchema: fileSchema)
        let bucket = object["sourceBucket"] as? String ?? folder.lastPathComponent
        var creation: Int64?

        if let text = object["creationTimestamp"] as? String {
            creation = Int64(text)
        }

        if let number = object["creationTimestamp"] as? NSNumber {
            creation = number.int64Value
        }

        let entries = object["files"] as? [[String: Any]] ?? []
        let dataFolder = folder.appendingPathComponent("data")
        var dataFiles: [InventoryDataFile] = []
        var missing: [String] = []

        for entry in entries {
            guard let key = entry["key"] as? String else { continue }
            let name = (key as NSString).lastPathComponent
            let expected = (entry["size"] as? NSNumber)?.int64Value
            let candidates = [dataFolder.appendingPathComponent(name), folder.appendingPathComponent(name)]

            if let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
               let actual = fileSize(url), expected == nil || expected == actual {
                dataFiles.append(InventoryDataFile(url: url, manifestKey: key, expectedSize: expected, actualSize: actual))
            } else {
                missing.append(name)
            }
        }

        let digest = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return InventorySource(
            folder: folder,
            manifestURL: manifestURL,
            sourceBucket: bucket,
            creationTimestampMilliseconds: creation,
            schema: schema,
            dataFiles: dataFiles,
            missingDataFiles: missing,
            manifestMD5: digest
        )
    }

    private static func loadBareFolder(folder: URL) throws -> InventorySource {
        var urls: [URL] = []

        for candidate in [folder, folder.appendingPathComponent("data")] {
            if let contents = try? FileManager.default.contentsOfDirectory(at: candidate, includingPropertiesForKeys: nil) {
                urls.append(contentsOf: contents.filter { $0.lastPathComponent.hasSuffix(".csv.gz") })
            }
        }

        guard !urls.isEmpty else {
            throw ImportError.invalidManifest("no manifest.json and no .csv.gz files in \(folder.path)")
        }

        let dataFiles = urls.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url -> InventoryDataFile? in
            guard let size = fileSize(url) else { return nil }
            return InventoryDataFile(url: url, manifestKey: url.lastPathComponent, expectedSize: nil, actualSize: size)
        }

        return InventorySource(
            folder: folder,
            manifestURL: nil,
            sourceBucket: folder.lastPathComponent,
            creationTimestampMilliseconds: nil,
            schema: .standard,
            dataFiles: dataFiles,
            missingDataFiles: [],
            manifestMD5: nil
        )
    }
}
