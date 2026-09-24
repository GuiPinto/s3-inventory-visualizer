import AppKit
import InventoryIndex
import TreemapLayout

protocol TreemapViewControllerDelegate: AnyObject {
    func treemapDidSelect(directory: UInt32, file: UInt64?)

    func treemapDidChangeRoot(_ directory: UInt32)
}

final class TreemapViewController: NSViewController {
    weak var delegate: TreemapViewControllerDelegate?

    private let reader: IndexReader
    private let engine: TreemapLayoutEngine
    private let aggregates: SubtreeAggregates
    private let history: NavigationHistory
    private let layoutQueue = DispatchQueue(label: "treemap.layout", qos: .userInitiated)
    private let aggregateQueue = DispatchQueue(label: "treemap.legend", qos: .userInitiated)

    private let metalView = TreemapMetalView(frame: .zero, device: MTLCreateSystemDefaultDevice())
    private let labelOverlay = LabelOverlayView()
    private let breadcrumb = BreadcrumbView()
    private let legend = LegendView()
    private let statusField = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    private var generation = 0
    private let generationLock = NSLock()
    private var latestGeneration = 0
    private var pendingLayoutWork: DispatchWorkItem?
    private var aggregateGeneration = 0
    private var lastViewportSize = CGSize.zero
    private var pendingZoomRect: CGRect?
    private var colorMode = Preferences.colorMode
    private var minimumCellArea = Preferences.minimumCellArea

    private(set) var selectedDirectory: UInt32 = IndexFormat.rootDirectory
    private(set) var selectedFile: UInt64?

    var root: UInt32 { history.current }
    var canGoBack: Bool { history.canGoBack }
    var canGoForward: Bool { history.canGoForward }
    var canGoUp: Bool { root != IndexFormat.rootDirectory }

    init(reader: IndexReader, engine: TreemapLayoutEngine, aggregates: SubtreeAggregates) {
        self.reader = reader
        self.engine = engine
        self.aggregates = aggregates
        history = NavigationHistory(root: IndexFormat.rootDirectory)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = TreemapPalette.canvasBackground.cgColor

        for subview in [breadcrumb, metalView, labelOverlay, legend, statusField, spinner] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(subview)
        }

        metalView.autoresizingMask = []
        statusField.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        statusField.textColor = NSColor(white: 0.62, alpha: 1)
        statusField.lineBreakMode = .byTruncatingMiddle
        statusField.maximumNumberOfLines = 1
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        NSLayoutConstraint.activate([
            breadcrumb.topAnchor.constraint(equalTo: container.topAnchor),
            breadcrumb.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            breadcrumb.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            breadcrumb.heightAnchor.constraint(equalToConstant: 38),

            metalView.topAnchor.constraint(equalTo: breadcrumb.bottomAnchor),
            metalView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            metalView.bottomAnchor.constraint(equalTo: statusField.topAnchor, constant: -4),

            labelOverlay.topAnchor.constraint(equalTo: metalView.topAnchor),
            labelOverlay.leadingAnchor.constraint(equalTo: metalView.leadingAnchor),
            labelOverlay.trailingAnchor.constraint(equalTo: metalView.trailingAnchor),
            labelOverlay.bottomAnchor.constraint(equalTo: metalView.bottomAnchor),

            spinner.trailingAnchor.constraint(equalTo: metalView.trailingAnchor, constant: -12),
            spinner.topAnchor.constraint(equalTo: metalView.topAnchor, constant: 12),

            statusField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            statusField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            statusField.bottomAnchor.constraint(equalTo: legend.topAnchor, constant: -3),

            legend.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            legend.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            legend.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            legend.heightAnchor.constraint(equalToConstant: 34),
        ])
        view = container
        wireCallbacks()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        metalView.renderer?.inventoryTimestamp = reader.manifest.inventoryTimestamp
        metalView.setColorMode(colorMode)
        var slots = [UInt8](repeating: 15, count: 65_536)

        for (position, identifier) in reader.manifest.extensionPalette.enumerated() where position < 15 {
            slots[Int(identifier)] = UInt8(position)
        }

