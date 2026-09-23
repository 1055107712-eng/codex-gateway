import XCTest
import Combine
@testable import CodexGateway

/// Validates the unified localization engine (`AppLanguage` / `L10n` /
/// `L10nTable`) plus `ModelRouteStandard.Strings` delegation. Pure Foundation —
/// no SwiftUI / AppKit needed, so these also run under the `swiftc` harness on a
/// CommandLineTools-only machine. Never touches the real app or Codex config.
final class LocalizationTests: XCTestCase {
  /// Unique throwaway suite per test so assertions never collide.
  private var suiteName = "cg.loc.\(UUID().uuidString)"
  private var defaults: UserDefaults!
  private let officialName = "com.rimusz.CodexGateway"
  private let cnTestName = "com.rimusz.CodexGateway.CNTest"

  override func setUp() {
    super.setUp()
    suiteName = "cg.loc.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
    defaults.removePersistentDomain(forName: suiteName)
    AppLanguage.systemCodeOverride = nil
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    AppLanguage.systemCodeOverride = nil
    super.tearDown()
  }

  private func makeL10n() -> L10n { L10n(defaults: defaults) }

  private func withSystem(_ code: String, _ body: () -> Void) {
    AppLanguage.systemCodeOverride = code
    body()
    AppLanguage.systemCodeOverride = nil
  }

  // MARK: 1–2 automatic follows system

  func testAutomaticZhSystemResolvesToZH() {
    withSystem("zh-Hans") {
      let l = makeL10n()
      XCTAssertEqual(l.resolvedCode, "zh-Hans")
      XCTAssertEqual(l.resolvedTableTag, "zh-Hans")
      XCTAssertEqual(l.text(.settingsTitle), "设置")
    }
  }

  func testAutomaticEnglishSystemResolvesToEN() {
    withSystem("en") {
      let l = makeL10n()
      XCTAssertEqual(l.resolvedCode, "en")
      XCTAssertEqual(l.resolvedTableTag, "en")
      XCTAssertEqual(l.text(.settingsTitle), "Settings")
    }
  }

  // MARK: 3–4 manual overrides

  func testManualZHOverridesEnglishSystem() {
    withSystem("en") {
      let l = makeL10n()
      l.setLanguage(.zhHans)
      XCTAssertEqual(l.resolvedTableTag, "zh-Hans")
      XCTAssertEqual(l.text(.modelRoute), "模型线路")
    }
  }

  func testManualEnglishOverridesChineseSystem() {
    withSystem("zh-Hans") {
      let l = makeL10n()
      l.setLanguage(.english)
      XCTAssertEqual(l.resolvedTableTag, "en")
      XCTAssertEqual(l.text(.modelRoute), "Model Route")
    }
  }

  // MARK: 5 preference persisted

  func testLanguagePreferencePersists() {
    let l = makeL10n()
    l.setLanguage(.zhHans)
    XCTAssertEqual(defaults.string(forKey: L10n.languageKey), "zh-Hans")
    XCTAssertEqual(makeL10n().language, .zhHans)
  }

  // MARK: 6 CN Test / official isolation

  func testCNTestAndOfficialUserDefaultsIsolate() {
    AppVariant.testOverride = .official
    let officialSuiteName = AppIdentity.userDefaultsSuite
    AppVariant.testOverride = .cnTest
    let cnTestSuiteName = AppIdentity.userDefaultsSuite
    AppVariant.testOverride = nil
    XCTAssertNotEqual(officialSuiteName, cnTestSuiteName)

    let official = UserDefaults(suiteName: officialSuiteName)!
    let cnTest = UserDefaults(suiteName: cnTestSuiteName)!
    official.removePersistentDomain(forName: officialSuiteName)
    cnTest.removePersistentDomain(forName: cnTestSuiteName)
    defer {
      official.removePersistentDomain(forName: officialSuiteName)
      cnTest.removePersistentDomain(forName: cnTestSuiteName)
    }

    L10n(defaults: cnTest).setLanguage(.english)
    XCTAssertEqual(L10n(defaults: official).language, .automatic)
    XCTAssertEqual(L10n(defaults: cnTest).language, .english)
  }

