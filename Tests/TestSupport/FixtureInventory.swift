import Foundation

/// One inventory row as the fixture builder and the brute-force reference see it.
public struct FixtureRow: Equatable {
    public var key: String              // decoded key
    public var size: UInt64
    public var lastModified: String     // ISO-8601 as the inventory writes it
    public var storageClass: String
    public var isLatest: Bool
    public var isDeleteMarker: Bool

    public init(
        key: String,
        size: UInt64,
        lastModified: String = "2026-01-01T00:00:00.000Z",
        storageClass: String = "STANDARD",
        isLatest: Bool = true,
        isDeleteMarker: Bool = false
    ) {
        self.key = key
        self.size = size
        self.lastModified = lastModified
        self.storageClass = storageClass
        self.isLatest = isLatest
        self.isDeleteMarker = isDeleteMarker
    }
}

import InventoryImport

public enum FixtureInventory {
    /// Percent-encodes every byte except the unreserved characters and '/', the way S3 Inventory does.
    public static func encodeKey(_ key: String) -> String {
        var result = ""
        for byte in key.utf8 {
            let isUnreserved = (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57)
                || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: ".")
                || byte == UInt8(ascii: "~") || byte == UInt8(ascii: "/")

            if isUnreserved {
                result.append(Character(UnicodeScalar(byte)))
            } else {
                result.append(String(format: "%%%02X", byte))
            }
        }

        return result
    }

    /// S3 Inventory orders rows by the DECODED key, so the fixture does the same.
    public static func sortedForInventory(_ rows: [FixtureRow]) -> [FixtureRow] {
        rows.sorted { Array($0.key.utf8).lexicographicallyPrecedes(Array($1.key.utf8)) }
    }

    public static func csvRow(_ row: FixtureRow, bucket: String, schemaColumns: [String]) -> String {
        let values: [String: String] = [
            "Bucket": bucket,
            "Key": encodeKey(row.key),
            "VersionId": "version1",
            "IsLatest": row.isLatest ? "true" : "false",
            "IsDeleteMarker": row.isDeleteMarker ? "true" : "false",
            "Size": row.isDeleteMarker ? "" : String(row.size),
            "LastModifiedDate": row.lastModified,
            "ETag": "etag",
            "StorageClass": row.isDeleteMarker ? "" : row.storageClass,
            "IsMultipartUploaded": "false",
            "ReplicationStatus": "",
            "IntelligentTieringAccessTier": "",
        ]
        return schemaColumns.map { "\"\(values[$0] ?? "")\"" }.joined(separator: ",") + "\n"
    }

    /// Writes manifest.json plus data/<uuid>.csv.gz. Rows are sorted by encoded key and split into contiguous ranges.
    @discardableResult
    public static func write(
        rows: [FixtureRow],
        to folder: URL,
        bucket: String = "fixture-bucket",
        fileCount: Int = 1,
        shuffleManifest: Bool = true,
        schemaColumns: [String] = InventorySchema.defaultColumns,
        creationTimestampMilliseconds: Int64 = 1_767_225_600_000
    ) throws -> URL {
        let dataFolder = folder.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: dataFolder, withIntermediateDirectories: true)
        let sorted = sortedForInventory(rows)
        let rowsPerFile = max(1, Int((Double(sorted.count) / Double(max(fileCount, 1))).rounded(.up)))
        var files: [[String: Any]] = []
        var start = 0

        repeat {
            let slice = sorted[min(start, sorted.count)..<min(start + rowsPerFile, sorted.count)]
            let name = UUID().uuidString.lowercased() + ".csv.gz"
            let url = dataFolder.appendingPathComponent(name)
            let writer = try GzipDeflateWriter(url: url)

            for row in slice {
                try writer.write(csvRow(row, bucket: bucket, schemaColumns: schemaColumns))
            }

            try writer.finish()
            let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! NSNumber).int64Value
            files.append([
                "key": "inventory/\(bucket)/data/\(name)",
                "size": size,
                "MD5checksum": "00000000000000000000000000000000"
            ])
            start += rowsPerFile
        } while start < sorted.count

        if shuffleManifest {
            files.shuffle()
        }

        let manifest: [String: Any] = [
            "sourceBucket": bucket,
            "destinationBucket": "arn:aws:s3:::logs",
            "version": "2016-11-30",
            "creationTimestamp": String(creationTimestampMilliseconds),
            "fileFormat": "CSV",
            "fileSchema": schemaColumns.joined(separator: ", "),
            "files": files,
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted])
        try data.write(to: folder.appendingPathComponent("manifest.json"))
        return folder
    }
}
