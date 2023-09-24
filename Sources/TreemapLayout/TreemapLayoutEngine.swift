import Foundation
import InventoryIndex

public final class TreemapLayoutEngine {
    /// A directory recurses only when its rect could hold about this many minimum cells. Below that the
    /// recursed picture is visually indistinguishable from one flat cell, and each extra node costs a
    /// scattered read across the whole directory index.
    public static let minimumCellsToRecurse = 16.0

    /// A directory whose files are all tiny relative to the whole would otherwise draw as one remainder
    /// cell, which tells the reader nothing. At the view root only, at least this many of its largest items
    /// are placed so the biggest contributors stay visible. Applying it at every nesting level instead would
    /// multiply the guarantee by the node count and force millions of sub-pixel cells.
    public static let minimumItemsToPlace = 2048
    public static let minimumDirectoryAreaForRecursion = 16.0
    public static let cellInset = 0.5
    public static let labelMinimumWidth = 64.0
    public static let labelMinimumHeight = 16.0
    public static let maximumLabels = 400

    private let dataSource: LayoutDataSource
    private var instances: [TreemapInstance] = []
    private var nodes: [HitTestNode] = []
    private var labels: [LayoutLabel] = []
    private var remainderCounts: [Int: (items: UInt64, bytes: UInt64)] = [:]
    private var request = LayoutRequest(rootDirectory: 0, width: 0, height: 0, minimumCellArea: 4)

    /// One reusable set of buffers per recursion level. The tree is at most a few dozen levels deep,
    /// so this removes almost every allocation from the hot path.
    private struct LevelScratch {
        var items: [Item] = []
        var weights: [Double] = []
        var rects: [LayoutRect] = []
    }

    private var scratch: [LevelScratch] = []

    /// Children deferred for the parallel pass, with the node they hang from.
    struct DeferredSubtree {
        var child: UInt32
        var rect: LayoutRect
        var cushion: CushionCoefficients
        var level: Int
        var parentNodeIndex: Int
        var group: UInt16
    }

    private var parallelChildren: [DeferredSubtree] = []

    /// The recursion depth at which children are handed to the parallel pass. -1 disables deferral,
    /// which is what the worker engines use so they lay out their subtree completely.
    private var deferralLevel = -1

    /// Lays the top level's subtrees out on every core. Set to false to measure the single threaded path.
    public var parallelismEnabled = true

    public init(dataSource: LayoutDataSource) { self.dataSource = dataSource }

    /// One subtree laid out into its own buffers, with node and instance indices local to itself.
    struct PartialLayout {
        var instances: [TreemapInstance] = []
        var nodes: [HitTestNode] = []
        var labels: [LayoutLabel] = []
        var remainderCounts: [Int: (items: UInt64, bytes: UInt64)] = [:]

        /// Where each laid out subtree starts, and which node of the caller it hangs from.
        var subtreeRoots: [(localNodeIndex: Int, parentNodeIndex: Int)] = []
    }

    /// Lays out a batch of subtrees into one set of buffers, so a worker merges once instead of once
    /// per subtree. Thousands of tiny partials cost far more in merging than they save in parallelism.
    func layoutSubtrees(_ entries: [DeferredSubtree], request: LayoutRequest) -> PartialLayout {
        self.request = request
        instances = []
        nodes = []
        labels = []
        remainderCounts = [:]

        if scratch.isEmpty {
            scratch = (0..<64).map { _ in LevelScratch() }
        }

        deferralLevel = -1
        var roots: [(localNodeIndex: Int, parentNodeIndex: Int)] = []
        roots.reserveCapacity(entries.count)

        for entry in entries {
            let localRoot = nodes.count
            nodes.append(HitTestNode(rect: entry.rect, directoryId: entry.child))

            if entry.rect.width >= TreemapLayoutEngine.labelMinimumWidth,
               entry.rect.height >= TreemapLayoutEngine.labelMinimumHeight {
                labels.append(LayoutLabel(
                    directoryId: entry.child,
                    rect: entry.rect,
                    text: dataSource.directoryName(entry.child)
                ))
            }

            layoutDirectory(
                entry.child,
                rect: entry.rect,
                level: entry.level,
                cushion: entry.cushion,
                nodeIndex: localRoot,
                group: entry.group
            )
            roots.append((localRoot, entry.parentNodeIndex))
        }

        return PartialLayout(
            instances: instances,
            nodes: nodes,
            labels: labels,
            remainderCounts: remainderCounts,
            subtreeRoots: roots
        )
    }

