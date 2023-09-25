import Foundation
import InventoryIndex
import InventoryImport
import TreemapLayout

struct CommandLineOptions {
    var positional: [String] = []
    var flags: [String: String] = [:]

    init(_ arguments: [String]) {
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]

            if argument.hasPrefix("--") {
                let name = String(argument.dropFirst(2))

                if index + 1 < arguments.count && !arguments[index + 1].hasPrefix("--") {
                    flags[name] = arguments[index + 1]
                    index += 2
                } else {
                    flags[name] = "true"
                    index += 1
                }
            } else {
                positional.append(argument)
                index += 1
            }
        }
    }

    func integer(_ name: String, default value: Int) -> Int {
        flags[name].flatMap(Int.init) ?? value
    }

    func double(_ name: String, default value: Double) -> Double {
        flags[name].flatMap(Double.init) ?? value
    }

    func bool(_ name: String) -> Bool {
        flags[name] == "true"
    }
}

func usage() -> Never {
    print("""
    usage:
      s3-inventory-tool index <inventory folder> [--output <folder>] [--threads N] [--force] [--allow-missing]
      s3-inventory-tool stats <index folder>
      s3-inventory-tool generate-fixture <folder> --rows N [--files F]
      s3-inventory-tool bench <index folder> [--width 2560] [--height 1440] [--min-area 4] [--root <path>] [--repeat 5] [--sequential]
      s3-inventory-tool lookup <index folder> <key prefix>
      s3-inventory-tool find <index folder> <substring> [--limit 20]
    """)
    exit(2)
}

func runIndex(_ options: CommandLineOptions) throws {
    guard let path = options.positional.first else {
        usage()
    }

    let inventory = URL(fileURLWithPath: path)
    let source = try InventorySource.load(folder: inventory)
    let output = options.flags["output"].map { URL(fileURLWithPath: $0) } ?? IndexReader.indexFolder(forInventory: inventory)
    var importOptions = ImportOptions()
    importOptions.threadCount = options.integer("threads", default: ProcessInfo.processInfo.activeProcessorCount)
    importOptions.overwriteExistingIndex = options.bool("force")
    importOptions.allowMissingDataFiles = options.bool("allow-missing")
    let compressed = formatByteCount(UInt64(source.totalCompressedBytes), units: .binary)
    print("bucket \(source.sourceBucket): \(source.dataFiles.count) files, \(compressed) compressed; missing \(source.missingDataFiles.count)")
    let pipeline = ImportPipeline(source: source, outputFolder: output, options: importOptions) { progress in
        let percent = progress.totalCompressedBytes > 0
            ? Double(progress.compressedBytesRead) * 100 / Double(progress.totalCompressedBytes) : 0
        let rate = progress.elapsedSeconds > 0 ? Double(progress.rowsConsumed) / progress.elapsedSeconds : 0
        let remaining = progress.estimatedRemainingSeconds.map { String(format: "eta %.0fs", $0) } ?? ""
        let phase = String(describing: progress.phase)
        let rows = formatCount(progress.rowsConsumed)
        let line = String(
            format: "\r%@ %3.0f%% files %d/%d rows %@ %.0f rows/s %.0fs %@   ",
            phase,
            percent,
            progress.filesCompleted,
            progress.fileCount,
            rows,
            rate,
            progress.elapsedSeconds,
            remaining
        )
        FileHandle.standardError.write(line.data(using: .utf8)!)
    }

    let manifest = try pipeline.run()
    let files = formatCount(manifest.counts.fileCount)
    let directories = formatCount(UInt64(manifest.counts.directoryCount))
    let bytes = formatByteCount(manifest.counts.totalBytes, units: .binary)
    print("\ndone: \(files) files, \(directories) directories, \(bytes) in \(String(format: "%.1f", manifest.importDurationSeconds))s")
    print("skipped non-current \(manifest.counts.skippedNonCurrent), delete markers \(manifest.counts.skippedDeleteMarkers), parse errors \(manifest.counts.rowParseErrors)")
}

