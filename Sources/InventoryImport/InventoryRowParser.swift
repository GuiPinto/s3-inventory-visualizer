import Foundation
import InventoryIndex

public struct RowChunk {
    public let fileIndex: Int
    public let chunkIndex: Int
    public var keyBytes: [UInt8] = []
    public var keyOffsets: [UInt32] = [0]
    public var sizes: [UInt64] = []
    public var lastModified: [UInt32] = []
    public var storageClass: [UInt8] = []
    public var needsDecoding: [Bool] = []
    public var skippedNonCurrent = 0
    public var skippedDeleteMarkers = 0
    public var parseErrors = 0
    public var compressedBytesDelta: Int64 = 0

    public var count: Int { sizes.count }

    public init(fileIndex: Int, chunkIndex: Int, capacity: Int) {
        self.fileIndex = fileIndex
        self.chunkIndex = chunkIndex
        keyBytes.reserveCapacity(capacity * 96)
        keyOffsets.reserveCapacity(capacity + 1)
        sizes.reserveCapacity(capacity)
        lastModified.reserveCapacity(capacity)
        storageClass.reserveCapacity(capacity)
        needsDecoding.reserveCapacity(capacity)
    }

    public mutating func appendRow(key: UnsafeBufferPointer<UInt8>, size: UInt64, lastModified: UInt32, storageClass: UInt8) {
        keyBytes.append(contentsOf: key)
        keyOffsets.append(UInt32(keyBytes.count))
        sizes.append(size)
        self.lastModified.append(lastModified)
        self.storageClass.append(storageClass)
        let hasEscape = key.baseAddress.map { memchr($0, Int32(UInt8(ascii: "%")), key.count) != nil } ?? false
        needsDecoding.append(hasEscape)
    }

    public func withKey<R>(_ row: Int, _ body: (UnsafeBufferPointer<UInt8>) throws -> R) rethrows -> R {
        try keyBytes.withUnsafeBufferPointer { buffer in
            let start = Int(keyOffsets[row])
            let end = Int(keyOffsets[row + 1])
            return try body(UnsafeBufferPointer(rebasing: buffer[start..<end]))
        }
    }
}

public final class InventoryRowParser {
    public static let maximumRowLength = 16_384
    public static let maximumParseErrorsPerFile = 1000
    public let schema: InventorySchema
    public let rowsPerChunk: Int
    private let readBufferSize: Int
    private var fieldStarts = [Int](repeating: 0, count: 33)
    private var fieldLengths = [Int](repeating: 0, count: 33)
    private var fieldEscaped = [Bool](repeating: false, count: 33)
    private var unescapeScratch: [UInt8] = []
    private var parseErrorsInFile = 0

    private static let fallbackFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public init(schema: InventorySchema, rowsPerChunk: Int = 262_144, readBufferSize: Int = 4 << 20) {
        self.schema = schema
        self.rowsPerChunk = rowsPerChunk
        self.readBufferSize = max(readBufferSize, 64)
    }

    public func parse(stream: GzipInflateStream, fileIndex: Int, emit: (RowChunk) throws -> Void) throws {
        let capacity = readBufferSize + InventoryRowParser.maximumRowLength
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        let fileName = stream.url.lastPathComponent
        parseErrorsInFile = 0
        var carry = 0
        var chunkIndex = 0
        var chunk = RowChunk(fileIndex: fileIndex, chunkIndex: 0, capacity: rowsPerChunk)
        var compressedAtLastEmit: Int64 = 0

        while true {
            let produced = try stream.read(into: UnsafeMutableBufferPointer(start: buffer + carry, count: capacity - carry))

            if produced == 0 {
                if carry > 0 {
                    try parseRow(UnsafeBufferPointer(start: buffer, count: carry), into: &chunk, fileName: fileName)
                }

                break
            }

            let end = carry + produced
            var rowStart = 0

            while let found = memchr(buffer + rowStart, Int32(UInt8(ascii: "\n")), end - rowStart) {
                let newlineIndex = UnsafeRawPointer(found) - UnsafeRawPointer(buffer)
                var rowEnd = newlineIndex

                if rowEnd > rowStart && buffer[rowEnd - 1] == UInt8(ascii: "\r") {
                    rowEnd -= 1
                }

                try parseRow(UnsafeBufferPointer(start: buffer + rowStart, count: rowEnd - rowStart), into: &chunk, fileName: fileName)
                rowStart = newlineIndex + 1

                if chunk.count == rowsPerChunk {
                    chunk.compressedBytesDelta = stream.compressedBytesRead - compressedAtLastEmit
                    compressedAtLastEmit = stream.compressedBytesRead
                    try emit(chunk)
                    chunkIndex += 1
                    chunk = RowChunk(fileIndex: fileIndex, chunkIndex: chunkIndex, capacity: rowsPerChunk)
                }
            }

            carry = end - rowStart

            guard carry < InventoryRowParser.maximumRowLength else { throw ImportError.rowTooLong(file: fileName) }

            if carry > 0 {
                memmove(buffer, buffer + rowStart, carry)
            }
        }

        chunk.compressedBytesDelta = stream.compressedBytesRead - compressedAtLastEmit
        try emit(chunk)
    }

