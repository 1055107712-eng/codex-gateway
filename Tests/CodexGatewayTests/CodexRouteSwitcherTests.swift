import XCTest
@testable import CodexGateway

final class CodexRouteSwitcherTests: XCTestCase {
  /// Temp config path unique per test.
  var configURL: URL!
  var fakeHome: URL!

  override func setUp() {
    super.setUp()
    fakeHome = FileManager.default.temporaryDirectory
      .appendingPathComponent("cg-route-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: fakeHome, withIntermediateDirectories: true)
    configURL = fakeHome.appendingPathComponent("config.toml")
    AppVariant.testOverride = .official
  }

  override func tearDown() {
    AppVariant.testOverride = nil
    try? FileManager.default.removeItem(at: fakeHome)
    super.tearDown()
  }

  /// A representative full config: managed gateway block, provider table, extra top-level keys.
  func writeConfig(_ text: String) {
    try? Data(text.utf8).write(to: configURL)
  }

  func readConfig() -> String {
    try! String(contentsOf: configURL, encoding: .utf8)
  }

  func switcher(preferences: RoutePreferences = RoutePreferences()) -> CodexRouteSwitcher {
    CodexRouteSwitcher(configPath: configURL.path, preferences: preferences)
  }

  let sampleConfig = """
  # >>> codexgateway managed >>>
  model_provider = "codexgateway"
  model_catalog_json = "/Users/t/odi/.codex/model-catalogs/custom-providers.json"
  openai_base_url = "http://127.0.0.1:8765/v1"
  # <<< codexgateway managed <<<

  model_reasoning_effort = "low"

  notify = ["turn-ended"]
  model = "zhishu-auto/zhishu-auto"

  [desktop]
  followUpQueueMode = "queue"
  localeOverride = "zh-CN"

  [model_providers.codexgateway]
  name = "CodexGateway"
  base_url = "http://127.0.0.1:8765/v1"
  wire_api = "responses"
  requires_openai_auth = true
  experimental_bearer_token = "token-secret-do-not-log"

  [model_providers.other]
  name = "Other"
  api_key = "some-key"
  """

  // MARK: 1. Gateway -> OpenAI

  func testGatewayToOpenAI() throws {
    writeConfig(sampleConfig)
    let result = try switcher().switchToOpenAI()
    XCTAssertEqual(result.route, .openAI)
    let snap = try switcher().read()
    XCTAssertEqual(snap.modelProvider, "openai")
    XCTAssertEqual(snap.model, "gpt-5.6-sol")
    XCTAssertEqual(snap.openAIBaseURL, .commented("http://127.0.0.1:8765/v1"))
    // provider table must remain intact
    XCTAssertTrue(readConfig().contains("[model_providers.codexgateway]"))
    XCTAssertTrue(readConfig().contains("name = \"CodexGateway\""))
  }

  // MARK: 2. OpenAI -> Gateway

  func testOpenAIToGateway() throws {
    writeConfig(sampleConfig)
    _ = try switcher().switchToOpenAI()
    let result = try switcher().switchToGateway()
    XCTAssertEqual(result.route, .gateway)
    let snap = try switcher().read()
    XCTAssertEqual(snap.modelProvider, "codexgateway")
    XCTAssertEqual(snap.model, "zhishu-auto/zhishu-auto")
    XCTAssertEqual(snap.openAIBaseURL, .active("http://127.0.0.1:8765/v1"))
  }

  // MARK: 3. Gateway -> OpenAI -> Gateway roundtrip

  func testRoundTrip() throws {
    writeConfig(sampleConfig)
    _ = try switcher().switchToOpenAI()
    _ = try switcher().switchToGateway()
    let snap = try switcher().read()
    XCTAssertEqual(snap.modelProvider, "codexgateway")
    XCTAssertEqual(snap.model, "zhishu-auto/zhishu-auto")
    XCTAssertEqual(snap.openAIBaseURL, .active("http://127.0.0.1:8765/v1"))
    // provider section byte-identical to the original
    XCTAssertEqual(readConfig(), sampleConfig)
  }

  // MARK: 4. openai_base_url already active (to OpenAI -> commented)

  func testActiveBaseURLGetsDisabledOnOpenAI() throws {
    writeConfig(sampleConfig)
    _ = try switcher().switchToOpenAI()
    let text = readConfig()
    XCTAssertTrue(text.contains("# openai_base_url = \"http://127.0.0.1:8765/v1\" # disabled by CodexGateway route switcher"))
    XCTAssertFalse(text.contains("\nopenai_base_url = \"http://127.0.0.1:8765/v1\""))
  }

  // MARK: 5. openai_base_url already commented (stays commented on OpenAI)

  func testCommentedBaseURLStaysCommented() throws {
    let cfg = sampleConfig.replacingOccurrences(
      of: "openai_base_url = \"http://127.0.0.1:8765/v1\"",
      with: "# openai_base_url = \"http://127.0.0.1:8765/v1\" # disabled by CodexGateway route switcher"
    )
    writeConfig(cfg)
    _ = try switcher().switchToOpenAI()
    XCTAssertEqual(try switcher().read().openAIBaseURL, .commented("http://127.0.0.1:8765/v1"))
    // switching back reactivates it
    _ = try switcher().switchToGateway()
    XCTAssertEqual(try switcher().read().openAIBaseURL, .active("http://127.0.0.1:8765/v1"))
  }

  // MARK: 6. openai_base_url entirely absent

  func testMissingBaseURLIsInserted() throws {
    let cfg = sampleConfig.replacingOccurrences(
      of: "openai_base_url = \"http://127.0.0.1:8765/v1\"\n", with: ""
    )
    XCTAssertFalse(cfg.contains("openai_base_url"))
    writeConfig(cfg)
    _ = try switcher().switchToGateway()
    let snap = try switcher().read()
    XCTAssertEqual(snap.openAIBaseURL, .active("http://127.0.0.1:8765/v1"))
    // provider block still intact
    XCTAssertTrue(readConfig().contains("[model_providers.codexgateway]"))
  }

  // MARK: 7. model_provider / model missing -> safe insertion

  func testMissingProviderAndModelInserted() throws {
    var cfg = "--comment only\n"
    // no model_provider / no model / no base_url
    writeConfig(cfg)
    _ = try switcher().switchToGateway()
    let snap = try switcher().read()
    XCTAssertEqual(snap.modelProvider, "codexgateway")
    XCTAssertEqual(snap.model, "zhishu-auto/zhishu-auto")
    XCTAssertEqual(snap.openAIBaseURL, .active("http://127.0.0.1:8765/v1"))
  }

  // MARK: 8. provider sections unchanged

  func testProviderSectionsPreservedByteForByte() throws {
    writeConfig(sampleConfig)
    _ = try switcher().switchToOpenAI()
    let after = readConfig()
    XCTAssertTrue(after.contains("""
    [model_providers.codexgateway]
    name = "CodexGateway"
    base_url = "http://127.0.0.1:8765/v1"
    wire_api = "responses"
    requires_openai_auth = true
    experimental_bearer_token = "token-secret-do-not-log"
    """))
    XCTAssertTrue(after.contains("""
    [model_providers.other]
    name = "Other"
    api_key = "some-key"
    """))
  }

  // MARK: 9. model_catalog_json unchanged

  func testModelCatalogJSONUnchanged() throws {
    writeConfig(sampleConfig)
    let before = readConfig()
    _ = try switcher().switchToOpenAI()
    let after = readConfig()
    let catalogLineBefore = before.split(separator: "\n").first { $0.contains("model_catalog_json") }
    let catalogLineAfter = after.split(separator: "\n").first { $0.contains("model_catalog_json") }
    XCTAssertEqual(catalogLineAfter, catalogLineBefore)
  }

  // MARK: 10. comments / blank lines preserved

  func testCommentsAndBlankLinesPreserved() throws {
    writeConfig(sampleConfig)
    let before = readConfig()
    _ = try switcher().switchToOpenAI()
    let after = readConfig()
    // the non-target lines must appear identically
    for line in before.split(separator: "\n") where !line.contains("model_provider")
      && !line.contains("\"model\" =") && !line.contains("openai_base_url")
      && !line.hasPrefix("model =") {
      XCTAssertTrue(after.contains(line) || line.hasPrefix("#"), "lost line: \(line)")
    }
    XCTAssertTrue(after.contains("model_reasoning_effort = \"low\""))
  }

  // MARK: 11. write failure -> rollback

  func testWriteFailureRollsBack() throws {
    writeConfig(sampleConfig)
    // Make the parent dir read-only so temp-file creation fails.
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fakeHome.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeHome.path)
    }
    XCTAssertThrowsError(try switcher().switchToOpenAI()) { error in
      XCTAssertFalse(String(describing: error).contains("token-secret"))
      XCTAssertFalse(String(describing: error).contains("some-key"))
    }
    // original file untouched (write never happened)
    XCTAssertEqual(readConfig(), sampleConfig)
  }

  // MARK: 12. backup file created

  func testBackupCreated() throws {
    writeConfig(sampleConfig)
    _ = try switcher().switchToOpenAI()
    let files = (try? FileManager.default.contentsOfDirectory(atPath: fakeHome.path)) ?? []
    let backups = files.filter { $0.hasPrefix("config.toml") && $0.contains(".codexgateway-ui.bak.") }
    XCTAssertEqual(backups.count, 1)
    let backup = try String(contentsOf: fakeHome.appendingPathComponent(backups[0]), encoding: .utf8)
    XCTAssertEqual(backup, sampleConfig)  // backup holds the pre-switch bytes
  }

  // MARK: 13. officialModel custom value

  func testCustomOfficialModel() throws {
    writeConfig(sampleConfig)
    let prefs = RoutePreferences(officialModel: "gpt-6-x")
    _ = try CodexRouteSwitcher(configPath: configURL.path, preferences: prefs).switchToOpenAI()
    XCTAssertEqual(try switcher(preferences: prefs).read().model, "gpt-6-x")
  }

  // MARK: 14. tokens/keys never leak into read or errors

  func testNoSecretLeak() throws {
    writeConfig(sampleConfig)
    let snap = try switcher().read()
    // Snapshot carries only model/provider/baseURL — never a key value.
    let dump = "\(snap)"
    XCTAssertFalse(dump.contains("token-secret"))
    XCTAssertFalse(dump.contains("some-key"))
    // A failing read message must not carry secrets either.
    try? FileManager.default.removeItem(at: configURL)
    XCTAssertThrowsError(try switcher().read()) { error in
      let msg = "\(error)"
      XCTAssertFalse(msg.contains("token-secret"))
      XCTAssertFalse(msg.contains("some-key"))
    }
  }

  // MARK: 15. idempotent repeat

  func testIdempotentRepeat() throws {
    writeConfig(sampleConfig)
    _ = try switcher().switchToGateway()       // no-op already gateway
    let afterFirst = readConfig()
    XCTAssertEqual(afterFirst, sampleConfig)
    let result = try switcher().switchToGateway()  // repeat
    XCTAssertEqual(result.route, .gateway)
    XCTAssertEqual(readConfig(), sampleConfig)
    // switching to OpenAI twice is safe
    _ = try switcher().switchToOpenAI()
    _ = try switcher().switchToOpenAI()
    let snap = try switcher().read()
    XCTAssertEqual(snap.modelProvider, "openai")
  }
}

