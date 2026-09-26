import AppKit
import InventoryIndex

final class SearchPanelController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    var onChoose: ((SearchHit) -> Void)?

    private let reader: IndexReader
    private let search: KeySearch
    private let searchField = NSSearchField()
    private let modeControl = NSSegmentedControl(
        labels: ["Starts with", "Contains"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let tableView = NSTableView()
    private let progressBar = NSProgressIndicator()
    private let cancelButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "")
    private let searchQueue = DispatchQueue(label: "search.contains", qos: .userInitiated)
    private var hits: [SearchHit] = []
    private var cancelFlag = false
    private let cancelLock = NSLock()

    init(reader: IndexReader) {
        self.reader = reader
        search = KeySearch(reader: reader)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 420),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Find in " + reader.manifest.source.sourceBucket
        super.init(window: panel)
        buildInterface(in: panel)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildInterface(in panel: NSPanel) {
        let content = NSView()
        panel.contentView = content

        searchField.placeholderString = "key prefix or substring"
        searchField.target = self
        searchField.action = #selector(runSearch)
        modeControl.selectedSegment = 0
        modeControl.target = self
        modeControl.action = #selector(runSearch)
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.isHidden = true
        cancelButton.title = "Cancel"
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelSearch)
        cancelButton.isHidden = true
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

        func column(_ identifier: String, _ title: String, width: CGFloat) -> NSTableColumn {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            return column
        }

        tableView.addTableColumn(column("key", "Key", width: 460))
        tableView.addTableColumn(column("size", "Size", width: 90))
        tableView.addTableColumn(column("class", "Class", width: 120))
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowSizeStyle = .small
        tableView.target = self
        tableView.doubleAction = #selector(chooseRow)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true

        for subview in [searchField, modeControl, scrollView, progressBar, cancelButton, statusLabel] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(subview)
        }

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            modeControl.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            modeControl.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: 10),
            modeControl.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -8),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            statusLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            progressBar.leadingAnchor.constraint(equalTo: statusLabel.trailingAnchor, constant: 10),
            progressBar.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            progressBar.widthAnchor.constraint(equalToConstant: 180),
            cancelButton.leadingAnchor.constraint(equalTo: progressBar.trailingAnchor, constant: 8),
            cancelButton.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            cancelButton.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -12),
        ])
    }

    func focusSearchField() {
        window?.makeFirstResponder(searchField)
    }

    private var isCancelled: Bool {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        return cancelFlag
    }

    @objc private func cancelSearch() {
        cancelLock.lock()
        cancelFlag = true
        cancelLock.unlock()
    }

    @objc private func runSearch() {
        let query = searchField.stringValue

        guard !query.isEmpty else {
            hits = []
            tableView.reloadData()
            statusLabel.stringValue = ""
            return
        }

        cancelLock.lock()
        cancelFlag = false
        cancelLock.unlock()

        if modeControl.selectedSegment == 0 {
            let started = Date()
            hits = search.startsWith(query)
            tableView.reloadData()
            statusLabel.stringValue = String(
                format: "%d results in %.0f ms",
                hits.count,
                Date().timeIntervalSince(started) * 1000
            )
            return
        }

        progressBar.isHidden = false
        progressBar.doubleValue = 0
        cancelButton.isHidden = false
        statusLabel.stringValue = "scanning..."
        let started = Date()
        searchQueue.async { [weak self] in
            guard let self else { return }
            let found = self.search.contains(query, progress: { fraction in
                DispatchQueue.main.async { self.progressBar.doubleValue = fraction }
            }, isCancelled: { self.isCancelled })

            DispatchQueue.main.async {
                self.progressBar.isHidden = true
                self.cancelButton.isHidden = true

                guard let found else {
                    self.statusLabel.stringValue = "cancelled"
                    return
                }

                self.hits = found
                self.tableView.reloadData()
                self.statusLabel.stringValue = String(
                    format: "%d results in %.1f s",
                    found.count,
                    Date().timeIntervalSince(started)
                )
            }
        }
    }

    @objc private func chooseRow() {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow

        guard row >= 0, row < hits.count else { return }
        onChoose?(hits[row])
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        hits.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < hits.count, let identifier = tableColumn?.identifier.rawValue else { return nil }
        let hit = hits[row]
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: 11)
        field.lineBreakMode = .byTruncatingMiddle

        switch identifier {
        case "key":
            field.stringValue = hit.key
        case "size":
            field.alignment = .right

            if let file = hit.fileIndex {
                field.stringValue = formatByteCount(reader.fileSize[Int(file)], units: Preferences.units)
            } else {
                field.stringValue = formatByteCount(reader.directories.subtreeBytes(hit.directoryId), units: Preferences.units)
            }
        case "class":
            if let file = hit.fileIndex {
                field.stringValue = StorageClass.names[Int(reader.fileStorageClass[Int(file)])]
            } else {
                field.stringValue = formatCount(reader.directories.subtreeFileCount(hit.directoryId)) + " files"
            }

            field.textColor = .secondaryLabelColor
        default:
            break
        }

        return field
    }
}
