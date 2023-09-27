import AppKit
import simd

public enum ColorMode: Int {
    case storageClass = 0
    case fileExtension = 1
    case age = 2
    case folder = 3
}

extension NSColor {
    convenience init(hexString: String) {
        var value: UInt64 = 0
        Scanner(string: hexString).scanHexInt64(&value)
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255.0,
            green: CGFloat((value >> 8) & 0xFF) / 255.0,
            blue: CGFloat(value & 0xFF) / 255.0,
            alpha: 1
        )
    }
}

enum TreemapPalette {
    static let canvasBackground = NSColor(hexString: "16181D")

    /// Index is the storage class identifier.
    static let storageClassColors: [NSColor] = [
        NSColor(hexString: "4C8DFF"),   // STANDARD, blue
        NSColor(hexString: "2BB5A0"),   // STANDARD_IA, teal
        NSColor(hexString: "5FC96B"),   // INTELLIGENT_TIERING, green
        NSColor(hexString: "39C2E0"),   // ONEZONE_IA, cyan
        NSColor(hexString: "F2A93B"),   // GLACIER_IR, amber
        NSColor(hexString: "F07A3C"),   // GLACIER, orange
        NSColor(hexString: "8B6CF6"),   // DEEP_ARCHIVE, violet
        NSColor(hexString: "8C919B"),   // OTHER, grey
    ]

    static let extensionColors: [NSColor] = [
        "4C8DFF", "2BB5A0", "F2A93B", "8B6CF6", "5FC96B",
        "F07A3C", "39C2E0", "E05C8A", "B5CF3B", "6C7BF6",
        "3BCFB0", "F0C93C", "9B6CD8", "5CA8E0", "D8734C",
    ].map { NSColor(hexString: $0) }

    static let extensionOtherColor = NSColor(hexString: "6A6F79")

    /// Newest to oldest, eight buckets.
    static let ageColors: [NSColor] = [
        "FFD98C", "FFB45C", "F08A4C", "D96A5C", "B05070", "7E4080", "55357A", "33285C",
    ].map { NSColor(hexString: $0) }

    static let ageBucketLabels = ["< 30 d", "< 90 d", "< 180 d", "< 1 y", "< 2 y", "< 3 y", "< 5 y", "older"]

    /// One hue per folder directly under whatever is being viewed, assigned largest first. Ordered so
    /// that neighbouring ranks are far apart in hue, because the biggest folders usually sit side by side.
    static let folderColors: [NSColor] = [
        "4C8DFF", "FF7A5C", "37C9A6", "F2B23B", "A46BFF",
        "5FD46B", "FF6FB5", "39C2E0", "E0D03C", "F0813C",
        "8C9BFF", "4FD1B5", "E06A9E", "7EC4FF", "C9A86B",
        "6BE0C8", "C46BFF", "FFC15C", "94E05F", "FF8F7A",
    ].map { NSColor(hexString: $0) }

    /// Used for cells that belong to the viewed folder itself rather than to one of its children.
    static let folderOwnColor = NSColor(hexString: "8C919B")

    static func color(forStorageClass identifier: Int) -> NSColor {
        storageClassColors[min(max(identifier, 0), storageClassColors.count - 1)]
    }

    static func simd(_ color: NSColor) -> SIMD4<Float> {
        let converted = color.usingColorSpace(.sRGB) ?? color
        return SIMD4<Float>(
            Float(converted.redComponent),
            Float(converted.greenComponent),
            Float(converted.blueComponent),
            1
        )
    }
}