// MARK: - RoutePreferences / AppVariant isolation

final class RoutePreferencesAndVariantTests: XCTestCase {
  func testVariantIsolationByBundleIDStyleSuffix() {
    // Bundle.main has no CNTest suffix here; falling back to .official is safe.
    AppVariant.testOverride = nil
    // Force through env path for determinism:
    XCTAssertEqual(AppVariant.official.productName, "CodexGateway")
    XCTAssertEqual(AppVariant.cnTest.productName, "CodexGateway CN Test")
    XCTAssertEqual(AppVariant.cnTest.bundleIdentifier, "com.rimusz.CodexGateway.CNTest")
    XCTAssertEqual(AppVariant.official.bundleIdentifier, "com.rimusz.CodexGateway")
    XCTAssertNotEqual(AppVariant.cnTest.userDefaultsSuite, AppVariant.official.userDefaultsSuite)
  }

  func testDefaultOfficialModel() {
    let prefs = RoutePreferences()
    XCTAssertEqual(prefs.officialModel, "gpt-5.6-sol")
    let custom = RoutePreferences(officialModel: "gpt-x")
    XCTAssertEqual(custom.officialModel, "gpt-x")
    // empty guards back to default
    XCTAssertEqual(RoutePreferences(officialModel: "").officialModel, "gpt-5.6-sol")
  }
}