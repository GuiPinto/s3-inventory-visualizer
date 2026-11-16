# S3 Inventory Visualizer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a native macOS app that imports an AWS S3 Inventory CSV export (up to 1.12 billion objects) into a memory-mapped columnar index and renders a WinDirStat-style cushion treemap with instant hover, zoom, color modes, a directory tree, details, and find.

**Architecture:** A Swift package holds three libraries (`InventoryIndex` = index format + reader services, `InventoryImport` = streaming importer, `TreemapLayout` = squarified cushion layout) and one CLI (`s3-inventory-tool`). An xcodegen-generated AppKit app links the package and draws the treemap with Metal. The importer streams the key-sorted inventory once; the viewer memory-maps column files and lays out only what the screen can show.

**Tech Stack:** Swift 6.2 toolchain in Swift 5 language mode, Swift Package Manager, XCTest, AppKit, Metal (MTKView), `import zlib` (gzip inflate/deflate), Apple `Compression` framework (LZFSE), xcodegen 2.x, xcodebuild. No third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-09-12-s3-inventory-visualizer-design.md` (read it first; every task argues from it).

## Global Constraints

- **Git is owned by the user.** Never run `git add`, `git commit`, `git push`, `git stash`, `git checkout` or any other git command. At the end of each task, report the list of changed files and stop; the user commits.
- **Identifiers are spelled in full.** No abbreviations in Swift identifiers, file names, or CLI flags (`directoryCount`, not `dirCnt`; `fileIndex`, not `fi`). Loop counters may be `index`.
- **Repository root:** `/Users/gui/Development/s3-inventory-visualizer`. All paths below are relative to it.
- **Language mode:** `swiftLanguageModes: [.v5]` in `Package.swift`; `SWIFT_VERSION: 5.0` in the app target. Do not switch to Swift 6 mode.
- **No third-party packages.** Argument parsing, LRU caches, and gzip are hand-written or system frameworks.
- **Index format constants (from the spec):** folder name `.s3-inventory-index`, 4096 names per block, 8 storage class slots, directory capacity 256,000,000, 64-byte column header with magic `S3VZCOL1`, little-endian, format version 1.
- **Storage class ids are fixed:** STANDARD 0, STANDARD_IA 1, INTELLIGENT_TIERING 2, ONEZONE_IA 3, GLACIER_IR 4, GLACIER 5, DEEP_ARCHIVE 6, everything else (REDUCED_RUNDANCY, EXPRESS_ONEZONE, OUTPOSTS, SNOW, empty, unknown) 7 = OTHER.
- **Skip at import:** rows with `IsLatest == false` or `IsDeleteMarker == true`; count them.
- **URL decoding:** `%XX` becomes the byte; `+` stays a literal `+`; an invalid escape keeps the literal bytes.
- **Performance targets (spec sections 6 and 8):** reference import ≤ 15 minutes (stretch 8) and ≤ 8 GB resident; any layout at 2560 × 1440, 4 px² cells ≤ 100 ms; hover ≤ 8 ms; color-mode switch is one uniform change.
- **Tests:** `swift test` from the repository root must pass at the end of every task. App tasks end with a manual checklist and a screenshot saved under `docs/screenshots/`.
- **Verify file state before editing.** The user switches branches during sessions; read a file immediately before editing it, and re-check with `grep` that a previous task's code is present before building on it.
- **Reference data for acceptance runs:** inventory folder `~/inventories/production-bucket` (574 files, 82.3 GB gzipped). Index output goes beside it in `.s3-inventory-index/` (about 40 GB; the disk has 142 GB free). Run the acceptance import with `caffeinate -i` so the Mac does not sleep.

---

## File structure

```
Package.swift
Makefile                                   # build, test, app, bench shortcuts
.gitignore                                 # .build/, App/*.xcodeproj, DerivedData, .s3-inventory-index/
README.md
docs/benchmarks.md                         # acceptance numbers, appended per phase
docs/screenshots/                          # app screenshots per task

Sources/InventoryIndex/                    # index format and reader-side services
  IndexFormat.swift                        # constants, column file names, IndexError
  ColumnFile.swift                         # ColumnHeader, MappedColumn<T>, ColumnWriter<T>, SparseMappedColumn<T>
  StorageClass.swift                       # fixed 8-slot enum and name mapping
  ExtensionDictionary.swift                # extension interning and extraction
  IndexManifest.swift                      # index.json Codable
  ByteCountFormatting.swift                # binary and decimal byte strings
  NameBlockCodec.swift                     # LZFSE block encode/decode, length-prefixed names
  IndexWriter.swift                        # opens every column for writing
  IndexReader.swift                        # maps every column; key(ofFile:), directory(ofFile:)
  DirectoryTree.swift                      # id arithmetic, ranges, names, paths, lookup
  NameBlockCache.swift                     # LRU of decoded blocks
  OwnFilesCache.swift                      # own files at or above a size threshold, sorted
  SubtreeAggregates.swift                  # on-demand extension and age breakdowns
  KeySearch.swift                          # starts-with and contains

Sources/InventoryImport/
  GzipStreams.swift                        # GzipInflateStream, GzipDeflateWriter (zlib)
  InventorySource.swift                    # manifest.json, InventorySchema, data file resolution
  InventoryRowParser.swift                 # CSV rows → RowChunk
  FileOrdering.swift                       # first key per file, sort
  OrderedChunkQueue.swift                  # producer/consumer queue with backpressure
  NameBlockSink.swift                      # parallel LZFSE with in-order writes
  TreeBuilder.swift                        # the single-threaded consumer
  PostPass.swift                           # childrenBySize, palette
  ImportPipeline.swift                     # orchestration, progress, cancel

Sources/TreemapLayout/
  LayoutGeometry.swift                     # LayoutRect, CushionCoefficients
  Squarify.swift                           # squarified rows
  LayoutTypes.swift                        # TreemapInstance, HitTestNode, LayoutResult, LayoutRequest, LayoutDataSource
  TreemapLayoutEngine.swift                # recursion with pixel budget and remainder
  IndexLayoutDataSource.swift              # LayoutDataSource over IndexReader + OwnFilesCache

Sources/s3-inventory-tool/
  main.swift                               # index | stats | bench | lookup | generate-fixture

Tests/TestSupport/FixtureInventory.swift   # builds synthetic inventories (manifest + gz CSV) and a brute-force reference tree
Tests/InventoryIndexTests/…
Tests/InventoryImportTests/…
Tests/TreemapLayoutTests/…

App/project.yml                            # xcodegen spec
App/Info.plist
App/Sources/AppDelegate.swift
App/Sources/Document/InventoryDocument.swift, InventoryDocumentController.swift
App/Sources/Window/MainWindowController.swift, MainSplitViewController.swift, NavigationHistory.swift
App/Sources/Treemap/Shaders.metal, TreemapRenderer.swift, TreemapMetalView.swift, TreemapViewController.swift,
                    LabelOverlayView.swift, BreadcrumbView.swift, LegendView.swift, TreemapPalette.swift
App/Sources/Tree/DirectoryOutlineViewController.swift, DirectoryOutlineItem.swift, ClassMixBarView.swift
App/Sources/Details/DetailsViewController.swift
App/Sources/Search/SearchPanelController.swift
App/Sources/Import/ImportSheetController.swift
App/Sources/Support/Preferences.swift
App/Resources/Assets.xcassets
```

---

## Phase 0 — Scaffold

### Task 1: Swift package skeleton, Makefile, test support target

**Files:**
- Create: `Package.swift`, `.gitignore`, `Makefile`, `README.md`
- Create: `Sources/InventoryIndex/IndexFormat.swift`
- Create: `Sources/InventoryImport/Placeholder.swift` (deleted in Task 7), `Sources/TreemapLayout/Placeholder.swift` (deleted in Task 15), `Sources/s3-inventory-tool/main.swift`
- Create: `Tests/TestSupport/FixtureInventory.swift` (first version: only the row model), `Tests/InventoryIndexTests/IndexFormatTests.swift`

**Interfaces:**
- Produces: `IndexFormat` constants and `IndexFiles` column names (used by every later task), `IndexError`.

- [ ] **Step 1: Write `Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "S3InventoryVisualizerCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "InventoryIndex", targets: ["InventoryIndex"]),
        .library(name: "InventoryImport", targets: ["InventoryImport"]),
        .library(name: "TreemapLayout", targets: ["TreemapLayout"]),
        .executable(name: "s3-inventory-tool", targets: ["s3-inventory-tool"]),
    ],
    targets: [
        .target(name: "InventoryIndex", swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]),
        .target(name: "InventoryImport", dependencies: ["InventoryIndex"], swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]),
        .target(name: "TreemapLayout", dependencies: ["InventoryIndex"]),
        .executableTarget(name: "s3-inventory-tool", dependencies: ["InventoryIndex", "InventoryImport", "TreemapLayout"]),
        .target(name: "TestSupport", dependencies: ["InventoryIndex", "InventoryImport"], path: "Tests/TestSupport"),
        .testTarget(name: "InventoryIndexTests", dependencies: ["InventoryIndex", "TestSupport"]),
        .testTarget(name: "InventoryImportTests", dependencies: ["InventoryImport", "TestSupport"]),
        .testTarget(name: "TreemapLayoutTests", dependencies: ["TreemapLayout", "TestSupport"]),
    ],
    swiftLanguageModes: [.v5]
)
```

Note: `-Ounchecked` removes overflow and bounds checks in release builds of the two hot libraries only. If `swift build -c release` refuses `unsafeFlags` for a root package dependency from the app (Task 2), remove the `swiftSettings` lines; correctness must never depend on them.

- [ ] **Step 2: Write `.gitignore`, `Makefile`, `README.md`**

`.gitignore`:
```
.build/
.swiftpm/
DerivedData/
App/*.xcodeproj
App/build/
*.xcuserstate
.DS_Store
.s3-inventory-index/
```

`Makefile`:
```make
.PHONY: build test release app clean bench

build:
	swift build

test:
	swift test

release:
	swift build -c release

app:
	cd App && xcodegen generate && xcodebuild -project S3InventoryVisualizer.xcodeproj -scheme "S3 Inventory Visualizer" -configuration Release -derivedDataPath build build | tail -20
	@echo "App at App/build/Build/Products/Release/S3 Inventory Visualizer.app"

clean:
	rm -rf .build App/build App/S3InventoryVisualizer.xcodeproj
```

`README.md`: title, one paragraph from the spec goal, the `make` targets, and a pointer to the spec and plan.

- [ ] **Step 3: Write `IndexFormat.swift`**

```swift
import Foundation

public enum IndexFormat {
    public static let formatVersion: UInt32 = 1
    public static let folderName = ".s3-inventory-index"
    public static let namesPerBlock = 4096
    public static let storageClassSlots = 8
    public static let directoryCapacity = 256_000_000
    public static let columnHeaderSize = 64
    public static let columnMagic: [UInt8] = Array("S3VZCOL1".utf8)
    public static let rootDirectory: UInt32 = 0
    public static let noParent: UInt32 = UInt32.max
    public static let ageBucketDays: [UInt32] = [30, 90, 180, 365, 730, 1095, 1825]  // 8 buckets: 7 boundaries + "older"
}

public enum IndexFiles {
    public static let manifest = "index.json"
    public static let directoryParent = "directory.parent.u32"
    public static let directoryDepth = "directory.depth.u8"
    public static let directorySubtreeDirectoryCount = "directory.subtreeDirectoryCount.u32"
    public static let directoryChildCount = "directory.childCount.u32"
    public static let directoryFileStart = "directory.fileStart.u64"
    public static let directorySubtreeFileCount = "directory.subtreeFileCount.u64"
    public static let directorySubtreeBytes = "directory.subtreeBytes.u64"
    public static let directoryOwnFileCount = "directory.ownFileCount.u32"
    public static let directoryOwnBytes = "directory.ownBytes.u64"
    public static let directoryNameOffset = "directory.nameOffset.u64"
    public static let directoryNameLength = "directory.nameLength.u16"
    public static let directoryNames = "directory.names.bytes"
    public static let directoryBytesByStorageClass = "directory.bytesByStorageClass.u64x8"
    public static let directoryDominantExtension = "directory.dominantExtension.u16"
    public static let directoryAgeWeightedBytes = "directory.ageWeightedBytes.u64"
    public static let directoryChildListStart = "directory.childListStart.u32"
    public static let directoryChildrenBySize = "directory.childrenBySize.u32"
    public static let fileSize = "file.size.u64"
    public static let fileLastModified = "file.lastModified.u32"
    public static let fileStorageClass = "file.storageClass.u8"
    public static let fileExtension = "file.extension.u16"
    public static let fileNameBlocks = "file.names.blocks"
    public static let fileNameData = "file.names.data"
}

public enum IndexError: Error, Equatable {
    case incompleteIndex(URL)
    case badColumnHeader(String)
    case elementSizeMismatch(String, expected: Int, found: Int)
    case systemCall(String, errno: Int32)
    case manifestMismatch(String)
}
```

- [ ] **Step 4: Write the first test and the placeholders**

`Tests/InventoryIndexTests/IndexFormatTests.swift`:
```swift
import XCTest
@testable import InventoryIndex

final class IndexFormatTests: XCTestCase {
    func testConstantsMatchSpec() {
        XCTAssertEqual(IndexFormat.folderName, ".s3-inventory-index")
        XCTAssertEqual(IndexFormat.namesPerBlock, 4096)
        XCTAssertEqual(IndexFormat.storageClassSlots, 8)
        XCTAssertEqual(IndexFormat.columnMagic.count, 8)
        XCTAssertEqual(IndexFormat.ageBucketDays.count, 7)
    }
}
```

`Sources/InventoryImport/Placeholder.swift` and `Sources/TreemapLayout/Placeholder.swift`: `import Foundation` and one line `enum Placeholder {}`. `Sources/s3-inventory-tool/main.swift`: `print("s3-inventory-tool: commands arrive in Task 13")`.

`Tests/TestSupport/FixtureInventory.swift` (first version):
```swift
import Foundation

/// One inventory row as the fixture builder and the brute-force reference see it.
public struct FixtureRow: Equatable {
    public var key: String              // decoded key
    public var size: UInt64
    public var lastModified: String     // ISO-8601 as the inventory writes it, e.g. "2026-02-16T12:16:56.000Z"
    public var storageClass: String
    public var isLatest: Bool = true
    public var isDeleteMarker: Bool = false
    public init(key: String, size: UInt64, lastModified: String = "2026-01-01T00:00:00.000Z", storageClass: String = "STANDARD", isLatest: Bool = true, isDeleteMarker: Bool = false) {
        self.key = key; self.size = size; self.lastModified = lastModified; self.storageClass = storageClass; self.isLatest = isLatest; self.isDeleteMarker = isDeleteMarker
    }
}
```

- [ ] **Step 5: Build and run the tests**

Run: `swift build && swift test 2>&1 | tail -5`
Expected: `Test Suite 'All tests' passed` with 1 test.

- [ ] **Step 6: Report**

List the created files. Do not run git.

### Task 2: App skeleton with xcodegen and a Metal view that clears to the canvas color

**Files:**
- Create: `App/project.yml`, `App/Info.plist`, `App/Sources/AppDelegate.swift`, `App/Sources/Treemap/TreemapMetalView.swift` (first version), `App/Sources/Treemap/Shaders.metal` (first version), `App/Resources/Assets.xcassets/Contents.json`

**Interfaces:**
- Produces: the app target `S3 Inventory Visualizer` that links `InventoryIndex`, `InventoryImport`, `TreemapLayout`; `TreemapMetalView` (an `MTKView` subclass) replaced in Task 18.

- [ ] **Step 1: Write `App/project.yml`**

```yaml
name: S3InventoryVisualizer
options:
  bundleIdPrefix: com.guipinto
  deploymentTarget:
    macOS: "14.0"
  createIntermediateGroups: true
packages:
  S3InventoryVisualizerCore:
    path: ..
targets:
  S3 Inventory Visualizer:
    type: application
    platform: macOS
    sources:
      - path: Sources
      - path: Resources
    info:
      path: Info.plist
      properties:
        CFBundleName: S3 Inventory Visualizer
        CFBundleDisplayName: S3 Inventory Visualizer
        CFBundleIdentifier: com.guipinto.s3-inventory-visualizer
        CFBundleShortVersionString: "0.1.0"
        CFBundleVersion: "1"
        LSMinimumSystemVersion: "14.0"
        NSPrincipalClass: NSApplication
        NSHighResolutionCapable: true
        CFBundleDocumentTypes:
          - CFBundleTypeName: S3 Inventory Folder
            CFBundleTypeRole: Viewer
            LSHandlerRank: Alternate
            LSItemContentTypes: [public.folder]
            NSDocumentClass: S3_Inventory_Visualizer.InventoryDocument
    dependencies:
      - package: S3InventoryVisualizerCore
        product: InventoryIndex
      - package: S3InventoryVisualizerCore
        product: InventoryImport
      - package: S3InventoryVisualizerCore
        product: TreemapLayout
    settings:
      base:
        SWIFT_VERSION: "5.0"
        PRODUCT_NAME: S3 Inventory Visualizer
        PRODUCT_BUNDLE_IDENTIFIER: com.guipinto.s3-inventory-visualizer
        CODE_SIGN_IDENTITY: "-"
        CODE_SIGN_STYLE: Manual
        ENABLE_HARDENED_RUNTIME: false
        ENABLE_APP_SANDBOX: false
        MTL_ENABLE_DEBUG_INFO: INCLUDE_SOURCE
        SWIFT_OPTIMIZATION_LEVEL: "-O"
        GENERATE_INFOPLIST_FILE: false
        INFOPLIST_FILE: Info.plist
schemes:
  S3 Inventory Visualizer:
    build:
      targets:
        S3 Inventory Visualizer: all
    run:
      config: Debug
```

`App/Info.plist` may be a minimal plist with `<dict/>`; xcodegen merges the `properties` above into it. `NSDocumentClass` uses the module name `S3_Inventory_Visualizer` (spaces become underscores). `InventoryDocument` arrives in Task 23; until then the app opens its window from the delegate.

- [ ] **Step 2: Write the delegate and the Metal view**

`App/Sources/AppDelegate.swift`:
```swift
import AppKit
import MetalKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "S3 Inventory Visualizer"
        window.contentView = TreemapMetalView(frame: window.contentView!.bounds, device: MTLCreateSystemDefaultDevice())
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
```

`App/Sources/Treemap/TreemapMetalView.swift` (first version):
```swift
import MetalKit

final class TreemapMetalView: MTKView {
    private var commandQueue: MTLCommandQueue?

    override init(frame frameRect: CGRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device)
        commandQueue = device?.makeCommandQueue()
        clearColor = MTLClearColor(red: 0x16 / 255.0, green: 0x18 / 255.0, blue: 0x1D / 255.0, alpha: 1)
        isPaused = true
        enableSetNeedsDisplay = true
        autoresizingMask = [.width, .height]
    }

    required init(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        guard let drawable = currentDrawable, let descriptor = currentRenderPassDescriptor,
              let commandBuffer = commandQueue?.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
```

`App/Sources/Treemap/Shaders.metal` (first version, proves the shader compile step):
```metal
#include <metal_stdlib>
using namespace metal;

vertex float4 treemapPlaceholderVertex(uint vertexIdentifier [[vertex_id]]) {
    return float4(0, 0, 0, 1);
}
fragment float4 treemapPlaceholderFragment() {
    return float4(1, 1, 1, 1);
}
```

`App/Resources/Assets.xcassets/Contents.json`: `{"info":{"author":"xcode","version":1}}`.

- [ ] **Step 3: Generate and build**

Run: `make app`
Expected: `** BUILD SUCCEEDED **`. If xcodegen complains about the package path, confirm `packages.S3InventoryVisualizerCore.path` resolves to the repository root (`..` from `App/`).

- [ ] **Step 4: Launch and screenshot**

Run: `open "App/build/Build/Products/Release/S3 Inventory Visualizer.app"`, then `screencapture -x docs/screenshots/task02-empty-window.png` after the window appears (create `docs/screenshots/` first). Expected: a dark `#16181D` window titled "S3 Inventory Visualizer". Quit the app.

- [ ] **Step 5: Report**

List the created files. Do not run git.

---
## Phase 1 — Index format

### Task 3: Column files — header, mapped reader, sequential writer, sparse random-access writer

**Files:**
- Create: `Sources/InventoryIndex/ColumnFile.swift`
- Test: `Tests/InventoryIndexTests/ColumnFileTests.swift`

**Interfaces:**
- Consumes: `IndexFormat`, `IndexError` (Task 1).
- Produces:
  - `struct ColumnHeader { formatVersion: UInt32; elementSize: UInt32; count: UInt64; func encoded() -> [UInt8]; static func decode(_:fileName:) throws -> ColumnHeader }`
  - `final class MappedColumn<Element>` — `init(url: URL) throws`, `count: Int`, `buffer: UnsafeBufferPointer<Element>`, `subscript(index: Int) -> Element`.
  - `final class ColumnWriter<Element>` — `init(url: URL, bufferSize: Int = 4 << 20) throws`, `count: Int`, `append(_:)`, `append(contentsOf: UnsafeBufferPointer<Element>)`, `appendBytes(_: UnsafeRawBufferPointer)` (only meaningful for `UInt8` columns), `finish() throws`.
  - `final class SparseMappedColumn<Element>` — `init(url: URL, capacity: Int) throws`, `subscript(index: Int) -> Element { get set }`, `finish(count: Int) throws`.
  - `Element` must be a trivial (POD) type: integers or structs of integers.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import InventoryIndex

final class ColumnFileTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("column-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    func testSequentialWriteThenMappedRead() throws {
        let url = folder.appendingPathComponent("values.u64")
        let writer = try ColumnWriter<UInt64>(url: url, bufferSize: 100)   // tiny buffer forces flushes
        for value in 0..<1000 { writer.append(UInt64(value) * 7) }
        try writer.finish()
        let column = try MappedColumn<UInt64>(url: url)
        XCTAssertEqual(column.count, 1000)
        XCTAssertEqual(column[0], 0)
        XCTAssertEqual(column[999], 999 * 7)
        XCTAssertEqual(Array(column.buffer[10..<13]), [70, 77, 84])
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int
        XCTAssertEqual(size, IndexFormat.columnHeaderSize + 1000 * 8)
    }

    func testByteColumnAppendBytes() throws {
        let url = folder.appendingPathComponent("names.bytes")
        let writer = try ColumnWriter<UInt8>(url: url)
        let text = Array("hello, world".utf8)
        text.withUnsafeBytes { writer.appendBytes($0) }
        try writer.finish()
        let column = try MappedColumn<UInt8>(url: url)
        XCTAssertEqual(String(decoding: column.buffer, as: UTF8.self), "hello, world")
    }

    func testSparseColumnTruncatesToCount() throws {
        let url = folder.appendingPathComponent("sparse.u32")
        let sparse = try SparseMappedColumn<UInt32>(url: url, capacity: 1_000_000)
        sparse[0] = 1
        sparse[5] = 55
        sparse[999] = 9999
        try sparse.finish(count: 1000)
        let column = try MappedColumn<UInt32>(url: url)
        XCTAssertEqual(column.count, 1000)
        XCTAssertEqual(column[5], 55)
        XCTAssertEqual(column[999], 9999)
        XCTAssertEqual(column[1], 0)
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int
        XCTAssertEqual(size, IndexFormat.columnHeaderSize + 1000 * 4)
    }

    func testElementSizeMismatchIsDetected() throws {
        let url = folder.appendingPathComponent("values.u32")
        let writer = try ColumnWriter<UInt32>(url: url)
        writer.append(1)
        try writer.finish()
        XCTAssertThrowsError(try MappedColumn<UInt64>(url: url)) { error in
            guard case IndexError.elementSizeMismatch = error else { return XCTFail("wrong error \(error)") }
        }
    }

    func testBadMagicIsDetected() throws {
        let url = folder.appendingPathComponent("garbage.u8")
        try Data(repeating: 0x41, count: 128).write(to: url)
        XCTAssertThrowsError(try MappedColumn<UInt8>(url: url)) { error in
            guard case IndexError.badColumnHeader = error else { return XCTFail("wrong error \(error)") }
        }
    }

    func testStructElements() throws {
        struct Pair { var left: UInt64; var right: UInt32; var padding: UInt32 }
        let url = folder.appendingPathComponent("pairs.bin")
        let writer = try ColumnWriter<Pair>(url: url)
        writer.append(Pair(left: 1, right: 2, padding: 0))
        writer.append(Pair(left: 3, right: 4, padding: 0))
        try writer.finish()
        let column = try MappedColumn<Pair>(url: url)
        XCTAssertEqual(column.count, 2)
        XCTAssertEqual(column[1].left, 3)
        XCTAssertEqual(column[1].right, 4)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ColumnFileTests 2>&1 | tail -5`
Expected: compile error, `ColumnWriter` not found.

- [ ] **Step 3: Write `ColumnFile.swift`**

```swift
import Foundation

public struct ColumnHeader {
    public var formatVersion: UInt32
    public var elementSize: UInt32
    public var count: UInt64

    public func encoded() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: IndexFormat.columnHeaderSize)
        bytes.replaceSubrange(0..<8, with: IndexFormat.columnMagic)
        withUnsafeBytes(of: formatVersion.littleEndian) { bytes.replaceSubrange(8..<12, with: $0) }
        withUnsafeBytes(of: elementSize.littleEndian) { bytes.replaceSubrange(12..<16, with: $0) }
        withUnsafeBytes(of: count.littleEndian) { bytes.replaceSubrange(16..<24, with: $0) }
        return bytes
    }

    public static func decode(_ bytes: UnsafeRawBufferPointer, fileName: String) throws -> ColumnHeader {
        guard bytes.count >= IndexFormat.columnHeaderSize,
              Array(bytes[0..<8]) == IndexFormat.columnMagic else { throw IndexError.badColumnHeader(fileName) }
        let formatVersion = UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 8, as: UInt32.self))
        let elementSize = UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 12, as: UInt32.self))
        let count = UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: 16, as: UInt64.self))
        guard formatVersion == IndexFormat.formatVersion else { throw IndexError.badColumnHeader(fileName) }
        return ColumnHeader(formatVersion: formatVersion, elementSize: elementSize, count: count)
    }
}

/// Read-only memory map of one column file. `Element` must be a trivial type.
public final class MappedColumn<Element> {
    public let url: URL
    public let count: Int
    public let buffer: UnsafeBufferPointer<Element>
    private let mappingBase: UnsafeMutableRawPointer
    private let mappingLength: Int

    public init(url: URL) throws {
        let (base, length, count) = try MappedColumn.map(url: url)
        self.url = url
        self.mappingBase = base
        self.mappingLength = length
        self.count = count
        let start = (base + IndexFormat.columnHeaderSize).assumingMemoryBound(to: Element.self)
        self.buffer = UnsafeBufferPointer(start: start, count: count)
    }

    private static func map(url: URL) throws -> (UnsafeMutableRawPointer, Int, Int) {
        let name = url.lastPathComponent
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw IndexError.systemCall("open \(name)", errno: errno) }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw IndexError.systemCall("fstat \(name)", errno: errno) }
        let length = Int(status.st_size)
        guard length >= IndexFormat.columnHeaderSize else { throw IndexError.badColumnHeader(name) }
        guard let base = mmap(nil, length, PROT_READ, MAP_PRIVATE, descriptor, 0), base != MAP_FAILED else {
            throw IndexError.systemCall("mmap \(name)", errno: errno)
        }
        do {
            let header = try ColumnHeader.decode(UnsafeRawBufferPointer(start: base, count: IndexFormat.columnHeaderSize), fileName: name)
            let stride = MemoryLayout<Element>.stride
            guard Int(header.elementSize) == stride else {
                throw IndexError.elementSizeMismatch(name, expected: stride, found: Int(header.elementSize))
            }
            let count = Int(header.count)
            guard IndexFormat.columnHeaderSize + count * stride <= length else { throw IndexError.badColumnHeader(name) }
            return (base, length, count)
        } catch {
            munmap(base, length)
            throw error
        }
    }

    deinit { munmap(mappingBase, mappingLength) }

    @inline(__always) public subscript(index: Int) -> Element { buffer[index] }
}

/// Append-only column writer with a large write buffer. Errors during `append` are remembered and thrown by `finish()`.
public final class ColumnWriter<Element> {
    public let url: URL
    public private(set) var count: Int = 0
    private let descriptor: Int32
    private let buffer: UnsafeMutableRawPointer
    private let bufferCapacity: Int
    private var bufferUsed = 0
    private var finished = false
    private var writeError: Error?
    private let stride = MemoryLayout<Element>.stride

    public init(url: URL, bufferSize: Int = 4 << 20) throws {
        self.url = url
        descriptor = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard descriptor >= 0 else { throw IndexError.systemCall("create \(url.lastPathComponent)", errno: errno) }
        bufferCapacity = max(bufferSize, stride * 16)
        buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferCapacity, alignment: 64)
        let placeholder = [UInt8](repeating: 0, count: IndexFormat.columnHeaderSize)
        try placeholder.withUnsafeBytes { try writeFully($0) }
    }

    @inline(__always) public func append(_ value: Element) {
        if bufferUsed + stride > bufferCapacity { flushBuffer() }
        buffer.storeBytes(of: value, toByteOffset: bufferUsed, as: Element.self)
        bufferUsed += stride
        count += 1
    }

    public func append(contentsOf values: UnsafeBufferPointer<Element>) {
        for value in values { append(value) }
    }

    /// Appends raw bytes; `count` advances by `bytes.count / stride` (use with `UInt8` columns).
    public func appendBytes(_ bytes: UnsafeRawBufferPointer) {
        var offset = 0
        while offset < bytes.count {
            if bufferUsed == bufferCapacity { flushBuffer() }
            let chunk = min(bytes.count - offset, bufferCapacity - bufferUsed)
            (buffer + bufferUsed).copyMemory(from: bytes.baseAddress! + offset, byteCount: chunk)
            bufferUsed += chunk
            offset += chunk
        }
        count += bytes.count / stride
    }

    private func flushBuffer() {
        guard writeError == nil, bufferUsed > 0 else { bufferUsed = 0; return }
        do { try writeFully(UnsafeRawBufferPointer(start: buffer, count: bufferUsed)) } catch { writeError = error }
        bufferUsed = 0
    }

    private func writeFully(_ bytes: UnsafeRawBufferPointer) throws {
        var offset = 0
        while offset < bytes.count {
            let written = write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
            guard written > 0 else { throw IndexError.systemCall("write \(url.lastPathComponent)", errno: errno) }
            offset += written
        }
    }

    public func finish() throws {
        guard !finished else { return }
        finished = true
        flushBuffer()
        defer { close(descriptor); buffer.deallocate() }
        if let error = writeError { throw error }
        let header = ColumnHeader(formatVersion: IndexFormat.formatVersion, elementSize: UInt32(stride), count: UInt64(count)).encoded()
        guard lseek(descriptor, 0, SEEK_SET) == 0 else { throw IndexError.systemCall("lseek \(url.lastPathComponent)", errno: errno) }
        try header.withUnsafeBytes { try writeFully($0) }
    }

    deinit { if !finished { close(descriptor); buffer.deallocate() } }
}

/// Random-access column writer over a sparse file (APFS allocates only the written pages).
public final class SparseMappedColumn<Element> {
    public let url: URL
    public let capacity: Int
    private let descriptor: Int32
    private let mappingBase: UnsafeMutableRawPointer
    private let mappingLength: Int
    private let elements: UnsafeMutablePointer<Element>
    private var finished = false

    public init(url: URL, capacity: Int) throws {
        self.url = url
        self.capacity = capacity
        let name = url.lastPathComponent
        descriptor = open(url.path, O_RDWR | O_CREAT | O_TRUNC, 0o644)
        guard descriptor >= 0 else { throw IndexError.systemCall("create \(name)", errno: errno) }
        mappingLength = IndexFormat.columnHeaderSize + capacity * MemoryLayout<Element>.stride
        guard ftruncate(descriptor, off_t(mappingLength)) == 0 else {
            close(descriptor); throw IndexError.systemCall("ftruncate \(name)", errno: errno)
        }
        guard let base = mmap(nil, mappingLength, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0), base != MAP_FAILED else {
            close(descriptor); throw IndexError.systemCall("mmap \(name)", errno: errno)
        }
        mappingBase = base
        elements = (base + IndexFormat.columnHeaderSize).assumingMemoryBound(to: Element.self)
    }

    @inline(__always) public subscript(index: Int) -> Element {
        get { elements[index] }
        set { elements[index] = newValue }
    }

    public func finish(count: Int) throws {
        guard !finished else { return }
        finished = true
        let name = url.lastPathComponent
        let header = ColumnHeader(formatVersion: IndexFormat.formatVersion, elementSize: UInt32(MemoryLayout<Element>.stride), count: UInt64(count)).encoded()
        header.withUnsafeBytes { mappingBase.copyMemory(from: $0.baseAddress!, byteCount: IndexFormat.columnHeaderSize) }
        let syncResult = msync(mappingBase, mappingLength, MS_SYNC)
        munmap(mappingBase, mappingLength)
        defer { close(descriptor) }
        guard syncResult == 0 else { throw IndexError.systemCall("msync \(name)", errno: errno) }
        let finalLength = IndexFormat.columnHeaderSize + count * MemoryLayout<Element>.stride
        guard ftruncate(descriptor, off_t(finalLength)) == 0 else { throw IndexError.systemCall("ftruncate \(name)", errno: errno) }
    }

    deinit { if !finished { munmap(mappingBase, mappingLength); close(descriptor) } }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter ColumnFileTests 2>&1 | tail -5`
Expected: 6 tests pass.

- [ ] **Step 5: Report the changed files. Do not run git.**

### Task 4: Storage classes, extension dictionary, index manifest, byte formatting

**Files:**
- Create: `Sources/InventoryIndex/StorageClass.swift`, `Sources/InventoryIndex/ExtensionDictionary.swift`, `Sources/InventoryIndex/IndexManifest.swift`, `Sources/InventoryIndex/ByteCountFormatting.swift`
- Test: `Tests/InventoryIndexTests/StorageClassTests.swift`, `Tests/InventoryIndexTests/ExtensionDictionaryTests.swift`, `Tests/InventoryIndexTests/IndexManifestTests.swift`, `Tests/InventoryIndexTests/ByteCountFormattingTests.swift`

**Interfaces:**
- Produces:
  - `enum StorageClass: UInt8, CaseIterable` with cases `standard = 0, standardInfrequentAccess, intelligentTiering, oneZoneInfrequentAccess, glacierInstantRetrieval, glacierFlexibleRetrieval, deepArchive, other = 7`; `inventoryName: String`; `static let names: [String]`; `static func identifier(forInventoryName: UnsafeBufferPointer<UInt8>) -> UInt8`; `static func identifier(forInventoryName: String) -> UInt8`.
  - `final class ExtensionDictionary` with `names: [String]` (index = id, `names[0] == ""`), `static let otherIdentifier: UInt16 = 65_535`, `func identifier(forBasename: UnsafeBufferPointer<UInt8>) -> UInt16`, `static func packedExtension(ofBasename: UnsafeBufferPointer<UInt8>) -> UInt64?`, `static func extensionString(ofBasename: String) -> String`.
  - `struct IndexManifest: Codable` (fields below) with `static func load(from folder: URL) throws -> IndexManifest` and `func save(to folder: URL) throws`; `static func extensionPalette(from bytesByExtension: [UInt16: UInt64], maximum: Int = 15) -> [UInt16]`.
  - `enum ByteUnits { case binary, decimal }`, `func formatByteCount(_ bytes: UInt64, units: ByteUnits, fractionDigits: Int = 1) -> String`, `func formatCount(_ value: UInt64) -> String`.

- [ ] **Step 1: Write the failing tests**

`StorageClassTests.swift`:
```swift
import XCTest
@testable import InventoryIndex

final class StorageClassTests: XCTestCase {
    func testKnownNamesMapToFixedIdentifiers() {
        XCTAssertEqual(StorageClass.identifier(forInventoryName: "STANDARD"), 0)
        XCTAssertEqual(StorageClass.identifier(forInventoryName: "STANDARD_IA"), 1)
        XCTAssertEqual(StorageClass.identifier(forInventoryName: "INTELLIGENT_TIERING"), 2)
        XCTAssertEqual(StorageClass.identifier(forInventoryName: "ONEZONE_IA"), 3)
        XCTAssertEqual(StorageClass.identifier(forInventoryName: "GLACIER_IR"), 4)
        XCTAssertEqual(StorageClass.identifier(forInventoryName: "GLACIER"), 5)
        XCTAssertEqual(StorageClass.identifier(forInventoryName: "DEEP_ARCHIVE"), 6)
    }
    func testUnknownAndEmptyMapToOther() {
        XCTAssertEqual(StorageClass.identifier(forInventoryName: "REDUCED_REDUNDANCY"), 7)
        XCTAssertEqual(StorageClass.identifier(forInventoryName: "EXPRESS_ONEZONE"), 7)
        XCTAssertEqual(StorageClass.identifier(forInventoryName: ""), 7)
        XCTAssertEqual(StorageClass.identifier(forInventoryName: "STANDARD_IAX"), 7)
    }
    func testNamesArrayHasEightEntriesInIdentifierOrder() {
        XCTAssertEqual(StorageClass.names, ["STANDARD", "STANDARD_IA", "INTELLIGENT_TIERING", "ONEZONE_IA", "GLACIER_IR", "GLACIER", "DEEP_ARCHIVE", "OTHER"])
    }
}
```

`ExtensionDictionaryTests.swift`:
```swift
import XCTest
@testable import InventoryIndex

final class ExtensionDictionaryTests: XCTestCase {
    private func identifier(_ dictionary: ExtensionDictionary, _ basename: String) -> UInt16 {
        Array(basename.utf8).withUnsafeBufferPointer { dictionary.identifier(forBasename: $0) }
    }
    func testExtractionRules() {
        XCTAssertEqual(ExtensionDictionary.extensionString(ofBasename: "photo.JPG"), "jpg")
        XCTAssertEqual(ExtensionDictionary.extensionString(ofBasename: "archive.tar.gz"), "gz")
        XCTAssertEqual(ExtensionDictionary.extensionString(ofBasename: "noextension"), "")
        XCTAssertEqual(ExtensionDictionary.extensionString(ofBasename: "trailingdot."), "")
        XCTAssertEqual(ExtensionDictionary.extensionString(ofBasename: "toolong.abcdefghi"), "")
        XCTAssertEqual(ExtensionDictionary.extensionString(ofBasename: "eight.abcdefgh"), "abcdefgh")
        XCTAssertEqual(ExtensionDictionary.extensionString(ofBasename: "notalnum.jp-g"), "")
        XCTAssertEqual(ExtensionDictionary.extensionString(ofBasename: ".hidden"), "hidden")
        XCTAssertEqual(ExtensionDictionary.extensionString(ofBasename: ""), "")
    }
    func testInterningIsStableAndCaseInsensitive() {
        let dictionary = ExtensionDictionary()
        XCTAssertEqual(identifier(dictionary, "a.jpg"), 1)
        XCTAssertEqual(identifier(dictionary, "b.JPG"), 1)
        XCTAssertEqual(identifier(dictionary, "c.mp4"), 2)
        XCTAssertEqual(identifier(dictionary, "plain"), 0)
        XCTAssertEqual(dictionary.names, ["", "jpg", "mp4"])
    }
    func testOverflowMapsToOther() {
        let dictionary = ExtensionDictionary()
        for value in 0..<65_540 {
            let basename = "f.\(String(value, radix: 36))"
            _ = identifier(dictionary, basename)
        }
        XCTAssertEqual(dictionary.names.count, 65_535)          // ids 0...65534
        XCTAssertEqual(identifier(dictionary, "f.zzzzzz"), ExtensionDictionary.otherIdentifier)
    }
}
```

`IndexManifestTests.swift`:
```swift
import XCTest
@testable import InventoryIndex

final class IndexManifestTests: XCTestCase {
    func testRoundTripThroughFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("manifest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var manifest = IndexManifest.empty(sourceBucket: "bucket", inventoryTimestamp: 1_700_000_000)
        manifest.counts.fileCount = 42
        manifest.extensionNames = ["", "jpg"]
        manifest.extensionPalette = [1]
        try manifest.save(to: folder)
        let loaded = try IndexManifest.load(from: folder)
        XCTAssertEqual(loaded.counts.fileCount, 42)
        XCTAssertEqual(loaded.extensionPalette, [1])
        XCTAssertEqual(loaded.source.sourceBucket, "bucket")
        XCTAssertEqual(loaded.storageClassNames, StorageClass.names)
    }
    func testMissingManifestIsIncompleteIndex() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString)")
        XCTAssertThrowsError(try IndexManifest.load(from: folder)) { error in
            guard case IndexError.incompleteIndex = error else { return XCTFail("wrong error \(error)") }
        }
    }
    func testExtensionPaletteTakesLargestByBytesExcludingNoExtension() {
        let bytes: [UInt16: UInt64] = [0: 1_000_000, 3: 10, 7: 500, 9: 20]
        XCTAssertEqual(IndexManifest.extensionPalette(from: bytes, maximum: 2), [7, 9])
        XCTAssertEqual(IndexManifest.extensionPalette(from: bytes), [7, 9, 3])
    }
}
```

`ByteCountFormattingTests.swift`:
```swift
import XCTest
@testable import InventoryIndex

final class ByteCountFormattingTests: XCTestCase {
    func testBinaryUnits() {
        XCTAssertEqual(formatByteCount(0, units: .binary), "0 B")
        XCTAssertEqual(formatByteCount(512, units: .binary), "512 B")
        XCTAssertEqual(formatByteCount(1536, units: .binary), "1.5 KiB")
        XCTAssertEqual(formatByteCount(869_012_548_707_428, units: .binary), "790.4 TiB")
    }
    func testDecimalUnits() {
        XCTAssertEqual(formatByteCount(1_500_000, units: .decimal), "1.5 MB")
        XCTAssertEqual(formatByteCount(869_012_548_707_428, units: .decimal), "869.0 TB")
    }
    func testCountsUseGroupingSeparators() {
        XCTAssertEqual(formatCount(1_119_935_804), "1,119,935,804")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter 'StorageClassTests|ExtensionDictionaryTests|IndexManifestTests|ByteCountFormattingTests' 2>&1 | tail -5`
Expected: compile errors for the missing types.

- [ ] **Step 3: Write the four source files**

`StorageClass.swift`:
```swift
import Foundation

public enum StorageClass: UInt8, CaseIterable {
    case standard = 0
    case standardInfrequentAccess = 1
    case intelligentTiering = 2
    case oneZoneInfrequentAccess = 3
    case glacierInstantRetrieval = 4
    case glacierFlexibleRetrieval = 5
    case deepArchive = 6
    case other = 7

    public var inventoryName: String {
        switch self {
        case .standard: return "STANDARD"
        case .standardInfrequentAccess: return "STANDARD_IA"
        case .intelligentTiering: return "INTELLIGENT_TIERING"
        case .oneZoneInfrequentAccess: return "ONEZONE_IA"
        case .glacierInstantRetrieval: return "GLACIER_IR"
        case .glacierFlexibleRetrieval: return "GLACIER"
        case .deepArchive: return "DEEP_ARCHIVE"
        case .other: return "OTHER"
        }
    }

    public static let names: [String] = allCases.map { $0.inventoryName }

    private static let knownNames: [(bytes: [UInt8], identifier: UInt8)] = allCases
        .filter { $0 != .other }
        .map { (Array($0.inventoryName.utf8), $0.rawValue) }

    public static func identifier(forInventoryName bytes: UnsafeBufferPointer<UInt8>) -> UInt8 {
        for entry in knownNames where entry.bytes.count == bytes.count {
            if entry.bytes.withUnsafeBufferPointer({ memcmp($0.baseAddress!, bytes.baseAddress!, bytes.count) == 0 }) {
                return entry.identifier
            }
        }
        return StorageClass.other.rawValue
    }

    public static func identifier(forInventoryName name: String) -> UInt8 {
        var bytes = Array(name.utf8)
        if bytes.isEmpty { return StorageClass.other.rawValue }
        return bytes.withUnsafeMutableBufferPointer { identifier(forInventoryName: UnsafeBufferPointer($0)) }
    }
}
```

`ExtensionDictionary.swift`:
```swift
import Foundation

/// Interns lowercase file extensions (1 to 8 ASCII alphanumerics after the last '.') into UInt16 ids.
/// Id 0 is "no extension". Ids above `maximumIdentifiers - 1` collapse into `otherIdentifier`.
public final class ExtensionDictionary {
    public static let maximumIdentifiers = 65_535
    public static let otherIdentifier: UInt16 = 65_535
    public static let maximumLength = 8

    public private(set) var names: [String] = [""]
    private var identifiersByPackedExtension: [UInt64: UInt16] = [:]

    public init() {}

    /// Packs the lowercase extension into a UInt64 (first byte in the high bits); nil when there is no extension.
    public static func packedExtension(ofBasename bytes: UnsafeBufferPointer<UInt8>) -> UInt64? {
        guard bytes.count >= 2 else { return nil }
        var dotIndex = bytes.count - 1
        var length = 0
        while dotIndex >= 0 {
            let byte = bytes[dotIndex]
            if byte == UInt8(ascii: ".") { break }
            let isDigit = byte >= 48 && byte <= 57
            let isUpper = byte >= 65 && byte <= 90
            let isLower = byte >= 97 && byte <= 122
            guard isDigit || isUpper || isLower else { return nil }
            length += 1
            if length > maximumLength { return nil }
            dotIndex -= 1
        }
        guard dotIndex >= 0, length >= 1 else { return nil }
        var packed: UInt64 = 0
        for index in (dotIndex + 1)..<bytes.count {
            var byte = bytes[index]
            if byte >= 65 && byte <= 90 { byte += 32 }
            packed = (packed << 8) | UInt64(byte)
        }
        return packed | (UInt64(length) << 56)   // length in the top byte keeps "a" distinct from "\0a"
    }

    public static func extensionString(ofBasename basename: String) -> String {
        var bytes = Array(basename.utf8)
        let packed = bytes.withUnsafeMutableBufferPointer { packedExtension(ofBasename: UnsafeBufferPointer($0)) }
        guard let packed else { return "" }
        return unpack(packed)
    }

    private static func unpack(_ packed: UInt64) -> String {
        let length = Int(packed >> 56)
        var characters: [UInt8] = []
        for index in 0..<length {
            let shift = UInt64((length - 1 - index) * 8)
            characters.append(UInt8((packed >> shift) & 0xFF))
        }
        return String(decoding: characters, as: UTF8.self)
    }

    public func identifier(forBasename bytes: UnsafeBufferPointer<UInt8>) -> UInt16 {
        guard let packed = ExtensionDictionary.packedExtension(ofBasename: bytes) else { return 0 }
        if let existing = identifiersByPackedExtension[packed] { return existing }
        guard names.count < ExtensionDictionary.maximumIdentifiers else { return ExtensionDictionary.otherIdentifier }
        let identifier = UInt16(names.count)
        names.append(ExtensionDictionary.unpack(packed))
        identifiersByPackedExtension[packed] = identifier
        return identifier
    }
}
```

`IndexManifest.swift`:
```swift
import Foundation

public struct IndexManifest: Codable, Equatable {
    public struct SourceIdentity: Codable, Equatable {
        public var sourceBucket: String
        public var manifestCreationTimestamp: String?
        public var manifestFileCount: Int
        public var manifestTotalBytes: Int64
        public var manifestMD5: String?
    }
    public struct Counts: Codable, Equatable {
        public var directoryCount: Int = 0
        public var fileCount: UInt64 = 0
        public var totalBytes: UInt64 = 0
        public var skippedNonCurrent: Int = 0
        public var skippedDeleteMarkers: Int = 0
        public var rowParseErrors: Int = 0
    }

    public var formatVersion: Int
    public var createdAt: Date
    public var importDurationSeconds: Double
    public var appVersion: String
    public var source: SourceIdentity
    public var counts: Counts
    public var missingDataFiles: [String]
    public var storageClassNames: [String]
    public var extensionNames: [String]
    public var extensionPalette: [UInt16]
    public var schemaColumns: [String]
    public var inventoryTimestamp: UInt32

    public var isPartial: Bool { !missingDataFiles.isEmpty }

    public static func empty(sourceBucket: String, inventoryTimestamp: UInt32) -> IndexManifest {
        IndexManifest(formatVersion: Int(IndexFormat.formatVersion), createdAt: Date(), importDurationSeconds: 0, appVersion: "0.1.0",
                      source: SourceIdentity(sourceBucket: sourceBucket, manifestCreationTimestamp: nil, manifestFileCount: 0, manifestTotalBytes: 0, manifestMD5: nil),
                      counts: Counts(), missingDataFiles: [], storageClassNames: StorageClass.names, extensionNames: [""],
                      extensionPalette: [], schemaColumns: [], inventoryTimestamp: inventoryTimestamp)
    }

    public static func load(from folder: URL) throws -> IndexManifest {
        let url = folder.appendingPathComponent(IndexFiles.manifest)
        guard FileManager.default.fileExists(atPath: url.path) else { throw IndexError.incompleteIndex(folder) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(IndexManifest.self, from: Data(contentsOf: url))
    }

    public func save(to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        let temporary = folder.appendingPathComponent(IndexFiles.manifest + ".tmp")
        try data.write(to: temporary)
        _ = try FileManager.default.replaceItemAt(folder.appendingPathComponent(IndexFiles.manifest), withItemAt: temporary)
    }

    /// The `maximum` extension ids with the most bytes, excluding id 0 (no extension) and the overflow id.
    public static func extensionPalette(from bytesByExtension: [UInt16: UInt64], maximum: Int = 15) -> [UInt16] {
        bytesByExtension
            .filter { $0.key != 0 && $0.key != ExtensionDictionary.otherIdentifier }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(maximum)
            .map { $0.key }
    }
}
```

`ByteCountFormatting.swift`:
```swift
import Foundation

public enum ByteUnits: String, CaseIterable {
    case binary
    case decimal
}

public func formatByteCount(_ bytes: UInt64, units: ByteUnits, fractionDigits: Int = 1) -> String {
    let base: Double = units == .binary ? 1024 : 1000
    let suffixes = units == .binary ? ["B", "KiB", "MiB", "GiB", "TiB", "PiB"] : ["B", "KB", "MB", "GB", "TB", "PB"]
    var value = Double(bytes)
    var suffixIndex = 0
    while value >= base && suffixIndex < suffixes.count - 1 {
        value /= base
        suffixIndex += 1
    }
    if suffixIndex == 0 { return "\(bytes) B" }
    return String(format: "%.\(fractionDigits)f %@", value, suffixes[suffixIndex])
}

private let countFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.groupingSeparator = ","
    formatter.usesGroupingSeparator = true
    return formatter
}()

public func formatCount(_ value: UInt64) -> String {
    countFormatter.string(from: NSNumber(value: value)) ?? String(value)
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter 'StorageClassTests|ExtensionDictionaryTests|IndexManifestTests|ByteCountFormattingTests' 2>&1 | tail -5`
Expected: all pass. If `testOverflowMapsToOther` is slow (65,540 inserts), it should still finish in well under a second.

- [ ] **Step 5: Report the changed files. Do not run git.**

### Task 5: Name blocks — LZFSE codec and decoded-block cache

**Files:**
- Create: `Sources/InventoryIndex/NameBlockCodec.swift`, `Sources/InventoryIndex/NameBlockCache.swift`
- Test: `Tests/InventoryIndexTests/NameBlockTests.swift`

**Interfaces:**
- Consumes: `MappedColumn`, `IndexFormat.namesPerBlock`.
- Produces:
  - `struct NameBlockEntry { var offset: UInt64; var compressedLength: UInt32; var rawLength: UInt32 }` (16 bytes, the element of `file.names.blocks`).
  - `enum NameBlockCodec` — `static func appendName(_ name: UnsafeBufferPointer<UInt8>, to raw: inout [UInt8])`, `static func encode(raw: [UInt8]) -> [UInt8]`, `static func decode(compressed: UnsafeRawBufferPointer, rawLength: Int) -> [UInt8]?`.
  - `final class DecodedNameBlock` — `nameCount: Int`, `func withName<R>(at index: Int, _ body: (UnsafeBufferPointer<UInt8>) -> R) -> R`, `func name(at index: Int) -> [UInt8]`.
  - `final class NameBlockCache` — `init(blocks: MappedColumn<NameBlockEntry>, data: MappedColumn<UInt8>, capacity: Int = 64)`, `blockCount: Int`, `func block(_ index: Int) -> DecodedNameBlock`, `func decodeBlockUncached(_ index: Int) -> DecodedNameBlock`, `func withName<R>(ofFile fileIndex: UInt64, _ body: (UnsafeBufferPointer<UInt8>) -> R) -> R`, `func name(ofFile fileIndex: UInt64) -> [UInt8]`, `func nameString(ofFile fileIndex: UInt64) -> String`. Thread-safe.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import InventoryIndex

final class NameBlockTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("names-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private func rawBlock(_ names: [String]) -> [UInt8] {
        var raw: [UInt8] = []
        for name in names { Array(name.utf8).withUnsafeBufferPointer { NameBlockCodec.appendName($0, to: &raw) } }
        return raw
    }

    func testEncodeDecodeRoundTripWithAwkwardNames() throws {
        let names = ["", "photo.jpg", String(repeating: "x", count: 1024), "ünïcödé ✓.mp4", "a\nb"]
        let raw = rawBlock(names)
        let compressed = NameBlockCodec.encode(raw: raw)
        let decoded = compressed.withUnsafeBytes { NameBlockCodec.decode(compressed: $0, rawLength: raw.count) }
        XCTAssertEqual(decoded, raw)
        let block = DecodedNameBlock(raw: raw)
        XCTAssertEqual(block.nameCount, 5)
        XCTAssertEqual(block.name(at: 0), [])
        XCTAssertEqual(String(decoding: block.name(at: 3), as: UTF8.self), "ünïcödé ✓.mp4")
        XCTAssertEqual(block.name(at: 2).count, 1024)
    }

    func testIncompressibleBlockStillRoundTrips() throws {
        var generator = SystemRandomNumberGenerator()
        let names = (0..<100).map { _ in String((0..<40).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement(using: &generator)! }) }
        let raw = rawBlock(names)
        let compressed = NameBlockCodec.encode(raw: raw)
        let decoded = compressed.withUnsafeBytes { NameBlockCodec.decode(compressed: $0, rawLength: raw.count) }
        XCTAssertEqual(decoded, raw)
    }

    func testCacheResolvesFilesAcrossBlockBoundaries() throws {
        // 4096 + 5 names → two blocks
        let allNames = (0..<(IndexFormat.namesPerBlock + 5)).map { "file-\($0).dat" }
        let blocksWriter = try ColumnWriter<NameBlockEntry>(url: folder.appendingPathComponent(IndexFiles.fileNameBlocks))
        let dataWriter = try ColumnWriter<UInt8>(url: folder.appendingPathComponent(IndexFiles.fileNameData))
        for start in stride(from: 0, to: allNames.count, by: IndexFormat.namesPerBlock) {
            let raw = rawBlock(Array(allNames[start..<min(start + IndexFormat.namesPerBlock, allNames.count)]))
            let compressed = NameBlockCodec.encode(raw: raw)
            blocksWriter.append(NameBlockEntry(offset: UInt64(dataWriter.count), compressedLength: UInt32(compressed.count), rawLength: UInt32(raw.count)))
            compressed.withUnsafeBytes { dataWriter.appendBytes($0) }
        }
        try blocksWriter.finish(); try dataWriter.finish()
        let cache = NameBlockCache(blocks: try MappedColumn(url: folder.appendingPathComponent(IndexFiles.fileNameBlocks)),
                                   data: try MappedColumn(url: folder.appendingPathComponent(IndexFiles.fileNameData)), capacity: 1)
        XCTAssertEqual(cache.blockCount, 2)
        XCTAssertEqual(cache.nameString(ofFile: 0), "file-0.dat")
        XCTAssertEqual(cache.nameString(ofFile: 4095), "file-4095.dat")
        XCTAssertEqual(cache.nameString(ofFile: 4096), "file-4096.dat")
        XCTAssertEqual(cache.nameString(ofFile: 4100), "file-4100.dat")
        XCTAssertEqual(cache.nameString(ofFile: 1), "file-1.dat")   // block 0 again after eviction (capacity 1)
        XCTAssertEqual(cache.cachedBlockCount, 1)
    }

    func testStrideOfEntryIsSixteen() {
        XCTAssertEqual(MemoryLayout<NameBlockEntry>.stride, 16)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter NameBlockTests 2>&1 | tail -5`
Expected: compile errors.

- [ ] **Step 3: Write `NameBlockCodec.swift`**

```swift
import Foundation
import Compression

public struct NameBlockEntry {
    public var offset: UInt64
    public var compressedLength: UInt32
    public var rawLength: UInt32
    public init(offset: UInt64, compressedLength: UInt32, rawLength: UInt32) {
        self.offset = offset; self.compressedLength = compressedLength; self.rawLength = rawLength
    }
}

public enum NameBlockCodec {
    /// Raw block layout: for each name, a little-endian UInt16 length followed by the bytes.
    public static func appendName(_ name: UnsafeBufferPointer<UInt8>, to raw: inout [UInt8]) {
        let length = UInt16(truncatingIfNeeded: name.count)
        raw.append(UInt8(truncatingIfNeeded: length))
        raw.append(UInt8(truncatingIfNeeded: length >> 8))
        raw.append(contentsOf: name)
    }

    public static func encode(raw: [UInt8]) -> [UInt8] {
        precondition(!raw.isEmpty, "empty name block")
        let capacity = raw.count + raw.count / 16 + 256
        var destination = [UInt8](repeating: 0, count: capacity)
        let written = raw.withUnsafeBufferPointer { source -> Int in
            destination.withUnsafeMutableBufferPointer { target in
                compression_encode_buffer(target.baseAddress!, capacity, source.baseAddress!, raw.count, nil, COMPRESSION_LZFSE)
            }
        }
        precondition(written > 0, "LZFSE encode failed")
        destination.removeSubrange(written...)
        return destination
    }

    public static func decode(compressed: UnsafeRawBufferPointer, rawLength: Int) -> [UInt8]? {
        var destination = [UInt8](repeating: 0, count: rawLength)
        let written = destination.withUnsafeMutableBufferPointer { target in
            compression_decode_buffer(target.baseAddress!, rawLength, compressed.baseAddress!.assumingMemoryBound(to: UInt8.self), compressed.count, nil, COMPRESSION_LZFSE)
        }
        return written == rawLength ? destination : nil
    }
}

public final class DecodedNameBlock {
    public let raw: [UInt8]
    private let starts: [UInt32]     // byte offset of each name's first byte
    private let lengths: [UInt16]
    public var nameCount: Int { lengths.count }

    public init(raw: [UInt8]) {
        self.raw = raw
        var starts: [UInt32] = []
        var lengths: [UInt16] = []
        starts.reserveCapacity(IndexFormat.namesPerBlock)
        lengths.reserveCapacity(IndexFormat.namesPerBlock)
        var cursor = 0
        while cursor + 2 <= raw.count {
            let length = Int(raw[cursor]) | (Int(raw[cursor + 1]) << 8)
            cursor += 2
            starts.append(UInt32(cursor))
            lengths.append(UInt16(length))
            cursor += length
        }
        self.starts = starts
        self.lengths = lengths
    }

    public func withName<R>(at index: Int, _ body: (UnsafeBufferPointer<UInt8>) -> R) -> R {
        raw.withUnsafeBufferPointer { buffer in
            body(UnsafeBufferPointer(rebasing: buffer[Int(starts[index])..<(Int(starts[index]) + Int(lengths[index]))]))
        }
    }

    public func name(at index: Int) -> [UInt8] { withName(at: index) { Array($0) } }
}
```

- [ ] **Step 4: Write `NameBlockCache.swift`**

```swift
import Foundation

/// Thread-safe LRU cache of decoded name blocks.
public final class NameBlockCache {
    private let blocks: MappedColumn<NameBlockEntry>
    private let data: MappedColumn<UInt8>
    private let capacity: Int
    private let lock = NSLock()
    private var cached: [Int: (block: DecodedNameBlock, lastUse: UInt64)] = [:]
    private var useCounter: UInt64 = 0

    public var blockCount: Int { blocks.count }
    public var cachedBlockCount: Int { lock.lock(); defer { lock.unlock() }; return cached.count }

    public init(blocks: MappedColumn<NameBlockEntry>, data: MappedColumn<UInt8>, capacity: Int = 64) {
        self.blocks = blocks
        self.data = data
        self.capacity = max(capacity, 1)
    }

    public func decodeBlockUncached(_ index: Int) -> DecodedNameBlock {
        let entry = blocks[index]
        let compressed = UnsafeRawBufferPointer(start: UnsafeRawPointer(data.buffer.baseAddress!) + Int(entry.offset), count: Int(entry.compressedLength))
        guard let raw = NameBlockCodec.decode(compressed: compressed, rawLength: Int(entry.rawLength)) else {
            fatalError("corrupt name block \(index) in \(blocks.url.path)")
        }
        return DecodedNameBlock(raw: raw)
    }

    public func block(_ index: Int) -> DecodedNameBlock {
        lock.lock()
        useCounter += 1
        if let hit = cached[index] {
            cached[index] = (hit.block, useCounter)
            lock.unlock()
            return hit.block
        }
        lock.unlock()
        let decoded = decodeBlockUncached(index)
        lock.lock()
        if cached.count >= capacity, let victim = cached.min(by: { $0.value.lastUse < $1.value.lastUse }) {
            cached.removeValue(forKey: victim.key)
        }
        cached[index] = (decoded, useCounter)
        lock.unlock()
        return decoded
    }

    public func withName<R>(ofFile fileIndex: UInt64, _ body: (UnsafeBufferPointer<UInt8>) -> R) -> R {
        let blockIndex = Int(fileIndex / UInt64(IndexFormat.namesPerBlock))
        let position = Int(fileIndex % UInt64(IndexFormat.namesPerBlock))
        return block(blockIndex).withName(at: position, body)
    }

    public func name(ofFile fileIndex: UInt64) -> [UInt8] { withName(ofFile: fileIndex) { Array($0) } }

    public func nameString(ofFile fileIndex: UInt64) -> String { withName(ofFile: fileIndex) { String(decoding: $0, as: UTF8.self) } }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter NameBlockTests 2>&1 | tail -5`
Expected: 4 tests pass.

- [ ] **Step 6: Report the changed files. Do not run git.**

### Task 6: IndexWriter, IndexReader, DirectoryTree, children-by-size post-processing

**Files:**
- Create: `Sources/InventoryIndex/IndexWriter.swift`, `Sources/InventoryIndex/IndexReader.swift`, `Sources/InventoryIndex/DirectoryTree.swift`, `Sources/InventoryIndex/IndexPostProcessing.swift`
- Test: `Tests/InventoryIndexTests/DirectoryTreeTests.swift`

**Interfaces:**
- Consumes: Tasks 3, 4, 5.
- Produces:
  - `final class IndexWriter` — `init(folder: URL, directoryCapacity: Int = IndexFormat.directoryCapacity) throws` (creates the folder, fails if `index.json` already exists), public column properties named exactly as the `IndexFiles` constants without the type suffix (`directoryParent`, `directoryDepth`, `directorySubtreeDirectoryCount`, `directoryChildCount`, `directoryFileStart`, `directorySubtreeFileCount`, `directorySubtreeBytes`, `directoryOwnFileCount`, `directoryOwnBytes`, `directoryNameOffset`, `directoryNameLength`, `directoryBytesByStorageClass` (capacity × 8), `directoryDominantExtension`, `directoryAgeWeightedBytes` — all `SparseMappedColumn`; `directoryNames`, `fileSize`, `fileLastModified`, `fileStorageClass`, `fileExtension`, `fileNameBlocks`, `fileNameData` — all `ColumnWriter`), `func finish(directoryCount: Int) throws`.
  - `enum IndexPostProcessing` — `static func writeChildrenBySize(folder: URL) throws` (reads the finished directory columns, writes `directory.childListStart.u32` and `directory.childrenBySize.u32`).
  - `struct DirectoryTree` — accessors listed in the spec section 7: `count`, `parent`, `depth`, `subtreeDirectoryCount`, `childCount`, `fileStart`, `subtreeFileCount`, `subtreeBytes`, `ownFileCount`, `ownBytes`, `dominantExtension`, `ageWeightedBytes`, `bytesByStorageClass(_:) -> [UInt64]`, `dominantStorageClass(_:) -> UInt8`, `averageAgeDays(_:) -> Double`, `name(_:) -> String`, `withNameBytes(_:_:)`, `path(_:) -> String`, `subtreeRange(_:) -> Range<UInt32>`, `subtreeFileRange(_:) -> Range<UInt64>`, `childrenInKeyOrder(_:) -> [UInt32]`, `childrenBySize(_:) -> [UInt32]`, `ownFileRanges(_:) -> [Range<UInt64>]`, `lookup(path: String) -> UInt32?`.
  - `final class IndexReader` — `init(folder: URL) throws`, `folder`, `manifest: IndexManifest`, `directories: DirectoryTree`, `fileSize`, `fileLastModified`, `fileStorageClass`, `fileExtension` (all `MappedColumn`), `names: NameBlockCache`, `func directory(ofFile: UInt64) -> UInt32`, `func key(ofFile: UInt64) -> String`, `static func indexFolder(forInventory folder: URL) -> URL`.

- [ ] **Step 1: Write the failing test with a hand-assembled four-directory index**

The fixture tree, in key order (bytes: `a/b/z` < `a/x` because `b` < `x`):

```
file 0  a/b/z   size 5   STANDARD      2026-01-01
file 1  a/x     size 10  STANDARD_IA   2025-01-01
file 2  a/y     size 20  DEEP_ARCHIVE  2024-01-01
file 3  c/w     size 40  STANDARD      2026-01-01
directories (pre-order): 0 root, 1 a, 2 a/b, 3 c
```

```swift
import XCTest
@testable import InventoryIndex

final class DirectoryTreeTests: XCTestCase {
    private var folder: URL!
    private let inventoryTimestamp: UInt32 = 1_767_225_600   // 2026-01-01T00:00:00Z

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tree-\(UUID().uuidString)")
        try writeFixtureIndex()
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private func writeFixtureIndex() throws {
        let writer = try IndexWriter(folder: folder, directoryCapacity: 16)
        // directory names pool: "" (root), "a", "b", "c"
        func writeDirectory(_ id: Int, parent: UInt32, depth: UInt8, name: String, subtreeDirectories: UInt32, children: UInt32,
                            fileStart: UInt64, subtreeFiles: UInt64, subtreeBytes: UInt64, ownFiles: UInt32, ownBytes: UInt64,
                            classBytes: [UInt64], dominantExtension: UInt16, ageWeighted: UInt64) {
            writer.directoryParent[id] = parent
            writer.directoryDepth[id] = depth
            writer.directoryNameOffset[id] = UInt64(writer.directoryNames.count)
            writer.directoryNameLength[id] = UInt16(name.utf8.count)
            Array(name.utf8).withUnsafeBytes { writer.directoryNames.appendBytes($0) }
            writer.directorySubtreeDirectoryCount[id] = subtreeDirectories
            writer.directoryChildCount[id] = children
            writer.directoryFileStart[id] = fileStart
            writer.directorySubtreeFileCount[id] = subtreeFiles
            writer.directorySubtreeBytes[id] = subtreeBytes
            writer.directoryOwnFileCount[id] = ownFiles
            writer.directoryOwnBytes[id] = ownBytes
            for slot in 0..<8 { writer.directoryBytesByStorageClass[id * 8 + slot] = classBytes[slot] }
            writer.directoryDominantExtension[id] = dominantExtension
            writer.directoryAgeWeightedBytes[id] = ageWeighted
        }
        writeDirectory(0, parent: IndexFormat.noParent, depth: 0, name: "", subtreeDirectories: 3, children: 2, fileStart: 0, subtreeFiles: 4, subtreeBytes: 75, ownFiles: 0, ownBytes: 0, classBytes: [45, 10, 0, 0, 0, 0, 20, 0], dominantExtension: 0, ageWeighted: 10 * 365 + 20 * 731)
        writeDirectory(1, parent: 0, depth: 1, name: "a", subtreeDirectories: 1, children: 1, fileStart: 0, subtreeFiles: 3, subtreeBytes: 35, ownFiles: 2, ownBytes: 30, classBytes: [5, 10, 0, 0, 0, 0, 20, 0], dominantExtension: 0, ageWeighted: 10 * 365 + 20 * 731)
        writeDirectory(2, parent: 1, depth: 2, name: "b", subtreeDirectories: 0, children: 0, fileStart: 0, subtreeFiles: 1, subtreeBytes: 5, ownFiles: 1, ownBytes: 5, classBytes: [5, 0, 0, 0, 0, 0, 0, 0], dominantExtension: 0, ageWeighted: 0)
        writeDirectory(3, parent: 0, depth: 1, name: "c", subtreeDirectories: 0, children: 0, fileStart: 3, subtreeFiles: 1, subtreeBytes: 40, ownFiles: 1, ownBytes: 40, classBytes: [40, 0, 0, 0, 0, 0, 0, 0], dominantExtension: 0, ageWeighted: 0)

        let files: [(name: String, size: UInt64, modified: UInt32, storageClass: UInt8)] = [
            ("z", 5, inventoryTimestamp, 0), ("x", 10, inventoryTimestamp - 365 * 86400, 1), ("y", 20, inventoryTimestamp - 731 * 86400, 6), ("w", 40, inventoryTimestamp, 0)]
        var raw: [UInt8] = []
        for file in files {
            writer.fileSize.append(file.size)
            writer.fileLastModified.append(file.modified)
            writer.fileStorageClass.append(file.storageClass)
            writer.fileExtension.append(0)
            Array(file.name.utf8).withUnsafeBufferPointer { NameBlockCodec.appendName($0, to: &raw) }
        }
        let compressed = NameBlockCodec.encode(raw: raw)
        writer.fileNameBlocks.append(NameBlockEntry(offset: 0, compressedLength: UInt32(compressed.count), rawLength: UInt32(raw.count)))
        compressed.withUnsafeBytes { writer.fileNameData.appendBytes($0) }
        try writer.finish(directoryCount: 4)
        try IndexPostProcessing.writeChildrenBySize(folder: folder)
        var manifest = IndexManifest.empty(sourceBucket: "fixture", inventoryTimestamp: inventoryTimestamp)
        manifest.counts.directoryCount = 4
        manifest.counts.fileCount = 4
        manifest.counts.totalBytes = 75
        try manifest.save(to: folder)
    }

    func testTreeAccessors() throws {
        let reader = try IndexReader(folder: folder)
        let tree = reader.directories
        XCTAssertEqual(tree.count, 4)
        XCTAssertEqual(tree.parent(0), IndexFormat.noParent)
        XCTAssertEqual(tree.parent(2), 1)
        XCTAssertEqual(tree.name(2), "b")
        XCTAssertEqual(tree.path(2), "a/b")
        XCTAssertEqual(tree.path(0), "")
        XCTAssertEqual(tree.childrenInKeyOrder(0), [1, 3])
        XCTAssertEqual(tree.childrenInKeyOrder(1), [2])
        XCTAssertEqual(tree.childrenBySize(0), [3, 1])           // c (40) before a (35)
        XCTAssertEqual(tree.subtreeRange(1), 1..<3)
        XCTAssertEqual(tree.subtreeFileRange(1), 0..<3)
        XCTAssertEqual(tree.ownFileRanges(1), [1..<3])             // gap after child b's file 0
        XCTAssertEqual(tree.ownFileRanges(0), [])
        XCTAssertEqual(tree.ownFileRanges(3), [3..<4])
        XCTAssertEqual(tree.lookup(path: "a/b"), 2)
        XCTAssertEqual(tree.lookup(path: ""), 0)
        XCTAssertNil(tree.lookup(path: "a/nope"))
        XCTAssertEqual(tree.bytesByStorageClass(1), [5, 10, 0, 0, 0, 0, 20, 0])
        XCTAssertEqual(tree.dominantStorageClass(1), 6)
        XCTAssertEqual(tree.averageAgeDays(1), Double(10 * 365 + 20 * 731) / 35, accuracy: 0.001)
    }

    func testFileLookups() throws {
        let reader = try IndexReader(folder: folder)
        XCTAssertEqual(reader.key(ofFile: 0), "a/b/z")
        XCTAssertEqual(reader.key(ofFile: 1), "a/x")
        XCTAssertEqual(reader.key(ofFile: 3), "c/w")
        XCTAssertEqual(reader.directory(ofFile: 0), 2)
        XCTAssertEqual(reader.directory(ofFile: 1), 1)
        XCTAssertEqual(reader.directory(ofFile: 2), 1)
        XCTAssertEqual(reader.directory(ofFile: 3), 3)
        XCTAssertEqual(reader.fileSize[2], 20)
        XCTAssertEqual(reader.manifest.counts.fileCount, 4)
    }

    func testMissingManifestMeansIncomplete() throws {
        try FileManager.default.removeItem(at: folder.appendingPathComponent(IndexFiles.manifest))
        XCTAssertThrowsError(try IndexReader(folder: folder)) { error in
            guard case IndexError.incompleteIndex = error else { return XCTFail("wrong error \(error)") }
        }
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter DirectoryTreeTests 2>&1 | tail -5`
Expected: compile errors.

- [ ] **Step 3: Write `IndexWriter.swift`**

```swift
import Foundation

public final class IndexWriter {
    public let folder: URL

    public let directoryParent: SparseMappedColumn<UInt32>
    public let directoryDepth: SparseMappedColumn<UInt8>
    public let directorySubtreeDirectoryCount: SparseMappedColumn<UInt32>
    public let directoryChildCount: SparseMappedColumn<UInt32>
    public let directoryFileStart: SparseMappedColumn<UInt64>
    public let directorySubtreeFileCount: SparseMappedColumn<UInt64>
    public let directorySubtreeBytes: SparseMappedColumn<UInt64>
    public let directoryOwnFileCount: SparseMappedColumn<UInt32>
    public let directoryOwnBytes: SparseMappedColumn<UInt64>
    public let directoryNameOffset: SparseMappedColumn<UInt64>
    public let directoryNameLength: SparseMappedColumn<UInt16>
    public let directoryBytesByStorageClass: SparseMappedColumn<UInt64>   // capacity × 8, index = id * 8 + slot
    public let directoryDominantExtension: SparseMappedColumn<UInt16>
    public let directoryAgeWeightedBytes: SparseMappedColumn<UInt64>

    public let directoryNames: ColumnWriter<UInt8>
    public let fileSize: ColumnWriter<UInt64>
    public let fileLastModified: ColumnWriter<UInt32>
    public let fileStorageClass: ColumnWriter<UInt8>
    public let fileExtension: ColumnWriter<UInt16>
    public let fileNameBlocks: ColumnWriter<NameBlockEntry>
    public let fileNameData: ColumnWriter<UInt8>

    public init(folder: URL, directoryCapacity: Int = IndexFormat.directoryCapacity) throws {
        self.folder = folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent(IndexFiles.manifest).path) {
            throw IndexError.manifestMismatch("index folder already contains a finished index: \(folder.path)")
        }
        func url(_ name: String) -> URL { folder.appendingPathComponent(name) }
        directoryParent = try SparseMappedColumn(url: url(IndexFiles.directoryParent), capacity: directoryCapacity)
        directoryDepth = try SparseMappedColumn(url: url(IndexFiles.directoryDepth), capacity: directoryCapacity)
        directorySubtreeDirectoryCount = try SparseMappedColumn(url: url(IndexFiles.directorySubtreeDirectoryCount), capacity: directoryCapacity)
        directoryChildCount = try SparseMappedColumn(url: url(IndexFiles.directoryChildCount), capacity: directoryCapacity)
        directoryFileStart = try SparseMappedColumn(url: url(IndexFiles.directoryFileStart), capacity: directoryCapacity)
        directorySubtreeFileCount = try SparseMappedColumn(url: url(IndexFiles.directorySubtreeFileCount), capacity: directoryCapacity)
        directorySubtreeBytes = try SparseMappedColumn(url: url(IndexFiles.directorySubtreeBytes), capacity: directoryCapacity)
        directoryOwnFileCount = try SparseMappedColumn(url: url(IndexFiles.directoryOwnFileCount), capacity: directoryCapacity)
        directoryOwnBytes = try SparseMappedColumn(url: url(IndexFiles.directoryOwnBytes), capacity: directoryCapacity)
        directoryNameOffset = try SparseMappedColumn(url: url(IndexFiles.directoryNameOffset), capacity: directoryCapacity)
        directoryNameLength = try SparseMappedColumn(url: url(IndexFiles.directoryNameLength), capacity: directoryCapacity)
        directoryBytesByStorageClass = try SparseMappedColumn(url: url(IndexFiles.directoryBytesByStorageClass), capacity: directoryCapacity * IndexFormat.storageClassSlots)
        directoryDominantExtension = try SparseMappedColumn(url: url(IndexFiles.directoryDominantExtension), capacity: directoryCapacity)
        directoryAgeWeightedBytes = try SparseMappedColumn(url: url(IndexFiles.directoryAgeWeightedBytes), capacity: directoryCapacity)
        directoryNames = try ColumnWriter(url: url(IndexFiles.directoryNames))
        fileSize = try ColumnWriter(url: url(IndexFiles.fileSize))
        fileLastModified = try ColumnWriter(url: url(IndexFiles.fileLastModified))
        fileStorageClass = try ColumnWriter(url: url(IndexFiles.fileStorageClass))
        fileExtension = try ColumnWriter(url: url(IndexFiles.fileExtension))
        fileNameBlocks = try ColumnWriter(url: url(IndexFiles.fileNameBlocks))
        fileNameData = try ColumnWriter(url: url(IndexFiles.fileNameData))
    }

    public func finish(directoryCount: Int) throws {
        try directoryParent.finish(count: directoryCount)
        try directoryDepth.finish(count: directoryCount)
        try directorySubtreeDirectoryCount.finish(count: directoryCount)
        try directoryChildCount.finish(count: directoryCount)
        try directoryFileStart.finish(count: directoryCount)
        try directorySubtreeFileCount.finish(count: directoryCount)
        try directorySubtreeBytes.finish(count: directoryCount)
        try directoryOwnFileCount.finish(count: directoryCount)
        try directoryOwnBytes.finish(count: directoryCount)
        try directoryNameOffset.finish(count: directoryCount)
        try directoryNameLength.finish(count: directoryCount)
        try directoryBytesByStorageClass.finish(count: directoryCount * IndexFormat.storageClassSlots)
        try directoryDominantExtension.finish(count: directoryCount)
        try directoryAgeWeightedBytes.finish(count: directoryCount)
        try directoryNames.finish()
        try fileSize.finish()
        try fileLastModified.finish()
        try fileStorageClass.finish()
        try fileExtension.finish()
        try fileNameBlocks.finish()
        try fileNameData.finish()
    }
}
```

- [ ] **Step 4: Write `DirectoryTree.swift`**

```swift
import Foundation

public struct DirectoryTree {
    let parentColumn: MappedColumn<UInt32>
    let depthColumn: MappedColumn<UInt8>
    let subtreeDirectoryCountColumn: MappedColumn<UInt32>
    let childCountColumn: MappedColumn<UInt32>
    let fileStartColumn: MappedColumn<UInt64>
    let subtreeFileCountColumn: MappedColumn<UInt64>
    let subtreeBytesColumn: MappedColumn<UInt64>
    let ownFileCountColumn: MappedColumn<UInt32>
    let ownBytesColumn: MappedColumn<UInt64>
    let nameOffsetColumn: MappedColumn<UInt64>
    let nameLengthColumn: MappedColumn<UInt16>
    let namesColumn: MappedColumn<UInt8>
    let bytesByStorageClassColumn: MappedColumn<UInt64>
    let dominantExtensionColumn: MappedColumn<UInt16>
    let ageWeightedBytesColumn: MappedColumn<UInt64>
    let childListStartColumn: MappedColumn<UInt32>
    let childrenBySizeColumn: MappedColumn<UInt32>

    public var count: Int { parentColumn.count }

    @inline(__always) public func parent(_ id: UInt32) -> UInt32 { parentColumn[Int(id)] }
    @inline(__always) public func depth(_ id: UInt32) -> UInt8 { depthColumn[Int(id)] }
    @inline(__always) public func subtreeDirectoryCount(_ id: UInt32) -> UInt32 { subtreeDirectoryCountColumn[Int(id)] }
    @inline(__always) public func childCount(_ id: UInt32) -> UInt32 { childCountColumn[Int(id)] }
    @inline(__always) public func fileStart(_ id: UInt32) -> UInt64 { fileStartColumn[Int(id)] }
    @inline(__always) public func subtreeFileCount(_ id: UInt32) -> UInt64 { subtreeFileCountColumn[Int(id)] }
    @inline(__always) public func subtreeBytes(_ id: UInt32) -> UInt64 { subtreeBytesColumn[Int(id)] }
    @inline(__always) public func ownFileCount(_ id: UInt32) -> UInt32 { ownFileCountColumn[Int(id)] }
    @inline(__always) public func ownBytes(_ id: UInt32) -> UInt64 { ownBytesColumn[Int(id)] }
    @inline(__always) public func dominantExtension(_ id: UInt32) -> UInt16 { dominantExtensionColumn[Int(id)] }
    @inline(__always) public func ageWeightedBytes(_ id: UInt32) -> UInt64 { ageWeightedBytesColumn[Int(id)] }

    public func bytesByStorageClass(_ id: UInt32) -> [UInt64] {
        let base = Int(id) * IndexFormat.storageClassSlots
        return Array(bytesByStorageClassColumn.buffer[base..<(base + IndexFormat.storageClassSlots)])
    }

    public func dominantStorageClass(_ id: UInt32) -> UInt8 {
        let base = Int(id) * IndexFormat.storageClassSlots
        var best = 0
        for slot in 1..<IndexFormat.storageClassSlots where bytesByStorageClassColumn[base + slot] > bytesByStorageClassColumn[base + best] { best = slot }
        return UInt8(best)
    }

    public func averageAgeDays(_ id: UInt32) -> Double {
        let bytes = subtreeBytes(id)
        return bytes == 0 ? 0 : Double(ageWeightedBytes(id)) / Double(bytes)
    }

    public func withNameBytes<R>(_ id: UInt32, _ body: (UnsafeBufferPointer<UInt8>) -> R) -> R {
        let start = Int(nameOffsetColumn[Int(id)])
        let length = Int(nameLengthColumn[Int(id)])
        return body(UnsafeBufferPointer(rebasing: namesColumn.buffer[start..<(start + length)]))
    }

    public func name(_ id: UInt32) -> String { withNameBytes(id) { String(decoding: $0, as: UTF8.self) } }

    public func path(_ id: UInt32) -> String {
        var segments: [String] = []
        var current = id
        while current != IndexFormat.rootDirectory && current != IndexFormat.noParent {
            segments.append(name(current))
            current = parent(current)
        }
        return segments.reversed().joined(separator: "/")
    }

    public func subtreeRange(_ id: UInt32) -> Range<UInt32> { id..<(id + 1 + subtreeDirectoryCount(id)) }

    public func subtreeFileRange(_ id: UInt32) -> Range<UInt64> {
        let start = fileStart(id)
        return start..<(start + subtreeFileCount(id))
    }

    public func childrenInKeyOrder(_ id: UInt32) -> [UInt32] {
        var result: [UInt32] = []
        result.reserveCapacity(Int(childCount(id)))
        let end = id + 1 + subtreeDirectoryCount(id)
        var child = id + 1
        while child < end {
            result.append(child)
            child += 1 + subtreeDirectoryCount(child)
        }
        return result
    }

    public func childrenBySize(_ id: UInt32) -> [UInt32] {
        let start = Int(childListStartColumn[Int(id)])
        return Array(childrenBySizeColumn.buffer[start..<(start + Int(childCount(id)))])
    }

    /// Own files are the gaps between children's subtree file ranges, in key order.
    public func ownFileRanges(_ id: UInt32) -> [Range<UInt64>] {
        var ranges: [Range<UInt64>] = []
        var cursor = fileStart(id)
        let end = cursor + subtreeFileCount(id)
        for child in childrenInKeyOrder(id) {
            let childStart = fileStart(child)
            if childStart > cursor { ranges.append(cursor..<childStart) }
            cursor = childStart + subtreeFileCount(child)
        }
        if end > cursor { ranges.append(cursor..<end) }
        return ranges
    }

    /// Exact segment walk from the root. "" is the root. A trailing "/" is ignored.
    public func lookup(path: String) -> UInt32? {
        var current = IndexFormat.rootDirectory
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        if trimmed.isEmpty { return current }
        for segment in trimmed.split(separator: "/", omittingEmptySubsequences: false) {
            let segmentBytes = Array(segment.utf8)
            var found: UInt32?
            for child in childrenInKeyOrder(current) {
                let matches = withNameBytes(child) { bytes in bytes.count == segmentBytes.count && segmentBytes.withUnsafeBufferPointer { bytes.elementsEqual($0) } }
                if matches { found = child; break }
            }
            guard let next = found else { return nil }
            current = next
        }
        return current
    }
}
```

- [ ] **Step 5: Write `IndexPostProcessing.swift`**

```swift
import Foundation

public enum IndexPostProcessing {
    /// Writes `directory.childListStart.u32` and `directory.childrenBySize.u32` from the finished directory columns.
    public static func writeChildrenBySize(folder: URL) throws {
        let subtreeDirectoryCount = try MappedColumn<UInt32>(url: folder.appendingPathComponent(IndexFiles.directorySubtreeDirectoryCount))
        let subtreeBytes = try MappedColumn<UInt64>(url: folder.appendingPathComponent(IndexFiles.directorySubtreeBytes))
        let childListStart = try ColumnWriter<UInt32>(url: folder.appendingPathComponent(IndexFiles.directoryChildListStart))
        let childrenBySize = try ColumnWriter<UInt32>(url: folder.appendingPathComponent(IndexFiles.directoryChildrenBySize))
        var children: [UInt32] = []
        for id in 0..<subtreeDirectoryCount.count {
            childListStart.append(UInt32(childrenBySize.count))
            children.removeAll(keepingCapacity: true)
            let end = id + 1 + Int(subtreeDirectoryCount[id])
            var child = id + 1
            while child < end {
                children.append(UInt32(child))
                child += 1 + Int(subtreeDirectoryCount[child])
            }
            children.sort { left, right in
                let leftBytes = subtreeBytes[Int(left)], rightBytes = subtreeBytes[Int(right)]
                return leftBytes != rightBytes ? leftBytes > rightBytes : left < right
            }
            for child in children { childrenBySize.append(child) }
        }
        try childListStart.finish()
        try childrenBySize.finish()
    }
}
```

- [ ] **Step 6: Write `IndexReader.swift`**

```swift
import Foundation

public final class IndexReader {
    public let folder: URL
    public let manifest: IndexManifest
    public let directories: DirectoryTree
    public let fileSize: MappedColumn<UInt64>
    public let fileLastModified: MappedColumn<UInt32>
    public let fileStorageClass: MappedColumn<UInt8>
    public let fileExtension: MappedColumn<UInt16>
    public let names: NameBlockCache

    public var fileCount: Int { fileSize.count }

    public static func indexFolder(forInventory folder: URL) -> URL { folder.appendingPathComponent(IndexFormat.folderName, isDirectory: true) }

    public init(folder: URL) throws {
        self.folder = folder
        manifest = try IndexManifest.load(from: folder)
        func column<Element>(_ name: String) throws -> MappedColumn<Element> { try MappedColumn(url: folder.appendingPathComponent(name)) }
        directories = DirectoryTree(
            parentColumn: try column(IndexFiles.directoryParent), depthColumn: try column(IndexFiles.directoryDepth),
            subtreeDirectoryCountColumn: try column(IndexFiles.directorySubtreeDirectoryCount), childCountColumn: try column(IndexFiles.directoryChildCount),
            fileStartColumn: try column(IndexFiles.directoryFileStart), subtreeFileCountColumn: try column(IndexFiles.directorySubtreeFileCount),
            subtreeBytesColumn: try column(IndexFiles.directorySubtreeBytes), ownFileCountColumn: try column(IndexFiles.directoryOwnFileCount),
            ownBytesColumn: try column(IndexFiles.directoryOwnBytes), nameOffsetColumn: try column(IndexFiles.directoryNameOffset),
            nameLengthColumn: try column(IndexFiles.directoryNameLength), namesColumn: try column(IndexFiles.directoryNames),
            bytesByStorageClassColumn: try column(IndexFiles.directoryBytesByStorageClass), dominantExtensionColumn: try column(IndexFiles.directoryDominantExtension),
            ageWeightedBytesColumn: try column(IndexFiles.directoryAgeWeightedBytes), childListStartColumn: try column(IndexFiles.directoryChildListStart),
            childrenBySizeColumn: try column(IndexFiles.directoryChildrenBySize))
        fileSize = try column(IndexFiles.fileSize)
        fileLastModified = try column(IndexFiles.fileLastModified)
        fileStorageClass = try column(IndexFiles.fileStorageClass)
        fileExtension = try column(IndexFiles.fileExtension)
        names = NameBlockCache(blocks: try column(IndexFiles.fileNameBlocks), data: try column(IndexFiles.fileNameData))
    }

    /// Deepest directory whose subtree contains the file: binary search on the monotonic `fileStart`, then walk up.
    public func directory(ofFile fileIndex: UInt64) -> UInt32 {
        var low = 0
        var high = directories.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if directories.fileStart(UInt32(middle)) <= fileIndex { low = middle } else { high = middle - 1 }
        }
        var candidate = UInt32(low)
        while candidate != IndexFormat.noParent {
            let start = directories.fileStart(candidate)
            if fileIndex >= start && fileIndex < start + directories.subtreeFileCount(candidate) { return candidate }
            candidate = directories.parent(candidate)
        }
        return IndexFormat.rootDirectory
    }

    public func key(ofFile fileIndex: UInt64) -> String {
        let directory = self.directory(ofFile: fileIndex)
        let name = names.nameString(ofFile: fileIndex)
        if directory == IndexFormat.rootDirectory { return name }
        return directories.path(directory) + "/" + name
    }
}
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `swift test --filter DirectoryTreeTests 2>&1 | tail -5`
Expected: 3 tests pass. Then run the whole suite: `swift test 2>&1 | tail -3` — all green.

- [ ] **Step 8: Report the changed files. Do not run git.**

---
## Phase 2 — Import pipeline

### Task 7: Gzip streams (inflate reader, deflate writer) and `ImportError`

**Files:**
- Create: `Sources/InventoryImport/ImportError.swift`, `Sources/InventoryImport/GzipStreams.swift`
- Delete: `Sources/InventoryImport/Placeholder.swift`
- Test: `Tests/InventoryImportTests/GzipStreamsTests.swift`

**Interfaces:**
- Produces:
  - `enum ImportError: Error` with cases `invalidManifest(String)`, `missingDataFiles([String])`, `corruptGzip(file: String, detail: String)`, `rowTooLong(file: String)`, `tooManyParseErrors(file: String, count: Int)`, `notKeySorted(file: String, previousKey: String, key: String)`, `directoryReentered(path: String)`, `tooManyFiles`, `outputExists(URL)`, `cancelled`, `systemCall(String, errno: Int32)`.
  - `final class GzipInflateStream` — `init(url: URL, bufferSize: Int = 1 << 20) throws`, `url`, `compressedBytesRead: Int64`, `func read(into: UnsafeMutableBufferPointer<UInt8>) throws -> Int` (0 at end).
  - `final class GzipDeflateWriter` — `init(url: URL) throws`, `func write(_: UnsafeRawBufferPointer) throws`, `func write(_ string: String) throws`, `func finish() throws`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import InventoryImport

final class GzipStreamsTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("gzip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private func readAll(_ url: URL, chunk: Int) throws -> [UInt8] {
        let stream = try GzipInflateStream(url: url, bufferSize: 777)
        var result: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: chunk)
        while true {
            let produced = try buffer.withUnsafeMutableBufferPointer { try stream.read(into: $0) }
            if produced == 0 { break }
            result.append(contentsOf: buffer[0..<produced])
        }
        return result
    }

    func testRoundTripWithSmallReadBuffers() throws {
        let url = folder.appendingPathComponent("round.csv.gz")
        let text = (0..<50_000).map { "\"bucket\",\"key/\($0)/file.jpg\",\"\($0 * 13)\"\n" }.joined()
        let writer = try GzipDeflateWriter(url: url)
        try writer.write(text)
        try writer.finish()
        let bytes = try readAll(url, chunk: 1000)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), text)
    }

    func testInteroperatesWithSystemGzip() throws {
        let plain = folder.appendingPathComponent("plain.txt")
        try "hello gzip\nsecond line\n".write(to: plain, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-k", plain.path]
        try process.run(); process.waitUntilExit()
        let bytes = try readAll(folder.appendingPathComponent("plain.txt.gz"), chunk: 4096)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "hello gzip\nsecond line\n")
    }

    func testTruncatedFileThrowsCorruptGzip() throws {
        let url = folder.appendingPathComponent("full.gz")
        let writer = try GzipDeflateWriter(url: url)
        try writer.write(String(repeating: "abcdefgh\n", count: 100_000))
        try writer.finish()
        let data = try Data(contentsOf: url)
        let truncated = folder.appendingPathComponent("truncated.gz")
        try data.prefix(data.count / 2).write(to: truncated)
        XCTAssertThrowsError(try readAll(truncated, chunk: 4096)) { error in
            guard case ImportError.corruptGzip = error else { return XCTFail("wrong error \(error)") }
        }
    }

    func testCompressedBytesReadTracksInput() throws {
        let url = folder.appendingPathComponent("count.gz")
        let writer = try GzipDeflateWriter(url: url)
        try writer.write(String(repeating: "x", count: 10_000))
        try writer.finish()
        let stream = try GzipInflateStream(url: url)
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while try buffer.withUnsafeMutableBufferPointer({ try stream.read(into: $0) }) > 0 {}
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int64
        XCTAssertEqual(stream.compressedBytesRead, size)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter GzipStreamsTests 2>&1 | tail -5`
Expected: compile errors.

- [ ] **Step 3: Write `ImportError.swift`**

```swift
import Foundation

public enum ImportError: Error, Equatable {
    case invalidManifest(String)
    case missingDataFiles([String])
    case corruptGzip(file: String, detail: String)
    case rowTooLong(file: String)
    case tooManyParseErrors(file: String, count: Int)
    case notKeySorted(file: String, previousKey: String, key: String)
    case directoryReentered(path: String)
    case tooManyFiles
    case outputExists(URL)
    case cancelled
    case systemCall(String, errno: Int32)
}
```

- [ ] **Step 4: Write `GzipStreams.swift`**

```swift
import Foundation
import zlib

public final class GzipInflateStream {
    public let url: URL
    public private(set) var compressedBytesRead: Int64 = 0
    private var stream = z_stream()
    private let descriptor: Int32
    private let inputBuffer: UnsafeMutablePointer<UInt8>
    private let inputCapacity: Int
    private var inputExhausted = false
    private var finished = false

    public init(url: URL, bufferSize: Int = 1 << 20) throws {
        self.url = url
        descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw ImportError.systemCall("open \(url.lastPathComponent)", errno: errno) }
        _ = fcntl(descriptor, F_RDAHEAD, 1)
        inputCapacity = bufferSize
        inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        let status = inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else {
            close(descriptor); inputBuffer.deallocate()
            throw ImportError.corruptGzip(file: url.lastPathComponent, detail: "inflateInit2 returned \(status)")
        }
    }

    deinit {
        inflateEnd(&stream)
        close(descriptor)
        inputBuffer.deallocate()
    }

    /// Fills `destination` as far as possible. Returns 0 only at the end of the stream.
    public func read(into destination: UnsafeMutableBufferPointer<UInt8>) throws -> Int {
        if finished { return 0 }
        stream.next_out = destination.baseAddress
        stream.avail_out = UInt32(destination.count)
        while stream.avail_out > 0 {
            if stream.avail_in == 0 && !inputExhausted {
                let bytesRead = Darwin.read(descriptor, inputBuffer, inputCapacity)
                guard bytesRead >= 0 else { throw ImportError.systemCall("read \(url.lastPathComponent)", errno: errno) }
                if bytesRead == 0 {
                    inputExhausted = true
                } else {
                    stream.next_in = inputBuffer
                    stream.avail_in = UInt32(bytesRead)
                    compressedBytesRead += Int64(bytesRead)
                }
            }
            let status = inflate(&stream, Z_NO_FLUSH)
            if status == Z_STREAM_END {
                if stream.avail_in == 0 && inputExhausted { finished = true; break }
                if stream.avail_in == 0 { continue }          // may be more members after the next read
                inflateReset(&stream)                          // concatenated gzip members
                continue
            }
            if status == Z_BUF_ERROR {
                if inputExhausted && stream.avail_in == 0 { throw ImportError.corruptGzip(file: url.lastPathComponent, detail: "truncated gzip stream") }
                continue
            }
            guard status == Z_OK else {
                let message = stream.msg.map { String(cString: $0) } ?? "zlib status \(status)"
                throw ImportError.corruptGzip(file: url.lastPathComponent, detail: message)
            }
        }
        return destination.count - Int(stream.avail_out)
    }
}

public final class GzipDeflateWriter {
    private var stream = z_stream()
    private let handle: FileHandle
    private var outputBuffer = [UInt8](repeating: 0, count: 1 << 20)
    private var finished = false

    public init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        let status = deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw ImportError.corruptGzip(file: url.lastPathComponent, detail: "deflateInit2 returned \(status)") }
    }

    public func write(_ string: String) throws {
        var bytes = Array(string.utf8)
        try bytes.withUnsafeMutableBytes { try write(UnsafeRawBufferPointer($0)) }
    }

    public func write(_ bytes: UnsafeRawBufferPointer) throws {
        stream.next_in = UnsafeMutablePointer(mutating: bytes.baseAddress!.assumingMemoryBound(to: UInt8.self))
        stream.avail_in = UInt32(bytes.count)
        try drain(flush: Z_NO_FLUSH)
    }

    public func finish() throws {
        guard !finished else { return }
        finished = true
        stream.avail_in = 0
        try drain(flush: Z_FINISH)
        deflateEnd(&stream)
        try handle.close()
    }

    private func drain(flush: Int32) throws {
        repeat {
            let produced: Int = try outputBuffer.withUnsafeMutableBufferPointer { buffer in
                stream.next_out = buffer.baseAddress
                stream.avail_out = UInt32(buffer.count)
                let status = deflate(&stream, flush)
                guard status != Z_STREAM_ERROR else { throw ImportError.corruptGzip(file: "output", detail: "deflate stream error") }
                return buffer.count - Int(stream.avail_out)
            }
            if produced > 0 { handle.write(Data(outputBuffer[0..<produced])) }
        } while stream.avail_out == 0
    }
}
```

- [ ] **Step 5: Delete the placeholder, run the tests**

Run: `rm Sources/InventoryImport/Placeholder.swift && swift test --filter GzipStreamsTests 2>&1 | tail -5`
Expected: 4 tests pass.

- [ ] **Step 6: Report the changed files. Do not run git.**

### Task 8: Inventory source — manifest, schema, data files; fixture inventory writer

**Files:**
- Create: `Sources/InventoryImport/InventorySource.swift`
- Modify: `Tests/TestSupport/FixtureInventory.swift` (add the writer)
- Test: `Tests/InventoryImportTests/InventorySourceTests.swift`

**Interfaces:**
- Produces:
  - `struct InventorySchema: Equatable` — `static let defaultColumns: [String]`, `columnNames`, `keyColumn`, `sizeColumn`, `lastModifiedColumn: Int?`, `storageClassColumn: Int?`, `isLatestColumn: Int?`, `isDeleteMarkerColumn: Int?`, `requiredFieldCount: Int`, `init(fileSchema: String) throws`, `static let standard`.
  - `struct InventoryDataFile: Equatable` — `url`, `manifestKey`, `expectedSize: Int64?`, `actualSize: Int64`.
  - `struct InventorySource` — `folder`, `manifestURL: URL?`, `sourceBucket`, `creationTimestampMilliseconds: Int64?`, `schema`, `dataFiles`, `missingDataFiles: [String]`, `manifestMD5: String?`, `totalCompressedBytes: Int64`, `inventoryTimestamp: UInt32`, `static func load(folder: URL) throws -> InventorySource`.
  - TestSupport: `FixtureInventory.encodeKey(_:)`, `FixtureInventory.sortedForInventory(_:)`, `FixtureInventory.write(rows:to:bucket:fileCount:shuffleManifest:schemaColumns:creationTimestampMilliseconds:) throws -> URL`.

- [ ] **Step 1: Extend `FixtureInventory.swift`**

Append to the file (keep `FixtureRow` from Task 1):

```swift
import InventoryImport

public enum FixtureInventory {
    /// Percent-encodes every byte except unreserved characters and '/', the way S3 Inventory does (space is %20, '+' is %2B).
    public static func encodeKey(_ key: String) -> String {
        var result = ""
        for byte in key.utf8 {
            let isUnreserved = (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57)
                || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "~") || byte == UInt8(ascii: "/")
            if isUnreserved { result.append(Character(UnicodeScalar(byte))) } else { result.append(String(format: "%%%02X", byte)) }
        }
        return result
    }

    public static func sortedForInventory(_ rows: [FixtureRow]) -> [FixtureRow] {
        rows.sorted { Array(encodeKey($0.key).utf8).lexicographicallyPrecedes(Array(encodeKey($1.key).utf8)) }
    }

    public static func csvRow(_ row: FixtureRow, bucket: String, schemaColumns: [String]) -> String {
        let values: [String: String] = [
            "Bucket": bucket, "Key": encodeKey(row.key), "VersionId": "version1", "IsLatest": row.isLatest ? "true" : "false",
            "IsDeleteMarker": row.isDeleteMarker ? "true" : "false", "Size": row.isDeleteMarker ? "" : String(row.size),
            "LastModifiedDate": row.lastModified, "ETag": "etag", "StorageClass": row.isDeleteMarker ? "" : row.storageClass,
            "IsMultipartUploaded": "false", "ReplicationStatus": "", "IntelligentTieringAccessTier": ""]
        return schemaColumns.map { "\"\(values[$0] ?? "")\"" }.joined(separator: ",") + "\n"
    }

    /// Writes manifest.json + data/<uuid>.csv.gz. Rows are sorted by encoded key and split into `fileCount` contiguous ranges.
    @discardableResult
    public static func write(rows: [FixtureRow], to folder: URL, bucket: String = "fixture-bucket", fileCount: Int = 1, shuffleManifest: Bool = true,
                             schemaColumns: [String] = InventorySchema.defaultColumns, creationTimestampMilliseconds: Int64 = 1_767_225_600_000) throws -> URL {
        let dataFolder = folder.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: dataFolder, withIntermediateDirectories: true)
        let sorted = sortedForInventory(rows)
        let rowsPerFile = max(1, Int((Double(sorted.count) / Double(fileCount)).rounded(.up)))
        var files: [[String: Any]] = []
        var start = 0
        while start < sorted.count || files.isEmpty {
            let slice = sorted[start..<min(start + rowsPerFile, sorted.count)]
            let name = UUID().uuidString.lowercased() + ".csv.gz"
            let url = dataFolder.appendingPathComponent(name)
            let writer = try GzipDeflateWriter(url: url)
            for row in slice { try writer.write(csvRow(row, bucket: bucket, schemaColumns: schemaColumns)) }
            try writer.finish()
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int64
            files.append(["key": "inventory/\(bucket)/data/\(name)", "size": size, "MD5checksum": "00000000000000000000000000000000"])
            start += rowsPerFile
            if slice.isEmpty { break }
        }
        if shuffleManifest { files.shuffle() }
        let manifest: [String: Any] = [
            "sourceBucket": bucket, "destinationBucket": "arn:aws:s3:::logs", "version": "2016-11-30",
            "creationTimestamp": String(creationTimestampMilliseconds), "fileFormat": "CSV",
            "fileSchema": schemaColumns.joined(separator: ", "), "files": files]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted])
        try data.write(to: folder.appendingPathComponent("manifest.json"))
        return folder
    }
}
```

- [ ] **Step 2: Write the failing tests**

```swift
import XCTest
import TestSupport
@testable import InventoryImport

final class InventorySourceTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("source-\(UUID().uuidString)")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    func testSchemaMapsColumns() throws {
        let schema = try InventorySchema(fileSchema: "Bucket, Key, VersionId, IsLatest, IsDeleteMarker, Size, LastModifiedDate, ETag, StorageClass, IsMultipartUploaded, ReplicationStatus, IntelligentTieringAccessTier")
        XCTAssertEqual(schema.keyColumn, 1)
        XCTAssertEqual(schema.sizeColumn, 5)
        XCTAssertEqual(schema.lastModifiedColumn, 6)
        XCTAssertEqual(schema.storageClassColumn, 8)
        XCTAssertEqual(schema.isLatestColumn, 3)
        XCTAssertEqual(schema.isDeleteMarkerColumn, 4)
        XCTAssertEqual(schema.requiredFieldCount, 9)
        let reduced = try InventorySchema(fileSchema: "Bucket, Key, Size")
        XCTAssertNil(reduced.lastModifiedColumn)
        XCTAssertEqual(reduced.requiredFieldCount, 3)
        XCTAssertThrowsError(try InventorySchema(fileSchema: "Bucket, Size"))
    }

    func testLoadsManifestAndResolvesDataFiles() throws {
        let rows = (0..<10).map { FixtureRow(key: "prefix/file\($0).jpg", size: UInt64($0)) }
        try FixtureInventory.write(rows: rows, to: folder, bucket: "my-bucket", fileCount: 3)
        let source = try InventorySource.load(folder: folder)
        XCTAssertEqual(source.sourceBucket, "my-bucket")
        XCTAssertEqual(source.dataFiles.count, 3)
        XCTAssertEqual(source.missingDataFiles, [])
        XCTAssertEqual(source.creationTimestampMilliseconds, 1_767_225_600_000)
        XCTAssertEqual(source.inventoryTimestamp, 1_767_225_600)
        XCTAssertEqual(source.schema, InventorySchema.standard)
        XCTAssertNotNil(source.manifestMD5)
        XCTAssertEqual(source.totalCompressedBytes, source.dataFiles.reduce(0) { $0 + $1.actualSize })
    }

    func testMissingAndMismatchedFilesAreReported() throws {
        let rows = (0..<10).map { FixtureRow(key: "k\($0)", size: 1) }
        try FixtureInventory.write(rows: rows, to: folder, fileCount: 2)
        let dataFiles = try FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent("data"), includingPropertiesForKeys: nil)
        try FileManager.default.removeItem(at: dataFiles[0])
        try Data([1, 2, 3]).write(to: dataFiles[1])   // wrong size
        let source = try InventorySource.load(folder: folder)
        XCTAssertEqual(source.dataFiles.count, 0)
        XCTAssertEqual(Set(source.missingDataFiles), Set(dataFiles.map { $0.lastPathComponent }))
    }

    func testBareFolderWithoutManifest() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let writer = try GzipDeflateWriter(url: folder.appendingPathComponent("part.csv.gz"))
        try writer.write("\"b\",\"k\",\"v\",\"true\",\"false\",\"1\",\"2026-01-01T00:00:00.000Z\",\"e\",\"STANDARD\",\"false\",\"\",\"\"\n")
        try writer.finish()
        let source = try InventorySource.load(folder: folder)
        XCTAssertNil(source.manifestURL)
        XCTAssertEqual(source.dataFiles.count, 1)
        XCTAssertEqual(source.schema, InventorySchema.standard)
        XCTAssertEqual(source.sourceBucket, folder.lastPathComponent)
    }

    func testNonCSVManifestIsRejected() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "{\"fileFormat\":\"Parquet\",\"sourceBucket\":\"b\",\"fileSchema\":\"Key, Size\",\"files\":[]}".write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try InventorySource.load(folder: folder)) { error in
            guard case ImportError.invalidManifest = error else { return XCTFail("wrong error \(error)") }
        }
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --filter InventorySourceTests 2>&1 | tail -5`
Expected: compile errors.

- [ ] **Step 4: Write `InventorySource.swift`**

```swift
import Foundation
import CryptoKit

public struct InventorySchema: Equatable {
    public static let defaultColumns = ["Bucket", "Key", "VersionId", "IsLatest", "IsDeleteMarker", "Size", "LastModifiedDate", "ETag",
                                        "StorageClass", "IsMultipartUploaded", "ReplicationStatus", "IntelligentTieringAccessTier"]
    public let columnNames: [String]
    public let keyColumn: Int
    public let sizeColumn: Int
    public let lastModifiedColumn: Int?
    public let storageClassColumn: Int?
    public let isLatestColumn: Int?
    public let isDeleteMarkerColumn: Int?

    public var requiredFieldCount: Int {
        ([keyColumn, sizeColumn] + [lastModifiedColumn, storageClassColumn, isLatestColumn, isDeleteMarkerColumn].compactMap { $0 }).max()! + 1
    }

    public init(fileSchema: String) throws {
        let names = fileSchema.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let key = names.firstIndex(of: "Key"), let size = names.firstIndex(of: "Size") else {
            throw ImportError.invalidManifest("fileSchema must contain Key and Size, found: \(fileSchema)")
        }
        columnNames = names
        keyColumn = key
        sizeColumn = size
        lastModifiedColumn = names.firstIndex(of: "LastModifiedDate")
        storageClassColumn = names.firstIndex(of: "StorageClass")
        isLatestColumn = names.firstIndex(of: "IsLatest")
        isDeleteMarkerColumn = names.firstIndex(of: "IsDeleteMarker")
    }

    public static let standard = try! InventorySchema(fileSchema: defaultColumns.joined(separator: ", "))
}

public struct InventoryDataFile: Equatable {
    public let url: URL
    public let manifestKey: String
    public let expectedSize: Int64?
    public let actualSize: Int64
}

public struct InventorySource {
    public let folder: URL
    public let manifestURL: URL?
    public let sourceBucket: String
    public let creationTimestampMilliseconds: Int64?
    public let schema: InventorySchema
    public let dataFiles: [InventoryDataFile]
    public let missingDataFiles: [String]
    public let manifestMD5: String?
    public var totalCompressedBytes: Int64 { dataFiles.reduce(0) { $0 + $1.actualSize } }
    public var manifestTotalBytes: Int64 { dataFiles.reduce(0) { $0 + ($1.expectedSize ?? $1.actualSize) } + 0 }

    /// Seconds since 1970 for the inventory snapshot; the manifest's creationTimestamp, else now.
    public var inventoryTimestamp: UInt32 {
        if let milliseconds = creationTimestampMilliseconds { return UInt32(clamping: milliseconds / 1000) }
        return UInt32(clamping: Int64(Date().timeIntervalSince1970))
    }

    public static func load(folder: URL) throws -> InventorySource {
        let manifestURL = folder.appendingPathComponent("manifest.json")
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            return try loadWithManifest(folder: folder, manifestURL: manifestURL)
        }
        return try loadBareFolder(folder: folder)
    }

    private static func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
    }

    private static func loadWithManifest(folder: URL, manifestURL: URL) throws -> InventorySource {
        let data = try Data(contentsOf: manifestURL)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ImportError.invalidManifest("manifest.json is not a JSON object") }
        guard (object["fileFormat"] as? String)?.uppercased() == "CSV" else { throw ImportError.invalidManifest("fileFormat must be CSV") }
        guard let fileSchema = object["fileSchema"] as? String else { throw ImportError.invalidManifest("fileSchema missing") }
        let schema = try InventorySchema(fileSchema: fileSchema)
        let bucket = object["sourceBucket"] as? String ?? folder.lastPathComponent
        var creation: Int64?
        if let text = object["creationTimestamp"] as? String { creation = Int64(text) }
        if let number = object["creationTimestamp"] as? NSNumber { creation = number.int64Value }
        let entries = object["files"] as? [[String: Any]] ?? []
        let dataFolder = folder.appendingPathComponent("data")
        var dataFiles: [InventoryDataFile] = []
        var missing: [String] = []
        for entry in entries {
            guard let key = entry["key"] as? String else { continue }
            let name = (key as NSString).lastPathComponent
            let expected = (entry["size"] as? NSNumber)?.int64Value
            let candidates = [dataFolder.appendingPathComponent(name), folder.appendingPathComponent(name)]
            if let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }), let actual = fileSize(url), expected == nil || expected == actual {
                dataFiles.append(InventoryDataFile(url: url, manifestKey: key, expectedSize: expected, actualSize: actual))
            } else {
                missing.append(name)
            }
        }
        let digest = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return InventorySource(folder: folder, manifestURL: manifestURL, sourceBucket: bucket, creationTimestampMilliseconds: creation,
                               schema: schema, dataFiles: dataFiles, missingDataFiles: missing, manifestMD5: digest)
    }

    private static func loadBareFolder(folder: URL) throws -> InventorySource {
        var urls: [URL] = []
        for candidate in [folder, folder.appendingPathComponent("data")] {
            if let contents = try? FileManager.default.contentsOfDirectory(at: candidate, includingPropertiesForKeys: nil) {
                urls.append(contentsOf: contents.filter { $0.lastPathComponent.hasSuffix(".csv.gz") })
            }
        }
        guard !urls.isEmpty else { throw ImportError.invalidManifest("no manifest.json and no .csv.gz files in \(folder.path)") }
        let dataFiles = urls.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url -> InventoryDataFile? in
            guard let size = fileSize(url) else { return nil }
            return InventoryDataFile(url: url, manifestKey: url.lastPathComponent, expectedSize: nil, actualSize: size)
        }
        return InventorySource(folder: folder, manifestURL: nil, sourceBucket: folder.lastPathComponent, creationTimestampMilliseconds: nil,
                               schema: .standard, dataFiles: dataFiles, missingDataFiles: [], manifestMD5: nil)
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter InventorySourceTests 2>&1 | tail -5`
Expected: 5 tests pass.

- [ ] **Step 6: Report the changed files. Do not run git.**

### Task 9: CSV row parser producing struct-of-arrays chunks

**Files:**
- Create: `Sources/InventoryImport/InventoryRowParser.swift`
- Test: `Tests/InventoryImportTests/InventoryRowParserTests.swift`

**Interfaces:**
- Consumes: `GzipInflateStream`, `InventorySchema`, `StorageClass.identifier(forInventoryName:)`.
- Produces:
  - `struct RowChunk` — `fileIndex`, `chunkIndex`, `keyBytes: [UInt8]`, `keyOffsets: [UInt32]` (count + 1 entries), `sizes: [UInt64]`, `lastModified: [UInt32]`, `storageClass: [UInt8]`, `needsDecoding: [Bool]`, `skippedNonCurrent`, `skippedDeleteMarkers`, `parseErrors`, `compressedBytesDelta: Int64`, `count`, `init(fileIndex:chunkIndex:capacity:)`, `mutating func appendRow(key: UnsafeBufferPointer<UInt8>, size: UInt64, lastModified: UInt32, storageClass: UInt8)`, `func withKey<R>(_ row: Int, _ body: (UnsafeBufferPointer<UInt8>) throws -> R) rethrows -> R`.
  - `final class InventoryRowParser` — `init(schema: InventorySchema, rowsPerChunk: Int = 262_144, readBufferSize: Int = 4 << 20)`, `func parse(stream: GzipInflateStream, fileIndex: Int, emit: (RowChunk) throws -> Void) throws`, `static func parseISO8601Seconds(_: UnsafeBufferPointer<UInt8>) -> UInt32?`, `static func daysFromCivil(year:month:day:) -> Int`, `static func extractField(row: [UInt8], column: Int) -> [UInt8]?` (slow helper for `FileOrdering`), `static let maximumRowLength = 16_384`, `static let maximumParseErrorsPerFile = 1000`.
  - Keys in `keyBytes` are the raw (still percent-encoded) bytes; `needsDecoding` flags rows containing `%`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import TestSupport
@testable import InventoryImport

final class InventoryRowParserTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("parser-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private func parse(_ csv: String, schema: InventorySchema = .standard, rowsPerChunk: Int = 262_144, readBufferSize: Int = 4 << 20) throws -> [RowChunk] {
        let url = folder.appendingPathComponent("\(UUID().uuidString).csv.gz")
        let writer = try GzipDeflateWriter(url: url)
        try writer.write(csv)
        try writer.finish()
        let parser = InventoryRowParser(schema: schema, rowsPerChunk: rowsPerChunk, readBufferSize: readBufferSize)
        var chunks: [RowChunk] = []
        try parser.parse(stream: try GzipInflateStream(url: url), fileIndex: 7) { chunks.append($0) }
        return chunks
    }

    private func key(_ chunk: RowChunk, _ row: Int) -> String { chunk.withKey(row) { String(decoding: $0, as: UTF8.self) } }

    func testParsesFieldsSkipsAndFlags() throws {
        let csv = """
        "b","snapshots/1/a.jpg","v","true","false","23115","2026-02-16T12:16:56.000Z","e","STANDARD","false","",""
        "b","old/version.jpg","v","false","false","10","2026-02-16T12:16:56.000Z","e","STANDARD","false","",""
        "b","deleted.jpg","v","true","true","","2026-02-16T12:16:56.000Z","e","","false","",""
        "b","dir%20one/f%25.jpg","v","true","false","0","2025-01-01T00:00:00.000Z","e","DEEP_ARCHIVE","false","",""
        "b","weird ""quoted"" key","v","true","false","5","2025-01-01T00:00:00.000Z","e","GLACIER_IR","false","",""
        "b","bad-size","v","true","false","abc","2025-01-01T00:00:00.000Z","e","STANDARD","false","",""

        """
        let chunks = try parse(csv)
        XCTAssertEqual(chunks.count, 1)
        let chunk = chunks[0]
        XCTAssertEqual(chunk.fileIndex, 7)
        XCTAssertEqual(chunk.count, 3)
        XCTAssertEqual(chunk.skippedNonCurrent, 1)
        XCTAssertEqual(chunk.skippedDeleteMarkers, 1)
        XCTAssertEqual(chunk.parseErrors, 1)
        XCTAssertEqual(key(chunk, 0), "snapshots/1/a.jpg")
        XCTAssertEqual(chunk.sizes[0], 23115)
        XCTAssertEqual(chunk.storageClass[0], 0)
        XCTAssertEqual(chunk.lastModified[0], 1_771_244_216)      // 2026-02-16T12:16:56Z
        XCTAssertFalse(chunk.needsDecoding[0])
        XCTAssertEqual(key(chunk, 1), "dir%20one/f%25.jpg")
        XCTAssertTrue(chunk.needsDecoding[1])
        XCTAssertEqual(chunk.storageClass[1], 6)
        XCTAssertEqual(key(chunk, 2), "weird \"quoted\" key")
        XCTAssertEqual(chunk.storageClass[2], 4)
    }

    func testReducedSchemaAndCRLF() throws {
        let schema = try InventorySchema(fileSchema: "Bucket, Key, Size")
        let chunks = try parse("\"b\",\"a\",\"1\"\r\n\"b\",\"c\",\"2\"\r\n", schema: schema)
        XCTAssertEqual(chunks[0].count, 2)
        XCTAssertEqual(chunks[0].lastModified, [0, 0])
        XCTAssertEqual(chunks[0].storageClass, [7, 7])
        XCTAssertEqual(key(chunks[0], 1), "c")
    }

    func testChunkAndReadBufferBoundaries() throws {
        let rows = (0..<1000).map { "\"b\",\"key/\(String(format: "%05d", $0))/name.jpg\",\"v\",\"true\",\"false\",\"\($0)\",\"2026-01-01T00:00:00.000Z\",\"e\",\"STANDARD_IA\",\"false\",\"\",\"\"\n" }
        let chunks = try parse(rows.joined(), rowsPerChunk: 300, readBufferSize: 100)
        XCTAssertEqual(chunks.map { $0.count }, [300, 300, 300, 100])
        XCTAssertEqual(chunks.map { $0.chunkIndex }, [0, 1, 2, 3])
        XCTAssertEqual(key(chunks[3], 99), "key/00999/name.jpg")
        XCTAssertEqual(chunks[3].sizes[99], 999)
        XCTAssertEqual(chunks.reduce(0) { $0 + $1.compressedBytesDelta }, chunks.last!.compressedBytesDelta + chunks.dropLast().reduce(0) { $0 + $1.compressedBytesDelta })
    }

    func testEmptyFileEmitsOneEmptyChunk() throws {
        let chunks = try parse("")
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].count, 0)
    }

    func testFastDateParserMatchesFoundation() throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let samples = ["2000-02-29T23:59:59.000Z", "2024-02-29T00:00:00.000Z", "1999-12-31T23:59:59.000Z", "2026-09-12T03:40:00.000Z", "1970-01-01T00:00:00.000Z", "2100-03-01T12:00:00.000Z"]
        for sample in samples {
            let expected = UInt32(formatter.date(from: sample)!.timeIntervalSince1970)
            let parsed = Array(sample.utf8).withUnsafeBufferPointer { InventoryRowParser.parseISO8601Seconds($0) }
            XCTAssertEqual(parsed, expected, sample)
        }
        XCTAssertNil(Array("not a date".utf8).withUnsafeBufferPointer { InventoryRowParser.parseISO8601Seconds($0) })
        XCTAssertEqual(InventoryRowParser.daysFromCivil(year: 1970, month: 1, day: 1), 0)
        XCTAssertEqual(InventoryRowParser.daysFromCivil(year: 2000, month: 3, day: 1), 11_017)
    }

    func testExtractFieldHelper() {
        let row = Array("\"b\",\"a,b\",\"3\"".utf8)
        XCTAssertEqual(InventoryRowParser.extractField(row: row, column: 1).map { String(decoding: $0, as: UTF8.self) }, "a,b")
        XCTAssertEqual(InventoryRowParser.extractField(row: row, column: 2).map { String(decoding: $0, as: UTF8.self) }, "3")
        XCTAssertNil(InventoryRowParser.extractField(row: row, column: 3))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter InventoryRowParserTests 2>&1 | tail -5`
Expected: compile errors.

- [ ] **Step 3: Write `InventoryRowParser.swift`**

```swift
import Foundation
import InventoryIndex

public struct RowChunk {
    public let fileIndex: Int
    public let chunkIndex: Int
    public var keyBytes: [UInt8] = []
    public var keyOffsets: [UInt32] = [0]
    public var sizes: [UInt64] = []
    public var lastModified: [UInt32] = []
    public var storageClass: [UInt8] = []
    public var needsDecoding: [Bool] = []
    public var skippedNonCurrent = 0
    public var skippedDeleteMarkers = 0
    public var parseErrors = 0
    public var compressedBytesDelta: Int64 = 0

    public var count: Int { sizes.count }

    public init(fileIndex: Int, chunkIndex: Int, capacity: Int) {
        self.fileIndex = fileIndex
        self.chunkIndex = chunkIndex
        keyBytes.reserveCapacity(capacity * 96)
        keyOffsets.reserveCapacity(capacity + 1)
        sizes.reserveCapacity(capacity)
        lastModified.reserveCapacity(capacity)
        storageClass.reserveCapacity(capacity)
        needsDecoding.reserveCapacity(capacity)
    }

    public mutating func appendRow(key: UnsafeBufferPointer<UInt8>, size: UInt64, lastModified: UInt32, storageClass: UInt8) {
        keyBytes.append(contentsOf: key)
        keyOffsets.append(UInt32(keyBytes.count))
        sizes.append(size)
        self.lastModified.append(lastModified)
        self.storageClass.append(storageClass)
        needsDecoding.append(memchr(key.baseAddress, Int32(UInt8(ascii: "%")), key.count) != nil)
    }

    public func withKey<R>(_ row: Int, _ body: (UnsafeBufferPointer<UInt8>) throws -> R) rethrows -> R {
        try keyBytes.withUnsafeBufferPointer { buffer in
            try body(UnsafeBufferPointer(rebasing: buffer[Int(keyOffsets[row])..<Int(keyOffsets[row + 1])]))
        }
    }
}

public final class InventoryRowParser {
    public static let maximumRowLength = 16_384
    public static let maximumParseErrorsPerFile = 1000
    public let schema: InventorySchema
    public let rowsPerChunk: Int
    private let readBufferSize: Int
    private var fieldStarts = [Int](repeating: 0, count: 32)
    private var fieldLengths = [Int](repeating: 0, count: 32)
    private var fieldEscaped = [Bool](repeating: false, count: 32)
    private var unescapeScratch: [UInt8] = []
    private var parseErrorsInFile = 0
    private static let fallbackFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public init(schema: InventorySchema, rowsPerChunk: Int = 262_144, readBufferSize: Int = 4 << 20) {
        self.schema = schema
        self.rowsPerChunk = rowsPerChunk
        self.readBufferSize = max(readBufferSize, 64)
    }

    public func parse(stream: GzipInflateStream, fileIndex: Int, emit: (RowChunk) throws -> Void) throws {
        let capacity = readBufferSize + InventoryRowParser.maximumRowLength
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        let fileName = stream.url.lastPathComponent
        parseErrorsInFile = 0
        var carry = 0
        var chunkIndex = 0
        var chunk = RowChunk(fileIndex: fileIndex, chunkIndex: 0, capacity: rowsPerChunk)
        var compressedAtLastEmit: Int64 = 0
        while true {
            let produced = try stream.read(into: UnsafeMutableBufferPointer(start: buffer + carry, count: capacity - carry))
            if produced == 0 {
                if carry > 0 { try parseRow(UnsafeBufferPointer(start: buffer, count: carry), into: &chunk, fileName: fileName) }
                break
            }
            let end = carry + produced
            var rowStart = 0
            while let found = memchr(buffer + rowStart, Int32(UInt8(ascii: "\n")), end - rowStart) {
                let newlineIndex = UnsafeRawPointer(found) - UnsafeRawPointer(buffer)
                var rowEnd = newlineIndex
                if rowEnd > rowStart && buffer[rowEnd - 1] == UInt8(ascii: "\r") { rowEnd -= 1 }
                try parseRow(UnsafeBufferPointer(start: buffer + rowStart, count: rowEnd - rowStart), into: &chunk, fileName: fileName)
                rowStart = newlineIndex + 1
                if chunk.count == rowsPerChunk {
                    chunk.compressedBytesDelta = stream.compressedBytesRead - compressedAtLastEmit
                    compressedAtLastEmit = stream.compressedBytesRead
                    try emit(chunk)
                    chunkIndex += 1
                    chunk = RowChunk(fileIndex: fileIndex, chunkIndex: chunkIndex, capacity: rowsPerChunk)
                }
            }
            carry = end - rowStart
            guard carry < InventoryRowParser.maximumRowLength else { throw ImportError.rowTooLong(file: fileName) }
            if carry > 0 { memmove(buffer, buffer + rowStart, carry) }
        }
        chunk.compressedBytesDelta = stream.compressedBytesRead - compressedAtLastEmit
        try emit(chunk)
    }

    private func parseRow(_ row: UnsafeBufferPointer<UInt8>, into chunk: inout RowChunk, fileName: String) throws {
        if row.isEmpty { return }
        guard let fieldCount = splitFields(row), fieldCount >= schema.requiredFieldCount else {
            try recordParseError(&chunk, fileName: fileName); return
        }
        if let column = schema.isLatestColumn, fieldLengths[column] == 5, row[fieldStarts[column]] == UInt8(ascii: "f") {
            chunk.skippedNonCurrent += 1; return
        }
        if let column = schema.isDeleteMarkerColumn, fieldLengths[column] == 4, row[fieldStarts[column]] == UInt8(ascii: "t") {
            chunk.skippedDeleteMarkers += 1; return
        }
        var size: UInt64 = 0
        let sizeStart = fieldStarts[schema.sizeColumn]
        for index in sizeStart..<(sizeStart + fieldLengths[schema.sizeColumn]) {
            let digit = row[index] &- 48
            guard digit <= 9 else { try recordParseError(&chunk, fileName: fileName); return }
            size = size &* 10 &+ UInt64(digit)
        }
        var lastModified: UInt32 = 0
        if let column = schema.lastModifiedColumn, fieldLengths[column] > 0 {
            let field = UnsafeBufferPointer(rebasing: row[fieldStarts[column]..<(fieldStarts[column] + fieldLengths[column])])
            if let fast = InventoryRowParser.parseISO8601Seconds(field) {
                lastModified = fast
            } else if let date = InventoryRowParser.fallbackFormatter.date(from: String(decoding: field, as: UTF8.self)) {
                lastModified = UInt32(clamping: Int64(date.timeIntervalSince1970))
            }
        }
        var storageClass = StorageClass.other.rawValue
        if let column = schema.storageClassColumn {
            storageClass = StorageClass.identifier(forInventoryName: UnsafeBufferPointer(rebasing: row[fieldStarts[column]..<(fieldStarts[column] + fieldLengths[column])]))
        }
        let keyStart = fieldStarts[schema.keyColumn]
        let keyLength = fieldLengths[schema.keyColumn]
        if fieldEscaped[schema.keyColumn] {
            unescapeScratch.removeAll(keepingCapacity: true)
            var index = keyStart
            let end = keyStart + keyLength
            while index < end {
                unescapeScratch.append(row[index])
                if row[index] == UInt8(ascii: "\"") { index += 2 } else { index += 1 }
            }
            unescapeScratch.withUnsafeBufferPointer { chunk.appendRow(key: $0, size: size, lastModified: lastModified, storageClass: storageClass) }
        } else {
            chunk.appendRow(key: UnsafeBufferPointer(rebasing: row[keyStart..<(keyStart + keyLength)]), size: size, lastModified: lastModified, storageClass: storageClass)
        }
    }

    private func recordParseError(_ chunk: inout RowChunk, fileName: String) throws {
        chunk.parseErrors += 1
        parseErrorsInFile += 1
        if parseErrorsInFile > InventoryRowParser.maximumParseErrorsPerFile { throw ImportError.tooManyParseErrors(file: fileName, count: parseErrorsInFile) }
    }

    /// Fills fieldStarts/fieldLengths/fieldEscaped; returns the field count or nil for a malformed row.
    private func splitFields(_ row: UnsafeBufferPointer<UInt8>) -> Int? {
        let quote = UInt8(ascii: "\""), comma = UInt8(ascii: ",")
        let count = row.count
        var cursor = 0
        var fieldCount = 0
        while fieldCount < 32 {
            if cursor < count && row[cursor] == quote {
                cursor += 1
                let start = cursor
                var escaped = false
                while true {
                    guard let found = memchr(row.baseAddress! + cursor, Int32(quote), count - cursor) else { return nil }
                    let index = UnsafeRawPointer(found) - UnsafeRawPointer(row.baseAddress!)
                    if index + 1 < count && row[index + 1] == quote { escaped = true; cursor = index + 2; continue }
                    cursor = index
                    break
                }
                fieldStarts[fieldCount] = start
                fieldLengths[fieldCount] = cursor - start
                fieldEscaped[fieldCount] = escaped
                cursor += 1
            } else {
                let start = cursor
                if let found = memchr(row.baseAddress! + cursor, Int32(comma), count - cursor) {
                    cursor = UnsafeRawPointer(found) - UnsafeRawPointer(row.baseAddress!)
                } else {
                    cursor = count
                }
                fieldStarts[fieldCount] = start
                fieldLengths[fieldCount] = cursor - start
                fieldEscaped[fieldCount] = false
            }
            fieldCount += 1
            if cursor < count && row[cursor] == comma {
                cursor += 1
                if cursor == count {          // trailing empty unquoted field
                    fieldStarts[fieldCount] = count; fieldLengths[fieldCount] = 0; fieldEscaped[fieldCount] = false
                    fieldCount += 1
                    break
                }
            } else {
                break
            }
        }
        return fieldCount
    }

    public static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let shiftedYear = month <= 2 ? year - 1 : year
        let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
        let yearOfEra = shiftedYear - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// Fast path for "YYYY-MM-DDTHH:MM:SS[.fff]Z". Returns nil for any other shape.
    public static func parseISO8601Seconds(_ bytes: UnsafeBufferPointer<UInt8>) -> UInt32? {
        guard bytes.count >= 19, bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"), bytes[10] == UInt8(ascii: "T"),
              bytes[13] == UInt8(ascii: ":"), bytes[16] == UInt8(ascii: ":") else { return nil }
        func digits(_ start: Int, _ count: Int) -> Int? {
            var value = 0
            for index in start..<(start + count) {
                let digit = Int(bytes[index]) - 48
                guard digit >= 0 && digit <= 9 else { return nil }
                value = value * 10 + digit
            }
            return value
        }
        guard let year = digits(0, 4), let month = digits(5, 2), let day = digits(8, 2),
              let hour = digits(11, 2), let minute = digits(14, 2), let second = digits(17, 2),
              month >= 1, month <= 12, day >= 1, day <= 31, hour <= 23, minute <= 59, second <= 60 else { return nil }
        let total = daysFromCivil(year: year, month: month, day: day) * 86_400 + hour * 3600 + minute * 60 + second
        guard total >= 0 && total <= Int(UInt32.max) else { return nil }
        return UInt32(total)
    }

    /// Slow, allocation-friendly field extraction for one row (used to read the first key of a file).
    public static func extractField(row: [UInt8], column: Int) -> [UInt8]? {
        let parser = InventoryRowParser(schema: .standard)
        let fieldCount = row.withUnsafeBufferPointer { parser.splitFields($0) }
        guard let fieldCount, column < fieldCount else { return nil }
        let start = parser.fieldStarts[column], length = parser.fieldLengths[column]
        var bytes = Array(row[start..<(start + length)])
        if parser.fieldEscaped[column] {
            var result: [UInt8] = []
            var index = 0
            while index < bytes.count { result.append(bytes[index]); index += bytes[index] == UInt8(ascii: "\"") ? 2 : 1 }
            bytes = result
        }
        return bytes
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter InventoryRowParserTests 2>&1 | tail -5`
Expected: 6 tests pass. If `testParsesFieldsSkipsAndFlags` fails on the `lastModified` value, recompute the expected epoch with `date -u -j -f "%Y-%m-%dT%H:%M:%S" "2026-02-16T12:16:56" +%s` and fix the test constant, not the parser, if they disagree by exactly the local timezone offset.

- [ ] **Step 5: Report the changed files. Do not run git.**

### Task 10: File ordering by first key

**Files:**
- Create: `Sources/InventoryImport/FileOrdering.swift`
- Test: `Tests/InventoryImportTests/FileOrderingTests.swift`

**Interfaces:**
- Produces: `enum FileOrdering` — `static func firstKey(of url: URL, schema: InventorySchema) throws -> [UInt8]?` (nil for a file without rows), `static func sortedByFirstKey(_ files: [InventoryDataFile], schema: InventorySchema) throws -> [InventoryDataFile]` (files without rows are dropped).

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import TestSupport
@testable import InventoryImport

final class FileOrderingTests: XCTestCase {
    func testFilesAreSortedByTheirFirstEncodedKey() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ordering-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let rows = ["zeta/1", "alpha/1", "mid dle/1", "alpha/2", "zeta/2", "mid dle/2"].map { FixtureRow(key: $0, size: 1) }
        try FixtureInventory.write(rows: rows, to: folder, fileCount: 3, shuffleManifest: true)
        let source = try InventorySource.load(folder: folder)
        let sorted = try FileOrdering.sortedByFirstKey(source.dataFiles, schema: source.schema)
        let firstKeys = try sorted.map { try FileOrdering.firstKey(of: $0.url, schema: source.schema).map { String(decoding: $0, as: UTF8.self) } }
        XCTAssertEqual(firstKeys, ["alpha/1", "mid%20dle/1", "zeta/1"])
    }

    func testEmptyFileHasNoFirstKey() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("empty-\(UUID().uuidString).csv.gz")
        let writer = try GzipDeflateWriter(url: url)
        try writer.finish()
        XCTAssertNil(try FileOrdering.firstKey(of: url, schema: .standard))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter FileOrderingTests 2>&1 | tail -5`
Expected: compile errors.

- [ ] **Step 3: Write `FileOrdering.swift`**

```swift
import Foundation

public enum FileOrdering {
    public static func firstKey(of url: URL, schema: InventorySchema) throws -> [UInt8]? {
        let stream = try GzipInflateStream(url: url, bufferSize: 64 * 1024)
        var collected: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while collected.count < InventoryRowParser.maximumRowLength {
            let produced = try buffer.withUnsafeMutableBufferPointer { try stream.read(into: $0) }
            if produced == 0 { break }
            collected.append(contentsOf: buffer[0..<produced])
            if collected.contains(UInt8(ascii: "\n")) { break }
        }
        guard !collected.isEmpty else { return nil }
        let rowEnd = collected.firstIndex(of: UInt8(ascii: "\n")) ?? collected.count
        var row = Array(collected[0..<rowEnd])
        if row.last == UInt8(ascii: "\r") { row.removeLast() }
        return InventoryRowParser.extractField(row: row, column: schema.keyColumn)
    }

    public static func sortedByFirstKey(_ files: [InventoryDataFile], schema: InventorySchema) throws -> [InventoryDataFile] {
        var keyed: [(key: [UInt8], file: InventoryDataFile)] = []
        for file in files {
            if let key = try firstKey(of: file.url, schema: schema) { keyed.append((key, file)) }
        }
        keyed.sort { $0.key.lexicographicallyPrecedes($1.key) }
        return keyed.map { $0.file }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter FileOrderingTests 2>&1 | tail -5`
Expected: 2 tests pass.

- [ ] **Step 5: Report the changed files. Do not run git.**

### Task 11: Tree builder — the single-threaded consumer

**Files:**
- Create: `Sources/InventoryImport/TreeBuilder.swift`
- Modify: `Tests/TestSupport/FixtureInventory.swift` (add `ReferenceTree`, `makeChunks`, `indexMismatches`)
- Test: `Tests/InventoryImportTests/TreeBuilderTests.swift`

**Interfaces:**
- Consumes: `IndexWriter`, `NameBlockCodec`, `ExtensionDictionary`, `RowChunk`.
- Produces:
  - `protocol RawNameBlockConsumer: AnyObject { func consume(rawBlock: [UInt8], nameCount: Int) throws; func finish() throws }`
  - `final class SynchronousNameBlockWriter: RawNameBlockConsumer` — `init(blocks: ColumnWriter<NameBlockEntry>, data: ColumnWriter<UInt8>)`.
  - `struct TreeBuilderSummary` — `directoryCount: Int`, `fileCount: UInt64`, `totalBytes: UInt64`, `rootExtensionBytes: [UInt16: UInt64]`, `extensionNames: [String]`, `skippedNonCurrent`, `skippedDeleteMarkers`, `parseErrors`.
  - `final class TreeBuilder` — `init(writer: IndexWriter, inventoryTimestamp: UInt32, nameBlockConsumer: RawNameBlockConsumer, fileNames: [String])`, `func consume(_ chunk: RowChunk) throws`, `func finish() throws -> TreeBuilderSummary`.
  - TestSupport: `ReferenceTree.build(rows:inventoryTimestamp:)`, `FixtureInventory.makeChunks(rows:rowsPerChunk:)`, `indexMismatches(reader:reference:) -> [String]`.

- [ ] **Step 1: Add the brute-force reference to `FixtureInventory.swift`**

```swift
import InventoryIndex

public final class ReferenceDirectory {
    public let name: String
    public let path: String
    public let identifier: UInt32
    public let parent: UInt32
    public let depth: Int
    public var children: [ReferenceDirectory] = []          // key order of first appearance
    public var ownFiles: [ReferenceFile] = []
    public var fileStart: UInt64
    init(name: String, path: String, identifier: UInt32, parent: UInt32, depth: Int, fileStart: UInt64) {
        self.name = name; self.path = path; self.identifier = identifier; self.parent = parent; self.depth = depth; self.fileStart = fileStart
    }
    public var subtreeDirectoryCount: Int { children.reduce(0) { $0 + 1 + $1.subtreeDirectoryCount } }
    public var subtreeFileCount: UInt64 { UInt64(ownFiles.count) + children.reduce(0) { $0 + $1.subtreeFileCount } }
    public var ownBytes: UInt64 { ownFiles.reduce(0) { $0 + $1.size } }
    public var subtreeBytes: UInt64 { ownBytes + children.reduce(0) { $0 + $1.subtreeBytes } }
    public var bytesByStorageClass: [UInt64] {
        var result = [UInt64](repeating: 0, count: 8)
        for file in ownFiles { result[Int(file.storageClass)] += file.size }
        for child in children { for slot in 0..<8 { result[slot] += child.bytesByStorageClass[slot] } }
        return result
    }
    public func ageWeightedBytes(inventoryTimestamp: UInt32) -> UInt64 {
        var total: UInt64 = 0
        for file in ownFiles {
            let ageDays: UInt64 = (file.lastModified == 0 || file.lastModified >= inventoryTimestamp) ? 0 : UInt64(inventoryTimestamp - file.lastModified) / 86_400
            total += file.size * ageDays
        }
        return total + children.reduce(0) { $0 + $1.ageWeightedBytes(inventoryTimestamp: inventoryTimestamp) }
    }
    public var extensionBytes: [UInt16: UInt64] {
        var result: [UInt16: UInt64] = [:]
        for file in ownFiles { result[file.extensionIdentifier, default: 0] += file.size }
        for child in children { for (key, value) in child.extensionBytes { result[key, default: 0] += value } }
        return result
    }
    public var dominantExtension: UInt16 {
        extensionBytes.max { left, right in left.value != right.value ? left.value < right.value : left.key > right.key }?.key ?? 0
    }
    public var childrenBySize: [UInt32] {
        children.sorted { $0.subtreeBytes != $1.subtreeBytes ? $0.subtreeBytes > $1.subtreeBytes : $0.identifier < $1.identifier }.map { $0.identifier }
    }
}

public struct ReferenceFile: Equatable {
    public var key: String
    public var name: String
    public var size: UInt64
    public var lastModified: UInt32
    public var storageClass: UInt8
    public var extensionIdentifier: UInt16
}

public struct ReferenceTree {
    public let root: ReferenceDirectory
    public let directoriesInPreOrder: [ReferenceDirectory]
    public let filesInKeyOrder: [ReferenceFile]
    public let extensionNames: [String]
    public let skippedNonCurrent: Int
    public let skippedDeleteMarkers: Int

    public static func build(rows: [FixtureRow], inventoryTimestamp: UInt32) -> ReferenceTree {
        let kept = FixtureInventory.sortedForInventory(rows.filter { $0.isLatest && !$0.isDeleteMarker })
        let extensions = ExtensionDictionary()
        let root = ReferenceDirectory(name: "", path: "", identifier: 0, parent: IndexFormat.noParent, depth: 0, fileStart: 0)
        var directories = [root]
        var files: [ReferenceFile] = []
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for row in kept {
            let segments = row.key.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            let name = segments.last!
            var current = root
            for segment in segments.dropLast() {
                if let existing = current.children.first(where: { $0.name == segment }) {
                    current = existing
                } else {
                    let path = current.path.isEmpty && current === root ? segment : current.path + "/" + segment
                    let created = ReferenceDirectory(name: segment, path: path, identifier: UInt32(directories.count), parent: current.identifier, depth: current.depth + 1, fileStart: UInt64(files.count))
                    directories.append(created)
                    current.children.append(created)
                    current = created
                }
            }
            let lastModified = UInt32(clamping: Int64(formatter.date(from: row.lastModified)?.timeIntervalSince1970 ?? 0))
            let extensionIdentifier = Array(name.utf8).withUnsafeBufferPointer { extensions.identifier(forBasename: $0) }
            let file = ReferenceFile(key: row.key, name: name, size: row.size, lastModified: lastModified, storageClass: StorageClass.identifier(forInventoryName: row.storageClass), extensionIdentifier: extensionIdentifier)
            current.ownFiles.append(file)
            files.append(file)
        }
        return ReferenceTree(root: root, directoriesInPreOrder: directories, filesInKeyOrder: files, extensionNames: extensions.names,
                             skippedNonCurrent: rows.filter { !$0.isLatest }.count, skippedDeleteMarkers: rows.filter { $0.isLatest && $0.isDeleteMarker }.count)
    }
}

extension FixtureInventory {
    /// Builds chunks the way the parser would: raw encoded keys, skipped rows counted, sorted by encoded key.
    public static func makeChunks(rows: [FixtureRow], rowsPerChunk: Int = 1000, fileIndex: Int = 0) -> [RowChunk] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var chunks: [RowChunk] = []
        var chunk = RowChunk(fileIndex: fileIndex, chunkIndex: 0, capacity: rowsPerChunk)
        for row in sortedForInventory(rows) {
            if !row.isLatest { chunk.skippedNonCurrent += 1; continue }
            if row.isDeleteMarker { chunk.skippedDeleteMarkers += 1; continue }
            let lastModified = UInt32(clamping: Int64(formatter.date(from: row.lastModified)?.timeIntervalSince1970 ?? 0))
            Array(encodeKey(row.key).utf8).withUnsafeBufferPointer {
                chunk.appendRow(key: $0, size: row.size, lastModified: lastModified, storageClass: StorageClass.identifier(forInventoryName: row.storageClass))
            }
            if chunk.count == rowsPerChunk { chunks.append(chunk); chunk = RowChunk(fileIndex: fileIndex, chunkIndex: chunks.count, capacity: rowsPerChunk) }
        }
        chunks.append(chunk)
        return chunks
    }
}

/// Compares every directory and file of an index against the reference. Returns human-readable mismatches (empty = equal).
public func indexMismatches(reader: IndexReader, reference: ReferenceTree, inventoryTimestamp: UInt32) -> [String] {
    var problems: [String] = []
    func check<T: Equatable>(_ label: String, _ actual: T, _ expected: T) { if actual != expected { problems.append("\(label): actual \(actual) expected \(expected)") } }
    let tree = reader.directories
    check("directoryCount", tree.count, reference.directoriesInPreOrder.count)
    for expected in reference.directoriesInPreOrder where Int(expected.identifier) < tree.count {
        let id = expected.identifier
        let label = "directory \(id) '\(expected.path)'"
        check("\(label) name", tree.name(id), expected.name)
        check("\(label) path", tree.path(id), expected.path)
        check("\(label) parent", tree.parent(id), expected.parent)
        check("\(label) depth", Int(tree.depth(id)), expected.depth)
        check("\(label) childCount", Int(tree.childCount(id)), expected.children.count)
        check("\(label) subtreeDirectoryCount", Int(tree.subtreeDirectoryCount(id)), expected.subtreeDirectoryCount)
        check("\(label) fileStart", tree.fileStart(id), expected.fileStart)
        check("\(label) subtreeFileCount", tree.subtreeFileCount(id), expected.subtreeFileCount)
        check("\(label) subtreeBytes", tree.subtreeBytes(id), expected.subtreeBytes)
        check("\(label) ownFileCount", Int(tree.ownFileCount(id)), expected.ownFiles.count)
        check("\(label) ownBytes", tree.ownBytes(id), expected.ownBytes)
        check("\(label) bytesByStorageClass", tree.bytesByStorageClass(id), expected.bytesByStorageClass)
        check("\(label) ageWeightedBytes", tree.ageWeightedBytes(id), expected.ageWeightedBytes(inventoryTimestamp: inventoryTimestamp))
        check("\(label) dominantExtension", tree.dominantExtension(id), expected.dominantExtension)
        check("\(label) childrenInKeyOrder", tree.childrenInKeyOrder(id), expected.children.map { $0.identifier })
        check("\(label) childrenBySize", tree.childrenBySize(id), expected.childrenBySize)
        let ownFileIndices = tree.ownFileRanges(id).flatMap { Array($0) }
        check("\(label) ownFiles", ownFileIndices.map { reader.names.nameString(ofFile: $0) }, expected.ownFiles.map { $0.name })
    }
    check("fileCount", reader.fileCount, reference.filesInKeyOrder.count)
    for (index, expected) in reference.filesInKeyOrder.enumerated() where index < reader.fileCount {
        let label = "file \(index) '\(expected.key)'"
        check("\(label) key", reader.key(ofFile: UInt64(index)), expected.key)
        check("\(label) size", reader.fileSize[index], expected.size)
        check("\(label) lastModified", reader.fileLastModified[index], expected.lastModified)
        check("\(label) storageClass", reader.fileStorageClass[index], expected.storageClass)
        check("\(label) extension", reader.manifest.extensionNames[Int(reader.fileExtension[index])], reference.extensionNames[Int(expected.extensionIdentifier)])
    }
    return problems
}
```

- [ ] **Step 2: Write the failing tests**

```swift
import XCTest
import TestSupport
import InventoryIndex
@testable import InventoryImport

final class TreeBuilderTests: XCTestCase {
    private var folder: URL!
    private let inventoryTimestamp: UInt32 = 1_767_225_600

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("builder-\(UUID().uuidString)")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    static let awkwardRows: [FixtureRow] = [
        FixtureRow(key: "a/b/c.txt", size: 10, lastModified: "2025-06-01T00:00:00.000Z", storageClass: "STANDARD"),
        FixtureRow(key: "a/b/c/x", size: 20, lastModified: "2024-06-01T00:00:00.000Z", storageClass: "STANDARD_IA"),
        FixtureRow(key: "a/b/d", size: 30, storageClass: "DEEP_ARCHIVE"),
        FixtureRow(key: "dir one/f%.jpg", size: 40, storageClass: "GLACIER_IR"),
        FixtureRow(key: "folder/", size: 0, storageClass: "STANDARD"),
        FixtureRow(key: "a//b", size: 5, storageClass: "REDUCED_REDUNDANCY"),
        FixtureRow(key: "deep/1/2/3/4/5/6/7/8/leaf.MP4", size: 6_000_000_000, lastModified: "2020-01-01T00:00:00.000Z", storageClass: "STANDARD_IA"),
        FixtureRow(key: "root-file.png", size: 7, storageClass: "STANDARD"),
        FixtureRow(key: String(repeating: "k", count: 1000) + "/n.jpg", size: 8, storageClass: "STANDARD"),
        FixtureRow(key: "zero.bin", size: 0, storageClass: "STANDARD"),
        FixtureRow(key: "old.jpg", size: 99, storageClass: "STANDARD", isLatest: false),
        FixtureRow(key: "gone.jpg", size: 0, storageClass: "", isLatest: true, isDeleteMarker: true),
        FixtureRow(key: "photos/2026/a.jpg", size: 100, storageClass: "STANDARD"),
        FixtureRow(key: "photos/2026/b.JPG", size: 200, storageClass: "STANDARD"),
        FixtureRow(key: "photos/2026/c.mp4", size: 250, storageClass: "STANDARD_IA"),
    ]

    private func build(rows: [FixtureRow], rowsPerChunk: Int = 4) throws -> (IndexReader, TreeBuilderSummary) {
        let writer = try IndexWriter(folder: folder, directoryCapacity: 1000)
        let sink = SynchronousNameBlockWriter(blocks: writer.fileNameBlocks, data: writer.fileNameData)
        let builder = TreeBuilder(writer: writer, inventoryTimestamp: inventoryTimestamp, nameBlockConsumer: sink, fileNames: ["fixture.csv.gz"])
        for chunk in FixtureInventory.makeChunks(rows: rows, rowsPerChunk: rowsPerChunk) { try builder.consume(chunk) }
        let summary = try builder.finish()
        try IndexPostProcessing.writeChildrenBySize(folder: folder)
        var manifest = IndexManifest.empty(sourceBucket: "fixture", inventoryTimestamp: inventoryTimestamp)
        manifest.counts.directoryCount = summary.directoryCount
        manifest.counts.fileCount = summary.fileCount
        manifest.extensionNames = summary.extensionNames
        try manifest.save(to: folder)
        return (try IndexReader(folder: folder), summary)
    }

    func testAwkwardRowsMatchReference() throws {
        let (reader, summary) = try build(rows: TreeBuilderTests.awkwardRows)
        let reference = ReferenceTree.build(rows: TreeBuilderTests.awkwardRows, inventoryTimestamp: inventoryTimestamp)
        XCTAssertEqual(indexMismatches(reader: reader, reference: reference, inventoryTimestamp: inventoryTimestamp), [])
        XCTAssertEqual(summary.skippedNonCurrent, 1)
        XCTAssertEqual(summary.skippedDeleteMarkers, 1)
        XCTAssertEqual(summary.fileCount, 13)
        XCTAssertEqual(reader.key(ofFile: UInt64(reference.filesInKeyOrder.firstIndex { $0.key == "dir one/f%.jpg" }!)), "dir one/f%.jpg")
        XCTAssertEqual(reader.directories.lookup(path: "deep/1/2/3/4/5/6/7/8").map { reader.directories.depth($0) }, 9)
        XCTAssertEqual(reader.directories.lookup(path: "a/").map { reader.directories.name($0) }, "")   // the empty segment of "a//b"
    }

    func testManyFilesCrossNameBlockBoundary() throws {
        var rows: [FixtureRow] = []
        for index in 0..<(IndexFormat.namesPerBlock * 2 + 17) {
            rows.append(FixtureRow(key: "bulk/\(index % 7)/item-\(String(format: "%06d", index)).dat", size: UInt64(index)))
        }
        let (reader, _) = try build(rows: rows, rowsPerChunk: 1000)
        let reference = ReferenceTree.build(rows: rows, inventoryTimestamp: inventoryTimestamp)
        XCTAssertEqual(indexMismatches(reader: reader, reference: reference, inventoryTimestamp: inventoryTimestamp), [])
        XCTAssertEqual(reader.names.blockCount, 3)
    }

    func testUnsortedInputAborts() throws {
        let writer = try IndexWriter(folder: folder, directoryCapacity: 100)
        let sink = SynchronousNameBlockWriter(blocks: writer.fileNameBlocks, data: writer.fileNameData)
        let builder = TreeBuilder(writer: writer, inventoryTimestamp: inventoryTimestamp, nameBlockConsumer: sink, fileNames: ["one.csv.gz"])
        var chunk = RowChunk(fileIndex: 0, chunkIndex: 0, capacity: 2)
        Array("b/1".utf8).withUnsafeBufferPointer { chunk.appendRow(key: $0, size: 1, lastModified: 0, storageClass: 0) }
        Array("a/1".utf8).withUnsafeBufferPointer { chunk.appendRow(key: $0, size: 1, lastModified: 0, storageClass: 0) }
        XCTAssertThrowsError(try builder.consume(chunk)) { error in
            guard case ImportError.notKeySorted(let file, let previous, let key) = error else { return XCTFail("wrong error \(error)") }
            XCTAssertEqual(file, "one.csv.gz"); XCTAssertEqual(previous, "b/1"); XCTAssertEqual(key, "a/1")
        }
    }

    func testReenteredDirectoryAborts() throws {
        // "a/x", "a-b/y", "a/z" is NOT sorted ("a/" < "a-" because '/' 0x2F > '-' 0x2D is false... '-' 0x2D < '/' 0x2F, so "a-b/y" < "a/x").
        // Use raw keys that pass the byte check yet re-enter a closed directory: impossible with a correct byte comparison,
        // so the test feeds two chunks where the second chunk restarts the previous-key check by simulating a new builder state.
        let writer = try IndexWriter(folder: folder, directoryCapacity: 100)
        let sink = SynchronousNameBlockWriter(blocks: writer.fileNameBlocks, data: writer.fileNameData)
        let builder = TreeBuilder(writer: writer, inventoryTimestamp: inventoryTimestamp, nameBlockConsumer: sink, fileNames: ["one.csv.gz"])
        var chunk = RowChunk(fileIndex: 0, chunkIndex: 0, capacity: 3)
        for key in ["a/x", "a/y", "a/z"] { Array(key.utf8).withUnsafeBufferPointer { chunk.appendRow(key: $0, size: 1, lastModified: 0, storageClass: 0) } }
        try builder.consume(chunk)
        builder.resetOrderingCheckForTesting()
        var second = RowChunk(fileIndex: 0, chunkIndex: 1, capacity: 2)
        for key in ["b/1", "a/w"] { Array(key.utf8).withUnsafeBufferPointer { second.appendRow(key: $0, size: 1, lastModified: 0, storageClass: 0) } }
        builder.resetOrderingCheckForTesting()
        XCTAssertThrowsError(try builder.consume(second)) { error in
            if case ImportError.notKeySorted = error { return }
            if case ImportError.directoryReentered = error { return }
            XCTFail("wrong error \(error)")
        }
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --filter TreeBuilderTests 2>&1 | tail -5`
Expected: compile errors.

- [ ] **Step 4: Write `TreeBuilder.swift`**

```swift
import Foundation
import InventoryIndex

public protocol RawNameBlockConsumer: AnyObject {
    func consume(rawBlock: [UInt8], nameCount: Int) throws
    func finish() throws
}

public final class SynchronousNameBlockWriter: RawNameBlockConsumer {
    private let blocks: ColumnWriter<NameBlockEntry>
    private let data: ColumnWriter<UInt8>
    public init(blocks: ColumnWriter<NameBlockEntry>, data: ColumnWriter<UInt8>) { self.blocks = blocks; self.data = data }
    public func consume(rawBlock: [UInt8], nameCount: Int) throws {
        let compressed = NameBlockCodec.encode(raw: rawBlock)
        blocks.append(NameBlockEntry(offset: UInt64(data.count), compressedLength: UInt32(compressed.count), rawLength: UInt32(rawBlock.count)))
        compressed.withUnsafeBytes { data.appendBytes($0) }
    }
    public func finish() throws {}
}

public struct TreeBuilderSummary {
    public var directoryCount: Int
    public var fileCount: UInt64
    public var totalBytes: UInt64
    public var rootExtensionBytes: [UInt16: UInt64]
    public var extensionNames: [String]
    public var skippedNonCurrent: Int
    public var skippedDeleteMarkers: Int
    public var parseErrors: Int
}

public final class TreeBuilder {
    private struct OpenDirectory {
        var identifier: UInt32
        var parentIdentifier: UInt32
        var depth: UInt8
        var nameOffset: UInt64
        var name: [UInt8]
        var childCount: UInt32 = 0
        var subtreeDirectoryCount: UInt32 = 0
        var fileStart: UInt64
        var subtreeFileCount: UInt64 = 0
        var subtreeBytes: UInt64 = 0
        var ownFileCount: UInt32 = 0
        var ownBytes: UInt64 = 0
        var bytesByStorageClass = [UInt64](repeating: 0, count: IndexFormat.storageClassSlots)
        var ageWeightedBytes: UInt64 = 0
        var extensionBytes: [UInt16: UInt64] = [:]
        var lastClosedChildName: [UInt8]? = nil
    }

    private let writer: IndexWriter
    private let inventoryTimestamp: UInt32
    private let nameBlockConsumer: RawNameBlockConsumer
    private let fileNames: [String]
    private let extensions = ExtensionDictionary()
    private var stack: [OpenDirectory] = []
    private var nextDirectoryIdentifier: UInt32 = 1
    private var nextFileIndex: UInt64 = 0
    private var currentDirectoryPath: [UInt8] = []
    private let previousKeyBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: InventoryRowParser.maximumRowLength)
    private var previousKeyLength = -1
    private let decodedKeyBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: InventoryRowParser.maximumRowLength)
    private var rawNameBlock: [UInt8] = []
    private var namesInBlock = 0
    private var rootExtensionBytes: [UInt16: UInt64] = [:]
    private var skippedNonCurrent = 0, skippedDeleteMarkers = 0, parseErrors = 0
    private var finished = false

    public init(writer: IndexWriter, inventoryTimestamp: UInt32, nameBlockConsumer: RawNameBlockConsumer, fileNames: [String]) {
        self.writer = writer
        self.inventoryTimestamp = inventoryTimestamp
        self.nameBlockConsumer = nameBlockConsumer
        self.fileNames = fileNames
        stack = [OpenDirectory(identifier: IndexFormat.rootDirectory, parentIdentifier: IndexFormat.noParent, depth: 0, nameOffset: 0, name: [], fileStart: 0)]
        rawNameBlock.reserveCapacity(IndexFormat.namesPerBlock * 80)
    }

    deinit { previousKeyBuffer.deallocate(); decodedKeyBuffer.deallocate() }

    /// Test hook: forget the previous key so a later chunk can exercise the directory re-entry check.
    public func resetOrderingCheckForTesting() { previousKeyLength = -1 }

    public func consume(_ chunk: RowChunk) throws {
        skippedNonCurrent += chunk.skippedNonCurrent
        skippedDeleteMarkers += chunk.skippedDeleteMarkers
        parseErrors += chunk.parseErrors
        let fileName = chunk.fileIndex < fileNames.count ? fileNames[chunk.fileIndex] : "file \(chunk.fileIndex)"
        for row in 0..<chunk.count {
            try chunk.withKey(row) { rawKey in
                if previousKeyLength >= 0 {
                    let commonLength = min(previousKeyLength, rawKey.count)
                    let comparison = memcmp(previousKeyBuffer, rawKey.baseAddress!, commonLength)
                    let isGreater = comparison < 0 || (comparison == 0 && rawKey.count > previousKeyLength)
                    guard isGreater else {
                        let previous = String(decoding: UnsafeBufferPointer(start: previousKeyBuffer, count: previousKeyLength), as: UTF8.self)
                        throw ImportError.notKeySorted(file: fileName, previousKey: previous, key: String(decoding: rawKey, as: UTF8.self))
                    }
                }
                previousKeyBuffer.update(from: rawKey.baseAddress!, count: rawKey.count)
                previousKeyLength = rawKey.count
                if chunk.needsDecoding[row] {
                    let decodedLength = TreeBuilder.decodePercentEncoding(rawKey, into: decodedKeyBuffer)
                    try addFile(key: UnsafeBufferPointer(start: decodedKeyBuffer, count: decodedLength), size: chunk.sizes[row],
                                lastModified: chunk.lastModified[row], storageClass: chunk.storageClass[row])
                } else {
                    try addFile(key: rawKey, size: chunk.sizes[row], lastModified: chunk.lastModified[row], storageClass: chunk.storageClass[row])
                }
            }
        }
    }

    /// `%XX` → byte; '+' stays '+'; a malformed escape is copied literally. Returns the decoded length.
    static func decodePercentEncoding(_ source: UnsafeBufferPointer<UInt8>, into destination: UnsafeMutablePointer<UInt8>) -> Int {
        func hexValue(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: return byte - 48
            case 65...70: return byte - 55
            case 97...102: return byte - 87
            default: return nil
            }
        }
        var read = 0, written = 0
        while read < source.count {
            if source[read] == UInt8(ascii: "%"), read + 2 < source.count + 0, read + 2 <= source.count - 1,
               let high = hexValue(source[read + 1]), let low = hexValue(source[read + 2]) {
                destination[written] = high << 4 | low
                read += 3
            } else {
                destination[written] = source[read]
                read += 1
            }
            written += 1
        }
        return written
    }

    private func addFile(key: UnsafeBufferPointer<UInt8>, size: UInt64, lastModified: UInt32, storageClass: UInt8) throws {
        var slashIndex = key.count - 1
        while slashIndex >= 0 && key[slashIndex] != UInt8(ascii: "/") { slashIndex -= 1 }
        let directoryPart = UnsafeBufferPointer(rebasing: key[0..<max(slashIndex, 0)])
        let basename = UnsafeBufferPointer(rebasing: key[(slashIndex + 1)..<key.count])
        let sameDirectory = directoryPart.count == currentDirectoryPath.count
            && (directoryPart.isEmpty || currentDirectoryPath.withUnsafeBufferPointer { memcmp($0.baseAddress!, directoryPart.baseAddress!, directoryPart.count) == 0 })
        if !sameDirectory {
            try moveToDirectory(directoryPart, hasDirectoryPart: slashIndex >= 0)
        }
        try appendFile(basename: basename, size: size, lastModified: lastModified, storageClass: storageClass)
    }

    private func moveToDirectory(_ directoryPart: UnsafeBufferPointer<UInt8>, hasDirectoryPart: Bool) throws {
        var segments: [Range<Int>] = []
        if hasDirectoryPart {
            var start = 0
            for index in 0...directoryPart.count {
                if index == directoryPart.count || directoryPart[index] == UInt8(ascii: "/") {
                    segments.append(start..<index)
                    start = index + 1
                }
            }
        }
        var matchedLevels = 0
        while matchedLevels < segments.count && matchedLevels + 1 < stack.count {
            let segment = segments[matchedLevels]
            let name = stack[matchedLevels + 1].name
            let equal = name.count == segment.count && (segment.isEmpty || name.withUnsafeBufferPointer { memcmp($0.baseAddress!, directoryPart.baseAddress! + segment.lowerBound, segment.count) == 0 })
            if !equal { break }
            matchedLevels += 1
        }
        while stack.count > matchedLevels + 1 { try closeTopDirectory() }
        for segment in segments[matchedLevels...] {
            try pushDirectory(UnsafeBufferPointer(rebasing: directoryPart[segment]))
        }
        currentDirectoryPath = Array(directoryPart)
    }

    private func pushDirectory(_ segment: UnsafeBufferPointer<UInt8>) throws {
        let parentIndex = stack.count - 1
        if let lastClosed = stack[parentIndex].lastClosedChildName, lastClosed.elementsEqual(segment) {
            throw ImportError.directoryReentered(path: String(decoding: currentDirectoryPath, as: UTF8.self) + "/" + String(decoding: segment, as: UTF8.self))
        }
        guard nextDirectoryIdentifier < UInt32.max else { throw ImportError.tooManyFiles }
        let identifier = nextDirectoryIdentifier
        nextDirectoryIdentifier += 1
        let nameOffset = UInt64(writer.directoryNames.count)
        writer.directoryNames.appendBytes(UnsafeRawBufferPointer(segment))
        let parent = stack[parentIndex]
        stack.append(OpenDirectory(identifier: identifier, parentIdentifier: parent.identifier, depth: parent.depth == 255 ? 255 : parent.depth + 1,
                                   nameOffset: nameOffset, name: Array(segment), fileStart: nextFileIndex))
    }

    private func closeTopDirectory() throws {
        let directory = stack.removeLast()
        let id = Int(directory.identifier)
        writer.directoryParent[id] = directory.parentIdentifier
        writer.directoryDepth[id] = directory.depth
        writer.directorySubtreeDirectoryCount[id] = directory.subtreeDirectoryCount
        writer.directoryChildCount[id] = directory.childCount
        writer.directoryFileStart[id] = directory.fileStart
        writer.directorySubtreeFileCount[id] = directory.subtreeFileCount
        writer.directorySubtreeBytes[id] = directory.subtreeBytes
        writer.directoryOwnFileCount[id] = directory.ownFileCount
        writer.directoryOwnBytes[id] = directory.ownBytes
        writer.directoryNameOffset[id] = directory.nameOffset
        writer.directoryNameLength[id] = UInt16(directory.name.count)
        for slot in 0..<IndexFormat.storageClassSlots { writer.directoryBytesByStorageClass[id * IndexFormat.storageClassSlots + slot] = directory.bytesByStorageClass[slot] }
        writer.directoryDominantExtension[id] = directory.extensionBytes.max { left, right in left.value != right.value ? left.value < right.value : left.key > right.key }?.key ?? 0
        writer.directoryAgeWeightedBytes[id] = directory.ageWeightedBytes
        guard !stack.isEmpty else { rootExtensionBytes = directory.extensionBytes; return }
        let parentIndex = stack.count - 1
        stack[parentIndex].childCount += 1
        stack[parentIndex].subtreeDirectoryCount += directory.subtreeDirectoryCount + 1
        stack[parentIndex].subtreeFileCount += directory.subtreeFileCount
        stack[parentIndex].subtreeBytes += directory.subtreeBytes
        for slot in 0..<IndexFormat.storageClassSlots { stack[parentIndex].bytesByStorageClass[slot] += directory.bytesByStorageClass[slot] }
        stack[parentIndex].ageWeightedBytes += directory.ageWeightedBytes
        if stack[parentIndex].extensionBytes.count < directory.extensionBytes.count {
            var merged = directory.extensionBytes
            for (key, value) in stack[parentIndex].extensionBytes { merged[key, default: 0] += value }
            stack[parentIndex].extensionBytes = merged
        } else {
            for (key, value) in directory.extensionBytes { stack[parentIndex].extensionBytes[key, default: 0] += value }
        }
        stack[parentIndex].lastClosedChildName = directory.name
    }

    private func appendFile(basename: UnsafeBufferPointer<UInt8>, size: UInt64, lastModified: UInt32, storageClass: UInt8) throws {
        guard nextFileIndex < UInt64(UInt32.max) else { throw ImportError.tooManyFiles }
        let extensionIdentifier = extensions.identifier(forBasename: basename)
        writer.fileSize.append(size)
        writer.fileLastModified.append(lastModified)
        writer.fileStorageClass.append(storageClass)
        writer.fileExtension.append(extensionIdentifier)
        NameBlockCodec.appendName(basename, to: &rawNameBlock)
        namesInBlock += 1
        if namesInBlock == IndexFormat.namesPerBlock { try flushNameBlock() }
        let ageDays: UInt64 = (lastModified == 0 || lastModified >= inventoryTimestamp) ? 0 : UInt64(inventoryTimestamp - lastModified) / 86_400
        let top = stack.count - 1
        stack[top].ownFileCount += 1
        stack[top].ownBytes += size
        stack[top].subtreeFileCount += 1
        stack[top].subtreeBytes += size
        stack[top].bytesByStorageClass[Int(storageClass & 7)] += size
        stack[top].ageWeightedBytes += size * ageDays
        stack[top].extensionBytes[extensionIdentifier, default: 0] += size
        nextFileIndex += 1
    }

    private func flushNameBlock() throws {
        let block = rawNameBlock
        rawNameBlock = []
        rawNameBlock.reserveCapacity(IndexFormat.namesPerBlock * 80)
        let count = namesInBlock
        namesInBlock = 0
        try nameBlockConsumer.consume(rawBlock: block, nameCount: count)
    }

    public func finish() throws -> TreeBuilderSummary {
        precondition(!finished, "finish called twice")
        finished = true
        while !stack.isEmpty { try closeTopDirectory() }
        if namesInBlock > 0 { try flushNameBlock() }
        try nameBlockConsumer.finish()
        let directoryCount = Int(nextDirectoryIdentifier)
        try writer.finish(directoryCount: directoryCount)
        let totalBytes = rootExtensionBytes.values.reduce(0, +)
        return TreeBuilderSummary(directoryCount: directoryCount, fileCount: nextFileIndex, totalBytes: totalBytes, rootExtensionBytes: rootExtensionBytes,
                                  extensionNames: extensions.names, skippedNonCurrent: skippedNonCurrent, skippedDeleteMarkers: skippedDeleteMarkers, parseErrors: parseErrors)
    }
}
```

Note on `decodePercentEncoding`: the condition must be simply `read + 2 < source.count` (both hex digits exist). Write it that way; the redundant clauses above are a reminder to check the bound once.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter TreeBuilderTests 2>&1 | tail -8`
Expected: 4 tests pass. If `testAwkwardRowsMatchReference` prints mismatches, read them: they name the directory or file and the field. Fix the builder, not the reference, unless the reference's rule is wrong against the spec.

- [ ] **Step 6: Report the changed files. Do not run git.**

### Task 12: Ordered chunk queue, parallel name-block sink, import pipeline

**Files:**
- Create: `Sources/InventoryImport/OrderedChunkQueue.swift`, `Sources/InventoryImport/NameBlockSink.swift`, `Sources/InventoryImport/ImportPipeline.swift`
- Test: `Tests/InventoryImportTests/OrderedChunkQueueTests.swift`, `Tests/InventoryImportTests/ImportPipelineTests.swift`

**Interfaces:**
- Produces:
  - `final class OrderedChunkQueue` — `init(fileCount: Int, maximumRowsInFlight: Int)`, `func enqueue(_: RowChunk) throws`, `func markFileComplete(_ fileIndex: Int)`, `func dequeueNext() throws -> RowChunk?` (nil when every file is complete and drained), `func cancel()`, `var completedFilesDelivered: Int`.
  - `final class NameBlockSink: RawNameBlockConsumer` — `init(blocks: ColumnWriter<NameBlockEntry>, data: ColumnWriter<UInt8>, workerCount: Int = 4, maximumInFlight: Int = 16)`.
  - `struct ImportProgress` — `enum Phase { case orderingFiles, importing, postProcessing, finished }`, `phase`, `filesCompleted`, `fileCount`, `rowsConsumed: UInt64`, `compressedBytesRead: Int64`, `totalCompressedBytes: Int64`, `elapsedSeconds: Double`, `estimatedRemainingSeconds: Double?`.
  - `struct ImportOptions` — `threadCount` (default `ProcessInfo.processInfo.activeProcessorCount`), `allowMissingDataFiles = false`, `overwriteExistingIndex = false`, `maximumRowsInFlight = 4_000_000`, `rowsPerChunk = 262_144`, `directoryCapacity = IndexFormat.directoryCapacity`, `nameBlockWorkerCount = 4`, `progressInterval = 0.25`.
  - `final class ImportPipeline` — `init(source: InventorySource, outputFolder: URL, options: ImportOptions = ImportOptions(), progress: @escaping (ImportProgress) -> Void)`, `func run() throws -> IndexManifest` (blocking), `func cancel()`.

- [ ] **Step 1: Write the failing tests**

`OrderedChunkQueueTests.swift`:
```swift
import XCTest
@testable import InventoryImport

final class OrderedChunkQueueTests: XCTestCase {
    private func chunk(_ file: Int, _ index: Int, rows: Int) -> RowChunk {
        var chunk = RowChunk(fileIndex: file, chunkIndex: index, capacity: rows)
        for row in 0..<rows { Array("f\(file)/c\(index)/r\(row)".utf8).withUnsafeBufferPointer { chunk.appendRow(key: $0, size: 1, lastModified: 0, storageClass: 0) } }
        return chunk
    }

    func testDeliversInFileAndChunkOrderUnderBackpressure() throws {
        let queue = OrderedChunkQueue(fileCount: 3, maximumRowsInFlight: 5)
        let group = DispatchGroup()
        for file in [2, 0, 1] {
            DispatchQueue.global().async(group: group) {
                for index in 0..<4 { try? queue.enqueue(self.chunk(file, index, rows: 3)) }
                queue.markFileComplete(file)
            }
        }
        var delivered: [(Int, Int)] = []
        while let next = try queue.dequeueNext() { delivered.append((next.fileIndex, next.chunkIndex)) }
        group.wait()
        XCTAssertEqual(delivered.map { $0.0 }, [0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2])
        XCTAssertEqual(delivered.map { $0.1 }, [0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3])
        XCTAssertEqual(queue.completedFilesDelivered, 3)
    }

    func testCancelWakesConsumer() throws {
        let queue = OrderedChunkQueue(fileCount: 1, maximumRowsInFlight: 10)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { queue.cancel() }
        XCTAssertThrowsError(try queue.dequeueNext()) { error in
            guard case ImportError.cancelled = error else { return XCTFail("wrong error \(error)") }
        }
    }
}
```

`ImportPipelineTests.swift`:
```swift
import XCTest
import TestSupport
import InventoryIndex
@testable import InventoryImport

final class ImportPipelineTests: XCTestCase {
    private var folder: URL!
    private var output: URL { folder.appendingPathComponent(IndexFormat.folderName) }
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("pipeline-\(UUID().uuidString)")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private func rows(count: Int) -> [FixtureRow] {
        (0..<count).map { index in
            FixtureRow(key: "assets/\(index % 13)/\(index % 5)/item-\(String(format: "%06d", index)).\(index % 3 == 0 ? "jpg" : "mp4")", size: UInt64(index * 37 % 1000),
                       lastModified: index % 2 == 0 ? "2026-01-01T00:00:00.000Z" : "2024-06-15T12:00:00.000Z", storageClass: index % 4 == 0 ? "DEEP_ARCHIVE" : "STANDARD")
        }
    }

    func testEndToEndImportMatchesReference() throws {
        let rows = rows(count: 5000) + TreeBuilderTests.awkwardRows
        try FixtureInventory.write(rows: rows, to: folder, fileCount: 6, shuffleManifest: true)
        let source = try InventorySource.load(folder: folder)
        var options = ImportOptions()
        options.threadCount = 3
        options.rowsPerChunk = 100
        options.maximumRowsInFlight = 250
        var progressEvents: [ImportProgress] = []
        let pipeline = ImportPipeline(source: source, outputFolder: output, options: options) { progressEvents.append($0) }
        let manifest = try pipeline.run()
        let reader = try IndexReader(folder: output)
        let reference = ReferenceTree.build(rows: rows, inventoryTimestamp: source.inventoryTimestamp)
        XCTAssertEqual(indexMismatches(reader: reader, reference: reference, inventoryTimestamp: source.inventoryTimestamp), [])
        XCTAssertEqual(manifest.counts.fileCount, UInt64(reference.filesInKeyOrder.count))
        XCTAssertEqual(manifest.counts.directoryCount, reference.directoriesInPreOrder.count)
        XCTAssertEqual(manifest.counts.skippedNonCurrent, 1)
        XCTAssertEqual(manifest.counts.skippedDeleteMarkers, 1)
        XCTAssertEqual(manifest.source.sourceBucket, "fixture-bucket")
        XCTAssertEqual(manifest.source.manifestFileCount, 6)
        XCTAssertEqual(manifest.extensionPalette.first.map { manifest.extensionNames[Int($0)] }, "mp4")
        XCTAssertEqual(progressEvents.last?.phase, .finished)
        XCTAssertTrue(progressEvents.contains { $0.phase == .importing })
    }

    func testCancelRemovesPartialOutput() throws {
        try FixtureInventory.write(rows: rows(count: 20_000), to: folder, fileCount: 4)
        let source = try InventorySource.load(folder: folder)
        var options = ImportOptions()
        options.rowsPerChunk = 50
        options.progressInterval = 0
        var pipeline: ImportPipeline!
        pipeline = ImportPipeline(source: source, outputFolder: output, options: options) { progress in
            if progress.phase == .importing && progress.rowsConsumed > 0 { pipeline.cancel() }
        }
        XCTAssertThrowsError(try pipeline.run()) { error in
            guard case ImportError.cancelled = error else { return XCTFail("wrong error \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testMissingDataFileFailsUnlessAllowed() throws {
        try FixtureInventory.write(rows: rows(count: 300), to: folder, fileCount: 3)
        let dataFiles = try FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent("data"), includingPropertiesForKeys: nil)
        try FileManager.default.removeItem(at: dataFiles[0])
        let source = try InventorySource.load(folder: folder)
        XCTAssertThrowsError(try ImportPipeline(source: source, outputFolder: output, progress: { _ in }).run()) { error in
            guard case ImportError.missingDataFiles(let names) = error else { return XCTFail("wrong error \(error)") }
            XCTAssertEqual(names, [dataFiles[0].lastPathComponent])
        }
        var options = ImportOptions()
        options.allowMissingDataFiles = true
        let manifest = try ImportPipeline(source: source, outputFolder: output, options: options, progress: { _ in }).run()
        XCTAssertEqual(manifest.missingDataFiles, [dataFiles[0].lastPathComponent])
        XCTAssertTrue(manifest.isPartial)
        XCTAssertGreaterThan(manifest.counts.fileCount, 0)
    }

    func testOverlappingFilesAbort() throws {
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("data"), withIntermediateDirectories: true)
        for (name, keys) in [("one.csv.gz", ["a/1", "c/1"]), ("two.csv.gz", ["b/1", "d/1"])] {
            let writer = try GzipDeflateWriter(url: folder.appendingPathComponent("data/\(name)"))
            for key in keys { try writer.write(FixtureInventory.csvRow(FixtureRow(key: key, size: 1), bucket: "b", schemaColumns: InventorySchema.defaultColumns)) }
            try writer.finish()
        }
        let source = try InventorySource.load(folder: folder)
        XCTAssertThrowsError(try ImportPipeline(source: source, outputFolder: output, progress: { _ in }).run()) { error in
            guard case ImportError.notKeySorted = error else { return XCTFail("wrong error \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testRefusesToOverwriteWithoutOption() throws {
        try FixtureInventory.write(rows: rows(count: 10), to: folder)
        let source = try InventorySource.load(folder: folder)
        _ = try ImportPipeline(source: source, outputFolder: output, progress: { _ in }).run()
        XCTAssertThrowsError(try ImportPipeline(source: source, outputFolder: output, progress: { _ in }).run()) { error in
            guard case ImportError.outputExists = error else { return XCTFail("wrong error \(error)") }
        }
        var options = ImportOptions()
        options.overwriteExistingIndex = true
        _ = try ImportPipeline(source: source, outputFolder: output, options: options, progress: { _ in }).run()
    }
}
```

Make `TreeBuilderTests.awkwardRows` accessible: it is `static let` inside `TreeBuilderTests`, which is in the same test target; keep it `static let` (internal) — both files compile into `InventoryImportTests`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter 'OrderedChunkQueueTests|ImportPipelineTests' 2>&1 | tail -5`
Expected: compile errors.

- [ ] **Step 3: Write `OrderedChunkQueue.swift`**

```swift
import Foundation

/// Producers push chunks in any order; the consumer receives them in (fileIndex, chunkIndex) order.
/// Backpressure: a producer blocks while `maximumRowsInFlight` is exceeded, unless its chunk belongs to the file the consumer needs next.
public final class OrderedChunkQueue {
    private let condition = NSCondition()
    private var pending: [Int: [Int: RowChunk]] = [:]
    private var completedFiles = Set<Int>()
    private var nextFileIndex = 0
    private var nextChunkIndex = 0
    private var rowsInFlight = 0
    private var cancelled = false
    private let fileCount: Int
    private let maximumRowsInFlight: Int
    public private(set) var completedFilesDelivered = 0

    public init(fileCount: Int, maximumRowsInFlight: Int) {
        self.fileCount = fileCount
        self.maximumRowsInFlight = maximumRowsInFlight
    }

    public func enqueue(_ chunk: RowChunk) throws {
        condition.lock()
        defer { condition.unlock() }
        while !cancelled && rowsInFlight >= maximumRowsInFlight && chunk.fileIndex != nextFileIndex { condition.wait() }
        if cancelled { throw ImportError.cancelled }
        pending[chunk.fileIndex, default: [:]][chunk.chunkIndex] = chunk
        rowsInFlight += chunk.count
        condition.broadcast()
    }

    public func markFileComplete(_ fileIndex: Int) {
        condition.lock()
        completedFiles.insert(fileIndex)
        condition.broadcast()
        condition.unlock()
    }

    public func dequeueNext() throws -> RowChunk? {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if cancelled { throw ImportError.cancelled }
            if nextFileIndex >= fileCount { return nil }
            if let chunk = pending[nextFileIndex]?.removeValue(forKey: nextChunkIndex) {
                rowsInFlight -= chunk.count
                nextChunkIndex += 1
                condition.broadcast()
                return chunk
            }
            if completedFiles.contains(nextFileIndex) && (pending[nextFileIndex]?.isEmpty ?? true) {
                pending[nextFileIndex] = nil
                nextFileIndex += 1
                nextChunkIndex = 0
                completedFilesDelivered += 1
                condition.broadcast()
                continue
            }
            condition.wait()
        }
    }

    public func cancel() {
        condition.lock()
        cancelled = true
        condition.broadcast()
        condition.unlock()
    }
}
```

- [ ] **Step 4: Write `NameBlockSink.swift`**

```swift
import Foundation
import InventoryIndex

/// Compresses name blocks on a worker pool and writes them in submission order.
public final class NameBlockSink: RawNameBlockConsumer {
    private let blocks: ColumnWriter<NameBlockEntry>
    private let data: ColumnWriter<UInt8>
    private let workers: DispatchQueue
    private let condition = NSCondition()
    private var nextSequence = 0
    private var nextSequenceToWrite = 0
    private var inFlight = 0
    private var finishedBlocks: [Int: (compressed: [UInt8], rawLength: Int)] = [:]
    private let maximumInFlight: Int

    public init(blocks: ColumnWriter<NameBlockEntry>, data: ColumnWriter<UInt8>, workerCount: Int = 4, maximumInFlight: Int = 16) {
        self.blocks = blocks
        self.data = data
        self.maximumInFlight = maximumInFlight
        workers = DispatchQueue(label: "name-block-sink", qos: .userInitiated, attributes: .concurrent)
        _ = workerCount   // Dispatch sizes the pool; the parameter documents the intended parallelism
    }

    public func consume(rawBlock: [UInt8], nameCount: Int) throws {
        condition.lock()
        while inFlight >= maximumInFlight { condition.wait() }
        let sequence = nextSequence
        nextSequence += 1
        inFlight += 1
        condition.unlock()
        workers.async { [self] in
            let compressed = NameBlockCodec.encode(raw: rawBlock)
            condition.lock()
            finishedBlocks[sequence] = (compressed, rawBlock.count)
            while let next = finishedBlocks.removeValue(forKey: nextSequenceToWrite) {
                blocks.append(NameBlockEntry(offset: UInt64(data.count), compressedLength: UInt32(next.compressed.count), rawLength: UInt32(next.rawLength)))
                next.compressed.withUnsafeBytes { data.appendBytes($0) }
                nextSequenceToWrite += 1
                inFlight -= 1
            }
            condition.broadcast()
            condition.unlock()
        }
    }

    public func finish() throws {
        condition.lock()
        while inFlight > 0 { condition.wait() }
        condition.unlock()
    }
}
```

- [ ] **Step 5: Write `ImportPipeline.swift`**

```swift
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

    public init(source: InventorySource, outputFolder: URL, options: ImportOptions = ImportOptions(), progress: @escaping (ImportProgress) -> Void) {
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

    private var isCancelled: Bool { stateLock.lock(); defer { stateLock.unlock() }; return cancelled }

    public func run() throws -> IndexManifest {
        let started = Date()
        if !source.missingDataFiles.isEmpty && !options.allowMissingDataFiles { throw ImportError.missingDataFiles(source.missingDataFiles) }
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
        if phase == .importing && bytes > 0 { remaining = elapsed * (Double(source.totalCompressedBytes) / Double(bytes) - 1) }
        progress(ImportProgress(phase: phase, filesCompleted: files, fileCount: source.dataFiles.count, rowsConsumed: rows, compressedBytesRead: bytes,
                                totalCompressedBytes: source.totalCompressedBytes, elapsedSeconds: elapsed, estimatedRemainingSeconds: remaining))
    }

    private func runUnchecked(started: Date) throws -> IndexManifest {
        report(.orderingFiles, files: 0, rows: 0, bytes: 0, started: started)
        let files = try FileOrdering.sortedByFirstKey(source.dataFiles, schema: source.schema)
        if isCancelled { throw ImportError.cancelled }
        let writer = try IndexWriter(folder: outputFolder, directoryCapacity: options.directoryCapacity)
        let sink = NameBlockSink(blocks: writer.fileNameBlocks, data: writer.fileNameData, workerCount: options.nameBlockWorkerCount)
        let builder = TreeBuilder(writer: writer, inventoryTimestamp: source.inventoryTimestamp, nameBlockConsumer: sink, fileNames: files.map { $0.url.lastPathComponent })
        let queue = OrderedChunkQueue(fileCount: files.count, maximumRowsInFlight: options.maximumRowsInFlight)
        stateLock.lock(); self.queue = queue; stateLock.unlock()
        if isCancelled { throw ImportError.cancelled }

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
                        stateLock.lock()
                        if producerError == nil, !(error is ImportError && (error as! ImportError) == .cancelled) { producerError = error }
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
            group.wait()
            stateLock.lock(); let failure = producerError; stateLock.unlock()
            throw failure ?? error
        }
        group.wait()
        stateLock.lock(); let failure = producerError; stateLock.unlock()
        if let failure { throw failure }
        if isCancelled { throw ImportError.cancelled }

        report(.postProcessing, files: files.count, rows: rows, bytes: bytes, started: started)
        let summary = try builder.finish()
        try IndexPostProcessing.writeChildrenBySize(folder: outputFolder)

        var manifest = IndexManifest.empty(sourceBucket: source.sourceBucket, inventoryTimestamp: source.inventoryTimestamp)
        manifest.importDurationSeconds = Date().timeIntervalSince(started)
        manifest.source = IndexManifest.SourceIdentity(sourceBucket: source.sourceBucket,
                                                       manifestCreationTimestamp: source.creationTimestampMilliseconds.map(String.init),
                                                       manifestFileCount: source.dataFiles.count + source.missingDataFiles.count,
                                                       manifestTotalBytes: source.manifestTotalBytes, manifestMD5: source.manifestMD5)
        manifest.counts = IndexManifest.Counts(directoryCount: summary.directoryCount, fileCount: summary.fileCount, totalBytes: summary.totalBytes,
                                               skippedNonCurrent: summary.skippedNonCurrent, skippedDeleteMarkers: summary.skippedDeleteMarkers, rowParseErrors: summary.parseErrors)
        manifest.missingDataFiles = source.missingDataFiles
        manifest.extensionNames = summary.extensionNames
        manifest.extensionPalette = IndexManifest.extensionPalette(from: summary.rootExtensionBytes)
        manifest.schemaColumns = source.schema.columnNames
        try manifest.save(to: outputFolder)
        report(.finished, files: files.count, rows: rows, bytes: bytes, started: started)
        return manifest
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --filter 'OrderedChunkQueueTests|ImportPipelineTests' 2>&1 | tail -8`
Expected: 7 tests pass. Then the full suite: `swift test 2>&1 | tail -3`.

- [ ] **Step 7: Report the changed files. Do not run git.**

### Task 13: CLI `index`, `stats`, `generate-fixture`; acceptance import of the reference bucket

**Files:**
- Modify: `Sources/s3-inventory-tool/main.swift`
- Create: `docs/benchmarks.md`

**Interfaces:**
- Produces: `s3-inventory-tool index <inventory folder> [--output <folder>] [--threads N] [--force] [--allow-missing]`, `s3-inventory-tool stats <index folder>`, `s3-inventory-tool generate-fixture <folder> --rows N [--files F]`. Tasks 16 and 17 add `bench` and `lookup` to the same file.

- [ ] **Step 1: Write `main.swift`**

```swift
import Foundation
import InventoryIndex
import InventoryImport

struct CommandLineOptions {
    var positional: [String] = []
    var flags: [String: String] = [:]
    init(_ arguments: [String]) {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("--") {
                let name = String(argument.dropFirst(2))
                if index + 1 < arguments.count && !arguments[index + 1].hasPrefix("--") { flags[name] = arguments[index + 1]; index += 2 } else { flags[name] = "true"; index += 1 }
            } else { positional.append(argument); index += 1 }
        }
    }
    func integer(_ name: String, default value: Int) -> Int { flags[name].flatMap(Int.init) ?? value }
    func double(_ name: String, default value: Double) -> Double { flags[name].flatMap(Double.init) ?? value }
    func bool(_ name: String) -> Bool { flags[name] == "true" }
}

func usage() -> Never {
    print("""
    usage:
      s3-inventory-tool index <inventory folder> [--output <folder>] [--threads N] [--force] [--allow-missing]
      s3-inventory-tool stats <index folder>
      s3-inventory-tool generate-fixture <folder> --rows N [--files F]
    """)
    exit(2)
}

func runIndex(_ options: CommandLineOptions) throws {
    guard let path = options.positional.first else { usage() }
    let inventory = URL(fileURLWithPath: path)
    let source = try InventorySource.load(folder: inventory)
    let output = options.flags["output"].map { URL(fileURLWithPath: $0) } ?? IndexReader.indexFolder(forInventory: inventory)
    var importOptions = ImportOptions()
    importOptions.threadCount = options.integer("threads", default: ProcessInfo.processInfo.activeProcessorCount)
    importOptions.overwriteExistingIndex = options.bool("force")
    importOptions.allowMissingDataFiles = options.bool("allow-missing")
    print("bucket \(source.sourceBucket): \(source.dataFiles.count) files, \(formatByteCount(UInt64(source.totalCompressedBytes), units: .binary)) compressed; missing \(source.missingDataFiles.count)")
    let pipeline = ImportPipeline(source: source, outputFolder: output, options: importOptions) { progress in
        let percent = progress.totalCompressedBytes > 0 ? Double(progress.compressedBytesRead) * 100 / Double(progress.totalCompressedBytes) : 0
        let rate = progress.elapsedSeconds > 0 ? Double(progress.rowsConsumed) / progress.elapsedSeconds : 0
        let remaining = progress.estimatedRemainingSeconds.map { String(format: "eta %.0fs", $0) } ?? ""
        print(String(format: "\r%@ %3.0f%% files %d/%d rows %@ %.0f rows/s %.0fs %@   ", "\(progress.phase)", percent, progress.filesCompleted, progress.fileCount,
                     formatCount(progress.rowsConsumed), rate, progress.elapsedSeconds, remaining), terminator: "")
        fflush(stdout)
    }
    let manifest = try pipeline.run()
    print("\ndone: \(formatCount(manifest.counts.fileCount)) files, \(formatCount(UInt64(manifest.counts.directoryCount))) directories, \(formatByteCount(manifest.counts.totalBytes, units: .binary)) in \(String(format: "%.1f", manifest.importDurationSeconds))s")
    print("skipped non-current \(manifest.counts.skippedNonCurrent), delete markers \(manifest.counts.skippedDeleteMarkers), parse errors \(manifest.counts.rowParseErrors)")
}

func runStats(_ options: CommandLineOptions) throws {
    guard let path = options.positional.first else { usage() }
    let reader = try IndexReader(folder: URL(fileURLWithPath: path))
    let tree = reader.directories
    let counts = reader.manifest.counts
    print("files \(formatCount(counts.fileCount)); directories \(formatCount(UInt64(counts.directoryCount))); bytes \(formatByteCount(counts.totalBytes, units: .binary)); partial \(reader.manifest.isPartial)")
    print("storage classes:")
    let classBytes = tree.bytesByStorageClass(IndexFormat.rootDirectory)
    for (slot, name) in StorageClass.names.enumerated() where classBytes[slot] > 0 {
        print(String(format: "  %-20@ %@ (%.2f%%)", name, formatByteCount(classBytes[slot], units: .binary), Double(classBytes[slot]) * 100 / Double(max(counts.totalBytes, 1))))
    }
    print("top-level prefixes by bytes:")
    for child in tree.childrenBySize(IndexFormat.rootDirectory).prefix(25) {
        print("  \(tree.name(child).padding(toLength: 40, withPad: " ", startingAt: 0)) \(formatByteCount(tree.subtreeBytes(child), units: .binary)) files \(formatCount(tree.subtreeFileCount(child))) directories \(formatCount(UInt64(tree.subtreeDirectoryCount(child))))")
    }
    print("extension palette: \(reader.manifest.extensionPalette.map { reader.manifest.extensionNames[Int($0)] })")
}

func runGenerateFixture(_ options: CommandLineOptions) throws {
    guard let path = options.positional.first else { usage() }
    let folder = URL(fileURLWithPath: path)
    let rowCount = options.integer("rows", default: 1_000_000)
    let fileCount = options.integer("files", default: max(1, rowCount / 1_000_000))
    let dataFolder = folder.appendingPathComponent("data")
    try FileManager.default.createDirectory(at: dataFolder, withIntermediateDirectories: true)
    var generator = SystemRandomNumberGenerator()
    func hex(_ length: Int) -> String { String((0..<length).map { _ in "0123456789abcdef".randomElement(using: &generator)! }) }
    // Keys are generated sorted: accounts ascending, then a fixed shape under each account.
    let accounts = (0..<max(1, rowCount / 2000)).map { _ in hex(24) }.sorted()
    var keys: [String] = []
    keys.reserveCapacity(rowCount)
    outer: for account in accounts {
        for year in [2023, 2024, 2025, 2026] {
            for _ in 0..<(rowCount / accounts.count / 4 + 1) {
                let uuid = hex(8) + "-" + hex(4) + "-" + hex(4) + "-" + hex(4) + "-" + hex(12)
                let suffix = ["_display.jpg", "_thumb.jpg", ".jpg", "_encoded.mp4", "_still.jpg"].randomElement(using: &generator)!
                keys.append("assets/\(account)/\(year)/snapshots/\(uuid.prefix(1))/\(uuid.dropFirst().prefix(1))/\(uuid.dropFirst(2).prefix(1))/\(uuid.dropFirst(3).prefix(1))/\(uuid)\(suffix)")
                if keys.count >= rowCount { break outer }
            }
        }
    }
    keys.sort()
    let rowsPerFile = max(1, keys.count / fileCount + 1)
    var files: [[String: Any]] = []
    for (fileIndex, start) in stride(from: 0, to: keys.count, by: rowsPerFile).enumerated() {
        let name = "part-\(fileIndex).csv.gz"
        let url = dataFolder.appendingPathComponent(name)
        let writer = try GzipDeflateWriter(url: url)
        for key in keys[start..<min(start + rowsPerFile, keys.count)] {
            let size = key.hasSuffix(".mp4") ? Int.random(in: 500_000...30_000_000, using: &generator) : Int.random(in: 10_000...3_000_000, using: &generator)
            let storageClass = size > 100_000 ? "STANDARD_IA" : "STANDARD"
            try writer.write("\"fixture\",\"\(key)\",\"v\",\"true\",\"false\",\"\(size)\",\"2025-0\(Int.random(in: 1...9, using: &generator))-1\(Int.random(in: 0...9, using: &generator))T10:00:00.000Z\",\"e\",\"\(storageClass)\",\"false\",\"\",\"\"\n")
        }
        try writer.finish()
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int64
        files.append(["key": "fixture/data/\(name)", "size": size, "MD5checksum": ""])
    }
    let manifest: [String: Any] = ["sourceBucket": "fixture", "fileFormat": "CSV", "creationTimestamp": "1767225600000",
                                   "fileSchema": InventorySchema.defaultColumns.joined(separator: ", "), "files": files]
    try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted]).write(to: folder.appendingPathComponent("manifest.json"))
    print("wrote \(keys.count) rows in \(files.count) files to \(folder.path)")
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { usage() }
let options = CommandLineOptions(Array(arguments.dropFirst()))
do {
    switch command {
    case "index": try runIndex(options)
    case "stats": try runStats(options)
    case "generate-fixture": try runGenerateFixture(options)
    default: usage()
    }
} catch {
    fputs("error: \(error)\n", stderr)
    exit(1)
}
```

- [ ] **Step 2: Build the release binary and run a synthetic 10 M-row import**

Run:
```bash
swift build -c release 2>&1 | tail -3
.build/release/s3-inventory-tool generate-fixture /tmp/fixture-10m --rows 10000000 --files 10
/usr/bin/time -l .build/release/s3-inventory-tool index /tmp/fixture-10m --force 2>&1 | tail -8
.build/release/s3-inventory-tool stats /tmp/fixture-10m/.s3-inventory-index
```
Expected: the import finishes; `stats` prints 10,000,000 files. Record rows per second and maximum resident set size. Target for this synthetic run on the reference Mac: ≥ 3 M rows/s. If it is under 1.5 M rows/s, profile with `xcrun xctrace record --template 'Time Profiler'` before moving on; the usual culprits are per-row allocations in `TreeBuilder.moveToDirectory` (the `segments` array) and `RowChunk.appendRow` reallocations.

- [ ] **Step 3: Acceptance import of the reference bucket**

Run (this takes minutes; keep the Mac awake):
```bash
caffeinate -i /usr/bin/time -l .build/release/s3-inventory-tool index ~/inventories/production-bucket --threads 8 --force 2>&1 | tee /tmp/reference-import.log | tail -12
du -sh ~/inventories/production-bucket/.s3-inventory-index
.build/release/s3-inventory-tool stats ~/inventories/production-bucket/.s3-inventory-index
```
Expected counts (from the census): files 1,119,900,884, directories 26,641,357, bytes 869,012,548,707,428 (790.4 TiB), skipped non-current 29,542, delete markers 5,378. Elapsed ≤ 15 minutes, maximum resident set size ≤ 8 GB, index folder about 40 GB.

- [ ] **Step 4: Write `docs/benchmarks.md`**

Record: date, machine, elapsed, rows per second, maximum resident set size, index size, the `stats` output, and any deviation from the expected counts with its explanation. Later tasks append sections to this file.

- [ ] **Step 5: Report the changed files and the benchmark numbers. Do not run git.**

---
## Phase 3 — Reader services and layout engine

### Task 14: Own-files cache (size-threshold selection and largest-N)

**Files:**
- Create: `Sources/InventoryIndex/OwnFilesCache.swift`
- Test: `Tests/InventoryIndexTests/OwnFilesCacheTests.swift`

**Interfaces:**
- Consumes: `IndexReader`, `DirectoryTree.ownFileRanges`.
- Produces:
  - `struct OwnFilesSelection: Equatable` — `fileIndices: [UInt64]`, `sizes: [UInt64]` (both sorted by size descending, ties by index ascending), `threshold: UInt64`, `ownBytes: UInt64`, `ownFileCount: UInt64`, `selectedBytes: UInt64`, `func narrowed(to threshold: UInt64) -> OwnFilesSelection`.
  - `final class OwnFilesCache` — `init(reader: IndexReader, capacity: Int = 256)`, `func ownFiles(of directory: UInt32, atLeast threshold: UInt64) -> OwnFilesSelection`, `func largestOwnFiles(of directory: UInt32, count: Int) -> OwnFilesSelection`. Thread-safe.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import TestSupport
import InventoryImport
@testable import InventoryIndex

final class OwnFilesCacheTests: XCTestCase {
    private var folder: URL!
    private var reader: IndexReader!
    private var rows: [FixtureRow] = []

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ownfiles-\(UUID().uuidString)")
        var generator = SystemRandomNumberGenerator()
        rows = (0..<300).map { FixtureRow(key: "big/file-\(String(format: "%04d", $0)).bin", size: UInt64.random(in: 0...5000, using: &generator)) }
        rows += (0..<40).map { FixtureRow(key: "big/sub\($0 % 4)/inner-\($0).bin", size: UInt64($0) * 100) }
        rows += [FixtureRow(key: "big/zzz-last.bin", size: 4999), FixtureRow(key: "other/x", size: 1)]
        try FixtureInventory.write(rows: rows, to: folder, fileCount: 2)
        let source = try InventorySource.load(folder: folder)
        _ = try ImportPipeline(source: source, outputFolder: IndexReader.indexFolder(forInventory: folder), progress: { _ in }).run()
        reader = try IndexReader(folder: IndexReader.indexFolder(forInventory: folder))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private func expectedOwnFiles(threshold: UInt64) -> [(String, UInt64)] {
        rows.filter { $0.key.hasPrefix("big/") && !$0.key.hasPrefix("big/sub") && $0.size >= threshold }
            .sorted { $0.size != $1.size ? $0.size > $1.size : FixtureInventory.encodeKey($0.key) < FixtureInventory.encodeKey($1.key) }
            .map { (String($0.key.dropFirst(4)), $0.size) }
    }

    func testThresholdSelectionMatchesBruteForce() throws {
        let cache = OwnFilesCache(reader: reader)
        let big = reader.directories.lookup(path: "big")!
        let selection = cache.ownFiles(of: big, atLeast: 2500)
        let expected = expectedOwnFiles(threshold: 2500)
        XCTAssertEqual(selection.fileIndices.map { reader.names.nameString(ofFile: $0) }, expected.map { $0.0 })
        XCTAssertEqual(selection.sizes, expected.map { $0.1 })
        XCTAssertEqual(selection.ownFileCount, 301)
        XCTAssertEqual(selection.ownBytes, rows.filter { $0.key.hasPrefix("big/") && !$0.key.hasPrefix("big/sub") }.reduce(0) { $0 + $1.size })
        XCTAssertEqual(selection.selectedBytes, expected.reduce(0) { $0 + $1.1 })
        // A larger threshold is served from the cached superset and must equal a fresh computation.
        let narrowed = cache.ownFiles(of: big, atLeast: 4000)
        XCTAssertEqual(narrowed.sizes, expectedOwnFiles(threshold: 4000).map { $0.1 })
        XCTAssertEqual(narrowed, OwnFilesCache(reader: reader).ownFiles(of: big, atLeast: 4000))
        // A smaller threshold recomputes.
        let widened = cache.ownFiles(of: big, atLeast: 0)
        XCTAssertEqual(widened.fileIndices.count, 301)
    }

    func testLargestOwnFiles() throws {
        let cache = OwnFilesCache(reader: reader)
        let big = reader.directories.lookup(path: "big")!
        let largest = cache.largestOwnFiles(of: big, count: 5)
        XCTAssertEqual(largest.sizes, Array(expectedOwnFiles(threshold: 0).prefix(5).map { $0.1 }))
        XCTAssertEqual(largest.fileIndices.map { reader.names.nameString(ofFile: $0) }, Array(expectedOwnFiles(threshold: 0).prefix(5).map { $0.0 }))
        let all = cache.largestOwnFiles(of: big, count: 10_000)
        XCTAssertEqual(all.fileIndices.count, 301)
    }

    func testDirectoryWithoutOwnFiles() throws {
        let cache = OwnFilesCache(reader: reader)
        let selection = cache.ownFiles(of: IndexFormat.rootDirectory, atLeast: 0)
        XCTAssertEqual(selection.fileIndices, [])
        XCTAssertEqual(selection.ownFileCount, 0)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter OwnFilesCacheTests 2>&1 | tail -5`
Expected: compile errors.

- [ ] **Step 3: Write `OwnFilesCache.swift`**

```swift
import Foundation

public struct OwnFilesSelection: Equatable {
    public var fileIndices: [UInt64]
    public var sizes: [UInt64]
    public var threshold: UInt64
    public var ownBytes: UInt64
    public var ownFileCount: UInt64
    public var selectedBytes: UInt64

    public func narrowed(to newThreshold: UInt64) -> OwnFilesSelection {
        guard newThreshold > threshold else { return self }
        var end = sizes.count
        var low = 0
        while low < end {                       // first index with size < newThreshold (sizes are descending)
            let middle = (low + end) / 2
            if sizes[middle] >= newThreshold { low = middle + 1 } else { end = middle }
        }
        let keptSizes = Array(sizes[0..<low])
        return OwnFilesSelection(fileIndices: Array(fileIndices[0..<low]), sizes: keptSizes, threshold: newThreshold,
                                 ownBytes: ownBytes, ownFileCount: ownFileCount, selectedBytes: keptSizes.reduce(0, +))
    }
}

public final class OwnFilesCache {
    private let reader: IndexReader
    private let capacity: Int
    private let lock = NSLock()
    private var entries: [UInt32: (selection: OwnFilesSelection, lastUse: UInt64)] = [:]
    private var useCounter: UInt64 = 0

    public init(reader: IndexReader, capacity: Int = 256) {
        self.reader = reader
        self.capacity = max(1, capacity)
    }

    public func ownFiles(of directory: UInt32, atLeast threshold: UInt64) -> OwnFilesSelection {
        lock.lock()
        useCounter += 1
        if let cached = entries[directory], cached.selection.threshold <= threshold {
            entries[directory] = (cached.selection, useCounter)
            lock.unlock()
            return cached.selection.narrowed(to: threshold)
        }
        lock.unlock()
        let computed = compute(directory: directory, threshold: threshold)
        lock.lock()
        if entries.count >= capacity, entries[directory] == nil, let victim = entries.min(by: { $0.value.lastUse < $1.value.lastUse }) {
            entries.removeValue(forKey: victim.key)
        }
        entries[directory] = (computed, useCounter)
        lock.unlock()
        return computed
    }

    private func compute(directory: UInt32, threshold: UInt64) -> OwnFilesSelection {
        let sizes = reader.fileSize.buffer
        var selected: [(size: UInt64, index: UInt64)] = []
        var ownBytes: UInt64 = 0
        var ownFileCount: UInt64 = 0
        for range in reader.directories.ownFileRanges(directory) {
            ownFileCount += range.upperBound - range.lowerBound
            var index = Int(range.lowerBound)
            let end = Int(range.upperBound)
            while index < end {
                let size = sizes[index]
                ownBytes &+= size
                if size >= threshold { selected.append((size, UInt64(index))) }
                index += 1
            }
        }
        selected.sort { $0.size != $1.size ? $0.size > $1.size : $0.index < $1.index }
        return OwnFilesSelection(fileIndices: selected.map { $0.index }, sizes: selected.map { $0.size }, threshold: threshold,
                                 ownBytes: ownBytes, ownFileCount: ownFileCount, selectedBytes: selected.reduce(0) { $0 + $1.size })
    }

    /// Bounded min-heap selection: O(n log count) over the directory's own files.
    public func largestOwnFiles(of directory: UInt32, count: Int) -> OwnFilesSelection {
        let sizes = reader.fileSize.buffer
        var heap: [(size: UInt64, index: UInt64)] = []     // min-heap on (size asc, index desc)
        heap.reserveCapacity(count + 1)
        func precedes(_ left: (size: UInt64, index: UInt64), _ right: (size: UInt64, index: UInt64)) -> Bool {
            left.size != right.size ? left.size < right.size : left.index > right.index
        }
        func siftUp(_ start: Int) {
            var child = start
            while child > 0 {
                let parent = (child - 1) / 2
                if precedes(heap[child], heap[parent]) { heap.swapAt(child, parent); child = parent } else { break }
            }
        }
        func siftDown(_ start: Int) {
            var parent = start
            while true {
                let left = 2 * parent + 1, right = left + 1
                var smallest = parent
                if left < heap.count && precedes(heap[left], heap[smallest]) { smallest = left }
                if right < heap.count && precedes(heap[right], heap[smallest]) { smallest = right }
                if smallest == parent { break }
                heap.swapAt(parent, smallest)
                parent = smallest
            }
        }
        var ownBytes: UInt64 = 0
        var ownFileCount: UInt64 = 0
        for range in reader.directories.ownFileRanges(directory) {
            ownFileCount += range.upperBound - range.lowerBound
            for index in Int(range.lowerBound)..<Int(range.upperBound) {
                let candidate = (size: sizes[index], index: UInt64(index))
                ownBytes &+= candidate.size
                if heap.count < count {
                    heap.append(candidate); siftUp(heap.count - 1)
                } else if count > 0 && precedes(heap[0], candidate) {
                    heap[0] = candidate; siftDown(0)
                }
            }
        }
        heap.sort { $0.size != $1.size ? $0.size > $1.size : $0.index < $1.index }
        return OwnFilesSelection(fileIndices: heap.map { $0.index }, sizes: heap.map { $0.size }, threshold: heap.last?.size ?? 0,
                                 ownBytes: ownBytes, ownFileCount: ownFileCount, selectedBytes: heap.reduce(0) { $0 + $1.size })
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter OwnFilesCacheTests 2>&1 | tail -5`
Expected: 3 tests pass.

- [ ] **Step 5: Report the changed files. Do not run git.**

### Task 15: Squarified layout and cushion coefficients (pure functions)

**Files:**
- Create: `Sources/TreemapLayout/LayoutGeometry.swift`, `Sources/TreemapLayout/Squarify.swift`
- Delete: `Sources/TreemapLayout/Placeholder.swift`
- Test: `Tests/TreemapLayoutTests/SquarifyTests.swift`, `Tests/TreemapLayoutTests/CushionTests.swift`

**Interfaces:**
- Produces:
  - `struct LayoutRect: Equatable` — `x, y, width, height: Double`, `area`, `func contains(x:y:) -> Bool`, `func insetBy(_:) -> LayoutRect`, `static let zero`.
  - `struct CushionCoefficients: Equatable` — `sxx, sx, syy, sy: Float`, `func adding(rect: LayoutRect, height: Double) -> CushionCoefficients`, `func localized(toOriginX:y:) -> CushionCoefficients`, `static let baseHeight = 0.75`, `static let heightFalloff = 0.75`, `static func height(atLevel: Int) -> Double`.
  - `enum Squarify` — `static func layout(weights: [Double], in rect: LayoutRect) -> [LayoutRect]` (one rect per weight, same order; the sum of areas equals the rect area; zero weights give zero-size rects).

- [ ] **Step 1: Write the failing tests**

`SquarifyTests.swift`:
```swift
import XCTest
@testable import TreemapLayout

final class SquarifyTests: XCTestCase {
    private func assertNoOverlapAndInside(_ rects: [LayoutRect], _ bounds: LayoutRect) {
        for rect in rects {
            XCTAssertGreaterThanOrEqual(rect.x, bounds.x - 1e-6); XCTAssertGreaterThanOrEqual(rect.y, bounds.y - 1e-6)
            XCTAssertLessThanOrEqual(rect.x + rect.width, bounds.x + bounds.width + 1e-6)
            XCTAssertLessThanOrEqual(rect.y + rect.height, bounds.y + bounds.height + 1e-6)
        }
        for (i, a) in rects.enumerated() where a.area > 0 {
            for b in rects[(i + 1)...] where b.area > 0 {
                let overlapWidth = min(a.x + a.width, b.x + b.width) - max(a.x, b.x)
                let overlapHeight = min(a.y + a.height, b.y + b.height) - max(a.y, b.y)
                XCTAssertFalse(overlapWidth > 1e-6 && overlapHeight > 1e-6, "rects \(a) and \(b) overlap")
            }
        }
    }

    func testSingleItemFillsRect() {
        let rect = LayoutRect(x: 10, y: 20, width: 300, height: 100)
        XCTAssertEqual(Squarify.layout(weights: [42], in: rect), [rect])
    }

    func testAreasAreProportionalAndOrderPreserved() {
        let rect = LayoutRect(x: 0, y: 0, width: 400, height: 100)
        let rects = Squarify.layout(weights: [300, 100], in: rect)
        XCTAssertEqual(rects[0].area, 30_000, accuracy: 1e-6)
        XCTAssertEqual(rects[1].area, 10_000, accuracy: 1e-6)
        XCTAssertEqual(rects[0].x, 0)                 // first item at the origin
        assertNoOverlapAndInside(rects, rect)
    }

    func testFourEqualWeightsInSquareAreSquares() {
        let rect = LayoutRect(x: 0, y: 0, width: 200, height: 200)
        let rects = Squarify.layout(weights: [1, 1, 1, 1], in: rect)
        for cell in rects { XCTAssertEqual(cell.width, 100, accuracy: 1e-6); XCTAssertEqual(cell.height, 100, accuracy: 1e-6) }
        assertNoOverlapAndInside(rects, rect)
    }

    func testManyDescendingWeightsCoverTheRect() {
        let rect = LayoutRect(x: 5, y: 7, width: 1000, height: 600)
        let weights = (1...60).map { Double(61 - $0) * Double(61 - $0) }
        let rects = Squarify.layout(weights: weights, in: rect)
        XCTAssertEqual(rects.count, 60)
        XCTAssertEqual(rects.reduce(0) { $0 + $1.area }, rect.area, accuracy: 1e-3)
        assertNoOverlapAndInside(rects, rect)
        let worstAspect = rects.map { max($0.width / $0.height, $0.height / $0.width) }.max()!
        XCTAssertLessThan(worstAspect, 8, "squarified rows keep aspect ratios reasonable")
    }

    func testZeroWeightsAndZeroTotal() {
        let rect = LayoutRect(x: 0, y: 0, width: 100, height: 100)
        let rects = Squarify.layout(weights: [10, 0, 0], in: rect)
        XCTAssertEqual(rects[0], rect)
        XCTAssertEqual(rects[1].area, 0)
        XCTAssertEqual(Squarify.layout(weights: [0, 0], in: rect).map { $0.area }, [0, 0])
        XCTAssertEqual(Squarify.layout(weights: [], in: rect), [])
    }
}
```

`CushionTests.swift`:
```swift
import XCTest
@testable import TreemapLayout

final class CushionTests: XCTestCase {
    func testCoefficientsForOneRect() {
        let rect = LayoutRect(x: 10, y: 20, width: 100, height: 50)
        let coefficients = CushionCoefficients().adding(rect: rect, height: 0.75)
        XCTAssertEqual(coefficients.sxx, Float(-4 * 0.75 / 100), accuracy: 1e-6)
        XCTAssertEqual(coefficients.sx, Float(4 * 0.75 * (10 + 110) / 100), accuracy: 1e-5)
        XCTAssertEqual(coefficients.syy, Float(-4 * 0.75 / 50), accuracy: 1e-6)
        XCTAssertEqual(coefficients.sy, Float(4 * 0.75 * (20 + 70) / 50), accuracy: 1e-5)
    }

    func testNestedRectsAccumulateAndLocalize() {
        let outer = LayoutRect(x: 0, y: 0, width: 200, height: 200)
        let inner = LayoutRect(x: 50, y: 50, width: 100, height: 100)
        let level0 = CushionCoefficients().adding(rect: outer, height: CushionCoefficients.height(atLevel: 0))
        let level1 = level0.adding(rect: inner, height: CushionCoefficients.height(atLevel: 1))
        XCTAssertEqual(level1.sxx, level0.sxx + Float(-4 * 0.75 * 0.75 / 100), accuracy: 1e-6)
        // Slope at the center of the inner rect (x = 100): the outer parabola peaks at 100 too, so the x slope is zero.
        let slopeAtCenter = 2 * level1.sxx * 100 + level1.sx
        XCTAssertEqual(slopeAtCenter, 0, accuracy: 1e-4)
        // Localizing to the inner origin must give the same slope when evaluated at local x = 50.
        let local = level1.localized(toOriginX: inner.x, y: inner.y)
        XCTAssertEqual(2 * local.sxx * 50 + local.sx, slopeAtCenter, accuracy: 1e-4)
        XCTAssertEqual(CushionCoefficients.height(atLevel: 2), 0.75 * 0.75 * 0.75, accuracy: 1e-12)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter 'SquarifyTests|CushionTests' 2>&1 | tail -5`
Expected: compile errors.

- [ ] **Step 3: Write `LayoutGeometry.swift`**

```swift
import Foundation

public struct LayoutRect: Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public static let zero = LayoutRect(x: 0, y: 0, width: 0, height: 0)

    public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
    public var area: Double { width * height }
    public func contains(x pointX: Double, y pointY: Double) -> Bool { pointX >= x && pointX < x + width && pointY >= y && pointY < y + height }
    public func insetBy(_ amount: Double) -> LayoutRect {
        guard width > 2 * amount, height > 2 * amount else { return self }
        return LayoutRect(x: x + amount, y: y + amount, width: width - 2 * amount, height: height - 2 * amount)
    }
}

/// Accumulated quadratic surface z = sxx·x² + sx·x + syy·y² + sy·y (van Wijk & van de Wetering cushion treemaps).
public struct CushionCoefficients: Equatable {
    public var sxx: Float = 0
    public var sx: Float = 0
    public var syy: Float = 0
    public var sy: Float = 0
    public static let baseHeight = 0.75
    public static let heightFalloff = 0.75

    public init() {}
    public init(sxx: Float, sx: Float, syy: Float, sy: Float) { self.sxx = sxx; self.sx = sx; self.syy = syy; self.sy = sy }

    public static func height(atLevel level: Int) -> Double { baseHeight * pow(heightFalloff, Double(level)) }

    public func adding(rect: LayoutRect, height: Double) -> CushionCoefficients {
        var result = self
        if rect.width > 0 {
            result.sxx -= Float(4 * height / rect.width)
            result.sx += Float(4 * height * (rect.x + rect.x + rect.width) / rect.width)
        }
        if rect.height > 0 {
            result.syy -= Float(4 * height / rect.height)
            result.sy += Float(4 * height * (rect.y + rect.y + rect.height) / rect.height)
        }
        return result
    }

    /// Re-expresses the surface in coordinates relative to (originX, originY): x = originX + localX.
    public func localized(toOriginX originX: Double, y originY: Double) -> CushionCoefficients {
        CushionCoefficients(sxx: sxx, sx: sx + 2 * sxx * Float(originX), syy: syy, sy: sy + 2 * syy * Float(originY))
    }
}
```

- [ ] **Step 4: Write `Squarify.swift`**

```swift
import Foundation

public enum Squarify {
    public static func layout(weights: [Double], in rect: LayoutRect) -> [LayoutRect] {
        var results = [LayoutRect](repeating: .zero, count: weights.count)
        let total = weights.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0, !weights.isEmpty else { return results }
        let scale = rect.area / total
        var remaining = rect
        var rowStart = 0
        var rowSum = 0.0, rowMinimum = Double.infinity, rowMaximum = 0.0
        var index = 0
        func worst(_ sum: Double, _ minimum: Double, _ maximum: Double, _ side: Double) -> Double {
            guard sum > 0, minimum > 0 else { return Double.infinity }
            return max(side * side * maximum / (sum * sum), sum * sum / (side * side * minimum))
        }
        func placeRow(_ range: Range<Int>, sum: Double) {
            guard sum > 0 else { return }
            if remaining.width >= remaining.height {
                let rowWidth = sum / remaining.height
                var y = remaining.y
                for item in range {
                    let itemHeight = weights[item] * scale / rowWidth
                    results[item] = LayoutRect(x: remaining.x, y: y, width: rowWidth, height: itemHeight)
                    y += itemHeight
                }
                remaining = LayoutRect(x: remaining.x + rowWidth, y: remaining.y, width: remaining.width - rowWidth, height: remaining.height)
            } else {
                let rowHeight = sum / remaining.width
                var x = remaining.x
                for item in range {
                    let itemWidth = weights[item] * scale / rowHeight
                    results[item] = LayoutRect(x: x, y: remaining.y, width: itemWidth, height: rowHeight)
                    x += itemWidth
                }
                remaining = LayoutRect(x: remaining.x, y: remaining.y + rowHeight, width: remaining.width, height: remaining.height - rowHeight)
            }
        }
        while index < weights.count {
            let area = weights[index] * scale
            if area <= 0 { index += 1; continue }         // zero-weight items keep a zero rect
            if index == rowStart || rowSum == 0 {
                rowStart = index; rowSum = area; rowMinimum = area; rowMaximum = area; index += 1; continue
            }
            let side = min(remaining.width, remaining.height)
            let current = worst(rowSum, rowMinimum, rowMaximum, side)
            let candidate = worst(rowSum + area, min(rowMinimum, area), max(rowMaximum, area), side)
            if candidate <= current {
                rowSum += area; rowMinimum = min(rowMinimum, area); rowMaximum = max(rowMaximum, area); index += 1
            } else {
                placeRow(rowStart..<index, sum: rowSum)
                rowStart = index; rowSum = 0
            }
        }
        if rowSum > 0 { placeRow(rowStart..<index, sum: rowSum) }
        // The last row should exactly consume the remaining space; absorb float drift into the final placed rect.
        return results
    }
}
```

Note: because zero-weight items are skipped inside a row range, `placeRow` gives them zero-size rects (weight 0 → `itemHeight`/`itemWidth` 0), which is the required behavior.

- [ ] **Step 5: Delete the placeholder and run the tests**

Run: `rm Sources/TreemapLayout/Placeholder.swift && swift test --filter 'SquarifyTests|CushionTests' 2>&1 | tail -5`
Expected: 7 tests pass.

- [ ] **Step 6: Report the changed files. Do not run git.**

### Task 16: Treemap layout engine with pixel budget, hit-test tree, and `bench`

**Files:**
- Create: `Sources/TreemapLayout/LayoutTypes.swift`, `Sources/TreemapLayout/TreemapLayoutEngine.swift`, `Sources/TreemapLayout/IndexLayoutDataSource.swift`
- Modify: `Sources/s3-inventory-tool/main.swift` (add `bench`)
- Test: `Tests/TreemapLayoutTests/TreemapLayoutEngineTests.swift`

**Interfaces:**
- Consumes: `Squarify`, `CushionCoefficients`, `OwnFilesSelection`, `OwnFilesCache`, `IndexReader`.
- Produces:
  - `struct TreemapInstance` (48 bytes): `x, y, width, height: Float`, `sxx, sx, syy, sy: Float`, `directoryId: UInt32`, `nodeReference: UInt32`, `timeSeconds: UInt32`, `extensionId: UInt16`, `storageClassId: UInt8`, `kind: UInt8`; `enum InstanceKind: UInt8 { case directoryLeaf = 0, file = 1, remainder = 2 }`; `func contains(x:y:) -> Bool`.
  - `struct HitTestNode` — `rect: LayoutRect`, `directoryId: UInt32`, `childNodes: [Int]`, `ownFileInstances: Range<Int>`, `remainderInstance: Int` (−1 none), `leafInstance: Int` (−1 none).
  - `struct LayoutLabel` — `directoryId`, `rect`, `text`.
  - `struct LayoutRequest: Hashable` — `rootDirectory: UInt32`, `width: Double`, `height: Double`, `minimumCellArea: Double`.
  - `enum LayoutHit: Equatable` — `.file(fileIndex: UInt64, instance: Int, directory: UInt32)`, `.directory(id: UInt32, instance: Int?)`, `.remainder(directory: UInt32, instance: Int, itemCount: UInt64, bytes: UInt64)`.
  - `struct LayoutResult` — `request`, `instances: [TreemapInstance]`, `nodes: [HitTestNode]`, `labels: [LayoutLabel]`, `remainderCounts: [Int: (items: UInt64, bytes: UInt64)]` (by node index), `elapsedSeconds: Double`, `func hitTest(x:y:) -> LayoutHit?`, `func node(forDirectory:) -> Int?`.
  - `struct DirectoryLeafAttributes { storageClass: UInt8; extensionId: UInt16; timeSeconds: UInt32 }`, `struct FileLeafAttributes { storageClass: UInt8; extensionId: UInt16; lastModified: UInt32 }`.
  - `protocol LayoutDataSource: AnyObject` — `subtreeBytes(of:) -> UInt64`, `subtreeFileCount(of:) -> UInt64`, `subtreeDirectoryCount(of:) -> UInt32`, `childrenBySize(of:) -> [UInt32]`, `ownFiles(of:atLeast:) -> OwnFilesSelection`, `directoryAttributes(_:) -> DirectoryLeafAttributes`, `fileAttributes(_:) -> FileLeafAttributes`, `directoryName(_:) -> String`.
  - `final class TreemapLayoutEngine` — `init(dataSource: LayoutDataSource)`, `func layout(_ request: LayoutRequest) -> LayoutResult`, `static let minimumDirectoryAreaForRecursion = 16.0`, `static let cellInset = 0.5`, `static let labelMinimumWidth = 64.0`, `static let labelMinimumHeight = 16.0`, `static let maximumLabels = 400`.
  - `final class IndexLayoutDataSource: LayoutDataSource` — `init(reader: IndexReader, ownFilesCache: OwnFilesCache)`.
  - CLI: `s3-inventory-tool bench <index folder> [--width 2560] [--height 1440] [--min-area 4] [--root <path>] [--repeat 5]`.

- [ ] **Step 1: Write the failing tests with a fake data source**

```swift
import XCTest
import InventoryIndex
@testable import TreemapLayout

/// In-memory tree: directory ids are pre-order; files have global indices.
final class FakeLayoutDataSource: LayoutDataSource {
    struct Directory { var name: String; var children: [UInt32]; var files: [UInt64]; var storageClass: UInt8 = 0; var timeSeconds: UInt32 = 0 }
    var directories: [Directory]
    var fileSizes: [UInt64]
    var fileClasses: [UInt8]
    init(directories: [Directory], fileSizes: [UInt64]) {
        self.directories = directories; self.fileSizes = fileSizes; fileClasses = fileSizes.map { _ in 0 }
    }
    func subtreeBytes(of directory: UInt32) -> UInt64 {
        let node = directories[Int(directory)]
        return node.files.reduce(0) { $0 + fileSizes[Int($1)] } + node.children.reduce(0) { $0 + subtreeBytes(of: $1) }
    }
    func subtreeFileCount(of directory: UInt32) -> UInt64 {
        let node = directories[Int(directory)]
        return UInt64(node.files.count) + node.children.reduce(0) { $0 + subtreeFileCount(of: $1) }
    }
    func subtreeDirectoryCount(of directory: UInt32) -> UInt32 {
        directories[Int(directory)].children.reduce(0) { $0 + 1 + subtreeDirectoryCount(of: $1) }
    }
    func childrenBySize(of directory: UInt32) -> [UInt32] {
        directories[Int(directory)].children.sorted { subtreeBytes(of: $0) != subtreeBytes(of: $1) ? subtreeBytes(of: $0) > subtreeBytes(of: $1) : $0 < $1 }
    }
    func ownFiles(of directory: UInt32, atLeast threshold: UInt64) -> OwnFilesSelection {
        let files = directories[Int(directory)].files
        let selected = files.filter { fileSizes[Int($0)] >= threshold }.sorted { fileSizes[Int($0)] != fileSizes[Int($1)] ? fileSizes[Int($0)] > fileSizes[Int($1)] : $0 < $1 }
        return OwnFilesSelection(fileIndices: selected, sizes: selected.map { fileSizes[Int($0)] }, threshold: threshold,
                                 ownBytes: files.reduce(0) { $0 + fileSizes[Int($1)] }, ownFileCount: UInt64(files.count), selectedBytes: selected.reduce(0) { $0 + fileSizes[Int($1)] })
    }
    func directoryAttributes(_ id: UInt32) -> DirectoryLeafAttributes { DirectoryLeafAttributes(storageClass: directories[Int(id)].storageClass, extensionId: 0, timeSeconds: directories[Int(id)].timeSeconds) }
    func fileAttributes(_ index: UInt64) -> FileLeafAttributes { FileLeafAttributes(storageClass: fileClasses[Int(index)], extensionId: 3, lastModified: 1000) }
    func directoryName(_ id: UInt32) -> String { directories[Int(id)].name }
}

final class TreemapLayoutEngineTests: XCTestCase {
    func testInstanceStrideIs48() { XCTAssertEqual(MemoryLayout<TreemapInstance>.stride, 48) }

    func testTwoFilesAreProportional() {
        let source = FakeLayoutDataSource(directories: [.init(name: "", children: [], files: [0, 1])], fileSizes: [300, 100])
        let result = TreemapLayoutEngine(dataSource: source).layout(LayoutRequest(rootDirectory: 0, width: 400, height: 100, minimumCellArea: 4))
        XCTAssertEqual(result.instances.count, 2)
        XCTAssertEqual(result.instances[0].kind, InstanceKind.file.rawValue)
        XCTAssertEqual(Double(result.instances[0].width * result.instances[0].height) / Double(result.instances[1].width * result.instances[1].height), 3, accuracy: 0.1)
        XCTAssertEqual(result.instances[0].nodeReference, 0)
        XCTAssertEqual(result.instances[1].nodeReference, 1)
        XCTAssertEqual(result.instances[0].extensionId, 3)
        XCTAssertEqual(result.nodes[0].ownFileInstances, 0..<2)
    }

    func testPixelBudgetCollapsesSmallItemsIntoRemainder() {
        let sizes = [1_000_000] + [UInt64](repeating: 1, count: 10_000)
        let source = FakeLayoutDataSource(directories: [.init(name: "", children: [], files: Array(0..<UInt64(sizes.count)))], fileSizes: sizes)
        let result = TreemapLayoutEngine(dataSource: source).layout(LayoutRequest(rootDirectory: 0, width: 100, height: 100, minimumCellArea: 4))
        XCTAssertEqual(result.instances.count, 2)
        XCTAssertEqual(result.instances[1].kind, InstanceKind.remainder.rawValue)
        XCTAssertEqual(result.remainderCounts[0]?.items, 10_000)
        XCTAssertEqual(result.remainderCounts[0]?.bytes, 10_000)
        let center = result.instances[1]
        XCTAssertEqual(result.hitTest(x: Double(center.x) + 0.5, y: Double(center.y) + 0.5), .remainder(directory: 0, instance: 1, itemCount: 10_000, bytes: 10_000))
    }

    func testRecursionLeafDirectoriesAndHitTesting() {
        // root: dir A (files 0,1: 500+500), dir B tiny (file 2: 1), own file 3 (1000)
        let source = FakeLayoutDataSource(directories: [
            .init(name: "", children: [1, 2], files: [3]),
            .init(name: "A", children: [], files: [0, 1], storageClass: 1),
            .init(name: "B", children: [], files: [2], storageClass: 6),
        ], fileSizes: [500, 500, 1, 1000])
        let result = TreemapLayoutEngine(dataSource: source).layout(LayoutRequest(rootDirectory: 0, width: 200, height: 100, minimumCellArea: 4))
        let kinds = result.instances.map { $0.kind }
        XCTAssertEqual(kinds.filter { $0 == InstanceKind.file.rawValue }.count, 3, "A's two files and root's own file")
        XCTAssertEqual(kinds.filter { $0 == InstanceKind.directoryLeaf.rawValue }.count, 1, "B is too small to recurse")
        let leaf = result.instances.first { $0.kind == InstanceKind.directoryLeaf.rawValue }!
        XCTAssertEqual(leaf.directoryId, 2)
        XCTAssertEqual(leaf.storageClassId, 6)
        XCTAssertNotNil(result.node(forDirectory: 1))
        let aNode = result.nodes[result.node(forDirectory: 1)!]
        XCTAssertEqual(aNode.ownFileInstances.count, 2)
        let fileInstance = result.instances[aNode.ownFileInstances.lowerBound]
        let hit = result.hitTest(x: Double(fileInstance.x + fileInstance.width / 2), y: Double(fileInstance.y + fileInstance.height / 2))
        guard case .file(let fileIndex, _, let directory)? = hit else { return XCTFail("expected a file hit, got \(String(describing: hit))") }
        XCTAssertEqual(directory, 1)
        XCTAssertTrue([0, 1].contains(fileIndex))
        XCTAssertNil(result.hitTest(x: -1, y: -1))
        XCTAssertTrue(result.labels.contains { $0.text == "A" })
        XCTAssertTrue(result.labels.allSatisfy { $0.rect.width >= 64 && $0.rect.height >= 16 })
    }

    func testInstanceCountStaysUnderBudget() {
        var generator = SystemRandomNumberGenerator()
        let sizes = (0..<50_000).map { _ in UInt64.random(in: 1...1000, using: &generator) }
        var directories = [FakeLayoutDataSource.Directory(name: "", children: Array(1...50), files: [])]
        for child in 1...50 { directories.append(.init(name: "d\(child)", children: [], files: Array(UInt64((child - 1) * 1000)..<UInt64(child * 1000)))) }
        let source = FakeLayoutDataSource(directories: directories, fileSizes: sizes)
        let request = LayoutRequest(rootDirectory: 0, width: 800, height: 600, minimumCellArea: 4)
        let result = TreemapLayoutEngine(dataSource: source).layout(request)
        XCTAssertLessThanOrEqual(result.instances.count, Int(800 * 600 / 4) + result.nodes.count)
        XCTAssertGreaterThan(result.instances.count, 1000)
        for instance in result.instances where instance.kind != InstanceKind.remainder.rawValue { XCTAssertGreaterThanOrEqual(instance.width * instance.height, 0) }
        XCTAssertEqual(TreemapLayoutEngine(dataSource: source).layout(request).instances.count, result.instances.count, "deterministic")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter TreemapLayoutEngineTests 2>&1 | tail -5`
Expected: compile errors.

- [ ] **Step 3: Write `LayoutTypes.swift`**

```swift
import Foundation
import InventoryIndex

public enum InstanceKind: UInt8 { case directoryLeaf = 0, file = 1, remainder = 2 }

/// Matches `struct TreemapInstance` in Shaders.metal byte for byte (48 bytes).
public struct TreemapInstance {
    public var x: Float, y: Float, width: Float, height: Float
    public var sxx: Float, sx: Float, syy: Float, sy: Float
    public var directoryId: UInt32
    public var nodeReference: UInt32
    public var timeSeconds: UInt32
    public var extensionId: UInt16
    public var storageClassId: UInt8
    public var kind: UInt8

    public func contains(x pointX: Double, y pointY: Double) -> Bool {
        pointX >= Double(x) && pointX < Double(x + width) && pointY >= Double(y) && pointY < Double(y + height)
    }
}

public struct HitTestNode {
    public var rect: LayoutRect
    public var directoryId: UInt32
    public var childNodes: [Int] = []
    public var ownFileInstances: Range<Int> = 0..<0
    public var remainderInstance: Int = -1
    public var leafInstance: Int = -1
}

public struct LayoutLabel: Equatable {
    public var directoryId: UInt32
    public var rect: LayoutRect
    public var text: String
}

public struct LayoutRequest: Hashable {
    public var rootDirectory: UInt32
    public var width: Double
    public var height: Double
    public var minimumCellArea: Double
    public init(rootDirectory: UInt32, width: Double, height: Double, minimumCellArea: Double) {
        self.rootDirectory = rootDirectory; self.width = width; self.height = height; self.minimumCellArea = minimumCellArea
    }
}

public enum LayoutHit: Equatable {
    case file(fileIndex: UInt64, instance: Int, directory: UInt32)
    case directory(id: UInt32, instance: Int?)
    case remainder(directory: UInt32, instance: Int, itemCount: UInt64, bytes: UInt64)
}

public struct DirectoryLeafAttributes { public var storageClass: UInt8; public var extensionId: UInt16; public var timeSeconds: UInt32
    public init(storageClass: UInt8, extensionId: UInt16, timeSeconds: UInt32) { self.storageClass = storageClass; self.extensionId = extensionId; self.timeSeconds = timeSeconds } }
public struct FileLeafAttributes { public var storageClass: UInt8; public var extensionId: UInt16; public var lastModified: UInt32
    public init(storageClass: UInt8, extensionId: UInt16, lastModified: UInt32) { self.storageClass = storageClass; self.extensionId = extensionId; self.lastModified = lastModified } }

public protocol LayoutDataSource: AnyObject {
    func subtreeBytes(of directory: UInt32) -> UInt64
    func subtreeFileCount(of directory: UInt32) -> UInt64
    func subtreeDirectoryCount(of directory: UInt32) -> UInt32
    func childrenBySize(of directory: UInt32) -> [UInt32]
    func ownFiles(of directory: UInt32, atLeast threshold: UInt64) -> OwnFilesSelection
    func directoryAttributes(_ id: UInt32) -> DirectoryLeafAttributes
    func fileAttributes(_ index: UInt64) -> FileLeafAttributes
    func directoryName(_ id: UInt32) -> String
}

public struct LayoutResult {
    public var request: LayoutRequest
    public var instances: [TreemapInstance]
    public var nodes: [HitTestNode]
    public var labels: [LayoutLabel]
    public var remainderCounts: [Int: (items: UInt64, bytes: UInt64)]
    public var elapsedSeconds: Double
    private var nodeByDirectory: [UInt32: Int]

    init(request: LayoutRequest, instances: [TreemapInstance], nodes: [HitTestNode], labels: [LayoutLabel], remainderCounts: [Int: (items: UInt64, bytes: UInt64)], elapsedSeconds: Double) {
        self.request = request; self.instances = instances; self.nodes = nodes; self.labels = labels; self.remainderCounts = remainderCounts; self.elapsedSeconds = elapsedSeconds
        var byDirectory: [UInt32: Int] = [:]
        for (index, node) in nodes.enumerated() where node.leafInstance < 0 { byDirectory[node.directoryId] = index }
        nodeByDirectory = byDirectory
    }

    public func node(forDirectory directory: UInt32) -> Int? { nodeByDirectory[directory] }

    public func hitTest(x: Double, y: Double) -> LayoutHit? {
        guard !nodes.isEmpty, nodes[0].rect.contains(x: x, y: y) else { return nil }
        var nodeIndex = 0
        while true {
            let node = nodes[nodeIndex]
            if node.leafInstance >= 0 { return .directory(id: node.directoryId, instance: node.leafInstance) }
            if let child = node.childNodes.first(where: { nodes[$0].rect.contains(x: x, y: y) }) { nodeIndex = child; continue }
            for instance in node.ownFileInstances where instances[instance].contains(x: x, y: y) {
                return .file(fileIndex: UInt64(instances[instance].nodeReference), instance: instance, directory: node.directoryId)
            }
            if node.remainderInstance >= 0, instances[node.remainderInstance].contains(x: x, y: y) {
                let counts = remainderCounts[nodeIndex] ?? (0, 0)
                return .remainder(directory: node.directoryId, instance: node.remainderInstance, itemCount: counts.items, bytes: counts.bytes)
            }
            return .directory(id: node.directoryId, instance: nil)
        }
    }
}
```

- [ ] **Step 4: Write `TreemapLayoutEngine.swift`**

```swift
import Foundation
import InventoryIndex

public final class TreemapLayoutEngine {
    public static let minimumDirectoryAreaForRecursion = 16.0
    public static let cellInset = 0.5
    public static let labelMinimumWidth = 64.0
    public static let labelMinimumHeight = 16.0
    public static let maximumLabels = 400

    private let dataSource: LayoutDataSource
    private var instances: [TreemapInstance] = []
    private var nodes: [HitTestNode] = []
    private var labels: [LayoutLabel] = []
    private var remainderCounts: [Int: (items: UInt64, bytes: UInt64)] = [:]
    private var request = LayoutRequest(rootDirectory: 0, width: 0, height: 0, minimumCellArea: 4)

    public init(dataSource: LayoutDataSource) { self.dataSource = dataSource }

    public func layout(_ request: LayoutRequest) -> LayoutResult {
        let started = DispatchTime.now()
        self.request = request
        instances = []; nodes = []; labels = []; remainderCounts = [:]
        instances.reserveCapacity(min(Int(request.width * request.height / max(request.minimumCellArea, 1)) / 2, 2_000_000))
        let rootRect = LayoutRect(x: 0, y: 0, width: request.width, height: request.height)
        nodes.append(HitTestNode(rect: rootRect, directoryId: request.rootDirectory))
        layoutDirectory(request.rootDirectory, rect: rootRect, level: 0, cushion: CushionCoefficients(), nodeIndex: 0)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e9
        return LayoutResult(request: request, instances: instances, nodes: nodes, labels: labels, remainderCounts: remainderCounts, elapsedSeconds: elapsed)
    }

    private enum Item { case directory(UInt32, UInt64), file(UInt64, UInt64) }

    private func layoutDirectory(_ directory: UInt32, rect: LayoutRect, level: Int, cushion: CushionCoefficients, nodeIndex: Int) {
        let subtreeBytes = dataSource.subtreeBytes(of: directory)
        let inner = rect.insetBy(TreemapLayoutEngine.cellInset)
        guard subtreeBytes > 0, inner.area >= 1 else { return }
        let threshold = UInt64((request.minimumCellArea * Double(subtreeBytes) / inner.area).rounded(.up))
        let children = dataSource.childrenBySize(of: directory)
        let ownFiles = dataSource.ownFiles(of: directory, atLeast: max(threshold, 1))

        var items: [Item] = []
        var placedBytes: UInt64 = 0
        var placedItems: UInt64 = 0
        var childCursor = 0, fileCursor = 0
        while true {
            let childBytes = childCursor < children.count ? dataSource.subtreeBytes(of: children[childCursor]) : 0
            let fileBytes = fileCursor < ownFiles.sizes.count ? ownFiles.sizes[fileCursor] : 0
            if childBytes == 0 && fileBytes == 0 { break }
            let takeChild = childBytes >= fileBytes
            let bytes = takeChild ? childBytes : fileBytes
            if bytes < threshold { break }
            if takeChild {
                items.append(.directory(children[childCursor], bytes))
                placedItems += dataSource.subtreeFileCount(of: children[childCursor]) + UInt64(dataSource.subtreeDirectoryCount(of: children[childCursor])) + 1
                childCursor += 1
            } else {
                items.append(.file(ownFiles.fileIndices[fileCursor], bytes))
                placedItems += 1
                fileCursor += 1
            }
            placedBytes += bytes
        }
        let remainderBytes = subtreeBytes - placedBytes
        let totalItems = dataSource.subtreeFileCount(of: directory) + UInt64(dataSource.subtreeDirectoryCount(of: directory))
        var weights = items.map { item -> Double in
            switch item { case .directory(_, let bytes), .file(_, let bytes): return Double(bytes) }
        }
        if remainderBytes > 0 { weights.append(Double(remainderBytes)) }
        let rects = Squarify.layout(weights: weights, in: inner)
        let childHeight = CushionCoefficients.height(atLevel: level + 1)

        // Own files first so their instances are contiguous.
        let fileInstancesStart = instances.count
        for (itemIndex, item) in items.enumerated() {
            guard case .file(let fileIndex, _) = item else { continue }
            let cellRect = rects[itemIndex]
            let attributes = dataSource.fileAttributes(fileIndex)
            appendInstance(rect: cellRect, cushion: cushion.adding(rect: cellRect, height: childHeight), directoryId: directory, nodeReference: UInt32(truncatingIfNeeded: fileIndex),
                           timeSeconds: attributes.lastModified, extensionId: attributes.extensionId, storageClass: attributes.storageClass, kind: .file)
        }
        nodes[nodeIndex].ownFileInstances = fileInstancesStart..<instances.count

        for (itemIndex, item) in items.enumerated() {
            guard case .directory(let child, _) = item else { continue }
            let cellRect = rects[itemIndex]
            let cellCushion = cushion.adding(rect: cellRect, height: childHeight)
            if cellRect.area >= TreemapLayoutEngine.minimumDirectoryAreaForRecursion {
                let childNodeIndex = nodes.count
                nodes.append(HitTestNode(rect: cellRect, directoryId: child))
                nodes[nodeIndex].childNodes.append(childNodeIndex)
                if cellRect.width >= TreemapLayoutEngine.labelMinimumWidth && cellRect.height >= TreemapLayoutEngine.labelMinimumHeight && labels.count < TreemapLayoutEngine.maximumLabels {
                    labels.append(LayoutLabel(directoryId: child, rect: cellRect, text: dataSource.directoryName(child)))
                }
                layoutDirectory(child, rect: cellRect, level: level + 1, cushion: cellCushion, nodeIndex: childNodeIndex)
            } else {
                let attributes = dataSource.directoryAttributes(child)
                let leafNodeIndex = nodes.count
                nodes.append(HitTestNode(rect: cellRect, directoryId: child, leafInstance: instances.count))
                nodes[nodeIndex].childNodes.append(leafNodeIndex)
                appendInstance(rect: cellRect, cushion: cellCushion, directoryId: child, nodeReference: child, timeSeconds: attributes.timeSeconds,
                               extensionId: attributes.extensionId, storageClass: attributes.storageClass, kind: .directoryLeaf)
            }
        }

        if remainderBytes > 0, let remainderRect = rects.last {
            let attributes = dataSource.directoryAttributes(directory)
            nodes[nodeIndex].remainderInstance = instances.count
            remainderCounts[nodeIndex] = (totalItems - placedItems, remainderBytes)
            appendInstance(rect: remainderRect, cushion: cushion.adding(rect: remainderRect, height: childHeight), directoryId: directory, nodeReference: directory,
                           timeSeconds: attributes.timeSeconds, extensionId: attributes.extensionId, storageClass: attributes.storageClass, kind: .remainder)
        }
    }

    private func appendInstance(rect: LayoutRect, cushion: CushionCoefficients, directoryId: UInt32, nodeReference: UInt32, timeSeconds: UInt32,
                                extensionId: UInt16, storageClass: UInt8, kind: InstanceKind) {
        let local = cushion.localized(toOriginX: rect.x, y: rect.y)
        instances.append(TreemapInstance(x: Float(rect.x), y: Float(rect.y), width: Float(rect.width), height: Float(rect.height),
                                         sxx: local.sxx, sx: local.sx, syy: local.syy, sy: local.sy,
                                         directoryId: directoryId, nodeReference: nodeReference, timeSeconds: timeSeconds,
                                         extensionId: extensionId, storageClassId: storageClass, kind: kind.rawValue))
    }
}
```

Note on `testRecursionLeafDirectoriesAndHitTesting`: directory B (1 byte of 2001) in a 200 × 100 view gets about 10 px², under the 16 px² recursion minimum, so it becomes a leaf; A (1000 of 2001) recurses. If the fake's numbers give B ≥ 16 px², shrink the request or B's size — the assertion is about the rule, not the exact numbers.

- [ ] **Step 5: Write `IndexLayoutDataSource.swift`**

```swift
import Foundation
import InventoryIndex

public final class IndexLayoutDataSource: LayoutDataSource {
    public let reader: IndexReader
    public let ownFilesCache: OwnFilesCache

    public init(reader: IndexReader, ownFilesCache: OwnFilesCache) {
        self.reader = reader
        self.ownFilesCache = ownFilesCache
    }

    public func subtreeBytes(of directory: UInt32) -> UInt64 { reader.directories.subtreeBytes(directory) }
    public func subtreeFileCount(of directory: UInt32) -> UInt64 { reader.directories.subtreeFileCount(directory) }
    public func subtreeDirectoryCount(of directory: UInt32) -> UInt32 { reader.directories.subtreeDirectoryCount(directory) }
    public func childrenBySize(of directory: UInt32) -> [UInt32] { reader.directories.childrenBySize(directory) }
    public func ownFiles(of directory: UInt32, atLeast threshold: UInt64) -> OwnFilesSelection { ownFilesCache.ownFiles(of: directory, atLeast: threshold) }

    public func directoryAttributes(_ id: UInt32) -> DirectoryLeafAttributes {
        let ageSeconds = reader.directories.averageAgeDays(id) * 86_400
        let time = max(0, Double(reader.manifest.inventoryTimestamp) - ageSeconds)
        return DirectoryLeafAttributes(storageClass: reader.directories.dominantStorageClass(id), extensionId: reader.directories.dominantExtension(id), timeSeconds: UInt32(time))
    }

    public func fileAttributes(_ index: UInt64) -> FileLeafAttributes {
        let position = Int(index)
        return FileLeafAttributes(storageClass: reader.fileStorageClass[position], extensionId: reader.fileExtension[position], lastModified: reader.fileLastModified[position])
    }

    public func directoryName(_ id: UInt32) -> String { reader.directories.name(id) }
}
```

- [ ] **Step 6: Add `bench` to `main.swift`**

Add `import TreemapLayout`, the usage line, the `case "bench": try runBench(options)`, and:

```swift
func runBench(_ options: CommandLineOptions) throws {
    guard let path = options.positional.first else { usage() }
    let reader = try IndexReader(folder: URL(fileURLWithPath: path))
    let dataSource = IndexLayoutDataSource(reader: reader, ownFilesCache: OwnFilesCache(reader: reader))
    let engine = TreemapLayoutEngine(dataSource: dataSource)
    let rootPath = options.flags["root"] ?? ""
    guard let root = reader.directories.lookup(path: rootPath) else { fputs("no directory '\(rootPath)'\n", stderr); exit(1) }
    let request = LayoutRequest(rootDirectory: root, width: options.double("width", default: 2560), height: options.double("height", default: 1440), minimumCellArea: options.double("min-area", default: 4))
    var timings: [Double] = []
    var lastResult: LayoutResult?
    for _ in 0..<options.integer("repeat", default: 5) {
        let result = engine.layout(request)
        timings.append(result.elapsedSeconds * 1000)
        lastResult = result
    }
    let sorted = timings.sorted()
    print("root '\(rootPath)': instances \(formatCount(UInt64(lastResult!.instances.count))), nodes \(formatCount(UInt64(lastResult!.nodes.count))), labels \(lastResult!.labels.count)")
    print(String(format: "layout ms: first %.1f, min %.1f, median %.1f", timings[0], sorted[0], sorted[sorted.count / 2]))
}
```

- [ ] **Step 7: Run the tests, then the benchmark on the reference index**

Run: `swift test --filter TreemapLayoutEngineTests 2>&1 | tail -5` — expected 5 tests pass.

Then:
```bash
swift build -c release 2>&1 | tail -1
for root in "" media albums queue shared/assets drafts; do .build/release/s3-inventory-tool bench ~/inventories/production-bucket/.s3-inventory-index --root "$root"; done
```
Expected: median ≤ 100 ms for every root at 2560 × 1440 with 4 px² cells (the first run of `albums` may be slower while its 5.15 M sizes page in). Append the numbers to `docs/benchmarks.md`. If a root is over budget, profile: the two known hot spots are `childrenBySize` copies for directories with tens of thousands of children and `ownFiles` recomputation when the cache threshold does not cover the request.

- [ ] **Step 8: Report the changed files and numbers. Do not run git.**

### Task 17: Key search (starts-with, contains) and subtree aggregates; `lookup`

**Files:**
- Create: `Sources/InventoryIndex/KeySearch.swift`, `Sources/InventoryIndex/SubtreeAggregates.swift`
- Modify: `Sources/s3-inventory-tool/main.swift` (add `lookup`)
- Test: `Tests/InventoryIndexTests/KeySearchTests.swift`, `Tests/InventoryIndexTests/SubtreeAggregatesTests.swift`

**Interfaces:**
- Produces:
  - `struct SearchHit: Equatable` — `fileIndex: UInt64?`, `directoryId: UInt32`, `key: String` (directory hits end with `/`).
  - `final class KeySearch` — `init(reader: IndexReader)`, `func startsWith(_ query: String, limit: Int = 10_000) -> [SearchHit]`, `func contains(_ needle: String, limit: Int = 10_000, progress: @escaping (Double) -> Void, isCancelled: @escaping () -> Bool) -> [SearchHit]?` (nil when cancelled).
  - `struct ExtensionBreakdownEntry: Equatable { extensionId: UInt16; bytes: UInt64; files: UInt64 }`, `struct ExtensionBreakdown: Equatable { entries: [ExtensionBreakdownEntry] (top 20 by bytes); otherBytes; otherFiles; totalBytes; totalFiles }`, `struct AgeBreakdown: Equatable { bucketBytes: [UInt64] (8); bucketFiles: [UInt64] (8) }`.
  - `final class SubtreeAggregates` — `init(reader: IndexReader, cacheCapacity: Int = 64)`, `func extensionBreakdown(of directory: UInt32, isCancelled: () -> Bool) -> ExtensionBreakdown?`, `func ageBreakdown(of directory: UInt32, isCancelled: () -> Bool) -> AgeBreakdown?`, `static func ageBucket(ageDays: UInt64) -> Int`.
  - CLI: `s3-inventory-tool lookup <index folder> <key>` prints the file index, size, class, date, directory id.

- [ ] **Step 1: Write the failing tests**

`KeySearchTests.swift`:
```swift
import XCTest
import TestSupport
import InventoryImport
@testable import InventoryIndex

final class KeySearchTests: XCTestCase {
    private var folder: URL!
    private var reader: IndexReader!
    private let rows: [FixtureRow] = [
        FixtureRow(key: "assets/acc1/2025/photo-1.jpg", size: 1), FixtureRow(key: "assets/acc1/2025/photo-2.jpg", size: 2),
        FixtureRow(key: "assets/acc1/2026/photo-3.jpg", size: 3), FixtureRow(key: "assets/acc2/2025/video.mp4", size: 4),
        FixtureRow(key: "assets/accident.txt", size: 5), FixtureRow(key: "queue/a/b", size: 6), FixtureRow(key: "photo-root.jpg", size: 7),
        FixtureRow(key: "assets/acc1/2025/", size: 0),
    ]
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("search-\(UUID().uuidString)")
        try FixtureInventory.write(rows: rows, to: folder, fileCount: 2)
        let source = try InventorySource.load(folder: folder)
        _ = try ImportPipeline(source: source, outputFolder: IndexReader.indexFolder(forInventory: folder), progress: { _ in }).run()
        reader = try IndexReader(folder: IndexReader.indexFolder(forInventory: folder))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    func testStartsWith() {
        let search = KeySearch(reader: reader)
        XCTAssertEqual(search.startsWith("assets/acc").map { $0.key }.sorted(), ["assets/acc1/", "assets/acc2/", "assets/accident.txt"])
        XCTAssertEqual(search.startsWith("assets/acc1/2025/photo").map { $0.key }.sorted(), ["assets/acc1/2025/photo-1.jpg", "assets/acc1/2025/photo-2.jpg"])
        XCTAssertEqual(search.startsWith("assets/acc1/2025/").map { $0.key }.sorted(), ["assets/acc1/2025/", "assets/acc1/2025/photo-1.jpg", "assets/acc1/2025/photo-2.jpg"])
        XCTAssertEqual(search.startsWith("photo").map { $0.key }, ["photo-root.jpg"])
        XCTAssertEqual(search.startsWith("nope/x"), [])
        XCTAssertEqual(search.startsWith("").map { $0.key }.sorted(), ["assets/", "queue/", "photo-root.jpg"])
        XCTAssertEqual(search.startsWith("assets/acc", limit: 1).count, 1)
        let hit = search.startsWith("assets/acc2/2025/video.mp4")[0]
        XCTAssertEqual(hit.fileIndex.map { reader.key(ofFile: $0) }, "assets/acc2/2025/video.mp4")
        XCTAssertEqual(hit.directoryId, reader.directories.lookup(path: "assets/acc2/2025"))
    }

    func testContains() {
        let search = KeySearch(reader: reader)
        var progressValues: [Double] = []
        let hits = search.contains("photo", progress: { progressValues.append($0) }, isCancelled: { false })!
        XCTAssertEqual(hits.map { $0.key }.sorted(), ["assets/acc1/2025/photo-1.jpg", "assets/acc1/2025/photo-2.jpg", "assets/acc1/2026/photo-3.jpg", "photo-root.jpg"])
        XCTAssertEqual(search.contains("acc1", progress: { _ in }, isCancelled: { false })!.map { $0.key }.sorted(), ["assets/acc1/"])
        XCTAssertEqual(search.contains("2025", limit: 2, progress: { _ in }, isCancelled: { false })!.count, 2)
        XCTAssertNil(search.contains("photo", progress: { _ in }, isCancelled: { true }))
        XCTAssertEqual(progressValues.last, 1.0)
    }
}
```

`SubtreeAggregatesTests.swift`:
```swift
import XCTest
import TestSupport
import InventoryImport
@testable import InventoryIndex

final class SubtreeAggregatesTests: XCTestCase {
    private var folder: URL!
    private var reader: IndexReader!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("aggregates-\(UUID().uuidString)")
        var rows: [FixtureRow] = []
        for index in 0..<2000 {
            let extensionName = ["jpg", "mp4", "png", "pdf", "zip"][index % 5]
            let date = ["2025-12-20T00:00:00.000Z", "2025-10-01T00:00:00.000Z", "2025-05-01T00:00:00.000Z", "2024-06-01T00:00:00.000Z", "2020-01-01T00:00:00.000Z"][index % 5]
            rows.append(FixtureRow(key: "tree/\(index % 7)/file-\(index).\(extensionName)", size: UInt64(index + 1), lastModified: date))
        }
        rows.append(FixtureRow(key: "elsewhere/x.jpg", size: 999_999))
        try FixtureInventory.write(rows: rows, to: folder, fileCount: 3, creationTimestampMilliseconds: 1_767_225_600_000)   // 2026-01-01
        let source = try InventorySource.load(folder: folder)
        _ = try ImportPipeline(source: source, outputFolder: IndexReader.indexFolder(forInventory: folder), progress: { _ in }).run()
        reader = try IndexReader(folder: IndexReader.indexFolder(forInventory: folder))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    func testExtensionBreakdown() {
        let aggregates = SubtreeAggregates(reader: reader)
        let tree = reader.directories.lookup(path: "tree")!
        let breakdown = aggregates.extensionBreakdown(of: tree, isCancelled: { false })!
        XCTAssertEqual(breakdown.totalFiles, 2000)
        XCTAssertEqual(breakdown.totalBytes, (1...2000).reduce(0, +))
        XCTAssertEqual(breakdown.entries.count, 5)
        let names = breakdown.entries.map { reader.manifest.extensionNames[Int($0.extensionId)] }
        XCTAssertEqual(names.first, "zip", "index % 5 == 4 has the largest sizes")
        XCTAssertEqual(breakdown.entries.map { $0.files }, [400, 400, 400, 400, 400])
        XCTAssertEqual(breakdown.otherBytes, 0)
        XCTAssertNil(aggregates.extensionBreakdown(of: tree, isCancelled: { true }))
    }

    func testAgeBreakdown() {
        let aggregates = SubtreeAggregates(reader: reader)
        let tree = reader.directories.lookup(path: "tree")!
        let breakdown = aggregates.ageBreakdown(of: tree, isCancelled: { false })!
        XCTAssertEqual(breakdown.bucketFiles.reduce(0, +), 2000)
        XCTAssertEqual(breakdown.bucketFiles[0], 400)   // 12 days old  (< 30)
        XCTAssertEqual(breakdown.bucketFiles[2], 400)   // 92 days old  (< 180)
        XCTAssertEqual(breakdown.bucketFiles[3], 400)   // 245 days old (< 365)
        XCTAssertEqual(breakdown.bucketFiles[4], 400)   // 579 days old (< 730)
        XCTAssertEqual(breakdown.bucketFiles[7], 400)   // 2192 days old (older than 5 years)
        XCTAssertEqual(SubtreeAggregates.ageBucket(ageDays: 0), 0)
        XCTAssertEqual(SubtreeAggregates.ageBucket(ageDays: 30), 1)
        XCTAssertEqual(SubtreeAggregates.ageBucket(ageDays: 1825), 7)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter 'KeySearchTests|SubtreeAggregatesTests' 2>&1 | tail -5`
Expected: compile errors.

- [ ] **Step 3: Write `KeySearch.swift`**

```swift
import Foundation

public struct SearchHit: Equatable {
    public var fileIndex: UInt64?
    public var directoryId: UInt32
    public var key: String
}

public final class KeySearch {
    private let reader: IndexReader
    public init(reader: IndexReader) { self.reader = reader }

    /// Walks the tree to the directory named by everything before the last "/", then scans that directory's children and own files.
    public func startsWith(_ query: String, limit: Int = 10_000) -> [SearchHit] {
        let tree = reader.directories
        let lastSlash = query.lastIndex(of: "/")
        let directoryPath = lastSlash.map { String(query[..<$0]) } ?? ""
        let namePrefix = Array((lastSlash.map { String(query[query.index(after: $0)...]) } ?? query).utf8)
        guard let directory = tree.lookup(path: directoryPath) else { return [] }
        var hits: [SearchHit] = []
        let prefixPath = directory == IndexFormat.rootDirectory ? "" : tree.path(directory) + "/"
        for child in tree.childrenInKeyOrder(directory) where hits.count < limit {
            let matches = tree.withNameBytes(child) { $0.count >= namePrefix.count && $0.prefix(namePrefix.count).elementsEqual(namePrefix) }
            if matches { hits.append(SearchHit(fileIndex: nil, directoryId: child, key: prefixPath + tree.name(child) + "/")) }
        }
        for range in tree.ownFileRanges(directory) {
            var index = range.lowerBound
            while index < range.upperBound && hits.count < limit {
                let matches = reader.names.withName(ofFile: index) { $0.count >= namePrefix.count && $0.prefix(namePrefix.count).elementsEqual(namePrefix) }
                if matches { hits.append(SearchHit(fileIndex: index, directoryId: directory, key: prefixPath + reader.names.nameString(ofFile: index))) }
                index += 1
            }
        }
        return hits
    }

    /// Parallel scan over every name block and every directory name. Returns nil when cancelled.
    public func contains(_ needle: String, limit: Int = 10_000, progress: @escaping (Double) -> Void, isCancelled: @escaping () -> Bool) -> [SearchHit]? {
        let needleBytes = Array(needle.utf8)
        guard !needleBytes.isEmpty else { return [] }
        let tree = reader.directories
        let blockCount = reader.names.blockCount
        let workerCount = max(1, min(ProcessInfo.processInfo.activeProcessorCount, blockCount))
        let lock = NSLock()
        var fileHits: [UInt64] = []
        var blocksDone = 0
        var cancelled = false
        DispatchQueue.concurrentPerform(iterations: workerCount) { worker in
            var local: [UInt64] = []
            var block = worker
            while block < blockCount {
                if isCancelled() { lock.lock(); cancelled = true; lock.unlock(); return }
                lock.lock(); let enough = fileHits.count + local.count >= limit; lock.unlock()
                if enough { break }
                let decoded = reader.names.decodeBlockUncached(block)
                for position in 0..<decoded.nameCount {
                    let found = decoded.withName(at: position) { name in
                        name.count >= needleBytes.count && needleBytes.withUnsafeBufferPointer { memmem(name.baseAddress, name.count, $0.baseAddress, $0.count) != nil }
                    }
                    if found { local.append(UInt64(block * IndexFormat.namesPerBlock + position)) }
                }
                lock.lock()
                blocksDone += 1
                if blocksDone % 64 == 0 { let fraction = Double(blocksDone) / Double(max(blockCount, 1)); lock.unlock(); progress(fraction * 0.9); lock.lock() }
                lock.unlock()
                block += workerCount
            }
            lock.lock(); fileHits.append(contentsOf: local); lock.unlock()
        }
        if cancelled { return nil }
        var hits: [SearchHit] = []
        for directory in 1..<UInt32(tree.count) where hits.count < limit {
            if isCancelled() { return nil }
            let found = tree.withNameBytes(directory) { name in
                name.count >= needleBytes.count && needleBytes.withUnsafeBufferPointer { memmem(name.baseAddress, name.count, $0.baseAddress, $0.count) != nil }
            }
            if found { hits.append(SearchHit(fileIndex: nil, directoryId: directory, key: tree.path(directory) + "/")) }
        }
        for fileIndex in fileHits.sorted().prefix(max(0, limit - hits.count)) {
            hits.append(SearchHit(fileIndex: fileIndex, directoryId: reader.directory(ofFile: fileIndex), key: reader.key(ofFile: fileIndex)))
        }
        progress(1.0)
        return hits
    }
}
```

- [ ] **Step 4: Write `SubtreeAggregates.swift`**

```swift
import Foundation

public struct ExtensionBreakdownEntry: Equatable { public var extensionId: UInt16; public var bytes: UInt64; public var files: UInt64 }
public struct ExtensionBreakdown: Equatable {
    public var entries: [ExtensionBreakdownEntry]
    public var otherBytes: UInt64
    public var otherFiles: UInt64
    public var totalBytes: UInt64
    public var totalFiles: UInt64
}
public struct AgeBreakdown: Equatable { public var bucketBytes: [UInt64]; public var bucketFiles: [UInt64] }

public final class SubtreeAggregates {
    private let reader: IndexReader
    private let lock = NSLock()
    private var extensionCache: [UInt32: ExtensionBreakdown] = [:]
    private var ageCache: [UInt32: AgeBreakdown] = [:]
    private let cacheCapacity: Int

    public init(reader: IndexReader, cacheCapacity: Int = 64) { self.reader = reader; self.cacheCapacity = cacheCapacity }

    public static func ageBucket(ageDays: UInt64) -> Int {
        for (bucket, boundary) in IndexFormat.ageBucketDays.enumerated() where ageDays < UInt64(boundary) { return bucket }
        return IndexFormat.ageBucketDays.count
    }

    private func slices(for directory: UInt32) -> [Range<Int>] {
        let range = reader.directories.subtreeFileRange(directory)
        let count = Int(range.upperBound - range.lowerBound)
        let workers = max(1, min(ProcessInfo.processInfo.activeProcessorCount, count / 65_536 + 1))
        let sliceLength = count / workers + 1
        return (0..<workers).map { worker in
            let start = Int(range.lowerBound) + worker * sliceLength
            return start..<min(start + sliceLength, Int(range.upperBound))
        }.filter { !$0.isEmpty }
    }

    public func extensionBreakdown(of directory: UInt32, isCancelled: () -> Bool) -> ExtensionBreakdown? {
        lock.lock(); if let cached = extensionCache[directory] { lock.unlock(); return cached }; lock.unlock()
        let slices = slices(for: directory)
        let slotCount = 65_536
        var partialBytes = [[UInt64]](repeating: [], count: slices.count)
        var partialFiles = [[UInt64]](repeating: [], count: slices.count)
        var cancelled = false
        let sizes = reader.fileSize.buffer, extensions = reader.fileExtension.buffer
        let resultLock = NSLock()
        withoutActuallyEscaping(isCancelled) { isCancelled in
            DispatchQueue.concurrentPerform(iterations: slices.count) { sliceIndex in
                var bytes = [UInt64](repeating: 0, count: slotCount)
                var files = [UInt64](repeating: 0, count: slotCount)
                for index in slices[sliceIndex] {
                    if index & 0xFFFFF == 0 && isCancelled() { resultLock.lock(); cancelled = true; resultLock.unlock(); return }
                    let slot = Int(extensions[index])
                    bytes[slot] &+= sizes[index]
                    files[slot] += 1
                }
                resultLock.lock(); partialBytes[sliceIndex] = bytes; partialFiles[sliceIndex] = files; resultLock.unlock()
            }
        }
        if cancelled { return nil }
        var totalBytes = [UInt64](repeating: 0, count: slotCount), totalFiles = [UInt64](repeating: 0, count: slotCount)
        for (bytes, files) in zip(partialBytes, partialFiles) where !bytes.isEmpty {
            for slot in 0..<slotCount where files[slot] > 0 { totalBytes[slot] &+= bytes[slot]; totalFiles[slot] += files[slot] }
        }
        let entries = (0..<slotCount).filter { totalFiles[$0] > 0 }
            .map { ExtensionBreakdownEntry(extensionId: UInt16($0), bytes: totalBytes[$0], files: totalFiles[$0]) }
            .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.extensionId < $1.extensionId }
        let top = Array(entries.prefix(20))
        let rest = entries.dropFirst(20)
        let breakdown = ExtensionBreakdown(entries: top, otherBytes: rest.reduce(0) { $0 + $1.bytes }, otherFiles: rest.reduce(0) { $0 + $1.files },
                                           totalBytes: entries.reduce(0) { $0 + $1.bytes }, totalFiles: entries.reduce(0) { $0 + $1.files })
        store(&extensionCache, directory, breakdown)
        return breakdown
    }

    public func ageBreakdown(of directory: UInt32, isCancelled: () -> Bool) -> AgeBreakdown? {
        lock.lock(); if let cached = ageCache[directory] { lock.unlock(); return cached }; lock.unlock()
        let slices = slices(for: directory)
        let bucketCount = IndexFormat.ageBucketDays.count + 1
        var partial = [(bytes: [UInt64], files: [UInt64])](repeating: ([], []), count: slices.count)
        var cancelled = false
        let sizes = reader.fileSize.buffer, modified = reader.fileLastModified.buffer
        let inventoryTimestamp = reader.manifest.inventoryTimestamp
        let resultLock = NSLock()
        withoutActuallyEscaping(isCancelled) { isCancelled in
            DispatchQueue.concurrentPerform(iterations: slices.count) { sliceIndex in
                var bytes = [UInt64](repeating: 0, count: bucketCount), files = [UInt64](repeating: 0, count: bucketCount)
                for index in slices[sliceIndex] {
                    if index & 0xFFFFF == 0 && isCancelled() { resultLock.lock(); cancelled = true; resultLock.unlock(); return }
                    let time = modified[index]
                    let ageDays: UInt64 = (time == 0 || time >= inventoryTimestamp) ? 0 : UInt64(inventoryTimestamp - time) / 86_400
                    let bucket = SubtreeAggregates.ageBucket(ageDays: ageDays)
                    bytes[bucket] &+= sizes[index]; files[bucket] += 1
                }
                resultLock.lock(); partial[sliceIndex] = (bytes, files); resultLock.unlock()
            }
        }
        if cancelled { return nil }
        var breakdown = AgeBreakdown(bucketBytes: [UInt64](repeating: 0, count: bucketCount), bucketFiles: [UInt64](repeating: 0, count: bucketCount))
        for part in partial where !part.bytes.isEmpty {
            for bucket in 0..<bucketCount { breakdown.bucketBytes[bucket] &+= part.bytes[bucket]; breakdown.bucketFiles[bucket] += part.files[bucket] }
        }
        store(&ageCache, directory, breakdown)
        return breakdown
    }

    private func store<Value>(_ cache: inout [UInt32: Value], _ directory: UInt32, _ value: Value) {
        lock.lock()
        if cache.count >= cacheCapacity, let victim = cache.keys.first { cache.removeValue(forKey: victim) }
        cache[directory] = value
        lock.unlock()
    }
}
```

- [ ] **Step 5: Add `lookup` to `main.swift`**

```swift
func runLookup(_ options: CommandLineOptions) throws {
    guard options.positional.count == 2 else { usage() }
    let reader = try IndexReader(folder: URL(fileURLWithPath: options.positional[0]))
    let hits = KeySearch(reader: reader).startsWith(options.positional[1], limit: 20)
    for hit in hits {
        if let fileIndex = hit.fileIndex {
            let position = Int(fileIndex)
            print("file \(fileIndex) \(hit.key) size \(reader.fileSize[position]) class \(StorageClass.names[Int(reader.fileStorageClass[position])]) modified \(reader.fileLastModified[position]) directory \(hit.directoryId)")
        } else {
            print("directory \(hit.directoryId) \(hit.key) bytes \(reader.directories.subtreeBytes(hit.directoryId)) files \(reader.directories.subtreeFileCount(hit.directoryId))")
        }
    }
    if hits.isEmpty { print("no match") }
}
```
Add `case "lookup": try runLookup(options)` and the usage line.

- [ ] **Step 6: Run the tests, then try the search on the reference index**

Run: `swift test --filter 'KeySearchTests|SubtreeAggregatesTests' 2>&1 | tail -5` — expected 4 tests pass. Then `swift test 2>&1 | tail -3` for the whole suite.

Then, with a release build: `.build/release/s3-inventory-tool lookup ~/inventories/production-bucket/.s3-inventory-index "exports/bulk-collections/8_Reading"` — expected: the 2.24 GiB zip from the census appears. Record in `docs/benchmarks.md` the wall time of a `contains` scan by adding a temporary timing print around `KeySearch.contains` in `runLookup` for the needle `_encoded.mp4` (expected 10 to 20 s; ≥ 10,000 hits), then remove the temporary print.

- [ ] **Step 7: Report the changed files. Do not run git.**

---
## Phase 4 — The application

Every app task ends the same way: `make app` must print `** BUILD SUCCEEDED **`, the app must
launch, and the task's manual checklist must pass with a screenshot saved under
`docs/screenshots/`. Never run git.

### Task 18: Palette, Metal renderer, and the treemap view

**Files:**
- Create: `App/Sources/Treemap/TreemapPalette.swift`, `App/Sources/Treemap/TreemapRenderer.swift`
- Modify: `App/Sources/Treemap/Shaders.metal` (replace the placeholder), `App/Sources/Treemap/TreemapMetalView.swift` (replace), `App/Sources/AppDelegate.swift`

**Interfaces:**
- Consumes: `TreemapLayout.LayoutResult`, `TreemapInstance`, `LayoutHit`.
- Produces:
  - `enum ColorMode: Int { case storageClass = 0, fileExtension = 1, age = 2 }`.
  - `enum TreemapPalette` — `static let canvasBackground: NSColor`, `static let storageClassColors: [NSColor]` (8, spec order), `static let extensionColors: [NSColor]` (15), `static let extensionOtherColor`, `static let ageColors: [NSColor]` (8, new to old), `static func color(forStorageClass: Int) -> NSColor`, `static func simd(_ color: NSColor) -> SIMD4<Float>`.
  - `struct TreemapUniforms` (matches the Metal struct): `viewportSize: SIMD2<Float>`, `colorMode: UInt32`, `inventoryTimestamp: UInt32`, `hoveredInstance: Int32`, `selectedDirectoryStart: UInt32`, `selectedDirectoryEnd: UInt32`, `highlightCategory: Int32`, `padding: UInt32`.
  - `final class TreemapRenderer` — `init?(device: MTLDevice)`, `func update(result: LayoutResult?)`, `func update(extensionPaletteSlots: [UInt8])` (65,536 entries), `var colorMode`, `var inventoryTimestamp`, `var hoveredInstance: Int`, `var selectedRange: Range<UInt32>?`, `var highlightCategory: Int`, `var transitionScale: Float`, `var transitionTranslation: SIMD2<Float>`, `var transitionOpacity: Float`, `var previousResultOpacity: Float`, `func captureTransitionSource()`, `func draw(in view: MTKView)`.
  - `final class TreemapMetalView: MTKView` — `var onHover: ((LayoutHit?, CGPoint) -> Void)?`, `var onClick: ((LayoutHit?, NSEvent) -> Void)?`, `var onDoubleClick: ((LayoutHit?) -> Void)?`, `var onViewportChange: ((CGSize) -> Void)?`, `var result: LayoutResult?`, `var renderer: TreemapRenderer?`, `func setColorMode(_:)`, `func setSelection(_:)`, `func setHighlightCategory(_:)`, `func animateZoom(from rect: CGRect)`.
  - Device-pixel rule: the view converts point coordinates to backing-store pixels with `convertToBacking`, and `onViewportChange` reports backing-store pixels. Every layout request and hit test uses device pixels.

- [ ] **Step 1: Write `TreemapPalette.swift`**

```swift
import AppKit
import simd

public enum ColorMode: Int { case storageClass = 0, fileExtension = 1, age = 2 }

enum TreemapPalette {
    static let canvasBackground = NSColor(srgbRed: 0x16 / 255.0, green: 0x18 / 255.0, blue: 0x1D / 255.0, alpha: 1)

    /// Index = storage class id (spec section 9).
    static let storageClassColors: [NSColor] = [
        NSColor(srgbRed: 0x4C / 255.0, green: 0x8D / 255.0, blue: 0xFF / 255.0, alpha: 1),   // STANDARD blue
        NSColor(srgbRed: 0x2B / 255.0, green: 0xB5 / 255.0, blue: 0xA0 / 255.0, alpha: 1),   // STANDARD_IA teal
        NSColor(srgbRed: 0x5F / 255.0, green: 0xC9 / 255.0, blue: 0x6B / 255.0, alpha: 1),   // INTELLIGENT_TIERING green
        NSColor(srgbRed: 0x39 / 255.0, green: 0xC2 / 255.0, blue: 0xE0 / 255.0, alpha: 1),   // ONEZONE_IA cyan
        NSColor(srgbRed: 0xF2 / 255.0, green: 0xA9 / 255.0, blue: 0x3B / 255.0, alpha: 1),   // GLACIER_IR amber
        NSColor(srgbRed: 0xF0 / 255.0, green: 0x7A / 255.0, blue: 0x3C / 255.0, alpha: 1),   // GLACIER orange
        NSColor(srgbRed: 0x8B / 255.0, green: 0x6C / 255.0, blue: 0xF6 / 255.0, alpha: 1),   // DEEP_ARCHIVE violet
        NSColor(srgbRed: 0x8C / 255.0, green: 0x91 / 255.0, blue: 0x9B / 255.0, alpha: 1),   // OTHER grey
    ]

    static let extensionColors: [NSColor] = [
        "4C8DFF", "2BB5A0", "F2A93B", "8B6CF6", "5FC96B", "F0 7A3C".replacingOccurrences(of: " ", with: ""), "39C2E0", "E05C8A",
        "B5CF3B", "6C7BF6", "3BCFB0", "F0C93C", "9B6CD8", "5CA8E0", "D8734C",
    ].map { NSColor(hexString: $0) }
    static let extensionOtherColor = NSColor(srgbRed: 0x6A / 255.0, green: 0x6F / 255.0, blue: 0x79 / 255.0, alpha: 1)

    /// New to old, 8 buckets.
    static let ageColors: [NSColor] = ["FFD98C", "FFB45C", "F08A4C", "D96A5C", "B05070", "7E4080", "55357A", "33285C"].map { NSColor(hexString: $0) }

    static func color(forStorageClass identifier: Int) -> NSColor { storageClassColors[min(max(identifier, 0), storageClassColors.count - 1)] }

    static func simd(_ color: NSColor) -> SIMD4<Float> {
        let converted = color.usingColorSpace(.sRGB) ?? color
        return SIMD4<Float>(Float(converted.redComponent), Float(converted.greenComponent), Float(converted.blueComponent), 1)
    }
}

extension NSColor {
    convenience init(hexString: String) {
        var value: UInt64 = 0
        Scanner(string: hexString).scanHexInt64(&value)
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255.0, green: CGFloat((value >> 8) & 0xFF) / 255.0, blue: CGFloat(value & 0xFF) / 255.0, alpha: 1)
    }
}
```

Fix the sixth extension color to the literal `"F07A3C"` (the `replacingOccurrences` call above is a typo guard; write the plain string).

- [ ] **Step 2: Write `Shaders.metal`**

```metal
#include <metal_stdlib>
using namespace metal;

struct TreemapInstance {
    float x, y, width, height;
    float sxx, sx, syy, sy;
    uint directoryId;
    uint nodeReference;
    uint timeSeconds;
    ushort extensionId;
    uchar storageClassId;
    uchar kind;
};

struct TreemapUniforms {
    float2 viewportSize;
    uint colorMode;
    uint inventoryTimestamp;
    int hoveredInstance;
    uint selectedDirectoryStart;
    uint selectedDirectoryEnd;
    int highlightCategory;
    uint padding;
};

struct TransitionUniforms {
    float2 translation;
    float scale;
    float opacity;
};

struct VertexOut {
    float4 position [[position]];
    float2 localPosition;      // pixels inside the cell
    float2 globalPosition;     // pixels in the layout
    float4 baseColor;
    float shading;             // 1 = normal, >1 = hover brighten
    float dim;                 // 0 = full colour, 1 = fully desaturated
    float isRemainder;
    float sxx, sx, syy, sy;
    float2 cellSize;
};

static float4 colorForInstance(constant TreemapInstance &instance,
                               constant TreemapUniforms &uniforms,
                               constant float4 *storageClassColors,
                               constant float4 *extensionColors,
                               constant float4 *ageColors,
                               constant uchar *extensionSlots) {
    if (uniforms.colorMode == 0u) {
        return storageClassColors[min(uint(instance.storageClassId), 7u)];
    }
    if (uniforms.colorMode == 1u) {
        uchar slot = extensionSlots[instance.extensionId];
        return slot >= 15 ? extensionColors[15] : extensionColors[slot];
    }
    uint age = uniforms.inventoryTimestamp > instance.timeSeconds ? (uniforms.inventoryTimestamp - instance.timeSeconds) / 86400u : 0u;
    uint bucket = age < 30u ? 0u : age < 90u ? 1u : age < 180u ? 2u : age < 365u ? 3u : age < 730u ? 4u : age < 1095u ? 5u : age < 1825u ? 6u : 7u;
    return ageColors[bucket];
}

static int categoryOfInstance(constant TreemapInstance &instance, constant TreemapUniforms &uniforms, constant uchar *extensionSlots) {
    if (uniforms.colorMode == 0u) { return int(instance.storageClassId); }
    if (uniforms.colorMode == 1u) { return int(extensionSlots[instance.extensionId]); }
    uint age = uniforms.inventoryTimestamp > instance.timeSeconds ? (uniforms.inventoryTimestamp - instance.timeSeconds) / 86400u : 0u;
    return age < 30u ? 0 : age < 90u ? 1 : age < 180u ? 2 : age < 365u ? 3 : age < 730u ? 4 : age < 1095u ? 5 : age < 1825u ? 6 : 7;
}

vertex VertexOut treemapVertex(uint vertexIdentifier [[vertex_id]],
                               uint instanceIdentifier [[instance_id]],
                               constant TreemapInstance *instances [[buffer(0)]],
                               constant TreemapUniforms &uniforms [[buffer(1)]],
                               constant float4 *storageClassColors [[buffer(2)]],
                               constant float4 *extensionColors [[buffer(3)]],
                               constant float4 *ageColors [[buffer(4)]],
                               constant uchar *extensionSlots [[buffer(5)]],
                               constant TransitionUniforms &transition [[buffer(6)]]) {
    constant TreemapInstance &instance = instances[instanceIdentifier];
    float2 corner = float2((vertexIdentifier == 1 || vertexIdentifier == 2) ? 1.0 : 0.0,
                           (vertexIdentifier >= 2) ? 1.0 : 0.0);
    float2 cellSize = float2(instance.width, instance.height);
    float2 pixel = float2(instance.x, instance.y) + corner * cellSize;
    float2 transformed = pixel * transition.scale + transition.translation;
    float2 normalized = transformed / uniforms.viewportSize;

    VertexOut out;
    out.position = float4(normalized.x * 2.0 - 1.0, 1.0 - normalized.y * 2.0, 0.0, 1.0);
    out.localPosition = corner * cellSize;
    out.globalPosition = pixel;
    out.baseColor = colorForInstance(instance, uniforms, storageClassColors, extensionColors, ageColors, extensionSlots);
    out.baseColor.a = transition.opacity;
    out.shading = (int(instanceIdentifier) == uniforms.hoveredInstance) ? 1.35 : 1.0;

    float dim = 0.0;
    if (uniforms.selectedDirectoryEnd > uniforms.selectedDirectoryStart) {
        bool inside = instance.directoryId >= uniforms.selectedDirectoryStart && instance.directoryId < uniforms.selectedDirectoryEnd;
        dim = inside ? 0.0 : 0.55;
    }
    if (uniforms.highlightCategory >= 0 && categoryOfInstance(instance, uniforms, extensionSlots) != uniforms.highlightCategory) {
        dim = max(dim, 0.7);
    }
    out.dim = dim;
    out.isRemainder = (instance.kind == 2) ? 1.0 : 0.0;
    out.sxx = instance.sxx; out.sx = instance.sx; out.syy = instance.syy; out.sy = instance.sy;
    out.cellSize = cellSize;
    return out;
}

fragment float4 treemapFragment(VertexOut in [[stage_in]]) {
    float3 color = in.baseColor.rgb;

    if (in.isRemainder > 0.5) {
        float stripe = fract((in.globalPosition.x + in.globalPosition.y) * 0.125);
        float hatch = stripe < 0.5 ? 0.82 : 0.62;
        color *= hatch;
        float grey = dot(color, float3(0.299, 0.587, 0.114));
        color = mix(color, float3(grey), 0.45);
    } else {
        float nx = -(2.0 * in.sxx * in.localPosition.x + in.sx);
        float ny = -(2.0 * in.syy * in.localPosition.y + in.sy);
        float3 normal = normalize(float3(nx, ny, 1.0));
        float3 light = normalize(float3(-1.0, -1.0, 10.0));
        float lambert = max(dot(normal, light), 0.0);
        color *= (0.25 + 0.85 * lambert);
    }

    color *= in.shading;
    if (in.dim > 0.0) {
        float grey = dot(color, float3(0.299, 0.587, 0.114));
        color = mix(color, float3(grey * 0.55), in.dim);
    }
    // 1px separator: darken the outermost pixel ring of every cell.
    float edge = min(min(in.localPosition.x, in.localPosition.y),
                     min(in.cellSize.x - in.localPosition.x, in.cellSize.y - in.localPosition.y));
    if (edge < 1.0 && in.cellSize.x > 3.0 && in.cellSize.y > 3.0) { color *= 0.55; }

    return float4(clamp(color, 0.0, 1.0), in.baseColor.a);
}
```

- [ ] **Step 2b: Write the failing shader-contract test**

Add `Tests/TreemapLayoutTests/InstanceLayoutContractTests.swift`:

```swift
import XCTest
@testable import TreemapLayout

/// The Metal struct in App/Sources/Treemap/Shaders.metal must match TreemapInstance byte for byte.
final class InstanceLayoutContractTests: XCTestCase {
    func testFieldOffsets() {
        XCTAssertEqual(MemoryLayout<TreemapInstance>.stride, 48)
        XCTAssertEqual(MemoryLayout<TreemapInstance>.offset(of: \.x), 0)
        XCTAssertEqual(MemoryLayout<TreemapInstance>.offset(of: \.sxx), 16)
        XCTAssertEqual(MemoryLayout<TreemapInstance>.offset(of: \.directoryId), 32)
        XCTAssertEqual(MemoryLayout<TreemapInstance>.offset(of: \.nodeReference), 36)
        XCTAssertEqual(MemoryLayout<TreemapInstance>.offset(of: \.timeSeconds), 40)
        XCTAssertEqual(MemoryLayout<TreemapInstance>.offset(of: \.extensionId), 44)
        XCTAssertEqual(MemoryLayout<TreemapInstance>.offset(of: \.storageClassId), 46)
        XCTAssertEqual(MemoryLayout<TreemapInstance>.offset(of: \.kind), 47)
    }
}
```

Run: `swift test --filter InstanceLayoutContractTests` — expected PASS (the struct from Task 16 already has this layout). If an offset differs, fix `TreemapInstance` field order, not the test.

- [ ] **Step 3: Write `TreemapRenderer.swift`**

```swift
import MetalKit
import simd
import TreemapLayout

struct TreemapUniforms {
    var viewportSize: SIMD2<Float> = .zero
    var colorMode: UInt32 = 0
    var inventoryTimestamp: UInt32 = 0
    var hoveredInstance: Int32 = -1
    var selectedDirectoryStart: UInt32 = 0
    var selectedDirectoryEnd: UInt32 = 0
    var highlightCategory: Int32 = -1
    var padding: UInt32 = 0
}

struct TransitionUniforms {
    var translation: SIMD2<Float> = .zero
    var scale: Float = 1
    var opacity: Float = 1
}

final class TreemapRenderer {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var instanceBuffer: MTLBuffer?
    private var instanceCount = 0
    private var previousInstanceBuffer: MTLBuffer?
    private var previousInstanceCount = 0
    private let storageClassBuffer: MTLBuffer
    private let extensionColorBuffer: MTLBuffer
    private let ageColorBuffer: MTLBuffer
    private let extensionSlotBuffer: MTLBuffer

    var colorMode: ColorMode = .storageClass
    var inventoryTimestamp: UInt32 = 0
    var hoveredInstance: Int = -1
    var selectedRange: Range<UInt32>?
    var highlightCategory: Int = -1
    var transitionScale: Float = 1
    var transitionTranslation: SIMD2<Float> = .zero
    var transitionOpacity: Float = 1
    var previousResultOpacity: Float = 0

    init?(device: MTLDevice) {
        guard let commandQueue = device.makeCommandQueue(), let library = device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "treemapVertex"),
              let fragmentFunction = library.makeFunction(name: "treemapFragment") else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        self.device = device
        self.commandQueue = commandQueue
        self.pipeline = pipeline
        func colorBuffer(_ colors: [NSColor]) -> MTLBuffer {
            var values = colors.map { TreemapPalette.simd($0) }
            return device.makeBuffer(bytes: &values, length: MemoryLayout<SIMD4<Float>>.stride * values.count, options: .storageModeManaged)!
        }
        storageClassBuffer = colorBuffer(TreemapPalette.storageClassColors)
        extensionColorBuffer = colorBuffer(TreemapPalette.extensionColors + [TreemapPalette.extensionOtherColor])
        ageColorBuffer = colorBuffer(TreemapPalette.ageColors)
        extensionSlotBuffer = device.makeBuffer(length: 65_536, options: .storageModeManaged)!
        memset(extensionSlotBuffer.contents(), 15, 65_536)
        extensionSlotBuffer.didModifyRange(0..<65_536)
    }

    func update(extensionPaletteSlots slots: [UInt8]) {
        precondition(slots.count == 65_536)
        slots.withUnsafeBytes { extensionSlotBuffer.contents().copyMemory(from: $0.baseAddress!, byteCount: 65_536) }
        extensionSlotBuffer.didModifyRange(0..<65_536)
    }

    func captureTransitionSource() {
        previousInstanceBuffer = instanceBuffer
        previousInstanceCount = instanceCount
    }

    func update(result: LayoutResult?) {
        guard let result, !result.instances.isEmpty else { instanceBuffer = nil; instanceCount = 0; return }
        let length = MemoryLayout<TreemapInstance>.stride * result.instances.count
        if instanceBuffer == nil || instanceBuffer!.length < length {
            instanceBuffer = device.makeBuffer(length: max(length, 1 << 20), options: .storageModeManaged)
        }
        result.instances.withUnsafeBytes { instanceBuffer!.contents().copyMemory(from: $0.baseAddress!, byteCount: length) }
        instanceBuffer!.didModifyRange(0..<length)
        instanceCount = result.instances.count
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable, let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        let size = view.drawableSize
        var uniforms = TreemapUniforms(viewportSize: SIMD2<Float>(Float(size.width), Float(size.height)), colorMode: UInt32(colorMode.rawValue),
                                       inventoryTimestamp: inventoryTimestamp, hoveredInstance: Int32(hoveredInstance),
                                       selectedDirectoryStart: selectedRange?.lowerBound ?? 0, selectedDirectoryEnd: selectedRange?.upperBound ?? 0,
                                       highlightCategory: Int32(highlightCategory))
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<TreemapUniforms>.stride, index: 1)
        encoder.setVertexBuffer(storageClassBuffer, offset: 0, index: 2)
        encoder.setVertexBuffer(extensionColorBuffer, offset: 0, index: 3)
        encoder.setVertexBuffer(ageColorBuffer, offset: 0, index: 4)
        encoder.setVertexBuffer(extensionSlotBuffer, offset: 0, index: 5)

        if previousResultOpacity > 0, let previous = previousInstanceBuffer, previousInstanceCount > 0 {
            var transition = TransitionUniforms(translation: transitionTranslation, scale: transitionScale, opacity: previousResultOpacity)
            var previousUniforms = uniforms
            previousUniforms.hoveredInstance = -1
            encoder.setVertexBytes(&previousUniforms, length: MemoryLayout<TreemapUniforms>.stride, index: 1)
            encoder.setVertexBuffer(previous, offset: 0, index: 0)
            encoder.setVertexBytes(&transition, length: MemoryLayout<TransitionUniforms>.stride, index: 6)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: previousInstanceCount)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<TreemapUniforms>.stride, index: 1)
        }

        if let buffer = instanceBuffer, instanceCount > 0 {
            var transition = TransitionUniforms(translation: .zero, scale: 1, opacity: transitionOpacity)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&transition, length: MemoryLayout<TransitionUniforms>.stride, index: 6)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: instanceCount)
        }
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
```

Note: the vertex shader maps `vertexIdentifier` 0,1,2,3 to corners (0,0), (1,0), (1,1), (0,1). A
`triangleStrip` needs the order (0,0), (1,0), (0,1), (1,1). Write the corner expression as
`float2(vertexIdentifier & 1u, (vertexIdentifier >> 1) & 1u)` and keep `triangleStrip`; that gives
(0,0), (1,0), (0,1), (1,1) which is the correct strip order. Change the `Shaders.metal` corner line
accordingly.

- [ ] **Step 4: Replace `TreemapMetalView.swift`**

```swift
import MetalKit
import TreemapLayout

final class TreemapMetalView: MTKView {
    var onHover: ((LayoutHit?, CGPoint) -> Void)?
    var onClick: ((LayoutHit?, NSEvent) -> Void)?
    var onDoubleClick: ((LayoutHit?) -> Void)?
    var onViewportChange: ((CGSize) -> Void)?

    private(set) var renderer: TreemapRenderer?
    private var trackingArea: NSTrackingArea?
    private var lastHoveredInstance = -1
    private var transitionStart: CFTimeInterval = 0
    private var transitionSourceRect: CGRect?
    private var displayLink: CVDisplayLink?

    var result: LayoutResult? {
        didSet {
            renderer?.update(result: result)
            needsDisplay = true
        }
    }

    override init(frame frameRect: CGRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device ?? MTLCreateSystemDefaultDevice())
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: Double(TreemapPalette.canvasBackground.redComponent), green: Double(TreemapPalette.canvasBackground.greenComponent),
                                   blue: Double(TreemapPalette.canvasBackground.blueComponent), alpha: 1)
        isPaused = true
        enableSetNeedsDisplay = true
        autoresizingMask = [.width, .height]
        if let device = self.device { renderer = TreemapRenderer(device: device) }
    }

    required init(coder: NSCoder) { fatalError("not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTrackingAreas()
        reportViewport()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        reportViewport()
    }

    private func reportViewport() {
        let backing = convertToBacking(bounds).size
        guard backing.width > 0, backing.height > 0 else { return }
        onViewportChange?(backing)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    /// Converts a point event into layout (device pixel, top-left origin) coordinates.
    private func layoutPoint(_ event: NSEvent) -> CGPoint {
        let inView = convert(event.locationInWindow, from: nil)
        let flipped = CGPoint(x: inView.x, y: bounds.height - inView.y)
        let backing = convertToBacking(flipped)
        return CGPoint(x: backing.x, y: backing.y)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = layoutPoint(event)
        let hit = result?.hitTest(x: point.x, y: point.y)
        let instance: Int
        switch hit {
        case .file(_, let index, _), .remainder(_, let index, _, _): instance = index
        case .directory(_, let index): instance = index ?? -1
        case nil: instance = -1
        }
        if instance != lastHoveredInstance {
            lastHoveredInstance = instance
            renderer?.hoveredInstance = instance
            needsDisplay = true
        }
        onHover?(hit, convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        lastHoveredInstance = -1
        renderer?.hoveredInstance = -1
        needsDisplay = true
        onHover?(nil, .zero)
    }

    override func mouseDown(with event: NSEvent) {
        let point = layoutPoint(event)
        let hit = result?.hitTest(x: point.x, y: point.y)
        if event.clickCount >= 2 { onDoubleClick?(hit) } else { onClick?(hit, event) }
    }

    func setColorMode(_ mode: ColorMode) { renderer?.colorMode = mode; needsDisplay = true }
    func setSelection(_ range: Range<UInt32>?) { renderer?.selectedRange = range; needsDisplay = true }
    func setHighlightCategory(_ category: Int) { renderer?.highlightCategory = category; needsDisplay = true }

    /// Scales the previous layout out of `rect` while the new one fades in (180 ms).
    func animateZoom(from rect: CGRect) {
        guard let renderer else { return }
        renderer.captureTransitionSource()
        transitionSourceRect = rect
        transitionStart = CACurrentMediaTime()
        renderer.previousResultOpacity = 1
        renderer.transitionOpacity = 0
        startTransitionTimer()
    }

    private func startTransitionTimer() {
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self, let renderer = self.renderer, let sourceRect = self.transitionSourceRect else { timer.invalidate(); return }
            let elapsed = CACurrentMediaTime() - self.transitionStart
            let fraction = min(elapsed / 0.18, 1.0)
            let eased = Float(1 - pow(1 - fraction, 3))
            let backing = self.convertToBacking(self.bounds).size
            let targetScaleX = Float(backing.width / max(sourceRect.width, 1))
            let targetScaleY = Float(backing.height / max(sourceRect.height, 1))
            let scale = 1 + (min(targetScaleX, targetScaleY) - 1) * eased
            renderer.transitionScale = scale
            renderer.transitionTranslation = SIMD2<Float>(-Float(sourceRect.origin.x) * scale * eased, -Float(sourceRect.origin.y) * scale * eased)
            renderer.previousResultOpacity = 1 - eased
            renderer.transitionOpacity = eased
            self.needsDisplay = true
            if fraction >= 1 {
                renderer.previousResultOpacity = 0
                renderer.transitionOpacity = 1
                renderer.transitionScale = 1
                renderer.transitionTranslation = .zero
                self.transitionSourceRect = nil
                timer.invalidate()
                self.needsDisplay = true
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) { renderer?.draw(in: self) }
}
```

- [ ] **Step 5: Wire a temporary demo into `AppDelegate`**

Replace `applicationDidFinishLaunching` so it opens the reference index when it exists, builds a
layout, and shows it; otherwise it shows the empty canvas. This demo code is replaced in Task 23.

```swift
import AppKit
import MetalKit
import InventoryIndex
import TreemapLayout

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var reader: IndexReader?
    private var engine: TreemapLayoutEngine?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "S3 Inventory Visualizer"
        let view = TreemapMetalView(frame: window.contentRect(forFrameRect: window.frame), device: MTLCreateSystemDefaultDevice())
        window.contentView = view
        let indexFolder = URL(fileURLWithPath: "~/inventories/production-bucket/.s3-inventory-index")
        if let reader = try? IndexReader(folder: indexFolder) {
            self.reader = reader
            let engine = TreemapLayoutEngine(dataSource: IndexLayoutDataSource(reader: reader, ownFilesCache: OwnFilesCache(reader: reader)))
            self.engine = engine
            view.renderer?.inventoryTimestamp = reader.manifest.inventoryTimestamp
            var slots = [UInt8](repeating: 15, count: 65_536)
            for (position, identifier) in reader.manifest.extensionPalette.enumerated() where position < 15 { slots[Int(identifier)] = UInt8(position) }
            view.renderer?.update(extensionPaletteSlots: slots)
            view.onViewportChange = { [weak view] size in
                guard let view else { return }
                view.result = engine.layout(LayoutRequest(rootDirectory: IndexFormat.rootDirectory, width: size.width, height: size.height, minimumCellArea: 4))
            }
            view.onHover = { hit, _ in
                guard let hit else { window.subtitle = ""; return }
                switch hit {
                case .file(let fileIndex, _, _): window.subtitle = reader.key(ofFile: fileIndex)
                case .directory(let id, _): window.subtitle = reader.directories.path(id) + "/"
                case .remainder(_, _, let items, let bytes): window.subtitle = "\(formatCount(items)) more items, \(formatByteCount(bytes, units: .binary))"
                }
            }
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
```

- [ ] **Step 6: Build, launch, and check the treemap**

Run: `swift test 2>&1 | tail -3 && make app` — expected all tests pass and `** BUILD SUCCEEDED **`.

Launch: `open "App/build/Build/Products/Release/S3 Inventory Visualizer.app"`.

Manual checklist:
1. The treemap fills the window with cushion-shaded rectangles.
2. Moving the mouse changes the window subtitle to the key under the cursor.
3. The hovered cell brightens.
4. Resizing the window relayouts and stays smooth.
5. Idle CPU in Activity Monitor is near 0 %.

Screenshot: `screencapture -x docs/screenshots/task18-treemap.png`. Append the first-paint time to `docs/benchmarks.md`.

- [ ] **Step 7: Report the changed files. Do not run git.**

### Task 19: Breadcrumb, legend, label overlay, and navigation history

**Files:**
- Create: `App/Sources/Treemap/BreadcrumbView.swift`, `App/Sources/Treemap/LegendView.swift`, `App/Sources/Treemap/LabelOverlayView.swift`, `App/Sources/Window/NavigationHistory.swift`
- Test: `Tests/InventoryIndexTests/NavigationHistoryTests.swift` (the type lives in the app, so copy it into `Sources/InventoryIndex/NavigationHistory.swift` instead and have the app import it)

**Decision:** put `NavigationHistory` in `InventoryIndex` so it is unit-testable; the app imports it.

**Interfaces:**
- Produces:
  - `final class NavigationHistory` (in `InventoryIndex`) — `init(root: UInt32)`, `var current: UInt32`, `var canGoBack: Bool`, `var canGoForward: Bool`, `func navigate(to: UInt32)`, `func goBack() -> UInt32?`, `func goForward() -> UInt32?`, `func reset(to: UInt32)`.
  - `final class BreadcrumbView: NSView` — `var onSelect: ((UInt32) -> Void)?`, `func update(path: [(id: UInt32, name: String)])`, `var canGoBack/canGoForward/canGoUp: Bool`, `var onBack/onForward/onUp: (() -> Void)?`.
  - `struct LegendEntry { color: NSColor; label: String; bytes: UInt64; category: Int }`; `final class LegendView: NSView` — `var onSelect: ((Int?) -> Void)?`, `func update(entries: [LegendEntry], totalBytes: UInt64, units: ByteUnits)`, `var highlighted: Int?`.
  - `final class LabelOverlayView: NSView` — `func update(labels: [LayoutLabel], scale: CGFloat)` (scale converts device pixels to points), hit-transparent (`hitTest` returns nil).

- [ ] **Step 1: Write `NavigationHistory.swift` in `Sources/InventoryIndex/` and its test**

```swift
import Foundation

public final class NavigationHistory {
    private var entries: [UInt32]
    private var position: Int

    public init(root: UInt32) { entries = [root]; position = 0 }
    public var current: UInt32 { entries[position] }
    public var canGoBack: Bool { position > 0 }
    public var canGoForward: Bool { position + 1 < entries.count }

    public func navigate(to directory: UInt32) {
        guard directory != current else { return }
        entries.removeSubrange((position + 1)...)
        entries.append(directory)
        position = entries.count - 1
    }
    public func goBack() -> UInt32? { guard canGoBack else { return nil }; position -= 1; return current }
    public func goForward() -> UInt32? { guard canGoForward else { return nil }; position += 1; return current }
    public func reset(to root: UInt32) { entries = [root]; position = 0 }
}
```

Test (`Tests/InventoryIndexTests/NavigationHistoryTests.swift`):

```swift
import XCTest
@testable import InventoryIndex

final class NavigationHistoryTests: XCTestCase {
    func testBackForwardAndTruncation() {
        let history = NavigationHistory(root: 0)
        XCTAssertFalse(history.canGoBack)
        history.navigate(to: 5); history.navigate(to: 9)
        XCTAssertEqual(history.current, 9)
        XCTAssertEqual(history.goBack(), 5)
        XCTAssertEqual(history.goBack(), 0)
        XCTAssertNil(history.goBack())
        XCTAssertEqual(history.goForward(), 5)
        history.navigate(to: 7)                   // truncates the forward entries
        XCTAssertFalse(history.canGoForward)
        XCTAssertEqual(history.goBack(), 5)
        history.navigate(to: 5)                   // navigating to the current entry is a no-op
        XCTAssertEqual(history.current, 5)
        history.reset(to: 0)
        XCTAssertFalse(history.canGoBack)
    }
}
```

Run: `swift test --filter NavigationHistoryTests` — write the test first, watch it fail, then add the type.

- [ ] **Step 2: Write `BreadcrumbView.swift`**

An `NSView` with a left group of three square `NSButton`s (`chevron.backward`, `chevron.forward`,
`arrow.up`, SF Symbols via `NSImage(systemSymbolName:accessibilityDescription:)`) and a horizontal
`NSStackView` of chip buttons inside an `NSScrollView`. Each chip is a bordered-less `NSButton`
with `bezelStyle = .inline`, title = the segment name (`"(root)"` for id 0), tag = the directory id,
target = self. A `"›"` text field separates chips. When the total chip width is larger than the
view, hide the middle chips and insert one `"…"` chip whose menu lists the hidden segments. Height
is 38 points. Background `NSColor(white: 0.10, alpha: 1)` with a 1 px bottom separator.

- [ ] **Step 3: Write `LegendView.swift`**

A 34-point-high `NSView` with a horizontal `NSStackView` of entries. Each entry is a small view: a
12 × 12 rounded swatch, the label in `NSFont.systemFont(ofSize: 11)`, and the byte string in
`NSColor.secondaryLabelColor`. Clicking an entry calls `onSelect(category)`; clicking the
highlighted entry again calls `onSelect(nil)`. The highlighted entry draws a 1 px border. Entries
that hold under 0.05 % of the bytes are dropped. `update` sorts by bytes descending.

- [ ] **Step 4: Write `LabelOverlayView.swift`**

```swift
import AppKit
import TreemapLayout

final class LabelOverlayView: NSView {
    private var labels: [LayoutLabel] = []
    private var scale: CGFloat = 1

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(labels: [LayoutLabel], scale: CGFloat) {
        self.labels = labels
        self.scale = scale
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !labels.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92),
        ]
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.8)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        var shadowed = attributes
        shadowed[.shadow] = shadow
        for label in labels {
            let rect = NSRect(x: label.rect.x / scale + 4, y: label.rect.y / scale + 2,
                              width: max(label.rect.width / scale - 8, 0), height: 14)
            guard rect.width > 20, rect.intersects(dirtyRect) else { continue }
            let text = label.text.isEmpty ? "(root)" : label.text
            (text as NSString).draw(with: rect, options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin], attributes: shadowed)
        }
    }
}
```

- [ ] **Step 5: Build and check**

Run: `swift test 2>&1 | tail -3 && make app`. The views are not wired into a window until Task 20;
this step only proves they compile.

- [ ] **Step 6: Report the changed files. Do not run git.**

### Task 20: Treemap view controller — layout on a background queue, zoom, color modes, tooltip

**Files:**
- Create: `App/Sources/Treemap/TreemapViewController.swift`, `App/Sources/Support/Preferences.swift`
- Modify: `App/Sources/AppDelegate.swift` (host the controller instead of the raw view)

**Interfaces:**
- Produces:
  - `enum Preferences` — `static var units: ByteUnits`, `static var minimumCellArea: Double`, `static var colorMode: ColorMode`, all backed by `UserDefaults.standard` with the spec defaults (binary, 4, storage class).
  - `protocol TreemapViewControllerDelegate: AnyObject` — `func treemapDidSelect(directory: UInt32, file: UInt64?)`, `func treemapDidChangeRoot(_ directory: UInt32)`, `func treemapDidHover(description: String?)`.
  - `final class TreemapViewController: NSViewController` — `init(reader: IndexReader, engine: TreemapLayoutEngine, ownFilesCache: OwnFilesCache)`, `weak var delegate`, `var root: UInt32 { get }`, `func setRoot(_ directory: UInt32, animated: Bool)`, `func select(directory: UInt32, file: UInt64?)`, `func setColorMode(_:)`, `func setMinimumCellArea(_:)`, `func goBack()`, `func goForward()`, `func goUp()`, `var canGoBack/canGoForward/canGoUp: Bool`, `func refreshLegend()`.
  - Layout runs on a serial `DispatchQueue(label: "treemap.layout", qos: .userInitiated)`. Each request carries a generation number; a result whose generation is stale is dropped. While a layout is in flight the view keeps drawing the previous result, and a 250 ms timer shows a small progress spinner in the top-right corner.

- [ ] **Step 1: Write `Preferences.swift`**

```swift
import Foundation
import InventoryIndex

enum Preferences {
    private static let defaults = UserDefaults.standard
    static var units: ByteUnits {
        get { ByteUnits(rawValue: defaults.string(forKey: "units") ?? "") ?? .binary }
        set { defaults.set(newValue.rawValue, forKey: "units") }
    }
    static var minimumCellArea: Double {
        get { let value = defaults.double(forKey: "minimumCellArea"); return value >= 1 ? value : 4 }
        set { defaults.set(newValue, forKey: "minimumCellArea") }
    }
    static var colorMode: ColorMode {
        get { ColorMode(rawValue: defaults.integer(forKey: "colorMode")) ?? .storageClass }
        set { defaults.set(newValue.rawValue, forKey: "colorMode") }
    }
}
```

- [ ] **Step 2: Write `TreemapViewController.swift`**

Structure:
- `loadView()` builds a container `NSView`; adds `BreadcrumbView` pinned to the top, `LegendView`
  pinned to the bottom, `TreemapMetalView` filling the middle, `LabelOverlayView` on top of the
  metal view with the same frame, and a one-line status `NSTextField` above the legend.
- `viewDidLayout()` reads `metalView.convertToBacking(metalView.bounds).size` and requests a layout
  when the size changed by more than half a pixel.
- `requestLayout(root:animated:)` increments `generation`, captures the values it needs, and
  dispatches to the layout queue. The completion hops to the main queue, drops stale generations,
  assigns `metalView.result`, updates the label overlay with `scale = backingScaleFactor`, updates
  the breadcrumb from the reader's path, and refreshes the legend.
- The legend for `.storageClass` uses `reader.directories.bytesByStorageClass(root)` (instant). For
  `.fileExtension` and `.age` it asks `SubtreeAggregates` on a background queue with the current
  generation and a cancellation flag, showing the previous legend until the answer arrives.
- Hover updates the status line: for a file the full key plus size and class; for a directory the
  path plus totals; for a remainder the item count and bytes. It also calls the delegate.
- Single click selects: `metalView.setSelection(reader.directories.subtreeRange(directory))` and the
  delegate call. Double click on a directory calls `setRoot(_:animated: true)` after capturing the
  clicked rect for the zoom animation. Double click on a file selects it.
- `setRoot` pushes to `NavigationHistory` and re-requests a layout.
- Keyboard: `keyDown` handles Return (zoom into the selection), Escape (clear the selection).

Write it with `weak self` in every closure and no work on the main queue beyond assigning buffers.

- [ ] **Step 3: Host it from `AppDelegate` (temporary until Task 23)**

Replace the window's content view with `TreemapViewController(...).view` and keep the hardcoded
reference index path.

- [ ] **Step 4: Build, launch, check**

Run: `swift test 2>&1 | tail -3 && make app && open "App/build/Build/Products/Release/S3 Inventory Visualizer.app"`.

Manual checklist:
1. The breadcrumb shows `(root)`; the legend shows the storage classes with byte totals.
2. Hovering shows the full key in the status line within one frame.
3. Double-clicking a large prefix zooms with a short animation; the breadcrumb grows a chip.
4. Clicking a breadcrumb chip returns to that level.
5. The Back and Forward buttons work.
6. Switching the color mode through the temporary menu (add Cmd+1/2/3 in `keyDown` for now)
   recolors in one frame with no relayout pause.
7. Clicking a legend entry dims everything else; clicking it again clears.
8. Idle CPU is near 0 %.

Screenshot each color mode: `docs/screenshots/task20-class.png`, `task20-extension.png`, `task20-age.png`.

- [ ] **Step 5: Report the changed files. Do not run git.**

### Task 21: Directory outline view and details panel

**Files:**
- Create: `App/Sources/Tree/DirectoryOutlineItem.swift`, `App/Sources/Tree/DirectoryOutlineViewController.swift`, `App/Sources/Tree/ClassMixBarView.swift`, `App/Sources/Details/DetailsViewController.swift`

**Interfaces:**
- Produces:
  - `final class DirectoryOutlineItem: NSObject` — `enum Kind { case directory(UInt32), filesGroup(UInt32), file(UInt64, UInt32), moreFiles(UInt32, remaining: UInt64) }`, `kind`, `cachedChildren: [DirectoryOutlineItem]?`.
  - `protocol DirectoryOutlineDelegate: AnyObject` — `func outlineDidSelect(directory: UInt32, file: UInt64?)`, `func outlineDidActivate(directory: UInt32)`.
  - `final class DirectoryOutlineViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate` — `init(reader:ownFilesCache:)`, `weak var delegate`, `func reveal(directory: UInt32, file: UInt64?)`, `func setRoot(_ directory: UInt32)`.
  - `final class ClassMixBarView: NSView` — `var bytesByStorageClass: [UInt64]`.
  - `final class DetailsViewController: NSViewController` — `init(reader:aggregates:)`, `func show(directory: UInt32)`, `func show(file: UInt64, directory: UInt32)`, `func showNothing()`, `var onCopyKey: ((String) -> Void)?`.

Rules:
- The outline is lazy: `outlineView(_:numberOfChildrenOfItem:)` answers from `childCount` plus one
  "Files (N)" row when `ownFileCount > 0`; children are built only when the row expands, and the
  built array is cached on the item.
- The "Files (N)" group expands to at most 100 rows from `ownFilesCache.largestOwnFiles(of:count: 100)`
  plus a "… N more" row when more exist. The "more" row is not selectable.
- Columns: Name (outline column, 260 wide), Size (right aligned, 90), % of parent (a 60-wide bar
  cell drawn with `NSBezierPath`), Items (right aligned, 90), Class mix (`ClassMixBarView`, 90).
- `reveal` walks the parent chain, expands each ancestor, then selects and scrolls to the row. It
  must not expand more than 12 levels.
- Details shows what the spec section 10 lists. Extension and age breakdowns run on a background
  queue with a spinner and a Cancel button; the `isCancelled` closure reads an atomic flag that the
  Cancel button and any new selection set.

- [ ] **Step 1: Write the four files**

- [ ] **Step 2: Build and check**

Manual checklist (after Task 22 wires them into the split view, so this step only compiles):
run `make app` and expect `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Report the changed files. Do not run git.**

### Task 22: Main window — split view, toolbar, menus, keyboard, search panel

**Files:**
- Create: `App/Sources/Window/MainSplitViewController.swift`, `App/Sources/Window/MainWindowController.swift`, `App/Sources/Search/SearchPanelController.swift`
- Modify: `App/Sources/AppDelegate.swift` (menus)

**Interfaces:**
- Produces:
  - `final class MainSplitViewController: NSSplitViewController` — `init(reader: IndexReader)`, owns `DirectoryOutlineViewController` (left, 300 wide, min 200, collapsible), `TreemapViewController` (center), `DetailsViewController` (right, 300 wide, min 240, collapsible); implements both delegate protocols so a selection in one pane updates the others without a loop (guard with an `isSynchronizing` flag).
  - `final class MainWindowController: NSWindowController, NSToolbarDelegate` — `init(reader: IndexReader, inventoryFolder: URL)`, builds the toolbar (back/forward/up, a segmented color-mode control, a units popup, a minimum-cell-area popup, a search field), title = the bucket name, subtitle = "N files · X TiB" plus " · partial index" when the manifest is partial.
  - `final class SearchPanelController: NSWindowController` — `init(reader: IndexReader)`, a panel with a search field, a "Starts with"/"Contains" segmented control, a results `NSTableView` (key, size, class), a progress bar with a Cancel button, and `var onChoose: ((SearchHit) -> Void)?`.
- Menus (built in code in `AppDelegate.applicationDidFinishLaunching`): App, File (Open… Cmd+O, Open Recent, Rebuild Index… , Close Cmd+W), Edit (Copy Cmd+C), View (Back Cmd+[, Forward Cmd+], Up Cmd+↑, Zoom In Return, Clear Selection Esc, Color by Storage Class Cmd+1 / Extension Cmd+2 / Age Cmd+3, Toggle Sidebar, Toggle Details), Find (Find… Cmd+F), Window, Help.

- [ ] **Step 1: Write the three files and the menu builder**

- [ ] **Step 2: Build, launch, and run the full checklist**

Run: `swift test 2>&1 | tail -3 && make app && open "App/build/Build/Products/Release/S3 Inventory Visualizer.app"`.

Manual checklist:
1. Three panes appear; the sidebar and details collapse and restore.
2. Selecting a directory in the tree highlights its subtree in the treemap and fills the details.
3. Clicking a file in the treemap reveals it in the tree and shows its key in the details.
4. Copy key (Cmd+C) puts the key on the clipboard.
5. Cmd+F opens the search panel; "Starts with" on `assets/a1b2c3d4e5f60718293a4b5c/2025` returns
   results immediately; "Contains" on `_encoded.mp4` shows a progress bar, finishes, and choosing a
   result zooms the treemap to that directory.
6. The toolbar color-mode control matches the Cmd+1/2/3 shortcuts.
7. The minimum-cell-area popup changes the detail level and relayouts.
8. The window title shows the bucket, the subtitle shows the totals.

Screenshot: `docs/screenshots/task22-main-window.png` and `task22-search.png`.

- [ ] **Step 3: Report the changed files. Do not run git.**

### Task 23: Document-based open and the import sheet

**Files:**
- Create: `App/Sources/Document/InventoryDocument.swift`, `App/Sources/Document/InventoryDocumentController.swift`, `App/Sources/Import/ImportSheetController.swift`
- Modify: `App/Sources/AppDelegate.swift` (remove the hardcoded demo; install the document controller)

**Interfaces:**
- Produces:
  - `final class InventoryDocument: NSDocument` — `var reader: IndexReader?`, `var inventoryFolder: URL?`, `override func read(from url: URL, ofType: String) throws` (validates the folder and checks the index), `override func makeWindowControllers()`, `func rebuildIndex()`.
  - `final class InventoryDocumentController: NSDocumentController` — `override func runModalOpenPanel(_:forTypes:)` configures the panel for directories only (`canChooseDirectories = true`, `canChooseFiles = false`).
  - `final class ImportSheetController: NSWindowController` — `init(source: InventorySource, outputFolder: URL, force: Bool)`, `func beginSheet(on window: NSWindow, completion: @escaping (Result<IndexManifest, Error>) -> Void)`, shows file count, compressed size, a progress bar, rows per second, elapsed and ETA, with Start and Cancel.

Open flow:
1. The user picks a folder. `InventorySource.load` runs; a failure shows an alert naming the problem.
2. `IndexReader.indexFolder(forInventory:)` is checked. When `index.json` exists and its
   `source.manifestMD5` (or, without a manifest, `manifestFileCount` plus `manifestTotalBytes`)
   matches the source, the index opens directly.
3. Otherwise the import sheet appears. Its Start button runs `ImportPipeline` on a background queue
   with `overwriteExistingIndex` set when a stale index folder exists, and `allowMissingDataFiles`
   set only after a second alert lists the missing files and the user approves.
4. On success the document opens its window. On cancel the document closes.
5. "Rebuild Index…" asks for confirmation, then repeats step 3 with `force`.

- [ ] **Step 1: Write the three files and rewrite `AppDelegate`**

- [ ] **Step 2: Build and run the open flow on a fresh folder**

Run: `make app`, then:
```bash
.build/release/s3-inventory-tool generate-fixture /tmp/open-flow-test --rows 2000000 --files 4
open "App/build/Build/Products/Release/S3 Inventory Visualizer.app"
```
Manual checklist:
1. Cmd+O, choose `/tmp/open-flow-test`; the import sheet appears with 4 files and the compressed size.
2. Start; the progress bar advances with a rows-per-second figure and an ETA.
3. The window opens on the finished index.
4. Quit and reopen the same folder: it opens at once with no sheet.
5. Open Recent lists it.
6. Rebuild Index… asks for confirmation and re-imports.
7. Cancel during an import leaves no `.s3-inventory-index` folder behind.

Screenshot: `docs/screenshots/task23-import-sheet.png`.

- [ ] **Step 3: Report the changed files. Do not run git.**

### Task 24: Final acceptance pass on the production inventory

**Files:**
- Modify: `docs/benchmarks.md`, `README.md`
- Create: `docs/screenshots/final-*.png`

- [ ] **Step 1: Confirm the whole suite passes**

Run: `swift test 2>&1 | tail -5`. Every test must pass. Record the test count.

- [ ] **Step 2: Open the production inventory in the app and measure**

Open `~/inventories/production-bucket` in the app (its index already
exists from Task 13).

Measure and record in `docs/benchmarks.md`:
- Seconds from choosing the folder to the first painted treemap.
- Layout milliseconds for the root and for `assets`, `queue`, `shared/assets`, `albums`,
  `OrphanedUploads` (read them from a temporary `print` of `result.elapsedSeconds`, or from
  the `bench` command with the same viewport).
- Resident memory after opening (Activity Monitor), after hovering across the whole canvas, and
  after zooming 10 levels deep.
- Idle CPU and GPU.
- Seconds for a "Contains" search for `_encoded.mp4`.

Targets: first paint ≤ 3 s; every layout ≤ 100 ms; resident memory ≤ 3 GB; idle CPU ≈ 0 %.

- [ ] **Step 3: Check the data against the known census**

In the app, confirm at the root: 1,119,900,884 files and 790.4 TiB. Confirm the top prefixes match
the census table (media 335.5 M files / 346.89 TiB, public 267.5 M / 214.75 TiB,
OrphanedUploads 43.6 M / 106.56 TiB, snapshots 111.8 M / 65.46 TiB, queue 311.0 M / 3.76 TiB).
Confirm the storage-class legend matches: STANDARD_IA 560.8 TiB, GLACIER_IR 104.4 TiB,
DEEP_ARCHIVE 72.1 TiB, STANDARD 53.0 TiB. Any mismatch is a bug; find it before finishing.

- [ ] **Step 4: Take the final screenshots and finish the README**

Screenshots: the root in storage-class mode, a zoomed prefix, extension mode, age mode, the search
panel, the import sheet. Save as `docs/screenshots/final-*.png`.

README: what the app does, the hardware it was measured on, the numbers from step 2, how to build
(`make app`), how to use the CLI, the index format summary, and the known limits from spec
section 13.

- [ ] **Step 5: Report every changed file and the final numbers. Do not run git.**

---

## What changed during execution (2026-09-12)

The plan was executed in one session. Every task landed. These are the places where the real data or
the real platform forced a different answer than the plan assumed. The spec has been updated to match.

1. **S3 Inventory sorts by the DECODED key.** The plan assumed encoded-byte order and the first
   production import aborted after 58 seconds on
   `schedules/email/schedules-email-footer-2021%402x.png`. Confirmed by scanning a whole 1,000,000-row
   file: zero decoded-order violations, two encoded-order violations. The tree builder now decodes
   before it compares, `FileOrdering` sorts by decoded first key, and the fixture writer emits decoded
   order. Regression test: `testDecodedKeyOrderIsAccepted`.

2. **Index format version 2 adds `directory.childrenBySizeBytes`.** Reading each child's size through
   its identifier was a random access into a 26.6 M-entry column and the largest single cost in a
   layout. Storing the bytes beside the identifiers makes the inner loop sequential.

3. **The recursion threshold is `max(16, minimumCellArea × 16)` px², not a flat 16 px².** At 16 px²
   the production root produced 234 K nodes and 377 ms; the coarser threshold halves that with no
   visible difference.

4. **The view root guarantees 2048 placed items.** Without it, `albums` (5.15 M files averaging
   742 KiB) drew as one remainder cell. Applying the guarantee at every nesting level instead produced
   12.4 M instances and an 8 s layout, so it is restricted to level 0.

5. **The extension dictionary packs without a length field.** An 8-character extension fills all 64
   bits, so a length in the top byte corrupted the first character. The length is recovered from the
   leading zero bytes instead, since every extension byte is a non-zero ASCII character.

6. **`@main` on the app delegate never fired.** `applicationDidFinishLaunching` was not called and the
   process ran with zero windows and no output. Replaced with an explicit `main.swift`.

7. **Xcode 26 ships without the Metal compiler.** `xcodebuild -downloadComponent MetalToolchain` is a
   prerequisite; the plan did not mention it.

8. **Three AppKit layout traps** cost real time and are recorded in the README and in the project
   memory: `.fullSizeContentView` hides the top of the content view behind a unified toolbar,
   `NSClipView` is not flipped so short content sinks to the bottom of a scroll view, and
   `NSSplitViewController` gives all extra width to the last pane unless the side panes hold a higher
   priority.

### A second pass over the application (same session)

9. **The import sheet could never build an index.** `ImportSheetController` is the target of its own
   buttons, and it was only held by a local variable, so it was deallocated as soon as the opening
   function returned. Build Index then went to a nil target and did nothing, silently. Any user
   opening a new inventory would have been stuck at that sheet. The delegate now holds the controller
   until its completion fires. Found by driving the real window with synthetic events, not by reading
   the code.

10. **Open Recent was an empty submenu.** The app does not use `NSDocument`, so nothing filled it.
    It is now built from `NSDocumentController.shared.recentDocumentURLs` each time it opens, with a
    Clear Menu item, and it reports a folder that has since been removed.

11. **Back, Forward, Up and Zoom stayed enabled at the root.** AppKit enables a menu item whenever any
    responder implements its action. `MainWindowController` now implements `NSMenuItemValidation`, so
    each item reflects the real navigation state.

12. **A long key clipped instead of wrapping in the details panel.** A key is one token with no
    spaces, so it needs `byCharWrapping`, an unlimited line count, and a `preferredMaxLayoutWidth`
    taken from the panel's actual width once it has been laid out.

13. **Cancelling a rebuild left the user with no window.** The rebuild closes the window first, on
    purpose, so the old index's pages are released before the new one is written; rebuilding the
    reference bucket would otherwise need room for two 38 GB indexes. Abandoning the sheet now
    reopens the inventory, whose index on disk was never touched.

14. **Every layout node re-scanned all of its own files** to recompute a byte total and a file count
    that the index already stores. A directory's largest own file is at most its own-file total, so
    when that total is below the pixel threshold no file can pass it and the scan can be skipped
    exactly. That removed 24 to 39 percent of the layout time on the deep prefixes.

### Selection and sidebar, after using it on the real bucket

15. **The selection was almost invisible.** Dimming everything outside the selected subtree only
    reads as "this part is selected" when the selection covers enough of the canvas. A directory of
    1.8 GB inside a 790 TiB bucket is two pixels across, so dimming the other 99.9999 percent just
    darkened the whole picture. The selection now adapts: below one percent coverage it draws a
    bright ring with a dark halo, grown to a 30 pixel minimum around the same centre, plus guide
    lines out to the canvas edges; at or above one percent it dims and desaturates everything
    outside instead, to 67 percent luminance, and brightens the inside by a quarter.

16. **Clicking in the treemap now rebuilds the sidebar around the click.** It collapses the whole
    outline, expands only the path down to the item, selects it and centres it in the visible area.
    Outline-driven selections are unaffected, because the split view controller guards against the
    echo.

Measuring the dimming by eye was misleading twice: the first sample point turned out to be inside
the selection. Comparing the average colour of the same pixels between two known states settled it.

### A fourth colour mode, added on request

17. **Colour by folder.** The three original modes all read as near monochrome on this bucket,
    because 71 percent of it is one storage class and 77 percent is one extension. The new mode
    colours each cell by which folder it sits under, relative to the current view, so the structure
    itself carries the colour. It cost one `UInt16` on `TreemapInstance`, taking the stride from 48
    to 52 bytes, which the layout contract test now asserts.

    Two decisions came out of trying it on the real bucket. The group is assigned relative to the
    **view root**, not the bucket root, so zooming into `assets` recolours by account rather than
    leaving everything one shade of blue. And only the twenty largest folders earn a hue: the first
    attempt wrapped the palette around all 5,778 root children, which was arithmetically honest but
    produced a legend reading "media +289" on every row. Everything past the palette now shares one
    neutral entry, "5,770 smaller folders", and the percentages add to 100.

### Finishing touches

18. **Application icon.** The supplied `AppIcon.iconset` already carried all ten macOS sizes and an
    asset-catalog `Contents.json`, so it moved to `App/Resources/Assets.xcassets/AppIcon.appiconset`
    unchanged, with `ASSETCATALOG_COMPILER_APPICON_NAME` and `CFBundleIconName` set to `AppIcon`.
    Verified by asking `NSWorkspace` for the built bundle's icon, which only resolves when it is
    installed correctly.

19. **About panel.** Credits Gui Pinto and guipinto.com as a live link, with the app's description
    and the index format version. The panel silently clips a long credits string, so it is kept to
    four short blocks; the first attempt lost its last two lines with no warning.

20. **Overlapping labels.** A nested box starts at its parent's top-left corner, so every level of a
    chain wrote its name in the same few pixels: `assets`, the account id, `2026` and `snapshots` drew
    on top of each other and read as garbage. The overlay now sorts labels by area and skips any whose
    text rectangle touches one already placed, which leaves the outermost and most useful name of each
    chain plus every sibling that has room. It is purely presentational, so the layout geometry and
    the area proportions are untouched.

21. **Flat tiles instead of cushion shading.** The cushion lighting multiplied every fill by
    `0.25 + 0.85 lambert`, so a `STANDARD_IA` cell rendered as a dark muddy green while its legend
    swatch stayed bright teal. The two could not be matched by eye. The fragment shader now fills
    flat, with a two percent top to bottom shade, and separates tiles with a gutter drawn in the
    canvas colour rather than by darkening the rim.

    Two details mattered. The gutter width scales with the tile, because a fixed one pixel gutter
    eats most of a four pixel cell and made every dense region read as darker than a sparse one
    holding the same colour. And hover and selection now blend toward white rather than multiplying,
    because a flat fill is already near its full value and a multiply clips the bright channels and
    shifts the hue.

    The instance still carries the cushion coefficients, so the old surface is a two line change in
    the shader.

22. **Moire, and the pixel grid.** Flat tiles exposed a problem the cushion shading had hidden. A
    squarified rectangle lands on fractional pixels, so a one pixel gutter was spread across two
    pixels by a different amount for every tile, and the whole canvas shimmered like a screen door.

    The vertex shader now snaps both EDGES of each tile to whole pixels, never the width: a tile's
    right edge and its neighbour's left edge are the same float, so they snap to the same integer and
    the two still meet exactly. Snapping is skipped while a zoom animates, where it would jitter.
    With tile and gutter both on the grid the gutter is a hard one pixel and needs no anti-aliasing.

    The gutter then took two corrections, each visible only on screen. Drawing it on all four sides
    costs a three pixel tile 89 percent of its colour, so it moved to the right and bottom only, where
    neighbours still end up separated by one clean line. That was still too dark at two pixels, which
    keeps only a quarter of its area, so the gutter now fades in with tile size: invisible on the
    smallest tiles, which read as a solid field of colour, and fully drawn once there is room for it.

### Performance against the plan's targets

| Target | Planned | Measured |
|---|---|---|
| Import of the reference bucket | ≤ 15 min | 15.6 min |
| Import peak memory | ≤ 8 GB | 6.7 GB |
| Index size | about 40 GB | 37 GB |
| Layout at 2560 × 1440, 4 px² | ≤ 100 ms | 61 to 377 ms by prefix |
| Hover | ≤ 8 ms | sub-millisecond, hit test walks a tree |
| Colour mode switch | one frame | one frame, a shader uniform |

The layout target is met for most prefixes and missed for the whole-bucket root (377 ms) and for two
wide prefixes. The cost is memory latency on scattered reads, not computation: removing every
per-node allocation changed the time by less than the run-to-run noise. Parallelising the recursion
across top-level children is the remaining lever and was not attempted.
