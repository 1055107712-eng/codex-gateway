import Foundation
import Combine

/// User-facing app language.
///
/// Persisted per build variant in `AppIdentity.userDefaultsSuite` so the
/// production app and CN Test never share a language choice. `automatic` follows
/// the system language.
enum AppLanguage: String, CaseIterable, Equatable, Sendable {
  case automatic
  case zhHans = "zh-Hans"
  case english = "en"

  /// Display label shown in the language picker. `automatic` is localized to
  /// follow the currently selected UI language; the concrete languages use their
  /// native names so they are self-describing in every UI.
  var displayName: String {
    switch self {
    case .automatic: return L10n.shared.text(.languageAutomatic)
    case .zhHans: return "简体中文"
    case .english: return "English"
    }
  }

  /// `zh-Hans` / `en` when manually chosen; else the code implied by the system.
  var resolvedCode: String {
    switch self {
    case .zhHans: return "zh-Hans"
    case .english: return "en"
    case .automatic: return AppLanguage.systemCode()
    }
  }

  /// Short key for table lookup.
  var tableTag: String {
    switch self {
    case .zhHans: return "zh-Hans"
    case .automatic: return resolvedCode == "zh-Hans" ? "zh-Hans" : "en"
    case .english: return "en"
    }
  }

  /// Test seam (mirrors `AppVariant.testOverride`) so unit tests can simulate a
  /// Chinese / English system locale on a host whose real language differs.
  static var systemCodeOverride: String?

  static func systemCode() -> String {
    if let override = systemCodeOverride { return override }
    let first = Locale.preferredLanguages.first ?? Locale.current.language.languageCode?.identifier ?? "en"
    if first.lowercased().hasPrefix("zh") { return "zh-Hans" }
    return "en"
  }
}

/// Semantic keys. Raw values are stable ids (not user-facing text); missing-table
/// lookups fall back to the English table, then to the raw id — never a crash.
enum L10nKey: String, CaseIterable {
  // Settings chrome
  case settingsTitle = "settings.title"
  case settingsNavigation = "settings.navigation"
  case providersAndModels = "settings.providersAndModels"
  case providersAndModelsSubtitle = "settings.providersAndModels.subtitle"
  case doctor = "doctor.title"
  case refresh = "common.refresh"
  case language = "common.language"
  case languageAutomatic = "common.languageAutomatic"

  // Section headers
  case providers = "settings.providers"
  case addProvider = "settings.addProvider"
  case models = "settings.models"
  case modelRoute = "settings.modelRoute"
  case modelRouteSubtitle = "settings.modelRoute.subtitle"

  // Model route
  case currentRoute = "modelRoute.currentRoute"
  case routeOfficial = "modelRoute.routeOfficial"
  case routeGateway = "modelRoute.routeGateway"
  case routeUnknown = "modelRoute.routeUnknown"
  case currentModel = "modelRoute.currentModel"
  case modelProvider = "modelRoute.modelProvider"
  case gatewayAddress = "modelRoute.gatewayAddress"
  case gatewayStatus = "modelRoute.gatewayStatus"
  case running = "modelRoute.running"
  case notRunning = "modelRoute.notRunning"
  case officialModel = "modelRoute.officialModel"
  case officialModelHelp = "modelRoute.officialModelHelp"
  case switchToOfficial = "modelRoute.switchToOfficial"
  case switchToGateway = "modelRoute.switchToGateway"
  case refreshStatus = "modelRoute.refreshStatus"
  case loadingRoute = "modelRoute.loading"
  case confirmSwitchDialogTitle = "modelRoute.confirmSwitchDialogTitle"
  case confirmSwitchOpenAI = "modelRoute.confirmSwitchOpenAI"
  case confirmSwitchGateway = "modelRoute.confirmSwitchGateway"
  case successOpenAI = "modelRoute.successOpenAI"
  case successGateway = "modelRoute.successGateway"
  case failurePrefix = "modelRoute.failurePrefix"

  // Status bar / AppKit
  case sbReady = "statusbar.ready"
  case sbLoading = "statusbar.loading"
  case sbError = "statusbar.error"
  case sbOffline = "statusbar.offline"
  case sbRunning = "statusbar.running"
  case sbStarting = "statusbar.starting"
  case sbSettings = "statusbar.settings"
  case sbDoctor = "statusbar.doctor"
  case sbOpenAtLogin = "statusbar.openAtLogin"
  case sbCheckForUpdates = "statusbar.checkForUpdates"
  case sbUpgradeAvailable = "statusbar.upgradeAvailable"
  case sbCheckingForUpdates = "statusbar.checkingForUpdates"
  case sbRestartCodex = "statusbar.restartCodex"
  case sbAbout = "statusbar.about"
  case sbQuit = "statusbar.quit"
  case sbCursorBridgeOff = "statusbar.cursorBridge.off"
  case sbCursorBridgeStarting = "statusbar.cursorBridge.starting"
  case sbCursorBridgeStopped = "statusbar.cursorBridge.stopped"
  case sbCursorBridgeError = "statusbar.cursorBridge.error"
  case restartCodexDialogTitle = "statusbar.restartDialog.title"
  case restartCodexDialogMessage = "statusbar.restartDialog.message"
  case restartButton = "common.restartButton"
  case cancel = "common.cancel"
  case ok = "common.ok"

