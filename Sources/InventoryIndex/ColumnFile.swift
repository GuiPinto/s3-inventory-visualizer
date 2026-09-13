import Foundation

public struct ColumnHeader {
    public var formatVersion: UInt32
    public var elementSize: UInt32
    public var count: UInt64

    public init(formatVersion: UInt32, elementSize: UInt32, count: UInt64) {
        self.formatVersion = formatVersion
        self.elementSize = elementSize
        self.count = count
    }

    public func encoded() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: IndexFormat.columnHeaderSize)
        bytes.replaceSubrange(0..<8, with: IndexFormat.columnMagic)
        withUnsafeBytes(of: formatVersion.littleEndian) { bytes.replaceSubrange(8..<12, with: $0) }
        withUnsafeBytes(of: elementSize.littleEndian) { bytes.replaceSubrange(12..<16, with: $0) }
        withUnsafeBytes(of: count.littleEndian) { bytes.replaceSubrange(16..<24, with: $0) }
        return bytes
    }

    public static func decode(_ bytes: UnsafeRawBufferPointer, fileName: String) throws -> ColumnHeader {
        guard bytes.count >= IndexFormat.columnHeaderSize,
              Array(bytes[0..<8]) == IndexFormat.columnMagic else { throw IndexError.badColumnHeader(fileName) }
        let formatVersion = UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 8, as: UInt32.self))
        let elementSize = UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 12, as: UInt32.self))
        let count = UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: 16, as: UInt64.self))

        guard formatVersion == IndexFormat.formatVersion else { throw IndexError.badColumnHeader(fileName) }
        return ColumnHeader(formatVersion: formatVersion, elementSize: elementSize, count: count)
    }
}

/// Read-only memory map of one column file. `Element` must be a trivial type.
public final class MappedColumn<Element> {
    public let url: URL
    public let count: Int
    public let buffer: UnsafeBufferPointer<Element>
    private let mappingBase: UnsafeMutableRawPointer
    private let mappingLength: Int

    public init(url: URL) throws {
        let (base, length, count) = try MappedColumn.map(url: url)
        self.url = url
        self.mappingBase = base
        self.mappingLength = length
        self.count = count
        let start = (base + IndexFormat.columnHeaderSize).assumingMemoryBound(to: Element.self)
        self.buffer = UnsafeBufferPointer(start: start, count: count)
    }

    private static func map(url: URL) throws -> (UnsafeMutableRawPointer, Int, Int) {
        let name = url.lastPathComponent
        let descriptor = open(url.path, O_RDONLY)

        guard descriptor >= 0 else { throw IndexError.systemCall("open \(name)", errno: errno) }
        defer { close(descriptor) }
        var status = stat()

        guard fstat(descriptor, &status) == 0 else { throw IndexError.systemCall("fstat \(name)", errno: errno) }
        let length = Int(status.st_size)

        guard length >= IndexFormat.columnHeaderSize else { throw IndexError.badColumnHeader(name) }

        guard let base = mmap(nil, length, PROT_READ, MAP_PRIVATE, descriptor, 0), base != MAP_FAILED else {
            throw IndexError.systemCall("mmap \(name)", errno: errno)
        }

        do {
            let header = try ColumnHeader.decode(UnsafeRawBufferPointer(start: base, count: IndexFormat.columnHeaderSize), fileName: name)
            let stride = MemoryLayout<Element>.stride

            guard Int(header.elementSize) == stride else {
                throw IndexError.elementSizeMismatch(name, expected: stride, found: Int(header.elementSize))
            }

            let count = Int(header.count)

            guard IndexFormat.columnHeaderSize + count * stride <= length else { throw IndexError.badColumnHeader(name) }
            return (base, length, count)
        } catch {
            munmap(base, length)
            throw error
        }
    }

    deinit {
        munmap(mappingBase, mappingLength)
    }

    /// Asks the kernel to read the mapping ahead. A cold index otherwise pays thousands of page faults
    /// during the first treemap layout.
    public func prefetch() {
        madvise(mappingBase, mappingLength, MADV_WILLNEED)
    }

    @inline(__always) public subscript(index: Int) -> Element { buffer[index] }
}

/// Append-only column writer with a large write buffer.
/// An error during `append` is remembered and thrown by `finish()`.
public final class ColumnWriter<Element> {
    public let url: URL
    public private(set) var count: Int = 0
    private let descriptor: Int32
    private let buffer: UnsafeMutableRawPointer
    private let bufferCapacity: Int
    private var bufferUsed = 0
    private var finished = false
    private var writeError: Error?
    private let stride = MemoryLayout<Element>.stride

    public init(url: URL, bufferSize: Int = 4 << 20) throws {
        self.url = url
        descriptor = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)

