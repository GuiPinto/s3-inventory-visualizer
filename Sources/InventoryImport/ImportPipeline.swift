import Foundation
import InventoryIndex

public struct ImportProgress {
    public enum Phase: Equatable { case orderingFiles, importing, postProcessing, finished }
    public var phase: Phase
    public var filesCompleted: Int
    public var fileCount: Int
    public var rowsConsumed: UInt64
    public var compressedBytesRead: Int64
    public var totalCompressedBytes: Int64
    public var elapsedSeconds: Double
    public var estimatedRemainingSeconds: Double?
}

public struct ImportOptions {
    public var threadCount = ProcessInfo.processInfo.activeProcessorCount
    public var allowMissingDataFiles = false
    public var overwriteExistingIndex = false
    public var maximumRowsInFlight = 4_000_000
    public var rowsPerChunk = 262_144
    public var directoryCapacity = IndexFormat.directoryCapacity
    public var nameBlockWorkerCount = 4
    public var progressInterval = 0.25
    public init() {}
}

public final class ImportPipeline {
    private let source: InventorySource
    private let outputFolder: URL
    private let options: ImportOptions
    private let progress: (ImportProgress) -> Void
    private let stateLock = NSLock()
    private var cancelled = false
    private var queue: OrderedChunkQueue?
    private var producerError: Error?

    public init(
        source: InventorySource,
        outputFolder: URL,
        options: ImportOptions = ImportOptions(),
        progress: @escaping (ImportProgress) -> Void
    ) {
        self.source = source
        self.outputFolder = outputFolder
        self.options = options
        self.progress = progress
    }

    public func cancel() {
        stateLock.lock()
        cancelled = true
        let queue = self.queue
        stateLock.unlock()
        queue?.cancel()
    }

    private var isCancelled: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cancelled
    }

    public func run() throws -> IndexManifest {
        let started = Date()

        if !source.missingDataFiles.isEmpty && !options.allowMissingDataFiles {
            throw ImportError.missingDataFiles(source.missingDataFiles)
        }

        if FileManager.default.fileExists(atPath: outputFolder.path) {
            guard options.overwriteExistingIndex else { throw ImportError.outputExists(outputFolder) }
            try FileManager.default.removeItem(at: outputFolder)
        }

        do {
            return try runUnchecked(started: started)
        } catch {
            try? FileManager.default.removeItem(at: outputFolder)
            throw error
        }
    }

    private func report(_ phase: ImportProgress.Phase, files: Int, rows: UInt64, bytes: Int64, started: Date) {
        let elapsed = Date().timeIntervalSince(started)
        var remaining: Double?

        if phase == .importing && bytes > 0 {
            remaining = elapsed * (Double(source.totalCompressedBytes) / Double(bytes) - 1)
        }

        progress(ImportProgress(
            phase: phase,
            filesCompleted: files,
            fileCount: source.dataFiles.count,
            rowsConsumed: rows,
            compressedBytesRead: bytes,
            totalCompressedBytes: source.totalCompressedBytes,
            elapsedSeconds: elapsed,
            estimatedRemainingSeconds: remaining
        ))
    }

    private func runUnchecked(started: Date) throws -> IndexManifest {
        report(.orderingFiles, files: 0, rows: 0, bytes: 0, started: started)
        let files = try FileOrdering.sortedByFirstKey(source.dataFiles, schema: source.schema)

        if isCancelled {
            throw ImportError.cancelled
        }

        let writer = try IndexWriter(folder: outputFolder, directoryCapacity: options.directoryCapacity)
        let sink = NameBlockSink(
            blocks: writer.fileNameBlocks,
            data: writer.fileNameData,
            workerCount: options.nameBlockWorkerCount
        )
        let builder = TreeBuilder(
            writer: writer,
            inventoryTimestamp: source.inventoryTimestamp,
            nameBlockConsumer: sink,
            fileNames: files.map { $0.url.lastPathComponent }
        )
        let queue = OrderedChunkQueue(fileCount: files.count, maximumRowsInFlight: options.maximumRowsInFlight)
        stateLock.lock()
        self.queue = queue
        stateLock.unlock()

        if isCancelled {
            throw ImportError.cancelled
        }

        let nextFileLock = NSLock()
        var nextFile = 0
        let group = DispatchGroup()

        for _ in 0..<max(1, options.threadCount) {
            DispatchQueue.global(qos: .userInitiated).async(group: group) { [self] in
                let parser = InventoryRowParser(schema: source.schema, rowsPerChunk: options.rowsPerChunk)

                while true {
                    nextFileLock.lock()
                    let fileIndex = nextFile
                    nextFile += 1
                    nextFileLock.unlock()

                    guard fileIndex < files.count, !isCancelled else { return }

                    do {
                        let stream = try GzipInflateStream(url: files[fileIndex].url)
                        try parser.parse(stream: stream, fileIndex: fileIndex) { chunk in try queue.enqueue(chunk) }
                        queue.markFileComplete(fileIndex)
                    } catch {
                        let isCancellation = (error as? ImportError) == ImportError.cancelled
                        stateLock.lock()

                        if producerError == nil && !isCancellation {
                            producerError = error
                        }

                        stateLock.unlock()
                        queue.cancel()
                        return
                    }
                }
            }
        }

        var rows: UInt64 = 0
        var bytes: Int64 = 0
        var lastReport = Date.distantPast

        do {
            while let chunk = try queue.dequeueNext() {
                try builder.consume(chunk)
                rows += UInt64(chunk.count)
                bytes += chunk.compressedBytesDelta

                if Date().timeIntervalSince(lastReport) >= options.progressInterval {
                    lastReport = Date()
                    report(.importing, files: queue.completedFilesDelivered, rows: rows, bytes: bytes, started: started)
                }
            }
        } catch {
            queue.cancel()
            group.wait()
            stateLock.lock()
            let failure = producerError
            stateLock.unlock()
            throw failure ?? error
        }

        group.wait()
        stateLock.lock()
        let failure = producerError
        stateLock.unlock()

        if let failure {
            throw failure
        }

        if isCancelled {
            throw ImportError.cancelled
        }

        report(.postProcessing, files: files.count, rows: rows, bytes: bytes, started: started)
        let summary = try builder.finish()
        try IndexPostProcessing.writeChildrenBySize(folder: outputFolder)

        var manifest = IndexManifest.empty(sourceBucket: source.sourceBucket, inventoryTimestamp: source.inventoryTimestamp)
        manifest.importDurationSeconds = Date().timeIntervalSince(started)
        manifest.source = IndexManifest.SourceIdentity(
            sourceBucket: source.sourceBucket,
            manifestCreationTimestamp: source.creationTimestampMilliseconds.map(String.init),
            manifestFileCount: source.dataFiles.count + source.missingDataFiles.count,
            manifestTotalBytes: source.manifestTotalBytes,
            manifestMD5: source.manifestMD5
        )
        manifest.counts = IndexManifest.Counts(
            directoryCount: summary.directoryCount,
            fileCount: summary.fileCount,
            totalBytes: summary.totalBytes,
            skippedNonCurrent: summary.skippedNonCurrent,
            skippedDeleteMarkers: summary.skippedDeleteMarkers,
            rowParseErrors: summary.parseErrors
        )
        manifest.missingDataFiles = source.missingDataFiles
        manifest.extensionNames = summary.extensionNames
        manifest.extensionPalette = IndexManifest.extensionPalette(from: summary.rootExtensionBytes)
        manifest.schemaColumns = source.schema.columnNames
        try manifest.save(to: outputFolder)
        report(.finished, files: files.count, rows: rows, bytes: bytes, started: started)
        return manifest
    }
}
