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
    public var cachedBlockCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cached.count
    }

    public init(blocks: MappedColumn<NameBlockEntry>, data: MappedColumn<UInt8>, capacity: Int = 64) {
        self.blocks = blocks
        self.data = data
        self.capacity = max(capacity, 1)
    }

    public func decodeBlockUncached(_ index: Int) -> DecodedNameBlock {
        let entry = blocks[index]

        guard let dataBase = data.buffer.baseAddress else { return DecodedNameBlock(raw: []) }
        let compressed = UnsafeRawBufferPointer(
            start: UnsafeRawPointer(dataBase) + Int(entry.offset),
            count: Int(entry.compressedLength)
        )

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

        if cached[index] == nil, cached.count >= capacity,
           let victim = cached.min(by: { $0.value.lastUse < $1.value.lastUse }) {
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

    public func name(ofFile fileIndex: UInt64) -> [UInt8] {
        withName(ofFile: fileIndex) { Array($0) }
    }

    public func nameString(ofFile fileIndex: UInt64) -> String {
        withName(ofFile: fileIndex) { String(decoding: $0, as: UTF8.self) }
    }
}