  // General
  case save = "common.save"
  case apply = "common.apply"
  case start = "common.start"
  case stop = "common.stop"
  case restart = "common.restart"
  case testConnection = "common.testConnection"
  case advanced = "common.advanced"
  case logs = "common.logs"
  case about = "common.about"
  case version = "common.version"
  case baseURL = "common.baseURL"
  case apiKey = "common.apiKey"
  case modelID = "common.modelID"
  case modelProviderValue = "common.modelProviderValue"
}

/// Shared localization engine used by both SwiftUI and AppKit.
///
/// A single instance is shared through the process; `ObservableObject` drives
/// SwiftUI re-renders on change, while AppKit (StatusBar) observes the posted
/// notification to rebuild menus. The language is stored in the per-variant
/// `UserDefaults` suite.
final class L10n: ObservableObject {
  static let shared = L10n()
  static let languageKey = "codexgateway.l10n.language"
  static let didChangeNotification = Notification.Name("codexgateway.l10n.didChange")

  /// Chosen language (may be `.automatic`).
  @Published private(set) var language: AppLanguage
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .init(suiteName: AppIdentity.userDefaultsSuite) ?? .standard) {
    self.defaults = defaults
    let raw = defaults.string(forKey: Self.languageKey)
    self.language = raw.flatMap(AppLanguage.init(rawValue:)) ?? .automatic
  }

  /// The effective table tag honoring `automatic` → system.
  var resolvedCode: String { language.resolvedCode }

  var resolvedTableTag: String {
    let code = resolvedCode
    return code == "zh-Hans" ? "zh-Hans" : "en"
  }

  func setLanguage(_ newLanguage: AppLanguage) {
    guard newLanguage != language else { return }
    language = newLanguage
    defaults.set(newLanguage.rawValue, forKey: Self.languageKey)
    NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
  }

  /// Returns the localized text for `key` under the current (resolved) language,
  /// falling back to English then to the raw key id.
  func text(_ key: L10nKey) -> String {
    resolve(rawKey: key.rawValue, language: resolvedTableTag)
  }

  /// Raw (non-enum) lookup with the same fallback chain — also what `text(_:)`
  /// uses internally. Useful for dynamically composed keys.
  func resolve(rawKey: String, language tag: String) -> String {
    let table = tag == "zh-Hans" ? L10nTable.zhHans : L10nTable.english
    if let value = table[rawKey] { return value }
    if let en = L10nTable.english[rawKey] { return en }
    return rawKey
  }

  /// Same as `text(_:)` but honors a caller-supplied language tag (`zh-Hans`/`en`).
  func text(_ key: L10nKey, language tag: String) -> String {
    resolve(rawKey: key.rawValue, language: tag)
  }
}