func runStats(_ options: CommandLineOptions) throws {
    guard let path = options.positional.first else {
        usage()
    }

    let reader = try IndexReader(folder: URL(fileURLWithPath: path))
    let tree = reader.directories
    let counts = reader.manifest.counts
    print("files \(formatCount(counts.fileCount)); directories \(formatCount(UInt64(counts.directoryCount))); bytes \(formatByteCount(counts.totalBytes, units: .binary)); partial \(reader.manifest.isPartial)")
    print("skipped non-current \(counts.skippedNonCurrent); delete markers \(counts.skippedDeleteMarkers); parse errors \(counts.rowParseErrors)")
    print("storage classes:")
    let classBytes = tree.bytesByStorageClass(IndexFormat.rootDirectory)

    for (slot, name) in StorageClass.names.enumerated() where classBytes[slot] > 0 {
        let share = Double(classBytes[slot]) * 100 / Double(max(counts.totalBytes, 1))
        let padded = name.padding(toLength: 20, withPad: " ", startingAt: 0)
        print("  \(padded) \(formatByteCount(classBytes[slot], units: .binary)) (\(String(format: "%.2f", share))%)")
    }

    print("top-level prefixes by bytes:")

    for child in tree.childrenBySize(IndexFormat.rootDirectory).prefix(25) {
        let name = tree.name(child).padding(toLength: 28, withPad: " ", startingAt: 0)
        let bytes = formatByteCount(tree.subtreeBytes(child), units: .binary)
        print("  \(name) \(bytes) files \(formatCount(tree.subtreeFileCount(child))) directories \(formatCount(UInt64(tree.subtreeDirectoryCount(child))))")
    }

    let paletteNames = reader.manifest.extensionPalette.map { reader.manifest.extensionNames[Int($0)] }
    print("extension palette: \(paletteNames)")
}

func runGenerateFixture(_ options: CommandLineOptions) throws {
    guard let path = options.positional.first else {
        usage()
    }

    let folder = URL(fileURLWithPath: path)
    let rowCount = options.integer("rows", default: 1_000_000)
    let fileCount = options.integer("files", default: max(1, rowCount / 1_000_000))
    let dataFolder = folder.appendingPathComponent("data")
    try? FileManager.default.removeItem(at: folder)
    try FileManager.default.createDirectory(at: dataFolder, withIntermediateDirectories: true)
    var generator = SystemRandomNumberGenerator()
    let hexDigits = Array("0123456789abcdef")

    func hex(_ length: Int) -> String {
        String((0..<length).map { _ in hexDigits.randomElement(using: &generator)! })
    }

    let accountCount = max(1, rowCount / 2000)
    let accounts = (0..<accountCount).map { _ in hex(24) }.sorted()
    let suffixes = ["_display.jpg", "_thumb.jpg", ".jpg", "_encoded.mp4", "_still.jpg"]
    var keys: [String] = []
    keys.reserveCapacity(rowCount)
    let perAccountYear = rowCount / accountCount / 4 + 1
    outer: for account in accounts {
        for year in [2023, 2024, 2025, 2026] {
            for _ in 0..<perAccountYear {
                let identifier = hex(8) + "-" + hex(4) + "-" + hex(4) + "-" + hex(4) + "-" + hex(12)
                let a = String(identifier.prefix(1))
                let b = String(identifier.dropFirst(1).prefix(1))
                let c = String(identifier.dropFirst(2).prefix(1))
                let d = String(identifier.dropFirst(3).prefix(1))
                let suffix = suffixes.randomElement(using: &generator)!
                keys.append("assets/" + account + "/" + String(year) + "/snapshots/" + a + "/" + b + "/" + c + "/" + d + "/" + identifier + suffix)

                if keys.count >= rowCount {
                    break outer
                }
            }
        }
    }

    keys.sort()
    let rowsPerFile = max(1, keys.count / max(fileCount, 1) + 1)
    var files: [[String: Any]] = []
    var fileIndex = 0
    var start = 0

    while start < keys.count {
        let name = "part-\(fileIndex).csv.gz"
        let url = dataFolder.appendingPathComponent(name)
        let writer = try GzipDeflateWriter(url: url)

        for key in keys[start..<min(start + rowsPerFile, keys.count)] {
            let size = key.hasSuffix(".mp4")
                ? Int.random(in: 500_000...30_000_000, using: &generator)
                : Int.random(in: 10_000...3_000_000, using: &generator)
            let storageClass = size > 100_000 ? "STANDARD_IA" : "STANDARD"
            let month = Int.random(in: 1...9, using: &generator)
            let day = Int.random(in: 0...9, using: &generator)
            let date = "2025-0\(month)-1\(day)T10:00:00.000Z"
            try writer.write("\"fixture\",\"\(key)\",\"v\",\"true\",\"false\",\"\(size)\",\"\(date)\",\"e\",\"\(storageClass)\",\"false\",\"\",\"\"\n")
        }

        try writer.finish()
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! NSNumber).int64Value
        files.append(["key": "fixture/data/\(name)", "size": size, "MD5checksum": ""])
        start += rowsPerFile
        fileIndex += 1
    }

    let manifest: [String: Any] = [
        "sourceBucket": "fixture",
        "fileFormat": "CSV",
        "creationTimestamp": "1767225600000",
        "fileSchema": InventorySchema.defaultColumns.joined(separator: ", "),
        "files": files
    ]
    try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted])
        .write(to: folder.appendingPathComponent("manifest.json"))
    print("wrote \(keys.count) rows in \(files.count) files to \(folder.path)")
}

