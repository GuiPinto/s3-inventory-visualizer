import AppKit
import InventoryIndex
import InventoryImport

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var windowControllers: [MainWindowController] = []

    /// The sheet controller is the target of its own buttons. Without a strong reference here it is
    /// deallocated as soon as the opening function returns, and Build Index silently does nothing.
    private var importSheetControllers: [ImportSheetController] = []
    private let recentMenu = NSMenu(title: "Open Recent")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenus()
        NSApp.activate(ignoringOtherApps: true)

        // A folder passed on the command line opens directly. This keeps automated runs free of the open panel.
        let arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }

        if let path = arguments.first {
            openFolder(URL(fileURLWithPath: path))
            return
        }

        if windowControllers.isEmpty {
            openInventory(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            openFolder(url)
        }
    }

    private var activeWindowController: MainWindowController? {
        NSApp.keyWindow?.windowController as? MainWindowController ?? windowControllers.last
    }

    // MARK: opening

    @objc func openInventory(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Inventory"
        panel.message = "Choose the folder that contains manifest.json and the data files."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openFolder(url)
    }

    private func presentError(_ message: String, informative: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informative
        alert.alertStyle = .warning
        alert.runModal()
    }

    func openFolder(_ folder: URL, forceRebuild: Bool = false, reopenIfAbandoned: Bool = false) {
        // The folder may be a finished index rather than an inventory, which is how an index built
        // on another machine arrives.
        if !forceRebuild, let reader = try? IndexReader(folder: folder) {
            presentWindow(reader: reader, folder: folder)
            return
        }

        let source: InventorySource

        do {
            source = try InventorySource.load(folder: folder)
        } catch {
            presentError("Cannot read that inventory", informative: "\(error)")
            return
        }

        let indexFolder = IndexReader.indexFolder(forInventory: folder)

        if !forceRebuild, let reader = try? IndexReader(folder: indexFolder), indexMatches(reader.manifest, source) {
            presentWindow(reader: reader, folder: folder)
            return
        }

        if !source.missingDataFiles.isEmpty {
            let alert = NSAlert()
            alert.messageText = "\(source.missingDataFiles.count) inventory files are missing"
            alert.informativeText = "The index will be marked partial. Missing: "
                + source.missingDataFiles.prefix(5).joined(separator: ", ")
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Cancel")

            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        let placeholder = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        placeholder.title = folder.lastPathComponent
        placeholder.center()
        placeholder.makeKeyAndOrderFront(nil)
        let sheet = ImportSheetController(source: source, outputFolder: indexFolder, force: forceRebuild)
        importSheetControllers.append(sheet)
        sheet.beginSheet(on: placeholder) { [weak self] result in
            placeholder.orderOut(nil)
            self?.importSheetControllers.removeAll { $0 === sheet }

            switch result {
            case .success:
                do {
                    let reader = try IndexReader(folder: indexFolder)
                    self?.presentWindow(reader: reader, folder: folder)
                } catch {
                    self?.presentError("The index could not be opened", informative: "\(error)")
                }
            case .failure(let error):
                // A cancelled rebuild already closed the old window. The index on disk is untouched
                // until the import actually starts, so reopen it rather than stranding the user.
                if case ImportError.cancelled = error {
                    if reopenIfAbandoned {
                        self?.openFolder(folder)
                    }

                    return
                }

                self?.presentError("The import failed", informative: "\(error)")

                if reopenIfAbandoned {
                    self?.openFolder(folder)
                }
            }
        }
    }

    private func indexMatches(_ manifest: IndexManifest, _ source: InventorySource) -> Bool {
        if let recorded = manifest.source.manifestMD5, let current = source.manifestMD5 {
            return recorded == current
        }

        return manifest.source.manifestFileCount == source.dataFiles.count + source.missingDataFiles.count
            && manifest.source.manifestTotalBytes == source.manifestTotalBytes
    }

    private func presentWindow(reader: IndexReader, folder: URL) {
        DispatchQueue.global(qos: .utility).async { reader.prefetchLayoutColumns() }
        let controller = MainWindowController(reader: reader, inventoryFolder: folder)
        windowControllers.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSDocumentController.shared.noteNewRecentDocumentURL(folder)
    }

    @objc func rebuildIndex(_ sender: Any?) {
        guard let controller = activeWindowController else { return }
        let alert = NSAlert()
        alert.messageText = "Rebuild the index?"
        alert.informativeText = "The existing index is deleted and built again from the inventory files."
        alert.addButton(withTitle: "Rebuild")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // The window is closed first so the old index's pages are released before the new one is
        // written. Rebuilding the reference bucket would otherwise need room for two 38 GB indexes.
        let folder = controller.inventoryFolder
        controller.close()
        windowControllers.removeAll { $0 === controller }
        openFolder(folder, forceRebuild: true, reopenIfAbandoned: true)
    }

    @objc private func showAboutPanel(_ sender: Any?) {
        AboutPanel.show()
    }

    // MARK: recent inventories

    /// This app does not use NSDocument, so the Open Recent menu is filled from the shared document
    /// controller's list by hand, each time the menu opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentMenu else { return }
        menu.removeAllItems()
        let urls = NSDocumentController.shared.recentDocumentURLs

        if urls.isEmpty {
            let empty = NSMenuItem(title: "No Recent Inventories", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }

        for url in urls {
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecentInventory(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.toolTip = url.path
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let clear = NSMenuItem(title: "Clear Menu", action: #selector(clearRecentInventories(_:)), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
    }

    @objc private func openRecentInventory(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }

        guard FileManager.default.fileExists(atPath: url.path) else {
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            presentError("That folder is gone", informative: url.path)
            return
        }

        openFolder(url)
    }

    @objc private func clearRecentInventories(_ sender: Any?) {
        NSDocumentController.shared.clearRecentDocuments(sender)
    }

    // MARK: menus

    private func buildMenus() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let aboutItem = NSMenuItem(
            title: "About S3 Inventory Visualizer",
            action: #selector(showAboutPanel(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = self
        appMenu.addItem(aboutItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open Inventory", action: #selector(openInventory(_:)), keyEquivalent: "o")
        let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        recentMenu.delegate = self
        recentItem.submenu = recentMenu
        fileMenu.addItem(recentItem)
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Rebuild Index", action: #selector(rebuildIndex(_:)), keyEquivalent: "r")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy Key", action: #selector(MainWindowController.copyKey(_:)), keyEquivalent: "c")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Find", action: #selector(MainWindowController.findInInventory(_:)), keyEquivalent: "f")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let back = NSMenuItem(title: "Back", action: #selector(MainWindowController.goBack(_:)), keyEquivalent: "[")
        back.keyEquivalentModifierMask = [.command]
        viewMenu.addItem(back)
        let forward = NSMenuItem(title: "Forward", action: #selector(MainWindowController.goForward(_:)), keyEquivalent: "]")
        forward.keyEquivalentModifierMask = [.command]
        viewMenu.addItem(forward)
        let up = NSMenuItem(title: "Up", action: #selector(MainWindowController.goUp(_:)), keyEquivalent: String(UnicodeScalar(NSUpArrowFunctionKey)!))
        up.keyEquivalentModifierMask = [.command]
        viewMenu.addItem(up)
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Zoom Into Selection", action: #selector(MainWindowController.zoomIntoSelection(_:)), keyEquivalent: "\r")
        viewMenu.addItem(withTitle: "Clear Selection", action: #selector(MainWindowController.clearSelection(_:)), keyEquivalent: "\u{1b}")
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Color by Storage Class", action: #selector(MainWindowController.colorByStorageClass(_:)), keyEquivalent: "1")
        viewMenu.addItem(withTitle: "Color by Extension", action: #selector(MainWindowController.colorByExtension(_:)), keyEquivalent: "2")
        viewMenu.addItem(withTitle: "Color by Age", action: #selector(MainWindowController.colorByAge(_:)), keyEquivalent: "3")
        viewMenu.addItem(withTitle: "Color by Folder", action: #selector(MainWindowController.colorByFolder(_:)), keyEquivalent: "4")
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Toggle Sidebar", action: #selector(MainWindowController.toggleSidebarPane(_:)), keyEquivalent: "s")
        viewMenu.addItem(withTitle: "Toggle Details", action: #selector(MainWindowController.toggleDetailsPane(_:)), keyEquivalent: "d")
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }
}