    /// Appends a worker's buffers, rewriting its local indices into this engine's global ones.
    private func merge(_ partial: PartialLayout) {
        let nodeOffset = nodes.count
        let instanceOffset = instances.count
        nodes.reserveCapacity(nodes.count + partial.nodes.count)

        for var node in partial.nodes {
            for index in node.childNodes.indices {
                node.childNodes[index] += nodeOffset
            }

            node.ownFileInstances = (node.ownFileInstances.lowerBound + instanceOffset)
                ..< (node.ownFileInstances.upperBound + instanceOffset)

            if node.remainderInstance >= 0 {
                node.remainderInstance += instanceOffset
            }

            if node.leafInstance >= 0 {
                node.leafInstance += instanceOffset
            }

            nodes.append(node)
        }

        instances.reserveCapacity(instances.count + partial.instances.count)
        instances.append(contentsOf: partial.instances)
        labels.append(contentsOf: partial.labels)

        for (localNode, counts) in partial.remainderCounts {
            remainderCounts[localNode + nodeOffset] = counts
        }

        for root in partial.subtreeRoots {
            nodes[root.parentNodeIndex].childNodes.append(root.localNodeIndex + nodeOffset)
        }
    }

    public func layout(_ request: LayoutRequest) -> LayoutResult {
        let started = DispatchTime.now()
        self.request = request
        instances = []
        nodes = []
        labels = []
        remainderCounts = [:]
        let budget = Int(request.width * request.height / max(request.minimumCellArea, 1))
        instances.reserveCapacity(min(max(budget / 2, 1024), 2_000_000))

        if scratch.isEmpty {
            scratch = (0..<64).map { _ in LevelScratch() }
        }

        parallelChildren = []
        deferralLevel = parallelismEnabled ? 0 : -1
        let rootRect = LayoutRect(x: 0, y: 0, width: request.width, height: request.height)
        nodes.append(HitTestNode(rect: rootRect, directoryId: request.rootDirectory))
        layoutDirectory(request.rootDirectory, rect: rootRect, level: 0, cushion: CushionCoefficients(), nodeIndex: 0)

        // A root with one or two fat children gains nothing from splitting at the top. Descend, laying
        // out each level in place, until there are enough independent subtrees to keep the cores busy.
        let workerCount = max(1, ProcessInfo.processInfo.activeProcessorCount)
        var descents = 0

        while parallelChildren.count < workerCount, parallelChildren.count > 0, descents < 4 {
            let pending = parallelChildren
            parallelChildren = []
            deferralLevel += 1
            descents += 1

            for entry in pending {
                let childNodeIndex = nodes.count
                nodes.append(HitTestNode(rect: entry.rect, directoryId: entry.child))
                nodes[entry.parentNodeIndex].childNodes.append(childNodeIndex)

                if entry.rect.width >= TreemapLayoutEngine.labelMinimumWidth,
                   entry.rect.height >= TreemapLayoutEngine.labelMinimumHeight,
                   labels.count < TreemapLayoutEngine.maximumLabels {
                    labels.append(LayoutLabel(
                        directoryId: entry.child,
                        rect: entry.rect,
                        text: dataSource.directoryName(entry.child)
                    ))
                }

                layoutDirectory(
                    entry.child,
                    rect: entry.rect,
                    level: entry.level,
                    cushion: entry.cushion,
                    nodeIndex: childNodeIndex,
                    group: entry.group
                )
            }

            if parallelChildren.isEmpty {
                break
            }
        }

        if !parallelChildren.isEmpty {
            let pending = parallelChildren
            parallelChildren = []
            deferralLevel = -1
            let workers = max(1, min(workerCount, pending.count))

            // Each worker takes a strided slice, so the batches stay similar in total size.
            var batches = [[DeferredSubtree]](repeating: [], count: workers)

            for (position, entry) in pending.enumerated() {
                batches[position % workers].append(entry)
            }

            var partials = [PartialLayout?](repeating: nil, count: workers)
            let resultLock = NSLock()

            if workers == 1 {
                partials[0] = TreemapLayoutEngine(dataSource: dataSource).layoutSubtrees(batches[0], request: request)
            } else {
                let engines = (0..<workers).map { _ in TreemapLayoutEngine(dataSource: dataSource) }
                DispatchQueue.concurrentPerform(iterations: workers) { worker in
                    let partial = engines[worker].layoutSubtrees(batches[worker], request: request)
                    resultLock.lock()
                    partials[worker] = partial
                    resultLock.unlock()
                }
            }

            for partial in partials {
                guard let partial else { continue }
                merge(partial)
            }
        }

        deferralLevel = -1

        // Each parallel engine applies the label cap to itself, so the merged total is trimmed here.
        if labels.count > TreemapLayoutEngine.maximumLabels {
            labels.sort { $0.rect.area > $1.rect.area }
            labels.removeSubrange(TreemapLayoutEngine.maximumLabels...)
        }

        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e9
        return LayoutResult(
            request: request,
            instances: instances,
            nodes: nodes,
            labels: labels,
            remainderCounts: remainderCounts,
            elapsedSeconds: elapsed
        )
    }