/// Static translation tables. These are the canonical runtime source (pure,
/// Foundation-only, testable); `*.lproj/Localizable.strings` mirror them for
/// Apple-standard localization tooling.
enum L10nTable {
  static let english: [String: String] = [
    L10nKey.settingsTitle.rawValue: "Settings",
    L10nKey.settingsNavigation.rawValue: "CodexGateway Settings",
    L10nKey.providersAndModels.rawValue: "Providers & Models",
    L10nKey.providersAndModelsSubtitle.rawValue: "Manage OpenAI-compatible providers and catalog models for Codex Desktop.",
    L10nKey.doctor.rawValue: "Doctor",
    L10nKey.refresh.rawValue: "Refresh",
    L10nKey.language.rawValue: "Language",
    L10nKey.languageAutomatic.rawValue: "Automatic",
    L10nKey.providers.rawValue: "Providers",
    L10nKey.addProvider.rawValue: "Add Provider",
    L10nKey.models.rawValue: "Models",
    L10nKey.modelRoute.rawValue: "Model Route",
    L10nKey.modelRouteSubtitle.rawValue: "Route Codex through OpenAI or your local CodexGateway.",
    L10nKey.currentRoute.rawValue: "Current route",
    L10nKey.routeOfficial.rawValue: "OpenAI official",
    L10nKey.routeGateway.rawValue: "CodexGateway",
    L10nKey.routeUnknown.rawValue: "Unknown",
    L10nKey.currentModel.rawValue: "Current model",
    L10nKey.modelProvider.rawValue: "model_provider",
    L10nKey.gatewayAddress.rawValue: "Gateway address",
    L10nKey.gatewayStatus.rawValue: "Gateway status",
    L10nKey.running.rawValue: "Running",
    L10nKey.notRunning.rawValue: "Not running",
    L10nKey.officialModel.rawValue: "Official model",
    L10nKey.officialModelHelp.rawValue: "Used when switching to OpenAI. Saving here does not switch the route.",
    L10nKey.switchToOfficial.rawValue: "Switch to Official GPT",
    L10nKey.switchToGateway.rawValue: "Switch back to CodexGateway",
    L10nKey.refreshStatus.rawValue: "Refresh status",
    L10nKey.loadingRoute.rawValue: "Reading route…",
    L10nKey.confirmSwitchDialogTitle.rawValue: "Switch model route?",
    L10nKey.confirmSwitchOpenAI.rawValue: "This will change Codex's model route and automatically create a backup of config.toml.",
    L10nKey.confirmSwitchGateway.rawValue: "This will restore the CodexGateway model route and automatically create a backup of config.toml.",
    L10nKey.successOpenAI.rawValue: "Switched to OpenAI official.\nPlease restart Codex for the change to take full effect.",
    L10nKey.successGateway.rawValue: "Switched to CodexGateway.\nPlease restart Codex for the change to take full effect.",
    L10nKey.failurePrefix.rawValue: "Could not modify Codex config.",
    L10nKey.sbReady.rawValue: "Ready",
    L10nKey.sbLoading.rawValue: "Loading",
    L10nKey.sbError.rawValue: "Error",
    L10nKey.sbOffline.rawValue: "Offline",
    L10nKey.sbRunning.rawValue: "Running",
    L10nKey.sbStarting.rawValue: "Starting…",
    L10nKey.sbSettings.rawValue: "Settings",
    L10nKey.sbDoctor.rawValue: "Doctor…",
    L10nKey.sbOpenAtLogin.rawValue: "Open at Login",
    L10nKey.sbCheckForUpdates.rawValue: "Check for Updates…",
    L10nKey.sbUpgradeAvailable.rawValue: "Upgrade Available…",
    L10nKey.sbCheckingForUpdates.rawValue: "Checking for Updates…",
    L10nKey.sbRestartCodex.rawValue: "Restart Codex",
    L10nKey.sbAbout.rawValue: "About {name}",
    L10nKey.sbQuit.rawValue: "Quit",
    L10nKey.sbCursorBridgeOff.rawValue: "Cursor Bridge · {desc}",
    L10nKey.sbCursorBridgeStarting.rawValue: "Starting…",
    L10nKey.sbCursorBridgeStopped.rawValue: "Stopped",
    L10nKey.sbCursorBridgeError.rawValue: "Error",
    L10nKey.restartCodexDialogTitle.rawValue: "Restart Codex?",
    L10nKey.restartCodexDialogMessage.rawValue: "This will restart Codex Desktop so it can reload provider and model configuration.",
    L10nKey.restartButton.rawValue: "Restart Codex",
    L10nKey.cancel.rawValue: "Cancel",
    L10nKey.ok.rawValue: "OK",
    L10nKey.save.rawValue: "Save",
    L10nKey.apply.rawValue: "Apply",
    L10nKey.start.rawValue: "Start",
    L10nKey.stop.rawValue: "Stop",
    L10nKey.restart.rawValue: "Restart",
    L10nKey.testConnection.rawValue: "Test Connection",
    L10nKey.advanced.rawValue: "Advanced",
    L10nKey.logs.rawValue: "Logs",
    L10nKey.about.rawValue: "About",
    L10nKey.version.rawValue: "Version",
    L10nKey.baseURL.rawValue: "Base URL",
    L10nKey.apiKey.rawValue: "API Key",
    L10nKey.modelID.rawValue: "Model ID",
    L10nKey.modelProviderValue.rawValue: "model_provider",
  ]

