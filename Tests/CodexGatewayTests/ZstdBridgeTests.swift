import XCTest
import Foundation
@testable import CodexGateway

/// Formal regression suite for `ZstdBridge` output-buffer sizing. Lives in the
/// repo test target so it runs under `swift test`; the same checks are also run
/// through the CLT `swiftc` harness on machines without Xcode.
///
/// Core contract: a large, high-compression-ratio zstd body without a frame
/// content-size must still decompress correctly (dynamic-growth path), while
/// corrupt/truncated frames must cleanly return nil — never silently fall back
/// to raw bytes.
final class ZstdBridgeTests: XCTestCase {
  override func setUp() {
    super.setUp()
    try? XCTSkipUnless(
      ZstdTestSupport.available,
      "libzstd not found — ZstdBridge tests require the same library the gateway loads."
    )
  }

  // 1. Known frame content-size, small JSON — exact-buffer path.
  func testKnownSizeSmallJSONDecodes() {
    let payload = #"{"model":"x","input":"hi"}"#
    guard let frame = ZstdTestSupport.compressKnown(payload) else {
      XCTFail("could not synthesize known-size zstd")
      return
    }
    XCTAssertTrue(ZstdTestSupport.frameHasContentSize(frame), "fixture must carry content size")
    let decoded = ZstdBridge.decompress(frame)
    XCTAssertNotNil(decoded)
    XCTAssertEqual(String(data: decoded ?? Data(), encoding: .utf8), payload)
  }

  // 2. Unknown frame content-size, small body — dynamic path within 8x budget.
  func testUnknownSizeSmallJSONDecodes() {
    let payload = #"{"model":"x","input":"hi"}"#
    guard let frame = ZstdTestSupport.compressUnknown(payload) else {
      XCTFail("could not synthesize unknown-size zstd")
      return
    }
    XCTAssertFalse(ZstdTestSupport.frameHasContentSize(frame), "fixture must NOT carry content size")
    let decoded = ZstdBridge.decompress(frame)
    XCTAssertNotNil(decoded)
    XCTAssertEqual(String(data: decoded ?? Data(), encoding: .utf8), payload)
  }

  // 3. Unknown frame content-size, HIGH compression ratio (decoded > 8x input).
  //    This is the regression: the old fixed 8x buffer silently failed here.
  func testUnknownSizeHighRatioDecodes() {
    let payload = buildCompressibleJSON(repeats: 60_000)
    guard let frame = ZstdTestSupport.compressUnknown(payload) else {
      XCTFail("could not synthesize high-ratio unknown-size zstd")
      return
    }
    XCTAssertFalse(ZstdTestSupport.frameHasContentSize(frame), "fixture must NOT carry content size")
    XCTAssertGreaterThan(payload.count, frame.count * 8, "fixture must exercise decoded > 8x input")

    let decoded = ZstdBridge.decompress(frame)
    XCTAssertNotNil(decoded, "high-ratio unknown-size must decompress (old 8x buffer regressed here)")
    XCTAssertEqual(String(data: decoded ?? Data(), encoding: .utf8), payload)
  }

  // 4. Corrupt / non-zstd bytes — must fail cleanly, never fall back to raw.
  func testCorruptZstdFails() {
    let payload = buildCompressibleJSON("corrupt", repeats: 40_000)
    guard let frame = ZstdTestSupport.compressUnknown(payload), frame.count > 16 else {
      XCTFail("could not synthesize corrupt fixture")
      return
    }
    var corrupt = frame
    corrupt.removeLast(corrupt.count / 4)
    XCTAssertNil(ZstdBridge.decompress(corrupt), "corrupt frame must return nil")
    XCTAssertNil(ZstdBridge.decompress(Data("definitely not zstd".utf8)), "non-zstd must return nil")
  }

  // 5. Truncated / partial trailing data — must fail cleanly.
  func testTruncatedZstdFails() {
    let payload = buildCompressibleJSON("truncated", repeats: 40_000)
    guard let frame = ZstdTestSupport.compressUnknown(payload) else {
      XCTFail("could not synthesize truncated fixture")
      return
    }
    let truncated = frame.prefix(frame.count / 5)
    XCTAssertNil(ZstdBridge.decompress(Data(truncated)), "truncated frame must return nil")
  }
}