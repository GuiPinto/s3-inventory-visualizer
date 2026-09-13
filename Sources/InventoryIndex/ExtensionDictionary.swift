import Foundation

/// Interns lowercase file extensions (1 to 8 ASCII alphanumerics after the last '.') into UInt16 ids.
/// Id 0 means "no extension". Anything past `maximumIdentifiers - 1` collapses into `otherIdentifier`.
public final class ExtensionDictionary {
    public static let maximumIdentifiers = 65_535
    public static let otherIdentifier: UInt16 = 65_535
    public static let maximumLength = 8

    public private(set) var names: [String] = [""]
    private var identifiersByPackedExtension: [UInt64: UInt16] = [:]

    public init() {}

    /// Packs the lowercase extension into a UInt64, first character in the most significant non-zero byte.
    /// Every extension byte is a non-zero ASCII character, so the length is recovered from the leading zero bytes.
    /// Returns nil when there is no extension.
    public static func packedExtension(ofBasename bytes: UnsafeBufferPointer<UInt8>) -> UInt64? {
        guard bytes.count >= 2 else { return nil }
        var dotIndex = bytes.count - 1
        var length = 0

        while dotIndex >= 0 {
            let byte = bytes[dotIndex]

            if byte == UInt8(ascii: ".") {
                break
            }

            let isDigit = byte >= 48 && byte <= 57
            let isUpper = byte >= 65 && byte <= 90
            let isLower = byte >= 97 && byte <= 122

            guard isDigit || isUpper || isLower else { return nil }
            length += 1

            if length > maximumLength {
                return nil
            }

            dotIndex -= 1
        }

        guard dotIndex >= 0, length >= 1 else { return nil }
        var packed: UInt64 = 0

        for index in (dotIndex + 1)..<bytes.count {
            var byte = bytes[index]

            if byte >= 65 && byte <= 90 {
                byte += 32
            }

            packed = (packed << 8) | UInt64(byte)
        }

        return packed
    }

    public static func extensionString(ofBasename basename: String) -> String {
        var bytes = Array(basename.utf8)

        guard !bytes.isEmpty else { return "" }
        let packed = bytes.withUnsafeMutableBufferPointer { packedExtension(ofBasename: UnsafeBufferPointer($0)) }

        guard let packed else { return "" }
        return unpack(packed)
    }

    private static func unpack(_ packed: UInt64) -> String {
        var length = 8

        while length > 1 && (packed >> UInt64((length - 1) * 8)) == 0 {
            length -= 1
        }

        var characters: [UInt8] = []
        characters.reserveCapacity(length)

        for index in 0..<length {
            let shift = UInt64((length - 1 - index) * 8)
            characters.append(UInt8((packed >> shift) & 0xFF))
        }

        return String(decoding: characters, as: UTF8.self)
    }

    public func identifier(forBasename bytes: UnsafeBufferPointer<UInt8>) -> UInt16 {
        guard let packed = ExtensionDictionary.packedExtension(ofBasename: bytes) else { return 0 }

        if let existing = identifiersByPackedExtension[packed] {
            return existing
        }

        guard names.count < ExtensionDictionary.maximumIdentifiers else { return ExtensionDictionary.otherIdentifier }
        let identifier = UInt16(names.count)
        names.append(ExtensionDictionary.unpack(packed))
        identifiersByPackedExtension[packed] = identifier
        return identifier
    }
}