    private func parseRow(_ row: UnsafeBufferPointer<UInt8>, into chunk: inout RowChunk, fileName: String) throws {
        if row.isEmpty {
            return
        }

        guard let fieldCount = splitFields(row), fieldCount >= schema.requiredFieldCount else {
            try recordParseError(&chunk, fileName: fileName)
            return
        }

        if let column = schema.isLatestColumn, fieldLengths[column] == 5, row[fieldStarts[column]] == UInt8(ascii: "f") {
            chunk.skippedNonCurrent += 1
            return
        }

        if let column = schema.isDeleteMarkerColumn, fieldLengths[column] == 4, row[fieldStarts[column]] == UInt8(ascii: "t") {
            chunk.skippedDeleteMarkers += 1
            return
        }

        var size: UInt64 = 0
        let sizeStart = fieldStarts[schema.sizeColumn]
        let sizeLength = fieldLengths[schema.sizeColumn]

        for index in sizeStart..<(sizeStart + sizeLength) {
            let digit = row[index] &- 48

            guard digit <= 9 else {
                try recordParseError(&chunk, fileName: fileName)
                return
            }

            size = size &* 10 &+ UInt64(digit)
        }

        var lastModified: UInt32 = 0

        if let column = schema.lastModifiedColumn, fieldLengths[column] > 0 {
            let field = UnsafeBufferPointer(rebasing: row[fieldStarts[column]..<(fieldStarts[column] + fieldLengths[column])])

            if let fast = InventoryRowParser.parseISO8601Seconds(field) {
                lastModified = fast
            } else if let date = InventoryRowParser.fallbackFormatter.date(from: String(decoding: field, as: UTF8.self)) {
                lastModified = UInt32(clamping: Int64(date.timeIntervalSince1970))
            }
        }

        var storageClass = StorageClass.other.rawValue

        if let column = schema.storageClassColumn {
            let field = UnsafeBufferPointer(rebasing: row[fieldStarts[column]..<(fieldStarts[column] + fieldLengths[column])])
            storageClass = StorageClass.identifier(forInventoryName: field)
        }

        let keyStart = fieldStarts[schema.keyColumn]
        let keyLength = fieldLengths[schema.keyColumn]

        if fieldEscaped[schema.keyColumn] {
            unescapeScratch.removeAll(keepingCapacity: true)
            var index = keyStart
            let end = keyStart + keyLength

            while index < end {
                unescapeScratch.append(row[index])
                index += row[index] == UInt8(ascii: "\"") ? 2 : 1
            }

            unescapeScratch.withUnsafeBufferPointer {
                chunk.appendRow(key: $0, size: size, lastModified: lastModified, storageClass: storageClass)
            }
        } else {
            let key = UnsafeBufferPointer(rebasing: row[keyStart..<(keyStart + keyLength)])
            chunk.appendRow(key: key, size: size, lastModified: lastModified, storageClass: storageClass)
        }
    }

    private func recordParseError(_ chunk: inout RowChunk, fileName: String) throws {
        chunk.parseErrors += 1
        parseErrorsInFile += 1

        if parseErrorsInFile > InventoryRowParser.maximumParseErrorsPerFile {
            throw ImportError.tooManyParseErrors(file: fileName, count: parseErrorsInFile)
        }
    }

