import Foundation
import InventoryIndex

public enum InstanceKind: UInt8 {
    case directoryLeaf = 0
    case file = 1
    case remainder = 2
}

/// Matches `struct TreemapInstance` in App/Sources/Treemap/Shaders.metal byte for byte (48 bytes).
public struct TreemapInstance {
    public var x: Float
    public var y: Float
    public var width: Float
    public var height: Float
    public var sxx: Float
    public var sx: Float
    public var syy: Float
    public var sy: Float
    public var directoryId: UInt32
    public var nodeReference: UInt32
    public var timeSeconds: UInt32
    public var extensionId: UInt16
    public var storageClassId: UInt8
    public var kind: UInt8

    /// Which child of the view root this cell sits under, ranked by size. `TreemapInstance.noGroup`
    /// means the cell belongs to the view root itself. Drives the colour by folder mode.
    public var groupId: UInt16
    public var groupPadding: UInt16 = 0

    public static let noGroup: UInt16 = 0xFFFF

    public func contains(x pointX: Double, y pointY: Double) -> Bool {
        pointX >= Double(x) && pointX < Double(x + width) && pointY >= Double(y) && pointY < Double(y + height)
    }
}

public struct HitTestNode {
    public var rect: LayoutRect
    public var directoryId: UInt32
    public var childNodes: [Int] = []
    public var ownFileInstances: Range<Int> = 0..<0
    public var remainderInstance: Int = -1
    public var leafInstance: Int = -1

    public init(rect: LayoutRect, directoryId: UInt32, leafInstance: Int = -1) {
        self.rect = rect
        self.directoryId = directoryId
        self.leafInstance = leafInstance
    }
}

public struct LayoutLabel: Equatable {
    public var directoryId: UInt32
    public var rect: LayoutRect
    public var text: String
}

public struct LayoutRequest: Hashable {
    public var rootDirectory: UInt32
    public var width: Double
    public var height: Double
    public var minimumCellArea: Double

    public init(rootDirectory: UInt32, width: Double, height: Double, minimumCellArea: Double) {
        self.rootDirectory = rootDirectory
        self.width = width
        self.height = height
        self.minimumCellArea = minimumCellArea
    }
}

public enum LayoutHit: Equatable {
    case file(fileIndex: UInt64, instance: Int, directory: UInt32)
    case directory(id: UInt32, instance: Int?)
    case remainder(directory: UInt32, instance: Int, itemCount: UInt64, bytes: UInt64)
}

public struct DirectoryLeafAttributes {
    public var storageClass: UInt8
    public var extensionId: UInt16
    public var timeSeconds: UInt32

    public init(storageClass: UInt8, extensionId: UInt16, timeSeconds: UInt32) {
        self.storageClass = storageClass
        self.extensionId = extensionId
        self.timeSeconds = timeSeconds
    }
}

public struct FileLeafAttributes {
    public var storageClass: UInt8
    public var extensionId: UInt16
    public var lastModified: UInt32

    public init(storageClass: UInt8, extensionId: UInt16, lastModified: UInt32) {
        self.storageClass = storageClass
        self.extensionId = extensionId
        self.lastModified = lastModified
    }
}

public protocol LayoutDataSource: AnyObject {
    func subtreeBytes(of directory: UInt32) -> UInt64
    func subtreeFileCount(of directory: UInt32) -> UInt64
    func subtreeDirectoryCount(of directory: UInt32) -> UInt32
    func childrenBySize(of directory: UInt32) -> [UInt32]

    /// Visits the children sorted by size without copying them out of the index.
    func withChildrenBySize<R>(of directory: UInt32, _ body: (UnsafeBufferPointer<UInt32>) -> R) -> R

    /// Visits the children sorted by size together with their subtree byte counts.
    func withChildrenBySizeAndBytes<R>(
        of directory: UInt32,
        _ body: (UnsafeBufferPointer<UInt32>, UnsafeBufferPointer<UInt64>) -> R
    ) -> R
    func ownFiles(of directory: UInt32, atLeast threshold: UInt64) -> OwnFilesSelection

    /// The largest `count` own files. Used when every file is too small to pass the pixel threshold.
    func largestOwnFiles(of directory: UInt32, count: Int) -> OwnFilesSelection

    func directoryAttributes(_ id: UInt32) -> DirectoryLeafAttributes

    func fileAttributes(_ index: UInt64) -> FileLeafAttributes

    func directoryName(_ id: UInt32) -> String
}

