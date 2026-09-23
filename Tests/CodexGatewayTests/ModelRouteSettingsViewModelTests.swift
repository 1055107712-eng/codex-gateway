import XCTest
import Combine
@testable import CodexGateway

/// Validates `ModelRouteStandard` (pure) and `ModelRouteSettingsViewModel`.
///
/// These run under Xcode / `swift test` on a full toolchain. The same 10
/// scenarios are also run CLT-only via the standalone `swiftc` harness. Only
/// temporary config files under the system temp dir are touched — never
/// `~/.codex/config.toml`.
final class ModelRouteSettingsViewModelTests: XCTestCase {
  var tempDir: URL!
  var configURL: URL!
  var defaults: UserDefaults!
  private var defaultsSuiteName: String = ""

  override func setUp() {
    super.setUp()
    tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("cg-vm-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    configURL = tempDir.appendingPathComponent("config.toml")
    defaultsSuiteName = "cg.vm.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: defaultsSuiteName)
  }

  override func tearDown() {
    if !defaultsSuiteName.isEmpty {
      defaults.removePersistentDomain(forName: defaultsSuiteName)
    }
    try? FileManager.default.removeItem(at: tempDir)
    super.tearDown()
  }

  private var gatewayConfig: String {
    """
    model_provider = "codexgateway"
    model_catalog_json = "/tmp/x.json"
    openai_base_url = "http://127.0.0.1:8765/v1"
    model = "zhishu-auto/zhishu-auto"

    [model_providers.codexgateway]
    name = "CodexGateway"
    experimental_bearer_token = "token-secret-do-not-log"
    """
  }

  private var openaiConfig: String {
    """
    model_provider = "openai"
    model_catalog_json = "/tmp/x.json"
    # openai_base_url = "http://127.0.0.1:8765/v1" # disabled by CodexGateway route switcher
    model = "gpt-5.6-sol"

    [model_providers.codexgateway]
    name = "CodexGateway"
    experimental_bearer_token = "token-secret-do-not-log"
    """
  }

  private func writeConfig(_ text: String) throws {
    try Data(text.utf8).write(to: configURL)
  }

  private func makeVM(
    probe: @escaping @Sendable () async -> Bool = { true }
  ) -> ModelRouteSettingsViewModel {
    ModelRouteSettingsViewModel(configPath: configURL.path, defaults: defaults, probeGateway: probe)
  }

  private func snapshot(_ vm: ModelRouteSettingsViewModel) -> ModelRouteStandard.Snapshot? {
    vm.snapshot
  }

  // MARK: pure derive

  func testDeriveGateway() {
    let snap = ModelRouteStandard.derive(
      from: CodexRouteSnapshot(
        modelProvider: "codexgateway", model: "zhishu-auto/zhishu-auto",
        openAIBaseURL: .active("http://127.0.0.1:8765/v1")),
      gatewayRunning: true)
    XCTAssertEqual(snap.route, .gateway)
    XCTAssertEqual(snap.model, "zhishu-auto/zhishu-auto")
    XCTAssertEqual(snap.modelProvider, "codexgateway")
    XCTAssertEqual(snap.gatewayAddress, "127.0.0.1:8765")
    XCTAssertTrue(snap.gatewayRunning)
  }

  func testDeriveOpenAIAndUnknown() {
    let open = ModelRouteStandard.derive(
      from: CodexRouteSnapshot(modelProvider: "openai", model: "gpt-5.6-sol", openAIBaseURL: .absent),
      gatewayRunning: false)
    XCTAssertEqual(open.route, .official)
    XCTAssertFalse(open.gatewayRunning)

    let unk = ModelRouteStandard.derive(
      from: CodexRouteSnapshot(modelProvider: nil, model: nil, openAIBaseURL: .absent),
      gatewayRunning: false)
    XCTAssertEqual(unk.route, .unknown)
  }

  // MARK: 1–3 status → UI state

  func testGatewayStatusMapsToUIState() async throws {
    try writeConfig(gatewayConfig)
    let vm = makeVM()
    await vm.refresh()
    guard case .loaded(let snap) = vm.loadState else { return XCTFail("not loaded") }
    XCTAssertEqual(snap.route, .gateway)
    XCTAssertTrue(snap.gatewayRunning)
    XCTAssertEqual(snap.modelProvider, "codexgateway")
  }

  func testOpenAIStatusMapsToUIState() async throws {
    try writeConfig(openaiConfig)
    let vm = makeVM()
    await vm.refresh()
    guard case .loaded(let snap) = vm.loadState else { return XCTFail("not loaded") }
    XCTAssertEqual(snap.route, .official)
    XCTAssertEqual(snap.model, "gpt-5.6-sol")
  }

  func testUnknownRoute() async throws {
    try writeConfig("-- only a comment\n")
    let vm = makeVM()
    await vm.refresh()
    guard case .loaded(let snap) = vm.loadState else { return XCTFail("not loaded") }
    XCTAssertEqual(snap.route, .unknown)
  }

  // MARK: 4–6 switch outcomes

  func testSwitchToOpenAISuccess() async throws {
    try writeConfig(gatewayConfig)
    let vm = makeVM()
    await vm.refresh()
    await vm.switchToOfficial()
    XCTAssertNotNil(vm.successMessage)
    XCTAssertTrue(vm.successMessage?.contains("OpenAI") == true)
    XCTAssertNil(vm.errorMessage)
    XCTAssertEqual(snapshot(vm)?.route, .official)
    XCTAssertEqual(snapshot(vm)?.model, "gpt-5.6-sol")
  }

  func testSwitchToGatewaySuccess() async throws {
    try writeConfig(openaiConfig)
    let vm = makeVM()
    await vm.refresh()
    await vm.switchToGateway()
    XCTAssertNotNil(vm.successMessage)
    XCTAssertTrue(vm.successMessage?.contains("CodexGateway") == true)
    XCTAssertEqual(snapshot(vm)?.route, .gateway)
  }

  func testSwitchErrorSetsMessageAndClearsSuccess() async throws {
    try writeConfig(gatewayConfig)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: tempDir.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempDir.path) }
    let vm = makeVM()
    await vm.switchToOfficial()
    XCTAssertNotNil(vm.errorMessage)
    // Message is now localized; compare against the current UI-language prefix.
    XCTAssertTrue(vm.errorMessage?.hasPrefix(L10n.shared.text(.failurePrefix)) == true)
    XCTAssertNil(vm.successMessage)
  }

  // MARK: 7–9 preference / refresh / success

  func testOfficialModelPreferencePersistsAndIsHonored() async throws {
    try writeConfig(gatewayConfig)
    let vm = makeVM()
    vm.officialModel = "gpt-6-x"
    vm.persistOfficialModel()
    XCTAssertEqual(RoutePreferences.load(defaults: defaults).officialModel, "gpt-6-x")
    await vm.switchToOfficial()
    XCTAssertEqual(snapshot(vm)?.model, "gpt-6-x")
  }

  func testRefreshReDerivesGatewayRunning() async throws {
    try writeConfig(gatewayConfig)
    var running = false
    let probe: @Sendable () async -> Bool = { running }
    let vm = makeVM(probe: probe)
    await vm.refresh()
    XCTAssertEqual(vm.snapshot?.gatewayRunning, false)
    running = true
    await vm.refresh()
    XCTAssertEqual(vm.snapshot?.gatewayRunning, true)
  }

  func testSuccessMessageDismiss() async throws {
    try writeConfig(gatewayConfig)
    let vm = makeVM()
    await vm.switchToOfficial()
    XCTAssertNotNil(vm.successMessage)
    vm.dismissSuccess()
    XCTAssertNil(vm.successMessage)
  }

  // MARK: 10 secrets never leak

  func testSecretNotInErrorMessage() async throws {
    try writeConfig(gatewayConfig)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: tempDir.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempDir.path) }
    let vm = makeVM()
    await vm.switchToOfficial()
    let msg = vm.errorMessage ?? ""
    // The error may legitimately name the backup file (…codexgateway-ui.bak…),
    // but it must never embed the config body or any credential.
    XCTAssertFalse(msg.contains("token-secret-do-not-log"))
    XCTAssertFalse(msg.contains("model_provider ="))
    XCTAssertFalse(msg.contains("zhishu-auto"))
  }
}