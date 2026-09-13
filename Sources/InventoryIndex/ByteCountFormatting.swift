import Foundation

public enum ByteUnits: String, CaseIterable {
    case binary
    case decimal
}

public func formatByteCount(_ bytes: UInt64, units: ByteUnits, fractionDigits: Int = 1) -> String {
    let base: Double = units == .binary ? 1024 : 1000
    let suffixes = units == .binary
        ? ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]
        : ["B", "KB", "MB", "GB", "TB", "PB"]
    var value = Double(bytes)
    var suffixIndex = 0

    while value >= base && suffixIndex < suffixes.count - 1 {
        value /= base
        suffixIndex += 1
    }

    if suffixIndex == 0 {
        return "\(bytes) B"
    }

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
