// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "S3InventoryVisualizerCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "InventoryIndex", targets: ["InventoryIndex"]),
    ],
    targets: [
        .target(name: "InventoryIndex"),
    ],
    swiftLanguageModes: [.v5]
)
