import Darwin
import Foundation

/// Inflates the bzip2 and gzip package lists Cydia repositories publish.
/// Field offsets match the system `bz_stream` (80 bytes) and `z_stream` (112 bytes) on arm64/x86_64 macOS.
enum ArchiveDecoder {
    /// Package indexes are small; cap expansion so a malicious archive cannot
    /// exhaust memory.
    static let maxOutputBytes = 64 * 1024 * 1024

    static func decompress(_ data: Data, path: String) -> Data? {
        if path.hasSuffix("bz2") {
            return bunzip2(data)
        }
        if path.hasSuffix("gz") {
            return gunzip(data)
        }
        return nil
    }

    private static func bunzip2(_ data: Data) -> Data? {
        guard !data.isEmpty, data.count <= Int(UInt32.max),
              let handle = dlopen("/usr/lib/libbz2.dylib", RTLD_LAZY) else {
            return nil
        }
        defer { dlclose(handle) }
        guard let initStream: CFn3 = load(handle, "BZ2_bzDecompressInit"),
              let decompress: CFn1 = load(handle, "BZ2_bzDecompress"),
              let endStream: CFn1 = load(handle, "BZ2_bzDecompressEnd") else {
            return nil
        }

        let stream = UnsafeMutableRawPointer.allocate(byteCount: 80, alignment: 8)
        stream.initializeMemory(as: UInt8.self, repeating: 0, count: 80)
        defer { stream.deallocate() }
        guard initStream(stream, 0, 0) == 0 else { return nil }
        defer { _ = endStream(stream) }

        return data.withUnsafeBytes { raw -> Data? in
            guard let base = raw.baseAddress else { return nil }
            storePointer(stream, 0, base)
            stream.storeBytes(of: UInt32(data.count), toByteOffset: 8, as: UInt32.self)
            return inflateLoop(stream: stream, process: decompress, outputOffset: 24, availOffset: 32, doneStatus: 4)
        }
    }

    private static func gunzip(_ data: Data) -> Data? {
        guard !data.isEmpty, data.count <= Int(UInt32.max),
              let handle = dlopen("/usr/lib/libz.dylib", RTLD_LAZY) else {
            return nil
        }
        defer { dlclose(handle) }
        guard let version: ZVersion = load(handle, "zlibVersion"),
              let initStream: ZInit = load(handle, "inflateInit2_"),
              let inflate: ZInflate = load(handle, "inflate"),
              let endStream: CFn1 = load(handle, "inflateEnd") else {
            return nil
        }

        let stream = UnsafeMutableRawPointer.allocate(byteCount: 112, alignment: 8)
        stream.initializeMemory(as: UInt8.self, repeating: 0, count: 112)
        defer { stream.deallocate() }

        let versionText = String(cString: version())
        let status: Int32 = versionText.withCString { cString in
            initStream(stream, 31, cString, 112)
        }
        guard status == 0 else { return nil }
        defer { _ = endStream(stream) }

        return data.withUnsafeBytes { raw -> Data? in
            guard let base = raw.baseAddress else { return nil }
            storePointer(stream, 0, base)
            stream.storeBytes(of: UInt32(data.count), toByteOffset: 8, as: UInt32.self)
            return inflateLoop(stream: stream, process: { inflate($0, 0) }, outputOffset: 24, availOffset: 32, doneStatus: 1)
        }
    }

    private static func inflateLoop(
        stream: UnsafeMutableRawPointer,
        process: (UnsafeMutableRawPointer) -> Int32,
        outputOffset: Int,
        availOffset: Int,
        doneStatus: Int32
    ) -> Data? {
        var output = Data()
        let chunk = 16 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 8)
        defer { buffer.deallocate() }

        while true {
            storePointer(stream, outputOffset, buffer)
            stream.storeBytes(of: UInt32(chunk), toByteOffset: availOffset, as: UInt32.self)

            let inputBefore = Int(stream.load(fromByteOffset: 8, as: UInt32.self))
            let status = process(stream)
            let inputAfter = Int(stream.load(fromByteOffset: 8, as: UInt32.self))
            let avail = Int(stream.load(fromByteOffset: availOffset, as: UInt32.self))
            let produced = chunk - avail

            if produced > 0 {
                output.append(Data(bytes: buffer, count: produced))
                if output.count > maxOutputBytes {
                    return nil
                }
            }

            if status == doneStatus {
                return output
            }
            if status != 0 {
                return nil
            }

            // A stream that makes no progress would otherwise spin forever.
            if produced == 0 && inputBefore == inputAfter {
                return nil
            }
        }
    }

    private static func storePointer(_ stream: UnsafeMutableRawPointer, _ offset: Int, _ pointer: UnsafeRawPointer?) {
        stream.storeBytes(of: UInt(bitPattern: pointer), toByteOffset: offset, as: UInt.self)
    }

    private static func load<T>(_ handle: UnsafeMutableRawPointer, _ name: String) -> T? {
        guard let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: T.self)
    }
}

private typealias CFn1 = @convention(c) (UnsafeMutableRawPointer) -> Int32
private typealias CFn3 = @convention(c) (UnsafeMutableRawPointer, Int32, Int32) -> Int32
private typealias ZInit = @convention(c) (UnsafeMutableRawPointer, Int32, UnsafePointer<CChar>, Int32) -> Int32
private typealias ZInflate = @convention(c) (UnsafeMutableRawPointer, Int32) -> Int32
private typealias ZVersion = @convention(c) () -> UnsafePointer<CChar>