func runBench(_ options: CommandLineOptions) throws {
    guard let path = options.positional.first else {
        usage()
    }

    let reader = try IndexReader(folder: URL(fileURLWithPath: path))
    let dataSource = IndexLayoutDataSource(reader: reader, ownFilesCache: OwnFilesCache(reader: reader))
    let engine = TreemapLayoutEngine(dataSource: dataSource)
    engine.parallelismEnabled = !options.bool("sequential")
    let rootPath = options.flags["root"] ?? ""

    guard let root = reader.directories.lookup(path: rootPath) else {
        FileHandle.standardError.write("no directory '\(rootPath)'\n".data(using: .utf8)!)
        exit(1)
    }

    let request = LayoutRequest(
        rootDirectory: root,
        width: options.double("width", default: 2560),
        height: options.double("height", default: 1440),
        minimumCellArea: options.double("min-area", default: 4)
    )
    var timings: [Double] = []
    var lastResult: LayoutResult?

    for _ in 0..<options.integer("repeat", default: 5) {
        let result = engine.layout(request)
        timings.append(result.elapsedSeconds * 1000)
        lastResult = result
    }

    guard let result = lastResult else { return }
    let sorted = timings.sorted()
    let label = rootPath.isEmpty ? "(root)" : rootPath
    print("root '\(label)': instances \(formatCount(UInt64(result.instances.count))), nodes \(formatCount(UInt64(result.nodes.count))), labels \(result.labels.count)")
    print(String(format: "layout ms: first %.1f, min %.1f, median %.1f", timings[0], sorted[0], sorted[sorted.count / 2]))
}

func runLookup(_ options: CommandLineOptions) throws {
    guard options.positional.count == 2 else {
        usage()
    }

    let reader = try IndexReader(folder: URL(fileURLWithPath: options.positional[0]))
    let hits = KeySearch(reader: reader).startsWith(options.positional[1], limit: 20)

    for hit in hits {
        if let fileIndex = hit.fileIndex {
            let position = Int(fileIndex)
            let size = formatByteCount(reader.fileSize[position], units: .binary)
            let storageClass = StorageClass.names[Int(reader.fileStorageClass[position])]
            print("file \(fileIndex) \(hit.key) size \(size) class \(storageClass) modified \(reader.fileLastModified[position]) directory \(hit.directoryId)")
        } else {
            let bytes = formatByteCount(reader.directories.subtreeBytes(hit.directoryId), units: .binary)
            print("directory \(hit.directoryId) \(hit.key) bytes \(bytes) files \(formatCount(reader.directories.subtreeFileCount(hit.directoryId)))")
        }
    }

    if hits.isEmpty {
        print("no match")
    }
}

func runFind(_ options: CommandLineOptions) throws {
    guard options.positional.count == 2 else {
        usage()
    }

    let reader = try IndexReader(folder: URL(fileURLWithPath: options.positional[0]))
    let started = Date()
    let limit = options.integer("limit", default: 20)
    let hits = KeySearch(reader: reader).contains(
        options.positional[1],
        limit: limit,
        progress: { _ in },
        isCancelled: { false }
    ) ?? []
    let elapsed = Date().timeIntervalSince(started)

    for hit in hits.prefix(limit) {
        print(hit.key)
    }

    print(String(format: "%d hits (limit %d) in %.2fs", hits.count, limit, elapsed))
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    usage()
}
let commandOptions = CommandLineOptions(Array(arguments.dropFirst()))
do {
    switch command {
    case "index": try runIndex(commandOptions)
    case "stats": try runStats(commandOptions)
    case "generate-fixture": try runGenerateFixture(commandOptions)
    case "bench": try runBench(commandOptions)
    case "lookup": try runLookup(commandOptions)
    case "find": try runFind(commandOptions)
    default: usage()
    }
} catch {
    FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
    exit(1)
}
