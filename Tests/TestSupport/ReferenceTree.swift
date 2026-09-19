import Foundation
import InventoryIndex
import InventoryImport

public final class ReferenceDirectory {
    public let name: String
    public let path: String
    public let identifier: UInt32
    public let parent: UInt32
    public let depth: Int
    public var children: [ReferenceDirectory] = []
    public var ownFiles: [ReferenceFile] = []
    public var fileStart: UInt64

    init(name: String, path: String, identifier: UInt32, parent: UInt32, depth: Int, fileStart: UInt64) {
        self.name = name
        self.path = path
        self.identifier = identifier
        self.parent = parent
        self.depth = depth
        self.fileStart = fileStart
    }

    public var subtreeDirectoryCount: Int { children.reduce(0) { $0 + 1 + $1.subtreeDirectoryCount } }
    public var subtreeFileCount: UInt64 { UInt64(ownFiles.count) + children.reduce(0) { $0 + $1.subtreeFileCount } }
    public var ownBytes: UInt64 { ownFiles.reduce(0) { $0 + $1.size } }
    public var subtreeBytes: UInt64 { ownBytes + children.reduce(0) { $0 + $1.subtreeBytes } }

    public var bytesByStorageClass: [UInt64] {
        var result = [UInt64](repeating: 0, count: 8)

        for file in ownFiles {
            result[Int(file.storageClass)] += file.size
        }

        for child in children {
            let childBytes = child.bytesByStorageClass

            for slot in 0..<8 {
                result[slot] += childBytes[slot]
            }
        }

        return result
    }

    public func ageWeightedBytes(inventoryTimestamp: UInt32) -> UInt64 {
        var total: UInt64 = 0

        for file in ownFiles {
            let ageDays: UInt64 = (file.lastModified == 0 || file.lastModified >= inventoryTimestamp)
                ? 0 : UInt64(inventoryTimestamp - file.lastModified) / 86_400
            total &+= file.size &* ageDays
        }

        return total &+ children.reduce(0) { $0 &+ $1.ageWeightedBytes(inventoryTimestamp: inventoryTimestamp) }
    }

    public var extensionBytes: [UInt16: UInt64] {
        var result: [UInt16: UInt64] = [:]

        for file in ownFiles {
            result[file.extensionIdentifier, default: 0] += file.size
        }

        for child in children {
            for (key, value) in child.extensionBytes {
                result[key, default: 0] += value
            }
        }

        return result
    }

    public var dominantExtension: UInt16 {
        var bestKey: UInt16 = 0
        var bestValue: UInt64 = 0
        var found = false

        for (key, value) in extensionBytes {
            if !found || value > bestValue || (value == bestValue && key < bestKey) {
                bestKey = key
                bestValue = value
                found = true
            }
        }

        return found ? bestKey : 0
    }

    public var childrenBySize: [UInt32] {
        children
            .sorted { $0.subtreeBytes != $1.subtreeBytes ? $0.subtreeBytes > $1.subtreeBytes : $0.identifier < $1.identifier }
            .map { $0.identifier }
    }
}

public struct ReferenceFile: Equatable {
    public var key: String
    public var name: String
    public var size: UInt64
    public var lastModified: UInt32
    public var storageClass: UInt8
    public var extensionIdentifier: UInt16
}

public struct ReferenceTree {
    public let root: ReferenceDirectory
    public let directoriesInPreOrder: [ReferenceDirectory]
    public let filesInKeyOrder: [ReferenceFile]
    public let extensionNames: [String]
    public let skippedNonCurrent: Int
    public let skippedDeleteMarkers: Int

    public static func build(rows: [FixtureRow], inventoryTimestamp: UInt32) -> ReferenceTree {
        let kept = FixtureInventory.sortedForInventory(rows.filter { $0.isLatest && !$0.isDeleteMarker })
        let extensions = ExtensionDictionary()
        let root = ReferenceDirectory(name: "", path: "", identifier: 0, parent: IndexFormat.noParent, depth: 0, fileStart: 0)
        var directories = [root]
        var files: [ReferenceFile] = []
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for row in kept {
            let segments = row.key.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            let name = segments.last ?? ""
            var current = root

            for segment in segments.dropLast() {
                if let existing = current.children.first(where: { $0.name == segment }) {
                    current = existing
                } else {
                    let path = current === root ? segment : current.path + "/" + segment
                    let created = ReferenceDirectory(
                        name: segment,
                        path: path,
                        identifier: UInt32(directories.count),
                        parent: current.identifier,
                        depth: current.depth + 1,
                        fileStart: UInt64(files.count)
                    )
                    directories.append(created)
                    current.children.append(created)
                    current = created
                }
            }

            let lastModified = UInt32(clamping: Int64(formatter.date(from: row.lastModified)?.timeIntervalSince1970 ?? 0))
            let extensionIdentifier = Array(name.utf8).withUnsafeBufferPointer { extensions.identifier(forBasename: $0) }
            let file = ReferenceFile(
                key: row.key,
                name: name,
                size: row.size,
                lastModified: lastModified,
                storageClass: StorageClass.identifier(forInventoryName: row.storageClass),
                extensionIdentifier: extensionIdentifier
            )
            current.ownFiles.append(file)
            files.append(file)
        }

        return ReferenceTree(
            root: root,
            directoriesInPreOrder: directories,
            filesInKeyOrder: files,
            extensionNames: extensions.names,
            skippedNonCurrent: rows.filter { !$0.isLatest }.count,
            skippedDeleteMarkers: rows.filter { $0.isLatest && $0.isDeleteMarker }.count
        )
    }
}