    /// Fills fieldStarts, fieldLengths and fieldEscaped; returns the field count, or nil for a malformed row.
    private func splitFields(_ row: UnsafeBufferPointer<UInt8>) -> Int? {
        guard let base = row.baseAddress else { return nil }
        let quote = UInt8(ascii: "\"")
        let comma = UInt8(ascii: ",")
        let count = row.count
        var cursor = 0
        var fieldCount = 0

        while fieldCount < 32 {
            if cursor < count && row[cursor] == quote {
                cursor += 1
                let start = cursor
                var escaped = false

                while true {
                    guard cursor <= count, let found = memchr(base + cursor, Int32(quote), count - cursor) else { return nil }
                    let index = UnsafeRawPointer(found) - UnsafeRawPointer(base)

                    if index + 1 < count && row[index + 1] == quote {
                        escaped = true
                        cursor = index + 2
                        continue
                    }

                    cursor = index
                    break
                }

                fieldStarts[fieldCount] = start
                fieldLengths[fieldCount] = cursor - start
                fieldEscaped[fieldCount] = escaped
                cursor += 1
            } else {
                let start = cursor

                if let found = memchr(base + cursor, Int32(comma), count - cursor) {
                    cursor = UnsafeRawPointer(found) - UnsafeRawPointer(base)
                } else {
                    cursor = count
                }

                fieldStarts[fieldCount] = start
                fieldLengths[fieldCount] = cursor - start
                fieldEscaped[fieldCount] = false
            }

            fieldCount += 1

            if cursor < count && row[cursor] == comma {
                cursor += 1

                if cursor == count && fieldCount < 32 {
                    fieldStarts[fieldCount] = count
                    fieldLengths[fieldCount] = 0
                    fieldEscaped[fieldCount] = false
                    fieldCount += 1
                    break
                }
            } else {
                break
            }
        }

        return fieldCount
    }

    public static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let shiftedYear = month <= 2 ? year - 1 : year
        let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
        let yearOfEra = shiftedYear - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// Fast path for "YYYY-MM-DDTHH:MM:SS[.fff]Z". Returns nil for any other shape.
    public static func parseISO8601Seconds(_ bytes: UnsafeBufferPointer<UInt8>) -> UInt32? {
        guard bytes.count >= 19, bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"),
              bytes[10] == UInt8(ascii: "T"), bytes[13] == UInt8(ascii: ":"), bytes[16] == UInt8(ascii: ":") else { return nil }

        func digits(_ start: Int, _ count: Int) -> Int? {
            var value = 0

            for index in start..<(start + count) {
                let digit = Int(bytes[index]) - 48

                guard digit >= 0 && digit <= 9 else { return nil }
                value = value * 10 + digit
            }

            return value
        }

        guard let year = digits(0, 4), let month = digits(5, 2), let day = digits(8, 2),
              let hour = digits(11, 2), let minute = digits(14, 2), let second = digits(17, 2),
              month >= 1, month <= 12, day >= 1, day <= 31, hour <= 23, minute <= 59, second <= 60 else { return nil }
        let total = daysFromCivil(year: year, month: month, day: day) * 86_400 + hour * 3600 + minute * 60 + second

        guard total >= 0 && total <= Int(UInt32.max) else { return nil }
        return UInt32(total)
    }

    /// Allocation-friendly field extraction for one row. Used to read the first key of a file.
    public static func extractField(row: [UInt8], column: Int) -> [UInt8]? {
        let parser = InventoryRowParser(schema: .standard)
        let fieldCount = row.withUnsafeBufferPointer { parser.splitFields($0) }

        guard let fieldCount, column < fieldCount else { return nil }
        let start = parser.fieldStarts[column]
        let length = parser.fieldLengths[column]
        var bytes = Array(row[start..<(start + length)])

        if parser.fieldEscaped[column] {
            var result: [UInt8] = []
            var index = 0

            while index < bytes.count {
                result.append(bytes[index])
                index += bytes[index] == UInt8(ascii: "\"") ? 2 : 1
            }

            bytes = result
        }

        return bytes
    }
}
