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
        guard let base = bytes.baseAddress, bytes.count > 0 else { return StorageClass.other.rawValue }

        for entry in knownNames where entry.bytes.count == bytes.count {
            let matches = entry.bytes.withUnsafeBufferPointer { memcmp($0.baseAddress!, base, bytes.count) == 0 }

            if matches {
                return entry.identifier
            }
        }

        return StorageClass.other.rawValue
    }

    public static func identifier(forInventoryName name: String) -> UInt8 {
        var bytes = Array(name.utf8)

        if bytes.isEmpty {
            return StorageClass.other.rawValue
        }

        return bytes.withUnsafeMutableBufferPointer { identifier(forInventoryName: UnsafeBufferPointer($0)) }
    }
}
