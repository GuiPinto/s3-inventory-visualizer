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
        .target(name: "InventoryIndex"),
        .target(name: "InventoryImport", dependencies: ["InventoryIndex"]),
        .target(name: "TreemapLayout", dependencies: ["InventoryIndex"]),
        .executableTarget(name: "s3-inventory-tool", dependencies: ["InventoryIndex", "InventoryImport", "TreemapLayout"]),
        .target(name: "TestSupport", dependencies: ["InventoryIndex", "InventoryImport"], path: "Tests/TestSupport"),
        .testTarget(name: "InventoryIndexTests", dependencies: ["InventoryIndex", "InventoryImport", "TestSupport"]),
        .testTarget(name: "InventoryImportTests", dependencies: ["InventoryImport", "TestSupport"]),
        .testTarget(name: "TreemapLayoutTests", dependencies: ["TreemapLayout", "TestSupport"]),
    ],
    swiftLanguageModes: [.v5]
)