    private enum Item {
        case directory(UInt32, UInt64)
        case file(UInt64, UInt64)
    }

    private func layoutDirectory(
        _ directory: UInt32,
        rect: LayoutRect,
        level: Int,
        cushion: CushionCoefficients,
        nodeIndex: Int,
        group: UInt16 = TreemapInstance.noGroup
    ) {
        let subtreeBytes = dataSource.subtreeBytes(of: directory)
        let inner = rect.insetBy(TreemapLayoutEngine.cellInset)

        guard subtreeBytes > 0, inner.area >= 1 else { return }
        let rawThreshold = request.minimumCellArea * Double(subtreeBytes) / inner.area
        let threshold = UInt64(max(rawThreshold.rounded(.up), 1))
        let recursionArea = max(
            TreemapLayoutEngine.minimumDirectoryAreaForRecursion,
            request.minimumCellArea * TreemapLayoutEngine.minimumCellsToRecurse
        )
        let guaranteedItems = level == 0 ? TreemapLayoutEngine.minimumItemsToPlace : 0
        var ownFiles = dataSource.ownFiles(of: directory, atLeast: threshold)

        if guaranteedItems > 0 {
            let childCount = dataSource.withChildrenBySize(of: directory) { $0.count }

            if ownFiles.fileIndices.count + childCount < guaranteedItems,
               ownFiles.ownFileCount > UInt64(ownFiles.fileIndices.count) {
                ownFiles = dataSource.largestOwnFiles(of: directory, count: guaranteedItems)
            }
        }

        let scratchLevel = min(level, scratch.count - 1)
        var items = scratch[scratchLevel].items
        var weights = scratch[scratchLevel].weights
        var rects = scratch[scratchLevel].rects
        items.removeAll(keepingCapacity: true)
        weights.removeAll(keepingCapacity: true)

        var placedBytes: UInt64 = 0
        var placedItems: UInt64 = 0
        dataSource.withChildrenBySizeAndBytes(of: directory) { children, childBytesColumn in
            var childCursor = 0
            var fileCursor = 0

            while true {
                let childBytes = childCursor < children.count ? childBytesColumn[childCursor] : 0
                let fileBytes = fileCursor < ownFiles.sizes.count ? ownFiles.sizes[fileCursor] : 0

                if childBytes == 0 && fileBytes == 0 {
                    break
                }

                let takeChild = childBytes >= fileBytes
                let bytes = takeChild ? childBytes : fileBytes

                // Stop at the pixel threshold, but never before the guaranteed minimum number of cells.
                if bytes < threshold && items.count >= guaranteedItems {
                    break
                }

                if takeChild {
                    let child = children[childCursor]
                    items.append(.directory(child, bytes))
                    placedItems += dataSource.subtreeFileCount(of: child)
                        + UInt64(dataSource.subtreeDirectoryCount(of: child)) + 1
                    childCursor += 1
                } else {
                    items.append(.file(ownFiles.fileIndices[fileCursor], bytes))
                    placedItems += 1
                    fileCursor += 1
                }

                placedBytes += bytes
            }
        }

        let remainderBytes = subtreeBytes > placedBytes ? subtreeBytes - placedBytes : 0
        let totalItems = dataSource.subtreeFileCount(of: directory) + UInt64(dataSource.subtreeDirectoryCount(of: directory))

        for item in items {
            switch item {
            case .directory(_, let bytes): weights.append(Double(bytes))
            case .file(_, let bytes): weights.append(Double(bytes))
            }
        }

        if remainderBytes > 0 {
            weights.append(Double(remainderBytes))
        }

        Squarify.layout(weights: weights, in: inner, into: &rects)
        scratch[scratchLevel].items = items
        scratch[scratchLevel].weights = weights
        scratch[scratchLevel].rects = rects
        let childHeight = CushionCoefficients.height(atLevel: level + 1)

        let fileInstancesStart = instances.count

        for (itemIndex, item) in items.enumerated() {
            guard case .file(let fileIndex, _) = item else { continue }
            let cellRect = rects[itemIndex]
            let attributes = dataSource.fileAttributes(fileIndex)
            appendInstance(
                rect: cellRect,
                cushion: cushion.adding(rect: cellRect, height: childHeight),
                directoryId: directory,
                nodeReference: UInt32(truncatingIfNeeded: fileIndex),
                timeSeconds: attributes.lastModified,
                extensionId: attributes.extensionId,
                storageClass: attributes.storageClass,
                kind: .file,
                group: group
            )
        }

        nodes[nodeIndex].ownFileInstances = fileInstancesStart..<instances.count

        var groupRank: UInt16 = 0

        for (itemIndex, item) in items.enumerated() {
            guard case .directory(let child, _) = item else { continue }
            let cellRect = rects[itemIndex]
            let cellCushion = cushion.adding(rect: cellRect, height: childHeight)

            // Only the children of the view root open a new colour group; everything deeper inherits it.
            var childGroup = group

            if level == 0 {
                childGroup = groupRank

                if groupRank < UInt16.max - 1 {
                    groupRank += 1
                }
            }

            if cellRect.area >= recursionArea {
                if level != deferralLevel,
                   cellRect.width >= TreemapLayoutEngine.labelMinimumWidth,
                   cellRect.height >= TreemapLayoutEngine.labelMinimumHeight,
                   labels.count < TreemapLayoutEngine.maximumLabels {
                    labels.append(LayoutLabel(directoryId: child, rect: cellRect, text: dataSource.directoryName(child)))
                }

                if level == deferralLevel {
                    parallelChildren.append(DeferredSubtree(
                        child: child,
                        rect: cellRect,
                        cushion: cellCushion,
                        level: level + 1,
                        parentNodeIndex: nodeIndex,
                        group: childGroup
                    ))
                } else {
                    let childNodeIndex = nodes.count
                    nodes.append(HitTestNode(rect: cellRect, directoryId: child))
                    nodes[nodeIndex].childNodes.append(childNodeIndex)
                    layoutDirectory(
                        child,
                        rect: cellRect,
                        level: level + 1,
                        cushion: cellCushion,
                        nodeIndex: childNodeIndex,
                        group: childGroup
                    )
                }
            } else {
                let attributes = dataSource.directoryAttributes(child)
                let leafNodeIndex = nodes.count
                nodes.append(HitTestNode(rect: cellRect, directoryId: child, leafInstance: instances.count))
                nodes[nodeIndex].childNodes.append(leafNodeIndex)
                appendInstance(
                    rect: cellRect,
                    cushion: cellCushion,
                    directoryId: child,
                    nodeReference: child,
                    timeSeconds: attributes.timeSeconds,
                    extensionId: attributes.extensionId,
                    storageClass: attributes.storageClass,
                    kind: .directoryLeaf,
                    group: childGroup
                )
            }
        }

        if remainderBytes > 0, let remainderRect = rects.last {
            let attributes = dataSource.directoryAttributes(directory)
            nodes[nodeIndex].remainderInstance = instances.count
            remainderCounts[nodeIndex] = (totalItems > placedItems ? totalItems - placedItems : 0, remainderBytes)
            appendInstance(
                rect: remainderRect,
                cushion: cushion.adding(rect: remainderRect, height: childHeight),
                directoryId: directory,
                nodeReference: directory,
                timeSeconds: attributes.timeSeconds,
                extensionId: attributes.extensionId,
                storageClass: attributes.storageClass,
                kind: .remainder,
                group: group
            )
        }
    }

    private func appendInstance(
        rect: LayoutRect,
        cushion: CushionCoefficients,
        directoryId: UInt32,
        nodeReference: UInt32,
        timeSeconds: UInt32,
        extensionId: UInt16,
        storageClass: UInt8,
        kind: InstanceKind,
        group: UInt16
    ) {
        let local = cushion.localized(toOriginX: rect.x, y: rect.y)
        instances.append(TreemapInstance(
            x: Float(rect.x),
            y: Float(rect.y),
            width: Float(rect.width),
            height: Float(rect.height),
            sxx: local.sxx,
            sx: local.sx,
            syy: local.syy,
            sy: local.sy,
            directoryId: directoryId,
            nodeReference: nodeReference,
            timeSeconds: timeSeconds,
            extensionId: extensionId,
            storageClassId: storageClass,
            kind: kind.rawValue,
            groupId: group
        ))
    }
}
