import Foundation

/// Runtime bridge to libzstd used ONLY by the test target to synthesize zstd
/// fixtures (production compression goes through Codex Desktop / the upstream
/// gateway). Mirrors `ZstdBridge`'s dlopen approach so tests run on any machine
/// that has the same library the gateway already depends on. Contains no test
/// assertions — returns nil whenever the native library is unavailable, letting
/// callers decide whether to skip.
enum ZstdTestSupport {
  static let libraryPaths = [
    "/opt/homebrew/lib/libzstd.dylib",
    "/usr/local/lib/libzstd.dylib",
    "/usr/lib/libzstd.dylib",
  ]

  // ZSTD_c_contentSizeFlag — stable-ish experimental control used at runtime
  // only (we dlsym, so the STATIC_LINKING_ONLY guard doesn't apply).
  private static let cContentSizeFlag: Int32 = 200

  typealias CompressFn = @convention(c) (UnsafeMutableRawPointer?, Int, UnsafeRawPointer?, Int, Int32) -> Int
  typealias CompressBoundFn = @convention(c) (Int) -> Int
  typealias CreateCCtxFn = @convention(c) () -> UnsafeMutableRawPointer?
  typealias SetParamFn = @convention(c) (UnsafeMutableRawPointer?, Int32, Int32) -> Int
  typealias Compress2Fn = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int, UnsafeRawPointer?, Int) -> Int
  typealias FreeCCtxFn = @convention(c) (UnsafeMutableRawPointer?) -> Int
  typealias IsErrorFn = @convention(c) (Int) -> UInt32
  typealias FrameSizeFn = @convention(c) (UnsafeRawPointer?, Int) -> UInt64

  private static var compressFn: CompressFn?
  private static var compressBoundFn: CompressBoundFn?
  private static var createCCtxFn: CreateCCtxFn?
  private static var setParamFn: SetParamFn?
  private static var compress2Fn: Compress2Fn?
  private static var freeCCtxFn: FreeCCtxFn?
  private static var isErrorFn: IsErrorFn?
  private static var frameSizeFn: FrameSizeFn?

  /// True when libzstd loaded and all compression entry points are present.
  static var available: Bool {
    if compressFn != nil { return true }
    guard let handle = loadHandle() else { return false }
    compressFn = dlsym(handle, "ZSTD_compress").map { unsafeBitCast($0, to: CompressFn.self) }
    compressBoundFn = dlsym(handle, "ZSTD_compressBound").map { unsafeBitCast($0, to: CompressBoundFn.self) }
    createCCtxFn = dlsym(handle, "ZSTD_createCCtx").map { unsafeBitCast($0, to: CreateCCtxFn.self) }
    setParamFn = dlsym(handle, "ZSTD_CCtx_setParameter").map { unsafeBitCast($0, to: SetParamFn.self) }
    compress2Fn = dlsym(handle, "ZSTD_compress2").map { unsafeBitCast($0, to: Compress2Fn.self) }
    freeCCtxFn = dlsym(handle, "ZSTD_freeCCtx").map { unsafeBitCast($0, to: FreeCCtxFn.self) }
    isErrorFn = dlsym(handle, "ZSTD_isError").map { unsafeBitCast($0, to: IsErrorFn.self) }
    frameSizeFn = dlsym(handle, "ZSTD_getFrameContentSize").map { unsafeBitCast($0, to: FrameSizeFn.self) }
    let ready = compressFn != nil && compressBoundFn != nil
      && createCCtxFn != nil && setParamFn != nil && compress2Fn != nil
    if !ready { compressFn = nil } // leave `available` false if the toolchain is partial
    return ready
  }

  private static var _handle: UnsafeMutableRawPointer?
  private static func loadHandle() -> UnsafeMutableRawPointer? {
    if let h = _handle { return h }
    for path in libraryPaths {
      if let h = dlopen(path, RTLD_NOW) { _handle = h; break }
    }
    return _handle
  }

  static func frameHasContentSize(_ data: Data) -> Bool {
    guard let f = frameSizeFn else { return false }
    let v = data.withUnsafeBytes { f($0.baseAddress, data.count) }
    return v != 0xFFFF_FFFF_FFFF_FFFF && v != 0xFFFF_FFFF_FFFF_FFFE
  }

  /// Single-shot compress: frame carries the authoritative content size.
  static func compressKnown(_ string: String) -> Data? {
    guard available else { return nil }
    let json = Data(string.utf8)
    let bound = compressBoundFn!(json.count)
    guard bound > 0 else { return nil }
    var out = Data(count: bound)
    let written = out.withUnsafeMutableBytes { ob in
      json.withUnsafeBytes { jb in
        compressFn!(ob.baseAddress, bound, jb.baseAddress, json.count, 3)
      }
    }
    guard written > 0, isErrorFn?(written) == 0 else { return nil }
    out.count = written
    return out
  }

  /// Streamed-style compress WITHOUT a frame content-size, used to hit the
  /// "unknown size / dynamic growth" path that the earlier build-size bug broke.
  static func compressUnknown(_ string: String) -> Data? {
    guard available, let cctx = createCCtxFn?() else { return nil }
    defer { _ = freeCCtxFn?(cctx) }
    guard let setParamFn, let compress2Fn else { return nil }
    let setResult = setParamFn(cctx, cContentSizeFlag, 0)
    guard isErrorFn?(setResult) == 0 else { return nil }
    let bound = compressBoundFn!(string.utf8.count)
    guard bound > 0 else { return nil }
    let json = Data(string.utf8)
    var out = Data(count: bound)
    let written = out.withUnsafeMutableBytes { ob in
      json.withUnsafeBytes { jb in
        compress2Fn(cctx, ob.baseAddress, bound, jb.baseAddress, json.count)
      }
    }
    guard written > 0, isErrorFn?(written) == 0 else { return nil }
    out.count = written
    return out
  }
}

/// Large, repetitive-but-valid JSON — high compression ratio. This is the
/// "context history" shape that used to trip the too-small output buffer.
func buildCompressibleJSON(_ pattern: String = "context_line", repeats: Int = 60_000) -> String {
  var s = "{\"model\":\"x\",\"instructions\":\""
  s += String(repeating: "system instruction non-redundant-" + pattern + "-content ", count: 200)
  s += "\",\"previous_response_id\":\"resp_abcdef\",\"input\":["
  s += String(repeating: "{\"role\":\"user\",\"content\":\"" + pattern + " additive text line \"" + "},", count: repeats)
  s += "],\"tools\":[]}"
  return s
}