import Foundation

/// Runtime bridge to libzstd for decompressing Codex Desktop request bodies.
enum ZstdBridge {
  private typealias DecompressFn = @convention(c) (
    UnsafeMutableRawPointer?, Int, UnsafeRawPointer?, Int
  ) -> Int

  private typealias DecompressBoundFn = @convention(c) (UnsafeRawPointer?, Int) -> UInt64
  private typealias FrameContentSizeFn = @convention(c) (UnsafeRawPointer?, Int) -> UInt64

  private static let contentSizeUnknown: UInt64 = 0xFFFF_FFFF_FFFF_FFFF
  private static let contentSizeError: UInt64 = 0xFFFF_FFFF_FFFF_FFFE

  /// Upper bound for a single decompressed HTTP body. Mirrors the 80MB receive cap:
  /// protects against decompression bombs while allowing legitimate large context.
  private static let maxDecompressedSize = 64 * 1024 * 1024

  private static let libraryPaths = [
    "/opt/homebrew/lib/libzstd.dylib",
    "/usr/local/lib/libzstd.dylib",
    "/usr/lib/libzstd.dylib"
  ]

  static func decompress(_ data: Data) -> Data? {
    guard data.count >= 4,
          data[0] == 0x28, data[1] == 0xB5, data[2] == 0x2F, data[3] == 0xFD else {
      return nil
    }
    guard let (handle, decompress, frameSize, decompressBound) = loadSymbols() else { return nil }
    defer { dlclose(handle) }

    return data.withUnsafeBytes { srcBuffer in
      guard let srcBase = srcBuffer.baseAddress else { return nil }

      var capacity = max(data.count * 8, 65_536)
      if let frameSize {
        let size = frameSize(srcBase, data.count)
        if size == contentSizeError || (size > 0 && size != contentSizeUnknown) {
          // Frame carries an authoritative content size: size the buffer exactly.
          let sized = Int(min(size, UInt64(Int.max)))
          if size == contentSizeError || sized > maxDecompressedSize {
            return nil
          }
          capacity = max(sized, capacity)
        } else {
          // Content size unknown: fall back to a safe upper bound when available.
          if let decompressBound {
            let bound = Int(min(decompressBound(srcBase, data.count), UInt64(maxDecompressedSize)))
            capacity = min(max(bound, capacity), maxDecompressedSize)
          }
        }
      }

      // Single-shot attempt (common path: exact or bounded capacity).
      if let out = tryDecompress(decompress, data, srcBase, capacity), !out.isEmpty {
        return out
      }

      // Dynamic growth fallback for unknown-size frames whose bound is unavailable
      // or whose single-shot buffer was too small. Bounded growth with a hard cap.
      var dynamic = max(capacity, 65_536)
      while dynamic <= maxDecompressedSize {
        dynamic = min(dynamic * 2, maxDecompressedSize)
        if let out = tryDecompress(decompress, data, srcBase, dynamic), !out.isEmpty {
          return out
        }
        if dynamic == maxDecompressedSize { break }
      }

      return nil
    }
  }

  private static func tryDecompress(
    _ decompress: DecompressFn,
    _ data: Data,
    _ srcBase: UnsafeRawPointer,
    _ capacity: Int
  ) -> Data? {
    var output = Data(count: capacity)
    let written: Int = output.withUnsafeMutableBytes { dstBuffer in
      guard let dstBase = dstBuffer.baseAddress else { return -1 }
      return Int(decompress(dstBase, capacity, srcBase, data.count))
    }
    guard written > 0 else { return nil }
    output.count = written
    return output
  }

  private static func loadSymbols() -> (UnsafeMutableRawPointer, DecompressFn, FrameContentSizeFn?, DecompressBoundFn?)? {
    for path in libraryPaths {
      guard let handle = dlopen(path, RTLD_NOW) else { continue }
      guard let decompressPtr = dlsym(handle, "ZSTD_decompress") else {
        dlclose(handle)
        continue
      }
      let decompress = unsafeBitCast(decompressPtr, to: DecompressFn.self)
      let frameSizePtr = dlsym(handle, "ZSTD_getFrameContentSize")
      let frameSize = frameSizePtr.map { unsafeBitCast($0, to: FrameContentSizeFn.self) }
      let boundPtr = dlsym(handle, "ZSTD_decompressBound")
      let bound = boundPtr.map { unsafeBitCast($0, to: DecompressBoundFn.self) }
      return (handle, decompress, frameSize, bound)
    }
    return nil
  }
}