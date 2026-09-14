import Foundation
import zlib

public final class GzipInflateStream {
    public let url: URL
    public private(set) var compressedBytesRead: Int64 = 0
    private var stream = z_stream()
    private let descriptor: Int32
    private let inputBuffer: UnsafeMutablePointer<UInt8>
    private let inputCapacity: Int
    private var inputExhausted = false
    private var finished = false

    public init(url: URL, bufferSize: Int = 1 << 20) throws {
        self.url = url
        descriptor = open(url.path, O_RDONLY)

        guard descriptor >= 0 else { throw ImportError.systemCall("open \(url.lastPathComponent)", errno: errno) }
        _ = fcntl(descriptor, F_RDAHEAD, 1)
        inputCapacity = max(bufferSize, 4096)
        inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: inputCapacity)
        let status = inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))

        guard status == Z_OK else {
            close(descriptor)
            inputBuffer.deallocate()
            throw ImportError.corruptGzip(file: url.lastPathComponent, detail: "inflateInit2 returned \(status)")
        }
    }

    deinit {
        inflateEnd(&stream)
        close(descriptor)
        inputBuffer.deallocate()
    }

    /// Fills `destination` as far as possible. Returns 0 only at the end of the stream.
    public func read(into destination: UnsafeMutableBufferPointer<UInt8>) throws -> Int {
        if finished || destination.isEmpty {
            return 0
        }

        stream.next_out = destination.baseAddress
        stream.avail_out = UInt32(destination.count)

        while stream.avail_out > 0 {
            if stream.avail_in == 0 && !inputExhausted {
                let bytesRead = Darwin.read(descriptor, inputBuffer, inputCapacity)

                guard bytesRead >= 0 else { throw ImportError.systemCall("read \(url.lastPathComponent)", errno: errno) }

                if bytesRead == 0 {
                    inputExhausted = true
                } else {
                    stream.next_in = inputBuffer
                    stream.avail_in = UInt32(bytesRead)
                    compressedBytesRead += Int64(bytesRead)
                }
            }

            let status = inflate(&stream, Z_NO_FLUSH)

            if status == Z_STREAM_END {
                if stream.avail_in == 0 && inputExhausted {
                    finished = true
                    break
                }

                if stream.avail_in == 0 {
                    continue
                }

                inflateReset(&stream)
                continue
            }

            if status == Z_BUF_ERROR {
                if inputExhausted && stream.avail_in == 0 {
                    throw ImportError.corruptGzip(file: url.lastPathComponent, detail: "truncated gzip stream")
                }

                continue
            }

            guard status == Z_OK else {
                let message = stream.msg.map { String(cString: $0) } ?? "zlib status \(status)"
                throw ImportError.corruptGzip(file: url.lastPathComponent, detail: message)
            }
        }

        return destination.count - Int(stream.avail_out)
    }
}

public final class GzipDeflateWriter {
    private var stream = z_stream()
    private let handle: FileHandle
    private var outputBuffer = [UInt8](repeating: 0, count: 1 << 20)
    private var finished = false

    public init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        let status = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            15 + 16,
            8,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )

        guard status == Z_OK else {
            throw ImportError.corruptGzip(file: url.lastPathComponent, detail: "deflateInit2 returned \(status)")
        }
    }

    public func write(_ string: String) throws {
        var bytes = Array(string.utf8)

        guard !bytes.isEmpty else { return }
        try bytes.withUnsafeMutableBytes { try write(UnsafeRawBufferPointer($0)) }
    }

    public func write(_ bytes: UnsafeRawBufferPointer) throws {
        guard let base = bytes.baseAddress, bytes.count > 0 else { return }
        stream.next_in = UnsafeMutablePointer(mutating: base.assumingMemoryBound(to: UInt8.self))
        stream.avail_in = UInt32(bytes.count)
        try drain(flush: Z_NO_FLUSH)
    }

    public func finish() throws {
        guard !finished else { return }
        finished = true
        stream.avail_in = 0
        try drain(flush: Z_FINISH)
        deflateEnd(&stream)
        try handle.close()
    }

    private func drain(flush: Int32) throws {
        repeat {
            let produced: Int = try outputBuffer.withUnsafeMutableBufferPointer { buffer in
                stream.next_out = buffer.baseAddress
                stream.avail_out = UInt32(buffer.count)
                let status = deflate(&stream, flush)

                guard status != Z_STREAM_ERROR else {
                    throw ImportError.corruptGzip(file: "output", detail: "deflate stream error")
                }

                return buffer.count - Int(stream.avail_out)
            }

            if produced > 0 {
                handle.write(Data(outputBuffer[0..<produced]))
            }
        } while stream.avail_out == 0
    }
}
