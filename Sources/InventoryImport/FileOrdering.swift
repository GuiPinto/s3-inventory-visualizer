import Foundation

public enum FileOrdering {
    public static func firstKey(of url: URL, schema: InventorySchema) throws -> [UInt8]? {
        let stream = try GzipInflateStream(url: url, bufferSize: 64 * 1024)
        var collected: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)

        while collected.count < InventoryRowParser.maximumRowLength {
            let produced = try buffer.withUnsafeMutableBufferPointer { try stream.read(into: $0) }

            if produced == 0 {
                break
            }

            collected.append(contentsOf: buffer[0..<produced])

            if collected.contains(UInt8(ascii: "\n")) {
                break
            }
        }

        guard !collected.isEmpty else { return nil }
        let rowEnd = collected.firstIndex(of: UInt8(ascii: "\n")) ?? collected.count
        var row = Array(collected[0..<rowEnd])

        if row.last == UInt8(ascii: "\r") {
            row.removeLast()
        }

        return InventoryRowParser.extractField(row: row, column: schema.keyColumn)
    }

    /// Decodes percent escapes the same way the tree builder does, so the sort key matches the row order.
    public static func decodedKey(_ encoded: [UInt8]) -> [UInt8] {
        var destination = [UInt8](repeating: 0, count: encoded.count)
        let length = encoded.withUnsafeBufferPointer { source in
            destination.withUnsafeMutableBufferPointer { target in
                TreeBuilder.decodePercentEncoding(source, into: target.baseAddress!)
            }
        }

        destination.removeSubrange(length...)
        return destination
    }

    /// Sorts by the DECODED first key, because that is the order S3 Inventory writes rows in.
    public static func sortedByFirstKey(_ files: [InventoryDataFile], schema: InventorySchema) throws -> [InventoryDataFile] {
        var keyed: [(key: [UInt8], file: InventoryDataFile)] = []

        for file in files {
            if let key = try firstKey(of: file.url, schema: schema) {
                keyed.append((decodedKey(key), file))
            }
        }

        keyed.sort { $0.key.lexicographicallyPrecedes($1.key) }
        return keyed.map { $0.file }
    }
}
