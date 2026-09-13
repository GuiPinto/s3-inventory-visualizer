import AppKit
import InventoryIndex

/// NSClipView draws from the bottom by default, which pushes short content to the foot of the panel.
final class TopAnchoredClipView: NSClipView {
    override var isFlipped: Bool { true }
}

final class DetailsViewController: NSViewController {
    var onCopyKey: ((String) -> Void)?

    private let reader: IndexReader
    private let aggregates: SubtreeAggregates
    private let stack = NSStackView()
    private let scrollView = NSScrollView()
    private let aggregateQueue = DispatchQueue(label: "details.aggregates", qos: .userInitiated)
    private var generation = 0
    private var currentKey: String?
    private var wrappingFields: [NSTextField] = []

    init(reader: IndexReader, aggregates: SubtreeAggregates) {
        self.reader = reader
        self.aggregates = aggregates
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentView = TopAnchoredClipView()
        scrollView.documentView = stack
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])
        view = scrollView
        showNothing()
    }

    private func clear() {
        generation += 1
        wrappingFields.removeAll()

        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func addHeading(_ text: String) {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 11, weight: .bold)
        field.textColor = NSColor.secondaryLabelColor
        stack.addArrangedSubview(field)
    }

    private func addRow(_ label: String, _ value: String) {
        let field = NSTextField(labelWithString: label + "   " + value)
        field.font = .systemFont(ofSize: 11)
        field.lineBreakMode = .byTruncatingMiddle
        field.preferredMaxLayoutWidth = 260
        stack.addArrangedSubview(field)
    }

    private func addSelectableText(_ text: String) {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        field.isSelectable = true

        // A key is one long token with no spaces, so it only wraps if breaking inside a word is allowed.
        field.lineBreakMode = .byCharWrapping
        field.maximumNumberOfLines = 0
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        wrappingFields.append(field)
        stack.addArrangedSubview(field)
        updateWrappingWidth()
    }

    /// The available width is only known once the panel has been laid out, so it is applied here and
    /// again from viewDidLayout.
    private func updateWrappingWidth() {
        let inset = stack.edgeInsets.left + stack.edgeInsets.right
        let width = max(scrollView.contentView.bounds.width - inset, 120)

        for field in wrappingFields where field.preferredMaxLayoutWidth != width {
            field.preferredMaxLayoutWidth = width
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateWrappingWidth()
    }

    private func addBar(_ label: String, _ bytes: UInt64, _ total: UInt64, _ color: NSColor) {
        let share = total == 0 ? 0 : Double(bytes) * 100 / Double(total)
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 6
        let swatch = NSView()
        swatch.wantsLayer = true
        swatch.layer?.backgroundColor = color.cgColor
        swatch.layer?.cornerRadius = 2
        swatch.translatesAutoresizingMaskIntoConstraints = false
        swatch.widthAnchor.constraint(equalToConstant: 10).isActive = true
        swatch.heightAnchor.constraint(equalToConstant: 10).isActive = true
        row.addArrangedSubview(swatch)
        let text = NSTextField(labelWithString: String(
            format: "%@  %@  %.1f%%",
            label,
            formatByteCount(bytes, units: Preferences.units),
            share
        ))
        text.font = .systemFont(ofSize: 11)
        row.addArrangedSubview(text)
        stack.addArrangedSubview(row)
    }

    func showNothing() {
        clear()
        currentKey = nil
        addHeading("NOTHING SELECTED")
        addRow("Click a cell", "in the treemap.")
    }

    func show(file fileIndex: UInt64, directory: UInt32) {
        clear()
        let position = Int(fileIndex)
        let key = reader.key(ofFile: fileIndex)
        currentKey = key
        addHeading("FILE")
        addSelectableText(key)
        addRow("Size", formatByteCount(reader.fileSize[position], units: Preferences.units)
               + "  (" + formatCount(reader.fileSize[position]) + " bytes)")
        addRow("Storage class", StorageClass.names[Int(reader.fileStorageClass[position])])
        let modified = reader.fileLastModified[position]

        if modified > 0 {
            let date = Date(timeIntervalSince1970: TimeInterval(modified))
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .medium
            addRow("Last modified", formatter.string(from: date))
        } else {
            addRow("Last modified", "unknown")
        }

        let extensionIdentifier = Int(reader.fileExtension[position])
        let extensionName = extensionIdentifier < reader.manifest.extensionNames.count
            ? reader.manifest.extensionNames[extensionIdentifier] : ""
        addRow("Extension", extensionName.isEmpty ? "(none)" : "." + extensionName)
        addRow("Directory", reader.directories.path(directory) + "/")

        let copyButton = NSButton(title: "Copy key", target: self, action: #selector(copyKey))
        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .small
        stack.addArrangedSubview(copyButton)
        let uriButton = NSButton(title: "Copy s3:// URI", target: self, action: #selector(copyURI))
        uriButton.bezelStyle = .rounded
        uriButton.controlSize = .small
        stack.addArrangedSubview(uriButton)
    }

    func show(directory: UInt32) {
        clear()
        let tree = reader.directories
        let path = tree.path(directory)
        currentKey = path.isEmpty ? "" : path + "/"
        addHeading("DIRECTORY")
        addSelectableText(path.isEmpty ? "(root)" : path + "/")
        let totalBytes = tree.subtreeBytes(directory)
        addRow("Total size", formatByteCount(totalBytes, units: Preferences.units))
        addRow("Files", formatCount(tree.subtreeFileCount(directory)))
        addRow("Directories", formatCount(UInt64(tree.subtreeDirectoryCount(directory))))
        addRow("Files here", formatCount(UInt64(tree.ownFileCount(directory)))
               + "  (" + formatByteCount(tree.ownBytes(directory), units: Preferences.units) + ")")
        let averageAge = tree.averageAgeDays(directory)
        addRow("Average age", String(format: "%.0f days", averageAge))

        addHeading("")
        addHeading("STORAGE CLASS")
        let classBytes = tree.bytesByStorageClass(directory)

        for (slot, bytes) in classBytes.enumerated() where bytes > 0 {
            addBar(StorageClass.names[slot], bytes, totalBytes, TreemapPalette.color(forStorageClass: slot))
        }

        addHeading("")
        addHeading("TOP EXTENSIONS")
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        stack.addArrangedSubview(spinner)

        generation += 1
        let thisGeneration = generation
        aggregateQueue.async { [weak self] in
            guard let self else { return }
            let breakdown = self.aggregates.extensionBreakdown(of: directory) {
                thisGeneration != self.generation
            }

            DispatchQueue.main.async {
                guard thisGeneration == self.generation else { return }
                spinner.stopAnimation(nil)
                self.stack.removeArrangedSubview(spinner)
                spinner.removeFromSuperview()

                guard let breakdown else { return }

                for (position, entry) in breakdown.entries.prefix(10).enumerated() {
                    let identifier = Int(entry.extensionId)
                    let name = identifier < self.reader.manifest.extensionNames.count
                        ? self.reader.manifest.extensionNames[identifier] : "?"
                    let color = position < TreemapPalette.extensionColors.count
                        ? TreemapPalette.extensionColors[position] : TreemapPalette.extensionOtherColor
                    self.addBar(name.isEmpty ? "(none)" : "." + name, entry.bytes, breakdown.totalBytes, color)
                }

                if breakdown.otherBytes > 0 {
                    self.addBar("other", breakdown.otherBytes, breakdown.totalBytes, TreemapPalette.extensionOtherColor)
                }

                self.appendAgeHistogram(directory: directory, generation: thisGeneration)
            }
        }
    }

    private func appendAgeHistogram(directory: UInt32, generation thisGeneration: Int) {
        addHeading("")
        addHeading("AGE")
        aggregateQueue.async { [weak self] in
            guard let self else { return }
            let breakdown = self.aggregates.ageBreakdown(of: directory) { thisGeneration != self.generation }
            DispatchQueue.main.async {
                guard thisGeneration == self.generation, let breakdown else { return }
                let total = breakdown.bucketBytes.reduce(UInt64(0)) { $0 &+ $1 }

                for (bucket, bytes) in breakdown.bucketBytes.enumerated() where bytes > 0 {
                    self.addBar(TreemapPalette.ageBucketLabels[bucket], bytes, total, TreemapPalette.ageColors[bucket])
                }
            }
        }
    }

    @objc private func copyKey() {
        guard let currentKey else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(currentKey, forType: .string)
        onCopyKey?(currentKey)
    }

    @objc private func copyURI() {
        guard let currentKey else { return }
        let uri = "s3://" + reader.manifest.source.sourceBucket + "/" + currentKey
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(uri, forType: .string)
        onCopyKey?(uri)
    }

    var hasKeyToCopy: Bool { currentKey != nil }

    func copyCurrentKey() {
        copyKey()
    }
}