  // MARK: 7–8 keys resolve in both languages

  func testAllZHKKeysHaveValues() {
    for key in L10nKey.allCases {
      let value = L10n.shared.resolve(rawKey: key.rawValue, language: "zh-Hans")
      XCTAssertFalse(value.isEmpty, "empty zh value for \(key.rawValue)")
      XCTAssertNotEqual(value, key.rawValue, "zh table missing key \(key.rawValue)")
    }
    XCTAssertEqual(L10nTable.zhHans[L10nKey.modelRoute.rawValue], "模型线路")
  }

  func testAllEnglishKeysHaveValues() {
    for key in L10nKey.allCases {
      let value = L10n.shared.resolve(rawKey: key.rawValue, language: "en")
      XCTAssertFalse(value.isEmpty, "empty en value for \(key.rawValue)")
      XCTAssertNotEqual(value, key.rawValue, "en table missing key \(key.rawValue)")
    }
    XCTAssertEqual(L10nTable.english[L10nKey.modelRoute.rawValue], "Model Route")
  }

  // MARK: 9 missing-key fallback

  func testMissingKeyFallsBackToRawId() {
    let l = makeL10n()
    XCTAssertEqual(l.resolve(rawKey: "does.not.exist", language: "zh-Hans"), "does.not.exist")
    XCTAssertEqual(l.resolve(rawKey: "does.not.exist", language: "en"), "does.not.exist")
  }

  // MARK: 10 Model Route copy

  func testModelRouteChineseCopy() {
    withSystem("zh-Hans") {
      let l = L10n.shared
      XCTAssertEqual(l.text(.confirmSwitchOpenAI), "将修改 Codex 的模型线路设置，并自动创建 config.toml 备份。")
      XCTAssertEqual(l.text(.confirmSwitchGateway), "将恢复 CodexGateway 模型线路，并自动创建 config.toml 备份。")
      XCTAssertTrue(l.text(.successOpenAI).contains("请重新启动 Codex"))
      XCTAssertTrue(l.text(.successGateway).contains("请重新启动 Codex"))
      XCTAssertEqual(l.text(.failurePrefix), "无法修改 Codex 配置。\n已自动恢复原配置。")
    }
  }

  func testModelRouteStringsDelegateToL10n() {
    withSystem("zh-Hans") {
      XCTAssertEqual(ModelRouteStandard.Strings.sectionTitle, "模型线路")
      XCTAssertEqual(
        ModelRouteStandard.Strings.confirmSwitch(.official),
        "将修改 Codex 的模型线路设置，并自动创建 config.toml 备份。"
      )
      XCTAssertTrue(ModelRouteStandard.Strings.success(.gateway).contains("CodexGateway"))
      XCTAssertTrue(ModelRouteStandard.Strings.failurePrefix.contains("无法修改 Codex"))
    }
  }

  // MARK: 11 AppKit menu keys

  func testAppKitMenuKeysResolve() {
    withSystem("zh-Hans") {
      XCTAssertEqual(L10n.shared.text(.sbSettings), "设置")
      XCTAssertEqual(L10n.shared.text(.sbQuit), "退出")
      XCTAssertEqual(L10n.shared.text(.sbRestartCodex), "重启 Codex")
      XCTAssertEqual(L10n.shared.text(.sbRunning), "运行中")
    }
    XCTAssertEqual(L10n.shared.text(.sbSettings, language: "en"), "Settings")
    XCTAssertEqual(L10n.shared.text(.sbQuit, language: "en"), "Quit")
  }

  // MARK: 12 change notification / refresh

  func testLanguageChangePostsNotification() {
    let l = makeL10n()
    var count = 0
    let token = NotificationCenter.default.addObserver(
      forName: L10n.didChangeNotification, object: l, queue: nil) { _ in count += 1 }

    l.setLanguage(.zhHans)
    l.setLanguage(.zhHans) // no-op must not post
    l.setLanguage(.english)
    XCTAssertEqual(count, 2)

    NotificationCenter.default.removeObserver(token)
  }
}