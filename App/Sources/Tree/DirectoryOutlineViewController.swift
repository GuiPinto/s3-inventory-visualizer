import AppKit
import InventoryIndex

protocol DirectoryOutlineDelegate: AnyObject {
    func outlineDidSelect(directory: UInt32, file: UInt64?)

    func outlineDidActivate(directory: UInt32)
}

final class DirectoryOutlineViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    weak var delegate: DirectoryOutlineDelegate?

    private let reader: IndexReader
    private let ownFilesCache: OwnFilesCache
    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()
    private var rootItems: [DirectoryOutlineItem] = []
    private var isSynchronizing = false

    private static let filesShownPerDirectory = 100

    init(reader: IndexReader, ownFilesCache: OwnFilesCache) {
        self.reader = reader
        self.ownFilesCache = ownFilesCache
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.rowSizeStyle = .small
        outlineView.headerView = NSTableHeaderView()
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.target = self
        outlineView.doubleAction = #selector(rowDoubleClicked)

        func column(_ identifier: String, _ title: String, width: CGFloat) -> NSTableColumn {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            column.minWidth = 40
            return column
        }

        let nameColumn = column("name", "Name", width: 230)
        outlineView.addTableColumn(nameColumn)
        outlineView.outlineTableColumn = nameColumn
        outlineView.addTableColumn(column("size", "Size", width: 84))
        outlineView.addTableColumn(column("share", "% parent", width: 62))
        outlineView.addTableColumn(column("items", "Items", width: 78))
        outlineView.addTableColumn(column("mix", "Class mix", width: 84))

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        view = scrollView
        rootItems = [DirectoryOutlineItem(kind: .directory(IndexFormat.rootDirectory))]
        outlineView.reloadData()
        outlineView.expandItem(rootItems[0])
    }

    private func children(of item: DirectoryOutlineItem) -> [DirectoryOutlineItem] {
        if let cached = item.cachedChildren {
            return cached
        }

        var result: [DirectoryOutlineItem] = []

        switch item.kind {
        case .directory(let identifier):
            for child in reader.directories.childrenBySize(identifier) {
                result.append(DirectoryOutlineItem(kind: .directory(child)))
            }

            if reader.directories.ownFileCount(identifier) > 0 {
                result.append(DirectoryOutlineItem(kind: .filesGroup(identifier)))
            }
        case .filesGroup(let identifier):
            let selection = ownFilesCache.largestOwnFiles(
                of: identifier,
                count: DirectoryOutlineViewController.filesShownPerDirectory
            )

            for fileIndex in selection.fileIndices {
                result.append(DirectoryOutlineItem(kind: .file(fileIndex, identifier)))
            }

            let remaining = selection.ownFileCount - UInt64(selection.fileIndices.count)

            if remaining > 0 {
                result.append(DirectoryOutlineItem(kind: .moreFiles(identifier, remaining: remaining)))
            }
        case .file, .moreFiles:
            break
        }

        item.cachedChildren = result
        return result
    }

    // MARK: data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item = item as? DirectoryOutlineItem else { return rootItems.count }
        return children(of: item).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item = item as? DirectoryOutlineItem else { return rootItems[index] }
        return children(of: item)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let item = item as? DirectoryOutlineItem else { return false }

        switch item.kind {
        case .directory(let identifier):
            return reader.directories.childCount(identifier) > 0 || reader.directories.ownFileCount(identifier) > 0
        case .filesGroup:
            return true
        case .file, .moreFiles:
            return false
        }
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? DirectoryOutlineItem)?.isSelectable ?? false
    }

    // MARK: delegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? DirectoryOutlineItem, let columnIdentifier = tableColumn?.identifier.rawValue else { return nil }
        let units = Preferences.units
        let tree = reader.directories

        if columnIdentifier == "mix" {
            guard case .directory(let identifier) = item.kind else { return NSView() }
            let bar = ClassMixBarView()
            bar.bytesByStorageClass = tree.bytesByStorageClass(identifier)
            return bar
        }

        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: 11)
        field.lineBreakMode = .byTruncatingMiddle

        if columnIdentifier != "name" {
            field.alignment = .right
        }

        switch item.kind {
        case .directory(let identifier):
            switch columnIdentifier {
            case "name":
                field.stringValue = identifier == IndexFormat.rootDirectory ? "(root)" : tree.name(identifier)
                field.font = .systemFont(ofSize: 11, weight: .medium)
            case "size":
                field.stringValue = formatByteCount(tree.subtreeBytes(identifier), units: units)
            case "share":
                let parent = tree.parent(identifier)

                if parent == IndexFormat.noParent {
                    field.stringValue = "100%"
                } else {
                    let parentBytes = tree.subtreeBytes(parent)
                    let share = parentBytes == 0 ? 0 : Double(tree.subtreeBytes(identifier)) * 100 / Double(parentBytes)
                    field.stringValue = String(format: "%.1f%%", share)
                }
            case "items":
                field.stringValue = formatCount(tree.subtreeFileCount(identifier))
            default:
                break
            }
        case .filesGroup(let identifier):
            if columnIdentifier == "name" {
                field.stringValue = "Files (\(formatCount(UInt64(tree.ownFileCount(identifier)))))"
                field.textColor = NSColor.secondaryLabelColor
            } else if columnIdentifier == "size" {
                field.stringValue = formatByteCount(tree.ownBytes(identifier), units: units)
            }
        case .file(let fileIndex, _):
            switch columnIdentifier {
            case "name":
                field.stringValue = reader.names.nameString(ofFile: fileIndex)
            case "size":
                field.stringValue = formatByteCount(reader.fileSize[Int(fileIndex)], units: units)
            case "items":
                field.stringValue = StorageClass.names[Int(reader.fileStorageClass[Int(fileIndex)])]
                field.font = .systemFont(ofSize: 9)
                field.textColor = NSColor.secondaryLabelColor
            default:
                break
            }
        case .moreFiles(_, let remaining):
            if columnIdentifier == "name" {
                field.stringValue = "... \(formatCount(remaining)) more"
                field.textColor = NSColor.tertiaryLabelColor
            }
        }

        return field
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isSynchronizing,
              let item = outlineView.item(atRow: outlineView.selectedRow) as? DirectoryOutlineItem else { return }

        switch item.kind {
        case .directory(let identifier):
            delegate?.outlineDidSelect(directory: identifier, file: nil)
        case .filesGroup(let identifier):
            delegate?.outlineDidSelect(directory: identifier, file: nil)
        case .file(let fileIndex, let identifier):
            delegate?.outlineDidSelect(directory: identifier, file: fileIndex)
        case .moreFiles:
            break
        }
    }

    @objc private func rowDoubleClicked() {
        guard let item = outlineView.item(atRow: outlineView.clickedRow) as? DirectoryOutlineItem,
              case .directory(let identifier) = item.kind else { return }
        delegate?.outlineDidActivate(directory: identifier)
    }

    /// Collapses everything, opens only the path down to the item, selects it and centres it.
    /// Called when the treemap or a search result drives the selection, never by the outline itself.
    func reveal(directory: UInt32, file: UInt64?) {
        var ancestors: [UInt32] = []
        var current = directory
        var guardCount = 0

        while current != IndexFormat.rootDirectory && current != IndexFormat.noParent && guardCount < 24 {
            ancestors.append(current)
            current = reader.directories.parent(current)
            guardCount += 1
        }

        isSynchronizing = true
        defer { isSynchronizing = false }

        // Start from a clean tree so the opened path is the only thing showing.
        outlineView.collapseItem(nil, collapseChildren: true)

        var item = rootItems[0]
        outlineView.expandItem(item)

        for ancestor in ancestors.reversed() {
            guard let next = children(of: item).first(where: {
                if case .directory(let identifier) = $0.kind {
                    return identifier == ancestor
                }

                return false
            }) else { break }

            outlineView.expandItem(next)
            item = next
        }

        var target: DirectoryOutlineItem = item

        if let file {
            if let group = children(of: item).first(where: {
                if case .filesGroup = $0.kind {
                    return true
                }

                return false
            }) {
                outlineView.expandItem(group)

                if let fileItem = children(of: group).first(where: {
                    if case .file(let index, _) = $0.kind {
                        return index == file
                    }

                    return false
                }) {
                    target = fileItem
                }
            }
        }

        let row = outlineView.row(forItem: target)

        guard row >= 0 else { return }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        centre(row: row)
    }

    /// Puts the row in the middle of the visible area rather than just barely inside it.
    private func centre(row: Int) {
        guard let clipView = outlineView.enclosingScrollView?.contentView else {
            outlineView.scrollRowToVisible(row)
            return
        }

        let rowRect = outlineView.rect(ofRow: row)
        let visibleHeight = clipView.bounds.height
        let target = rowRect.midY - visibleHeight / 2
        let maximum = max(0, outlineView.bounds.height - visibleHeight)
        clipView.scroll(to: NSPoint(x: 0, y: min(max(target, 0), maximum)))
        outlineView.enclosingScrollView?.reflectScrolledClipView(clipView)
    }
}
