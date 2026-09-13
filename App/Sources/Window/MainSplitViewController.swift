import AppKit
import InventoryIndex
import TreemapLayout

final class MainSplitViewController: NSSplitViewController, TreemapViewControllerDelegate, DirectoryOutlineDelegate {
    let reader: IndexReader
    let treemapController: TreemapViewController
    let outlineController: DirectoryOutlineViewController
    let detailsController: DetailsViewController

    private var isSynchronizing = false

    init(reader: IndexReader) {
        self.reader = reader
        let ownFilesCache = OwnFilesCache(reader: reader)
        let aggregates = SubtreeAggregates(reader: reader)
        let engine = TreemapLayoutEngine(dataSource: IndexLayoutDataSource(reader: reader, ownFilesCache: ownFilesCache))
        treemapController = TreemapViewController(reader: reader, engine: engine, aggregates: aggregates)
        outlineController = DirectoryOutlineViewController(reader: reader, ownFilesCache: ownFilesCache)
        detailsController = DetailsViewController(reader: reader, aggregates: aggregates)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var hasPlacedDividers = false

    override func viewDidAppear() {
        super.viewDidAppear()

        // Once only. This runs again whenever the view reappears, and placing the dividers from a
        // transient width can collapse the details pane entirely.
        guard !hasPlacedDividers, splitView.subviews.count == 3, splitView.bounds.width > 0 else { return }
        hasPlacedDividers = true
        let total = splitView.bounds.width
        let sidebarWidth: CGFloat = 300
        let detailsWidth: CGFloat = 320
        splitView.setPosition(sidebarWidth, ofDividerAt: 0)
        splitView.setPosition(total - detailsWidth, ofDividerAt: 1)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        treemapController.delegate = self
        outlineController.delegate = self

        // The side panes hold their width; the treemap absorbs everything left over.
        let sidebar = NSSplitViewItem(sidebarWithViewController: outlineController)
        sidebar.minimumThickness = 220
        sidebar.maximumThickness = 520
        sidebar.canCollapse = true
        sidebar.holdingPriority = NSLayoutConstraint.Priority(260)
        addSplitViewItem(sidebar)

        let center = NSSplitViewItem(viewController: treemapController)
        center.minimumThickness = 400
        center.canCollapse = false
        center.holdingPriority = NSLayoutConstraint.Priority(50)
        addSplitViewItem(center)

        let details = NSSplitViewItem(viewController: detailsController)
        details.minimumThickness = 240
        details.maximumThickness = 460
        details.canCollapse = true
        details.holdingPriority = NSLayoutConstraint.Priority(260)
        addSplitViewItem(details)
    }

    // MARK: treemap delegate

    func treemapDidSelect(directory: UInt32, file: UInt64?) {
        guard !isSynchronizing else { return }
        isSynchronizing = true
        defer { isSynchronizing = false }
        outlineController.reveal(directory: directory, file: file)

        if let file {
            detailsController.show(file: file, directory: directory)
        } else {
            detailsController.show(directory: directory)
        }
    }

    func treemapDidChangeRoot(_ directory: UInt32) {
        guard !isSynchronizing else { return }
        isSynchronizing = true
        defer { isSynchronizing = false }
        outlineController.reveal(directory: directory, file: nil)
        detailsController.show(directory: directory)
        refreshToolbarState()
    }

    // MARK: outline delegate

    func outlineDidSelect(directory: UInt32, file: UInt64?) {
        guard !isSynchronizing else { return }
        isSynchronizing = true
        defer { isSynchronizing = false }
        treemapController.select(directory: directory, file: file)

        if let file {
            detailsController.show(file: file, directory: directory)
        } else {
            detailsController.show(directory: directory)
        }
    }

    func outlineDidActivate(directory: UInt32) {
        treemapController.setRoot(directory, animated: false)
    }

    func refreshToolbarState() {
        (view.window?.windowController as? MainWindowController)?.refreshToolbarState()
    }

    func reveal(hit: SearchHit) {
        treemapController.reveal(directory: hit.directoryId, file: hit.fileIndex)
        outlineController.reveal(directory: hit.directoryId, file: hit.fileIndex)

        if let file = hit.fileIndex {
            detailsController.show(file: file, directory: hit.directoryId)
        } else {
            detailsController.show(directory: hit.directoryId)
        }
    }

    func toggleSidebar() {
        splitViewItems[0].animator().isCollapsed.toggle()
    }

    func toggleDetails() {
        splitViewItems[2].animator().isCollapsed.toggle()
    }
}
