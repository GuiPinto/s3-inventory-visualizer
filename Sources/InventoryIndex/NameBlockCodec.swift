import Foundation
import Compression

public struct NameBlockEntry {
    public var offset: UInt64
    public var compressedLength: UInt32
    public var rawLength: UInt32

    public init(offset: UInt64, compressedLength: UInt32, rawLength: UInt32) {
        self.offset = offset
        self.compressedLength = compressedLength
        self.rawLength = rawLength
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
        guard let base = compressed.baseAddress, rawLength > 0 else { return nil }
        var destination = [UInt8](repeating: 0, count: rawLength)
        let written = destination.withUnsafeMutableBufferPointer { target in
            compression_decode_buffer(
                target.baseAddress!,
                rawLength,
                base.assumingMemoryBound(to: UInt8.self),
                compressed.count,
                nil,
                COMPRESSION_LZFSE
            )
        }

        return written == rawLength ? destination : nil
    }
}

public final class DecodedNameBlock {
    public let raw: [UInt8]
    private let starts: [UInt32]
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
            let start = Int(starts[index])
            let end = start + Int(lengths[index])
            return body(UnsafeBufferPointer(rebasing: buffer[start..<end]))
        }
    }

    public func name(at index: Int) -> [UInt8] {
        withName(at: index) { Array($0) }
    }
}
