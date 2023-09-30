import AppKit
import InventoryIndex
import InventoryImport

final class ImportSheetController: NSWindowController {
    private let source: InventorySource
    private let outputFolder: URL
    private let force: Bool
    private var pipeline: ImportPipeline?
    private var completion: ((Result<IndexManifest, Error>) -> Void)?

    private let headline = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let startButton = NSButton()
    private let cancelButton = NSButton()
    private var started = false

    init(source: InventorySource, outputFolder: URL, force: Bool) {
        self.source = source
        self.outputFolder = outputFolder
        self.force = force
        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        super.init(window: sheet)
        buildInterface(in: sheet)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildInterface(in sheet: NSWindow) {
        let content = NSView()
        sheet.contentView = content

        headline.stringValue = "Build an index for “\(source.sourceBucket)”"
        headline.font = .systemFont(ofSize: 14, weight: .semibold)
        let compressed = formatByteCount(UInt64(source.totalCompressedBytes), units: .binary)
        var text = "\(source.dataFiles.count) inventory files, \(compressed) compressed."
        if !source.missingDataFiles.isEmpty {
            text += " \(source.missingDataFiles.count) files are missing."
        }

        text += "\nThe index is written to \(outputFolder.lastPathComponent) beside the inventory."
        detail.stringValue = text
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 3

        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        statusLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor

        startButton.title = "Build Index"
        startButton.bezelStyle = .rounded
        startButton.keyEquivalent = "\r"
        startButton.target = self
        startButton.action = #selector(startImport)
        cancelButton.title = "Cancel"
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancelImport)

        for subview in [headline, detail, progressBar, statusLabel, startButton, cancelButton] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(subview)
        }

        NSLayoutConstraint.activate([
            headline.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            headline.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            headline.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            detail.topAnchor.constraint(equalTo: headline.bottomAnchor, constant: 8),
            detail.leadingAnchor.constraint(equalTo: headline.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: headline.trailingAnchor),
            progressBar.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 14),
            progressBar.leadingAnchor.constraint(equalTo: headline.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: headline.trailingAnchor),
            statusLabel.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 6),
            statusLabel.leadingAnchor.constraint(equalTo: headline.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: headline.trailingAnchor),
            cancelButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            cancelButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            startButton.bottomAnchor.constraint(equalTo: cancelButton.bottomAnchor),
            startButton.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -10),
        ])
    }

    func beginSheet(on parent: NSWindow, completion: @escaping (Result<IndexManifest, Error>) -> Void) {
        self.completion = completion

        guard let sheet = window else { return }
        parent.beginSheet(sheet) { _ in }
    }

    private func finish(_ result: Result<IndexManifest, Error>) {
        guard let sheet = window else { return }
        sheet.sheetParent?.endSheet(sheet)
        completion?(result)
        completion = nil
    }

    @objc private func cancelImport() {
        if started {
            pipeline?.cancel()
        } else {
            finish(.failure(ImportError.cancelled))
        }
    }

    @objc private func startImport() {
        guard !started else { return }
        started = true
        startButton.isEnabled = false
        statusLabel.stringValue = "ordering files..."

        var options = ImportOptions()
        options.overwriteExistingIndex = force || FileManager.default.fileExists(atPath: outputFolder.path)
        options.allowMissingDataFiles = !source.missingDataFiles.isEmpty
        let pipeline = ImportPipeline(source: source, outputFolder: outputFolder, options: options) { [weak self] progress in
            DispatchQueue.main.async { self?.updateProgress(progress) }
        }

        self.pipeline = pipeline
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let manifest = try pipeline.run()
                DispatchQueue.main.async { self?.finish(.success(manifest)) }
            } catch {
                DispatchQueue.main.async { self?.finish(.failure(error)) }
            }
        }
    }

    private func updateProgress(_ progress: ImportProgress) {
        let fraction = progress.totalCompressedBytes > 0
            ? Double(progress.compressedBytesRead) / Double(progress.totalCompressedBytes) : 0
        progressBar.doubleValue = min(max(fraction, 0), 1)
        let rate = progress.elapsedSeconds > 0 ? Double(progress.rowsConsumed) / progress.elapsedSeconds : 0
        var text = "\(progress.phase)  files \(progress.filesCompleted)/\(progress.fileCount)"
        text += "  rows \(formatCount(progress.rowsConsumed))"
        text += String(format: "  %.0f rows/s  %.0fs", rate, progress.elapsedSeconds)

        if let remaining = progress.estimatedRemainingSeconds, progress.phase == .importing {
            text += String(format: "  eta %.0fs", remaining)
        }

        statusLabel.stringValue = text
    }
}
