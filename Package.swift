// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "S3InventoryVisualizerCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "InventoryIndex", targets: ["InventoryIndex"]),
        .library(name: "InventoryImport", targets: ["InventoryImport"]),
    ],
    targets: [
        .target(name: "InventoryIndex"),
        .target(name: "InventoryImport", dependencies: ["InventoryIndex"]),
        .testTarget(name: "InventoryIndexTests", dependencies: ["InventoryIndex"]),
        .testTarget(name: "InventoryImportTests", dependencies: ["InventoryImport"]),
    ],
    swiftLanguageModes: [.v5]
)