extension FixtureInventory {
    /// Builds chunks the way the parser would: raw encoded keys, skipped rows counted, sorted by encoded key.
    public static func makeChunks(rows: [FixtureRow], rowsPerChunk: Int = 1000, fileIndex: Int = 0) -> [RowChunk] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var chunks: [RowChunk] = []
        var chunk = RowChunk(fileIndex: fileIndex, chunkIndex: 0, capacity: rowsPerChunk)

        for row in sortedForInventory(rows) {
            if !row.isLatest {
                chunk.skippedNonCurrent += 1
                continue
            }

            if row.isDeleteMarker {
                chunk.skippedDeleteMarkers += 1
                continue
            }

            let lastModified = UInt32(clamping: Int64(formatter.date(from: row.lastModified)?.timeIntervalSince1970 ?? 0))
            Array(encodeKey(row.key).utf8).withUnsafeBufferPointer {
                chunk.appendRow(
                    key: $0,
                    size: row.size,
                    lastModified: lastModified,
                    storageClass: StorageClass.identifier(forInventoryName: row.storageClass)
                )
            }

            if chunk.count == rowsPerChunk {
                chunks.append(chunk)
                chunk = RowChunk(fileIndex: fileIndex, chunkIndex: chunks.count, capacity: rowsPerChunk)
            }
        }

        chunks.append(chunk)
        return chunks
    }
}

/// Compares every directory and file of an index against the reference. Returns readable mismatches; empty means equal.
public func indexMismatches(reader: IndexReader, reference: ReferenceTree, inventoryTimestamp: UInt32) -> [String] {
    var problems: [String] = []

    func check<T: Equatable>(_ label: String, _ actual: T, _ expected: T) {
        if actual != expected {
            problems.append("\(label): actual \(actual) expected \(expected)")
        }
    }

    let tree = reader.directories
    check("directoryCount", tree.count, reference.directoriesInPreOrder.count)

    for expected in reference.directoriesInPreOrder where Int(expected.identifier) < tree.count {
        let id = expected.identifier
        let label = "directory \(id) '\(expected.path)'"
        check("\(label) name", tree.name(id), expected.name)
        check("\(label) path", tree.path(id), expected.path)
        check("\(label) parent", tree.parent(id), expected.parent)
        check("\(label) depth", Int(tree.depth(id)), expected.depth)
        check("\(label) childCount", Int(tree.childCount(id)), expected.children.count)
        check("\(label) subtreeDirectoryCount", Int(tree.subtreeDirectoryCount(id)), expected.subtreeDirectoryCount)
        check("\(label) fileStart", tree.fileStart(id), expected.fileStart)
        check("\(label) subtreeFileCount", tree.subtreeFileCount(id), expected.subtreeFileCount)
        check("\(label) subtreeBytes", tree.subtreeBytes(id), expected.subtreeBytes)
        check("\(label) ownFileCount", Int(tree.ownFileCount(id)), expected.ownFiles.count)
        check("\(label) ownBytes", tree.ownBytes(id), expected.ownBytes)
        check("\(label) bytesByStorageClass", tree.bytesByStorageClass(id), expected.bytesByStorageClass)
        check("\(label) ageWeightedBytes", tree.ageWeightedBytes(id), expected.ageWeightedBytes(inventoryTimestamp: inventoryTimestamp))
        check("\(label) childrenInKeyOrder", tree.childrenInKeyOrder(id), expected.children.map { $0.identifier })
        check("\(label) childrenBySize", tree.childrenBySize(id), expected.childrenBySize)
        let ownFileIndices = tree.ownFileRanges(id).flatMap { Array($0) }
        check("\(label) ownFiles", ownFileIndices.map { reader.names.nameString(ofFile: $0) }, expected.ownFiles.map { $0.name })
    }

    check("fileCount", reader.fileCount, reference.filesInKeyOrder.count)

    for (index, expected) in reference.filesInKeyOrder.enumerated() where index < reader.fileCount {
        let label = "file \(index) '\(expected.key)'"
        check("\(label) key", reader.key(ofFile: UInt64(index)), expected.key)
        check("\(label) size", reader.fileSize[index], expected.size)
        check("\(label) lastModified", reader.fileLastModified[index], expected.lastModified)
        check("\(label) storageClass", reader.fileStorageClass[index], expected.storageClass)
        let actualExtension = Int(reader.fileExtension[index]) < reader.manifest.extensionNames.count
            ? reader.manifest.extensionNames[Int(reader.fileExtension[index])] : "?"
        check("\(label) extension", actualExtension, reference.extensionNames[Int(expected.extensionIdentifier)])
    }

    return problems
}
