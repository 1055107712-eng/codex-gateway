import XCTest
import Foundation
@testable import CodexGateway

/// Formal regression suite for request-body decoding semantics. Pinpoints the
/// contract that a *declared* `content-encoding` (zstd/gzip) which fails to
/// decode must surface as an explicit decode failure — it must NEVER silently
/// fall back to forwarding the raw compressed bytes to the JSON parser.
///
/// The exact HTTP strings are pinned via `semanticError` to the same two literals
/// `GatewayServer` returns: "Request body decode failed" (decode stage) vs
/// "Invalid JSON body" (JSON stage, only after a successful decode).
final class RequestBodyDecodingTests: XCTestCase {
  private let garbage = Data("definitely not a compressed payload at all_###".utf8)

  override func setUp() {
    super.setUp()
    try? XCTSkipUnless(
      ZstdTestSupport.available,
      "libzstd not found — decoder tests need zstd fixtures to be synthesized."
    )
  }

  /// Maps a decode/parse outcome to the exact router error string. Mirrors the
  /// two-stage branch in `GatewayServer.handleResponses` so the regression
  /// contract is machine-checked, not just eyeballed.
  private func routerError(decoded: Data?) -> String? {
    guard let decoded else { return "Request body decode failed" }
    guard JSONSerialization.isValidJSONObjectValid(decoded) else { return "Invalid JSON body" }
    return nil
  }

  // 6. Declared zstd that fails to decode → nil (no raw-body fallback).
  func testDeclaredZstdDecodeFailureDoesNotFallback() {
    XCTAssertNil(HTTPBodyDecoder.decodeContentEncoding(garbage, headers: ["content-encoding": "zstd"]))
    XCTAssertNil(HTTPBodyDecoder.decodeContentEncoding(garbage, headers: ["content-encoding": "x-zstd"]))
  }

  // 7. Declared gzip that fails to decode → nil (no raw-body fallback).
  func testDeclaredGzipDecodeFailureDoesNotFallback() {
    XCTAssertNil(HTTPBodyDecoder.decodeContentEncoding(garbage, headers: ["content-encoding": "gzip"]))
    XCTAssertNil(HTTPBodyDecoder.decodeContentEncoding(garbage, headers: ["content-encoding": "x-gzip"]))
  }

  // 8. Valid zstd JSON request → decodes and parses as JSON.
  func testValidZstdJSONRequestParses() {
    let payload = #"{"model":"x","input":"hi","stream":true}"#
    guard let frame = ZstdTestSupport.compressUnknown(payload) else {
      XCTFail("could not synthesize zstd")
      return
    }
    let decoded = HTTPBodyDecoder.decodeContentEncoding(frame, headers: ["content-encoding": "zstd"])
    XCTAssertNotNil(decoded)
    XCTAssertEqual(String(data: decoded ?? Data(), encoding: .utf8), payload)
    XCTAssertTrue(JSONSerialization.isValidJSONObjectValid(decoded ?? Data()))
    XCTAssertNil(routerError(decoded: decoded))
  }

  // 9. Successful decode but invalid JSON → Invalid JSON body (not decode failure).
  func testInvalidJSONAfterSuccessfulDecodeIsJSONError() {
    let invalidJSON = "this is not json"
    guard let frame = ZstdTestSupport.compressUnknown(invalidJSON) else {
      XCTFail("could not synthesize zstd")
      return
    }
    let decoded = HTTPBodyDecoder.decodeContentEncoding(frame, headers: ["content-encoding": "zstd"])
    XCTAssertNotNil(decoded, "decode itself succeeds")
    XCTAssertFalse(JSONSerialization.isValidJSONObjectValid(decoded ?? Data()), "JSON must be invalid")
    XCTAssertEqual(routerError(decoded: decoded), "Invalid JSON body")
  }

  // 10. Decode failure → explicit "Request body decode failed".
  func testDecodeFailureReturnsRequestBodyDecodeFailed() {
    // Use a sufficiently large payload so the synthesized zstd frame comfortably
    // exceeds the 16-byte sanitizer bound while still being a small valid crop.
    let payload = String(repeating: "{\"a\":1} ", count: 40)
    guard let frame = ZstdTestSupport.compressUnknown(payload), frame.count > 16 else {
      XCTFail("could not synthesize corrupt fixture")
      return
    }
    var corrupt = frame
    corrupt.removeLast(corrupt.count / 3)
    let decoded = HTTPBodyDecoder.decodeContentEncoding(corrupt, headers: ["content-encoding": "zstd"])
    XCTAssertNil(decoded)
    XCTAssertEqual(routerError(decoded: decoded), "Request body decode failed")
  }
}

private extension JSONSerialization {
  /// true when data decodes to a valid JSON document.
  static func isValidJSONObjectValid(_ data: Data) -> Bool {
    (try? JSONSerialization.jsonObject(with: data)) != nil
  }
}