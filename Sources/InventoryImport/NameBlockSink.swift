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

    public init(
        blocks: ColumnWriter<NameBlockEntry>,
        data: ColumnWriter<UInt8>,
        workerCount: Int = 4,
        maximumInFlight: Int = 16
    ) {
        self.blocks = blocks
        self.data = data
        self.maximumInFlight = max(maximumInFlight, 1)
        workers = DispatchQueue(label: "name-block-sink", qos: .userInitiated, attributes: .concurrent)
        _ = workerCount
    }

    public func consume(rawBlock: [UInt8], nameCount: Int) throws {
        condition.lock()

        while inFlight >= maximumInFlight {
            condition.wait()
        }

        let sequence = nextSequence
        nextSequence += 1
        inFlight += 1
        condition.unlock()
        workers.async { [self] in
            let compressed = NameBlockCodec.encode(raw: rawBlock)
            condition.lock()
            finishedBlocks[sequence] = (compressed, rawBlock.count)

            while let next = finishedBlocks.removeValue(forKey: nextSequenceToWrite) {
                blocks.append(NameBlockEntry(
                    offset: UInt64(data.count),
                    compressedLength: UInt32(next.compressed.count),
                    rawLength: UInt32(next.rawLength)
                ))
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

        while inFlight > 0 {
            condition.wait()
        }

        condition.unlock()
    }
}
