import AppKit
import InventoryIndex

final class MainWindowController: NSWindowController, NSToolbarDelegate, NSMenuItemValidation {
    let reader: IndexReader
    let inventoryFolder: URL
    private let splitController: MainSplitViewController
    private var searchPanel: SearchPanelController?

    private let navigationControl = NSSegmentedControl(images: [
        NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: "Back")!,
        NSImage(systemSymbolName: "chevron.forward", accessibilityDescription: "Forward")!,
        NSImage(systemSymbolName: "arrow.up", accessibilityDescription: "Up")!,
    ], trackingMode: .momentary, target: nil, action: nil)
    private let colorModeControl = NSSegmentedControl(
        labels: ["Class", "Extension", "Age", "Folder"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let unitsPopUp = NSPopUpButton()
    private let detailPopUp = NSPopUpButton()
    private let searchField = NSSearchField()

    private static let identifierNavigation = NSToolbarItem.Identifier("navigation")
    private static let identifierColorMode = NSToolbarItem.Identifier("colorMode")
    private static let identifierUnits = NSToolbarItem.Identifier("units")
    private static let identifierDetail = NSToolbarItem.Identifier("detail")
    private static let identifierSearch = NSToolbarItem.Identifier("search")

    init(reader: IndexReader, inventoryFolder: URL) {
        self.reader = reader
        self.inventoryFolder = inventoryFolder
        splitController = MainSplitViewController(reader: reader)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1500, height: 940),
            // Without fullSizeContentView the content view starts below the toolbar.
            // With it, the top of the split view hides behind the toolbar.
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = splitController
        window.minSize = NSSize(width: 900, height: 600)
        super.init(window: window)

        let counts = reader.manifest.counts
        window.title = reader.manifest.source.sourceBucket
        var subtitle = formatCount(counts.fileCount) + " files · " + formatByteCount(counts.totalBytes, units: Preferences.units)

        if reader.manifest.isPartial {
            subtitle += " · partial index"
        }

        window.subtitle = subtitle
        buildToolbar()
        refreshToolbarState()

        // The split view controller resizes the window to its own fitting size, so the intended
        // content size is applied after the content view controller has loaded.
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1500, height: 940)
        let width = min(1500, visibleFrame.width - 40)
        let height = min(940, visibleFrame.height - 40)
        window.setContentSize(NSSize(width: width, height: height))
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildToolbar() {
        navigationControl.target = self
        navigationControl.action = #selector(navigationClicked(_:))
        colorModeControl.target = self
        colorModeControl.action = #selector(colorModeClicked(_:))
        colorModeControl.selectedSegment = Preferences.colorMode.rawValue

        unitsPopUp.addItems(withTitles: ["Binary (KiB)", "Decimal (KB)"])
        unitsPopUp.selectItem(at: Preferences.units == .binary ? 0 : 1)
        unitsPopUp.target = self
        unitsPopUp.action = #selector(unitsChanged(_:))

        detailPopUp.addItems(withTitles: ["Finest (1 px²)", "Fine (2 px²)", "Normal (4 px²)", "Coarse (8 px²)", "Coarsest (16 px²)"])
        let areas: [Double] = [1, 2, 4, 8, 16]
        detailPopUp.selectItem(at: areas.firstIndex(of: Preferences.minimumCellArea) ?? 2)
        detailPopUp.target = self
        detailPopUp.action = #selector(detailChanged(_:))

        searchField.placeholderString = "Find"
        searchField.target = self
        searchField.action = #selector(searchFieldActivated)

        let toolbar = NSToolbar(identifier: "main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
        window?.toolbarStyle = .unified
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            MainWindowController.identifierNavigation,
            .flexibleSpace,
            MainWindowController.identifierColorMode,
            MainWindowController.identifierDetail,
            MainWindowController.identifierUnits,
            .flexibleSpace,
            MainWindowController.identifierSearch
        ]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)

        switch identifier {
        case MainWindowController.identifierNavigation:
            item.view = navigationControl
            item.label = "Navigate"
        case MainWindowController.identifierColorMode:
            item.view = colorModeControl
            item.label = "Color by"
        case MainWindowController.identifierUnits:
            item.view = unitsPopUp
            item.label = "Units"
        case MainWindowController.identifierDetail:
            item.view = detailPopUp
            item.label = "Detail"
        case MainWindowController.identifierSearch:
            item.view = searchField
            item.label = "Find"
        default:
            return nil
        }

        return item
    }

    func refreshToolbarState() {
        navigationControl.setEnabled(splitController.treemapController.canGoBack, forSegment: 0)
        navigationControl.setEnabled(splitController.treemapController.canGoForward, forSegment: 1)
        navigationControl.setEnabled(splitController.treemapController.canGoUp, forSegment: 2)
    }

    @objc private func navigationClicked(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 0: splitController.treemapController.goBack()
        case 1: splitController.treemapController.goForward()
        default: splitController.treemapController.goUp()
        }

        refreshToolbarState()
    }

    @objc private func colorModeClicked(_ sender: NSSegmentedControl) {
        guard let mode = ColorMode(rawValue: sender.selectedSegment) else { return }
        splitController.treemapController.setColorMode(mode)
    }

    @objc private func unitsChanged(_ sender: NSPopUpButton) {
        Preferences.units = sender.indexOfSelectedItem == 0 ? .binary : .decimal
        splitController.treemapController.reloadUnits()
        let counts = reader.manifest.counts
        var subtitle = formatCount(counts.fileCount) + " files · " + formatByteCount(counts.totalBytes, units: Preferences.units)

        if reader.manifest.isPartial {
            subtitle += " · partial index"
        }

        window?.subtitle = subtitle
    }

    @objc private func detailChanged(_ sender: NSPopUpButton) {
        let areas: [Double] = [1, 2, 4, 8, 16]
        splitController.treemapController.setMinimumCellArea(areas[sender.indexOfSelectedItem])
    }

    @objc private func searchFieldActivated() {
        showSearch(initialQuery: searchField.stringValue)
    }

    func showSearch(initialQuery: String? = nil) {
        if searchPanel == nil {
            let panel = SearchPanelController(reader: reader)
            panel.onChoose = { [weak self] hit in self?.splitController.reveal(hit: hit) }
            searchPanel = panel
        }

        searchPanel?.showWindow(nil)
        searchPanel?.focusSearchField()
    }

    // MARK: menu validation

    /// Without this the navigation items stay enabled at the root, because AppKit only checks that
    /// some responder implements the action.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(goBack(_:)):
            return splitController.treemapController.canGoBack
        case #selector(goForward(_:)):
            return splitController.treemapController.canGoForward
        case #selector(goUp(_:)):
            return splitController.treemapController.canGoUp
        case #selector(zoomIntoSelection(_:)):
            return splitController.treemapController.selectedDirectory != splitController.treemapController.root
        case #selector(copyKey(_:)):
            return splitController.detailsController.hasKeyToCopy
        default:
            return true
        }
    }

    // MARK: menu actions

    @objc func goBack(_ sender: Any?) {
        splitController.treemapController.goBack()
        refreshToolbarState()
    }

    @objc func goForward(_ sender: Any?) {
        splitController.treemapController.goForward()
        refreshToolbarState()
    }

    @objc func goUp(_ sender: Any?) {
        splitController.treemapController.goUp()
        refreshToolbarState()
    }

    @objc func zoomIntoSelection(_ sender: Any?) {
        splitController.treemapController.zoomIntoSelection()
        refreshToolbarState()
    }

    @objc func clearSelection(_ sender: Any?) {
        splitController.treemapController.clearSelection()
    }

    @objc func colorByStorageClass(_ sender: Any?) {
        colorModeControl.selectedSegment = 0
        splitController.treemapController.setColorMode(.storageClass)
    }

    @objc func colorByExtension(_ sender: Any?) {
        colorModeControl.selectedSegment = 1
        splitController.treemapController.setColorMode(.fileExtension)
    }

    @objc func colorByAge(_ sender: Any?) {
        colorModeControl.selectedSegment = 2
        splitController.treemapController.setColorMode(.age)
    }

    @objc func colorByFolder(_ sender: Any?) {
        colorModeControl.selectedSegment = 3
        splitController.treemapController.setColorMode(.folder)
    }

    @objc func toggleSidebarPane(_ sender: Any?) {
        splitController.toggleSidebar()
    }

    @objc func toggleDetailsPane(_ sender: Any?) {
        splitController.toggleDetails()
    }

    @objc func copyKey(_ sender: Any?) {
        splitController.detailsController.copyCurrentKey()
    }

    @objc func findInInventory(_ sender: Any?) {
        showSearch()
    }
}