        metalView.renderer?.update(extensionPaletteSlots: slots)
        refreshBreadcrumb()
        refreshLegend()
    }

    private func wireCallbacks() {
        metalView.onViewportChange = { [weak self] size in self?.viewportChanged(size) }
        metalView.onHover = { [weak self] hit, _ in self?.updateStatus(for: hit) }
        metalView.onClick = { [weak self] hit, _ in self?.handleClick(hit) }
        metalView.onDoubleClick = { [weak self] hit, rect in self?.handleDoubleClick(hit, rect) }
        breadcrumb.onSelect = { [weak self] directory in self?.setRoot(directory, animated: false) }
        breadcrumb.onBack = { [weak self] in self?.goBack() }
        breadcrumb.onForward = { [weak self] in self?.goForward() }
        breadcrumb.onUp = { [weak self] in self?.goUp() }
        legend.onSelect = { [weak self] category in self?.metalView.setHighlightCategory(category ?? -1) }
    }

    /// Resizes arrive in bursts while a window animates, so they are coalesced before a layout starts.
    private func viewportChanged(_ size: CGSize) {
        guard abs(size.width - lastViewportSize.width) > 0.5 || abs(size.height - lastViewportSize.height) > 0.5 else { return }
        lastViewportSize = size
        pendingLayoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.requestLayout() }
        pendingLayoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func requestLayout() {
        pendingLayoutWork?.cancel()
        pendingLayoutWork = nil

        guard lastViewportSize.width > 0, lastViewportSize.height > 0 else { return }
        generation += 1
        let thisGeneration = generation
        generationLock.lock()
        latestGeneration = thisGeneration
        generationLock.unlock()
        let request = LayoutRequest(
            rootDirectory: root,
            width: lastViewportSize.width,
            height: lastViewportSize.height,
            minimumCellArea: minimumCellArea
        )
        let zoomRect = pendingZoomRect
        pendingZoomRect = nil
        spinner.startAnimation(nil)
        layoutQueue.async { [weak self] in
            guard let self else { return }

            // A newer request may have arrived while this one waited on the serial queue. Skip the stale work.
            self.generationLock.lock()
            let newest = self.latestGeneration
            self.generationLock.unlock()

            guard thisGeneration == newest else { return }
            let result = self.engine.layout(request)
            DispatchQueue.main.async {
                guard thisGeneration == self.generation else { return }
                self.spinner.stopAnimation(nil)

                if let zoomRect {
                    self.metalView.animateZoom(from: zoomRect)
                }

                self.metalView.result = result
                self.labelOverlay.update(labels: result.labels, scale: self.view.window?.backingScaleFactor ?? 2)
                self.applySelectionHighlight()
            }
        }
    }

    private func applySelectionHighlight() {
        guard selectedDirectory != root || selectedFile != nil else {
            metalView.setSelection(nil, outlining: .zero, showingGuides: false)
            return
        }

        guard let layoutRect = metalView.result?.selectionRect(directory: selectedDirectory, file: selectedFile) else {
            metalView.setSelection(nil, outlining: .zero, showingGuides: false)
            return
        }

        // A cell can be a couple of pixels across. The marker is grown to a readable minimum around the
        // same centre, then kept inside the canvas.
        let minimumSide: Double = 30
        let width = max(layoutRect.width, minimumSide)
        let height = max(layoutRect.height, minimumSide)
        var x = layoutRect.x + layoutRect.width / 2 - width / 2
        var y = layoutRect.y + layoutRect.height / 2 - height / 2
        x = min(max(x, 1), max(lastViewportSize.width - width - 1, 1))
        y = min(max(y, 1), max(lastViewportSize.height - height - 1, 1))
        let outline = CGRect(x: x, y: y, width: width, height: height)

        // Dimming the rest only reads as "this part is selected" when the selection covers enough of
        // the canvas. Below that it just darkens everything, so the marker carries the meaning instead
        // and guide lines point to it.
        let canvasArea = max(lastViewportSize.width * lastViewportSize.height, 1)
        let coverage = (layoutRect.width * layoutRect.height) / canvasArea
        let dimTheRest = coverage >= 0.01 && selectedDirectory != root && selectedFile == nil
        let range = dimTheRest ? reader.directories.subtreeRange(selectedDirectory) : nil
        metalView.setSelection(range, outlining: outline, showingGuides: !dimTheRest)
    }

    private func refreshBreadcrumb() {
        var path: [(id: UInt32, name: String)] = []
        var current = root

        while current != IndexFormat.noParent {
            path.append((current, reader.directories.name(current)))

            if current == IndexFormat.rootDirectory {
                break
            }

            current = reader.directories.parent(current)
        }

        breadcrumb.update(path: path.reversed(), canGoBack: canGoBack, canGoForward: canGoForward, canGoUp: canGoUp)
    }

    func refreshLegend() {
        aggregateGeneration += 1
        let thisGeneration = aggregateGeneration
        let directory = root
        let units = Preferences.units

        switch colorMode {
        case .storageClass:
            let bytes = reader.directories.bytesByStorageClass(directory)
            let entries = bytes.enumerated().filter { $0.element > 0 }.map { slot, value in
                LegendEntry(
                    color: TreemapPalette.color(forStorageClass: slot),
                    label: StorageClass.names[slot],
                    bytes: value,
                    category: slot
                )
            }

            legend.update(entries: entries, totalBytes: reader.directories.subtreeBytes(directory), units: units)
        case .fileExtension:
            aggregateQueue.async { [weak self] in
                guard let self else { return }
                let breakdown = self.aggregates.extensionBreakdown(of: directory) {
                    thisGeneration != self.aggregateGeneration
                }

                guard let breakdown else { return }
                let palette = self.reader.manifest.extensionPalette
                var entries: [LegendEntry] = []

                for (slot, identifier) in palette.enumerated() where slot < 15 {
                    let bytes = breakdown.entries.first { $0.extensionId == identifier }?.bytes ?? 0

                    guard bytes > 0 else { continue }
                    entries.append(LegendEntry(
                        color: TreemapPalette.extensionColors[slot],
                        label: "." + self.reader.manifest.extensionNames[Int(identifier)],
                        bytes: bytes,
                        category: slot
                    ))
                }

                let paletteSet = Set(palette.prefix(15))
                let otherBytes = breakdown.entries.filter { !paletteSet.contains($0.extensionId) }
                    .reduce(UInt64(0)) { $0 &+ $1.bytes } &+ breakdown.otherBytes

                if otherBytes > 0 {
                    entries.append(LegendEntry(
                        color: TreemapPalette.extensionOtherColor,
                        label: "other",
                        bytes: otherBytes,
                        category: 15
                    ))
                }

                DispatchQueue.main.async {
                    guard thisGeneration == self.aggregateGeneration else { return }
                    self.legend.update(entries: entries, totalBytes: breakdown.totalBytes, units: units)
                }
            }
        case .folder:
            // The engine ranks the view root's children by size, so the legend uses the same order.
            let children = reader.directories.childrenBySize(directory)
            let colourCount = TreemapPalette.folderColors.count
            var entries: [LegendEntry] = []

            for (rank, child) in children.prefix(colourCount).enumerated() {
                let bytes = reader.directories.subtreeBytes(child)

                guard bytes > 0 else { continue }
                let name = reader.directories.name(child)
                entries.append(LegendEntry(
                    color: TreemapPalette.folderColors[rank],
                    label: name.isEmpty ? "(unnamed)" : name,
                    bytes: bytes,
                    category: rank
                ))
            }

            // Everything past the palette draws in the neutral colour, together with the view root's
            // own files, so the legend reports them as one entry and the percentages add up.
            var neutralBytes = reader.directories.ownBytes(directory)
            var neutralFolders = 0

            for child in children.dropFirst(colourCount) {
                neutralBytes &+= reader.directories.subtreeBytes(child)
                neutralFolders += 1
            }

            if neutralBytes > 0 {
                let label = neutralFolders > 0 ? "\(formatCount(UInt64(neutralFolders))) smaller folders" : "files here"
                entries.append(LegendEntry(
                    color: TreemapPalette.folderOwnColor,
                    label: label,
                    bytes: neutralBytes,
                    category: -2
                ))
            }

            legend.update(entries: entries, totalBytes: reader.directories.subtreeBytes(directory), units: units)
        case .age:
            aggregateQueue.async { [weak self] in
                guard let self else { return }
                let breakdown = self.aggregates.ageBreakdown(of: directory) {
                    thisGeneration != self.aggregateGeneration
                }

                guard let breakdown else { return }
                var entries: [LegendEntry] = []

                for (bucket, bytes) in breakdown.bucketBytes.enumerated() where bytes > 0 {
                    entries.append(LegendEntry(
                        color: TreemapPalette.ageColors[bucket],
                        label: TreemapPalette.ageBucketLabels[bucket],
                        bytes: bytes,
                        category: bucket
                    ))
                }

                let total = breakdown.bucketBytes.reduce(UInt64(0)) { $0 &+ $1 }
                DispatchQueue.main.async {
                    guard thisGeneration == self.aggregateGeneration else { return }
                    self.legend.update(entries: entries, totalBytes: total, units: units)
                }
            }
        }
    }

    private func updateStatus(for hit: LayoutHit?) {
        let units = Preferences.units

        guard let hit else {
            statusField.stringValue = ""
            return
        }

        switch hit {
        case .file(let fileIndex, _, _):
            let position = Int(fileIndex)
            let size = formatByteCount(reader.fileSize[position], units: units)
            let storageClass = StorageClass.names[Int(reader.fileStorageClass[position])]
            statusField.stringValue = reader.key(ofFile: fileIndex) + "    " + size + "    " + storageClass
        case .directory(let identifier, _):
            let path = reader.directories.path(identifier)
            let bytes = formatByteCount(reader.directories.subtreeBytes(identifier), units: units)
            let files = formatCount(reader.directories.subtreeFileCount(identifier))
            statusField.stringValue = (path.isEmpty ? "(root)" : path + "/") + "    " + bytes + "    " + files + " files"
        case .remainder(_, _, let items, let bytes):
            statusField.stringValue = formatCount(items) + " more items, " + formatByteCount(bytes, units: units)
        }
    }

    private func handleClick(_ hit: LayoutHit?) {
        guard let hit else { return }

        switch hit {
        case .file(let fileIndex, _, let directory):
            select(directory: directory, file: fileIndex)
        case .directory(let identifier, _):
            select(directory: identifier, file: nil)
        case .remainder(let directory, _, _, _):
            select(directory: directory, file: nil)
        }
    }

    private func handleDoubleClick(_ hit: LayoutHit?, _ sourceRect: CGRect?) {
        guard let hit else { return }

        if case .directory(let identifier, _) = hit, identifier != root {
            pendingZoomRect = sourceRect
            setRoot(identifier, animated: sourceRect != nil)
        } else {
            handleClick(hit)
        }
    }

    func select(directory: UInt32, file: UInt64?) {
        selectedDirectory = directory
        selectedFile = file
        applySelectionHighlight()
        delegate?.treemapDidSelect(directory: directory, file: file)
    }

    func setRoot(_ directory: UInt32, animated: Bool) {
        guard directory != root else { return }

        if !animated {
            pendingZoomRect = nil
        }

        history.navigate(to: directory)
        finishRootChange()
    }

    private func finishRootChange() {
        selectedDirectory = root
        selectedFile = nil
        legend.clearHighlight()
        metalView.setHighlightCategory(-1)
        refreshBreadcrumb()
        refreshLegend()
        requestLayout()
        delegate?.treemapDidChangeRoot(root)
    }

    func goBack() {
        guard history.goBack() != nil else { return }
        pendingZoomRect = nil
        finishRootChange()
    }

    func goForward() {
        guard history.goForward() != nil else { return }
        pendingZoomRect = nil
        finishRootChange()
    }

    func goUp() {
        guard root != IndexFormat.rootDirectory else { return }
        setRoot(reader.directories.parent(root), animated: false)
    }

    func zoomIntoSelection() {
        guard selectedDirectory != root else { return }
        setRoot(selectedDirectory, animated: false)
    }

    func clearSelection() {
        selectedDirectory = root
        selectedFile = nil
        applySelectionHighlight()
        legend.clearHighlight()
        metalView.setHighlightCategory(-1)
    }

    func setColorMode(_ mode: ColorMode) {
        colorMode = mode
        Preferences.colorMode = mode
        metalView.setColorMode(mode)
        legend.clearHighlight()
        metalView.setHighlightCategory(-1)
        refreshLegend()
    }

    func setMinimumCellArea(_ area: Double) {
        minimumCellArea = area
        Preferences.minimumCellArea = area
        requestLayout()
    }

    func reloadUnits() {
        refreshLegend()
    }

    /// Reveals a file or directory: makes its containing directory the root when it is out of view.
    func reveal(directory: UInt32, file: UInt64?) {
        let range = reader.directories.subtreeRange(root)

        if !range.contains(directory) {
            history.navigate(to: directory)
            finishRootChange()
        }

        select(directory: directory, file: file)
    }
}