        guard descriptor >= 0 else { throw IndexError.systemCall("create \(url.lastPathComponent)", errno: errno) }
        bufferCapacity = max(bufferSize, stride * 16)
        buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferCapacity, alignment: 64)
        let placeholder = [UInt8](repeating: 0, count: IndexFormat.columnHeaderSize)

        do {
            try placeholder.withUnsafeBytes { try writeFully($0) }
        } catch {
            close(descriptor)
            buffer.deallocate()
            throw error
        }
    }

    @inline(__always) public func append(_ value: Element) {
        if bufferUsed + stride > bufferCapacity {
            flushBuffer()
        }

        buffer.storeBytes(of: value, toByteOffset: bufferUsed, as: Element.self)
        bufferUsed += stride
        count += 1
    }

    public func append(contentsOf values: UnsafeBufferPointer<Element>) {
        for value in values {
            append(value)
        }
    }

    /// Appends raw bytes; `count` advances by `bytes.count / stride` (use with `UInt8` columns).
    public func appendBytes(_ bytes: UnsafeRawBufferPointer) {
        guard let base = bytes.baseAddress else { return }
        var offset = 0

        while offset < bytes.count {
            if bufferUsed == bufferCapacity {
                flushBuffer()
            }

            let chunk = min(bytes.count - offset, bufferCapacity - bufferUsed)
            (buffer + bufferUsed).copyMemory(from: base + offset, byteCount: chunk)
            bufferUsed += chunk
            offset += chunk
        }

        count += bytes.count / stride
    }

    private func flushBuffer() {
        guard writeError == nil, bufferUsed > 0 else {
            bufferUsed = 0
            return
        }

        do {
            try writeFully(UnsafeRawBufferPointer(start: buffer, count: bufferUsed))
        } catch {
            writeError = error
        }

        bufferUsed = 0
    }

    private func writeFully(_ bytes: UnsafeRawBufferPointer) throws {
        guard let base = bytes.baseAddress else { return }
        var offset = 0

        while offset < bytes.count {
            let written = write(descriptor, base + offset, bytes.count - offset)

            guard written > 0 else { throw IndexError.systemCall("write \(url.lastPathComponent)", errno: errno) }
            offset += written
        }
    }

    public func finish() throws {
        guard !finished else { return }
        finished = true
        flushBuffer()
        defer {
            close(descriptor)
            buffer.deallocate()
        }

        if let error = writeError {
            throw error
        }

        let header = ColumnHeader(formatVersion: IndexFormat.formatVersion, elementSize: UInt32(stride), count: UInt64(count)).encoded()

        guard lseek(descriptor, 0, SEEK_SET) == 0 else { throw IndexError.systemCall("lseek \(url.lastPathComponent)", errno: errno) }
        try header.withUnsafeBytes { try writeFully($0) }
    }

    deinit {
        if !finished {
            close(descriptor)
            buffer.deallocate()
        }
    }
}

/// Random-access column writer over a sparse file. APFS allocates only the written pages.
public final class SparseMappedColumn<Element> {
    public let url: URL
    public let capacity: Int
    private let descriptor: Int32
    private let mappingBase: UnsafeMutableRawPointer
    private let mappingLength: Int
    private let elements: UnsafeMutablePointer<Element>
    private var finished = false

    public init(url: URL, capacity: Int) throws {
        self.url = url
        self.capacity = capacity
        let name = url.lastPathComponent
        descriptor = open(url.path, O_RDWR | O_CREAT | O_TRUNC, 0o644)

        guard descriptor >= 0 else { throw IndexError.systemCall("create \(name)", errno: errno) }
        mappingLength = IndexFormat.columnHeaderSize + capacity * MemoryLayout<Element>.stride

        guard ftruncate(descriptor, off_t(mappingLength)) == 0 else {
            close(descriptor)
            throw IndexError.systemCall("ftruncate \(name)", errno: errno)
        }

        guard let base = mmap(nil, mappingLength, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0), base != MAP_FAILED else {
            close(descriptor)
            throw IndexError.systemCall("mmap \(name)", errno: errno)
        }

        mappingBase = base
        elements = (base + IndexFormat.columnHeaderSize).assumingMemoryBound(to: Element.self)
    }

    @inline(__always) public subscript(index: Int) -> Element {
        get { elements[index] }
        set { elements[index] = newValue }
    }

    public func finish(count: Int) throws {
        guard !finished else { return }
        finished = true
        let name = url.lastPathComponent
        let header = ColumnHeader(
            formatVersion: IndexFormat.formatVersion,
            elementSize: UInt32(MemoryLayout<Element>.stride),
            count: UInt64(count)
        ).encoded()
        header.withUnsafeBytes { mappingBase.copyMemory(from: $0.baseAddress!, byteCount: IndexFormat.columnHeaderSize) }
        let syncResult = msync(mappingBase, mappingLength, MS_SYNC)
        munmap(mappingBase, mappingLength)
        defer { close(descriptor) }

        guard syncResult == 0 else { throw IndexError.systemCall("msync \(name)", errno: errno) }
        let finalLength = IndexFormat.columnHeaderSize + count * MemoryLayout<Element>.stride

        guard ftruncate(descriptor, off_t(finalLength)) == 0 else { throw IndexError.systemCall("ftruncate \(name)", errno: errno) }
    }

    deinit {
        if !finished {
            munmap(mappingBase, mappingLength)
            close(descriptor)
        }
    }
}