public extension LayoutDataSource {
    /// Default for sources that only implement the copying accessor.
    func withChildrenBySize<R>(of directory: UInt32, _ body: (UnsafeBufferPointer<UInt32>) -> R) -> R {
        var children = childrenBySize(of: directory)
        return children.withUnsafeMutableBufferPointer { body(UnsafeBufferPointer($0)) }
    }

    func withChildrenBySizeAndBytes<R>(
        of directory: UInt32,
        _ body: (UnsafeBufferPointer<UInt32>, UnsafeBufferPointer<UInt64>) -> R
    ) -> R {
        var children = childrenBySize(of: directory)
        var bytes = children.map { subtreeBytes(of: $0) }
        return children.withUnsafeMutableBufferPointer { childBuffer in
            bytes.withUnsafeMutableBufferPointer { byteBuffer in
                body(UnsafeBufferPointer(childBuffer), UnsafeBufferPointer(byteBuffer))
            }
        }
    }
}

public struct LayoutResult {
    public var request: LayoutRequest
    public var instances: [TreemapInstance]
    public var nodes: [HitTestNode]
    public var labels: [LayoutLabel]
    public var remainderCounts: [Int: (items: UInt64, bytes: UInt64)]
    public var elapsedSeconds: Double
    private var nodeByDirectory: [UInt32: Int]

    init(
        request: LayoutRequest,
        instances: [TreemapInstance],
        nodes: [HitTestNode],
        labels: [LayoutLabel],
        remainderCounts: [Int: (items: UInt64, bytes: UInt64)],
        elapsedSeconds: Double
    ) {
        self.request = request
        self.instances = instances
        self.nodes = nodes
        self.labels = labels
        self.remainderCounts = remainderCounts
        self.elapsedSeconds = elapsedSeconds
        var byDirectory: [UInt32: Int] = [:]

        for (index, node) in nodes.enumerated() where node.leafInstance < 0 {
            byDirectory[node.directoryId] = index
        }

        nodeByDirectory = byDirectory
    }

    public func node(forDirectory directory: UInt32) -> Int? {
        nodeByDirectory[directory]
    }

    /// The rectangle a selection should be outlined with: the directory's own node rect, its flat
    /// cell when it was too small to recurse, or the file's own cell.
    public func selectionRect(directory: UInt32, file: UInt64?) -> LayoutRect? {
        if let file {
            if let nodeIndex = nodeByDirectory[directory] {
                for instance in nodes[nodeIndex].ownFileInstances
                where UInt64(instances[instance].nodeReference) == file {
                    return rect(of: instances[instance])
                }
            }

            for instance in instances
            where instance.kind == InstanceKind.file.rawValue
                && instance.directoryId == directory
                && UInt64(instance.nodeReference) == file {
                return rect(of: instance)
            }

            return nil
        }

        if let nodeIndex = nodeByDirectory[directory] {
            return nodes[nodeIndex].rect
        }

        for node in nodes where node.directoryId == directory && node.leafInstance >= 0 {
            return node.rect
        }

        return nil
    }

    private func rect(of instance: TreemapInstance) -> LayoutRect {
        LayoutRect(
            x: Double(instance.x),
            y: Double(instance.y),
            width: Double(instance.width),
            height: Double(instance.height)
        )
    }

    public func hitTest(x: Double, y: Double) -> LayoutHit? {
        guard !nodes.isEmpty, nodes[0].rect.contains(x: x, y: y) else { return nil }
        var nodeIndex = 0

        while true {
            let node = nodes[nodeIndex]

            if node.leafInstance >= 0 {
                return .directory(id: node.directoryId, instance: node.leafInstance)
            }

            if let child = node.childNodes.first(where: { nodes[$0].rect.contains(x: x, y: y) }) {
                nodeIndex = child
                continue
            }

            for instance in node.ownFileInstances where instances[instance].contains(x: x, y: y) {
                return .file(
                    fileIndex: UInt64(instances[instance].nodeReference),
                    instance: instance,
                    directory: node.directoryId
                )
            }

            if node.remainderInstance >= 0, instances[node.remainderInstance].contains(x: x, y: y) {
                let counts = remainderCounts[nodeIndex] ?? (0, 0)
                return .remainder(
                    directory: node.directoryId,
                    instance: node.remainderInstance,
                    itemCount: counts.items,
                    bytes: counts.bytes
                )
            }

            return .directory(id: node.directoryId, instance: nil)
        }
    }
}