  static let zhHans: [String: String] = [
    L10nKey.settingsTitle.rawValue: "设置",
    L10nKey.settingsNavigation.rawValue: "CodexGateway 设置",
    L10nKey.providersAndModels.rawValue: "提供商与模型",
    L10nKey.providersAndModelsSubtitle.rawValue: "管理 OpenAI 兼容的提供商与 Codex 模型目录。",
    L10nKey.doctor.rawValue: "诊断",
    L10nKey.refresh.rawValue: "刷新",
    L10nKey.language.rawValue: "语言",
    L10nKey.languageAutomatic.rawValue: "自动",
    L10nKey.providers.rawValue: "提供商",
    L10nKey.addProvider.rawValue: "添加提供商",
    L10nKey.models.rawValue: "模型",
    L10nKey.modelRoute.rawValue: "模型线路",
    L10nKey.modelRouteSubtitle.rawValue: "让 Codex 走 OpenAI 或本地 CodexGateway。",
    L10nKey.currentRoute.rawValue: "当前线路",
    L10nKey.routeOfficial.rawValue: "OpenAI 官方",
    L10nKey.routeGateway.rawValue: "CodexGateway",
    L10nKey.routeUnknown.rawValue: "未知",
    L10nKey.currentModel.rawValue: "当前模型",
    L10nKey.modelProvider.rawValue: "model_provider",
    L10nKey.gatewayAddress.rawValue: "Gateway 地址",
    L10nKey.gatewayStatus.rawValue: "Gateway 状态",
    L10nKey.running.rawValue: "运行中",
    L10nKey.notRunning.rawValue: "未运行",
    L10nKey.officialModel.rawValue: "官方模型",
    L10nKey.officialModelHelp.rawValue: "切换到 OpenAI 时使用。在这里保存不会切换线路。",
    L10nKey.switchToOfficial.rawValue: "切换到官方 GPT",
    L10nKey.switchToGateway.rawValue: "切换回 CodexGateway",
    L10nKey.refreshStatus.rawValue: "刷新状态",
    L10nKey.loadingRoute.rawValue: "正在读取线路…",
    L10nKey.confirmSwitchDialogTitle.rawValue: "切换模型线路？",
    L10nKey.confirmSwitchOpenAI.rawValue: "将修改 Codex 的模型线路设置，并自动创建 config.toml 备份。",
    L10nKey.confirmSwitchGateway.rawValue: "将恢复 CodexGateway 模型线路，并自动创建 config.toml 备份。",
    L10nKey.successOpenAI.rawValue: "已切换到 OpenAI 官方。\n请重新启动 Codex 使设置完全生效。",
    L10nKey.successGateway.rawValue: "已切换到 CodexGateway。\n请重新启动 Codex 使设置完全生效。",
    L10nKey.failurePrefix.rawValue: "无法修改 Codex 配置。\n已自动恢复原配置。",
    L10nKey.sbReady.rawValue: "就绪",
    L10nKey.sbLoading.rawValue: "加载中",
    L10nKey.sbError.rawValue: "错误",
    L10nKey.sbOffline.rawValue: "离线",
    L10nKey.sbRunning.rawValue: "运行中",
    L10nKey.sbStarting.rawValue: "启动中…",
    L10nKey.sbSettings.rawValue: "设置",
    L10nKey.sbDoctor.rawValue: "诊断…",
    L10nKey.sbOpenAtLogin.rawValue: "登录时启动",
    L10nKey.sbCheckForUpdates.rawValue: "检查更新…",
    L10nKey.sbUpgradeAvailable.rawValue: "有可用更新…",
    L10nKey.sbCheckingForUpdates.rawValue: "正在检查更新…",
    L10nKey.sbRestartCodex.rawValue: "重启 Codex",
    L10nKey.sbAbout.rawValue: "关于 {name}",
    L10nKey.sbQuit.rawValue: "退出",
    L10nKey.sbCursorBridgeOff.rawValue: "Cursor Bridge · {desc}",
    L10nKey.sbCursorBridgeStarting.rawValue: "启动中…",
    L10nKey.sbCursorBridgeStopped.rawValue: "已停止",
    L10nKey.sbCursorBridgeError.rawValue: "错误",
    L10nKey.restartCodexDialogTitle.rawValue: "重启 Codex？",
    L10nKey.restartCodexDialogMessage.rawValue: "将重启 Codex Desktop，以便重新加载提供商与模型配置。",
    L10nKey.restartButton.rawValue: "重启 Codex",
    L10nKey.cancel.rawValue: "取消",
    L10nKey.ok.rawValue: "确定",
    L10nKey.save.rawValue: "保存",
    L10nKey.apply.rawValue: "应用",
    L10nKey.start.rawValue: "启动",
    L10nKey.stop.rawValue: "停止",
    L10nKey.restart.rawValue: "重启",
    L10nKey.testConnection.rawValue: "测试连接",
    L10nKey.advanced.rawValue: "高级设置",
    L10nKey.logs.rawValue: "日志",
    L10nKey.about.rawValue: "关于",
    L10nKey.version.rawValue: "版本",
    L10nKey.baseURL.rawValue: "API 地址（Base URL）",
    L10nKey.apiKey.rawValue: "API Key",
    L10nKey.modelID.rawValue: "模型 ID",
    L10nKey.modelProviderValue.rawValue: "model_provider",
  ]
}