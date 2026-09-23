import Foundation
import Combine

/// Drives the "Model Route" settings section.
///
/// Owns all route knowledge — status reading, switching, the official-model
/// preference, and error state — so `SettingsView` only renders state and
/// forwards button taps. It never writes `config.toml` directly; all mutation
/// goes through `CodexRouteSwitcher` (backup + atomic write + verify + rollback).
/// A plain `ObservableObject` (like `SettingsStore`); it is driven from the
/// View's MainActor context, and its dependency-free core also runs fine under
/// `swiftc` harness tests on CommandLineTools.
final class ModelRouteSettingsViewModel: ObservableObject {
  enum LoadState: Equatable {
    case loading
    case loaded(ModelRouteStandard.Snapshot)
    case failed(String)
  }

  @Published private(set) var loadState: LoadState = .loading
  @Published private(set) var successMessage: String?
  @Published private(set) var errorMessage: String?
  @Published var officialModel: String
  @Published private(set) var isSwitching = false

  private let makeSwitcher: () -> CodexRouteSwitcher
  private var preferences: RoutePreferences
  private let defaults: UserDefaults
  private let probeGateway: () async -> Bool

  init(
    configPath: String = Paths.codexConfig,
    defaults: UserDefaults = .init(suiteName: AppIdentity.userDefaultsSuite) ?? .standard,
    probeGateway: @escaping () async -> Bool = { await ModelRouteSettingsViewModel.probeGatewayHTTP() },
    preferences: RoutePreferences? = nil
  ) {
    let loaded = preferences ?? RoutePreferences.load(defaults: defaults)
    self.preferences = loaded
    self.defaults = defaults
    self.officialModel = loaded.officialModel
    self.probeGateway = probeGateway
    let path = configPath
    // Re-read persisted prefs on each switch so a user-edited officialModel is
    // honored even though the value came in before the switch.
    self.makeSwitcher = {
      CodexRouteSwitcher(configPath: path, preferences: RoutePreferences.load(defaults: defaults))
    }
  }

  var snapshot: ModelRouteStandard.Snapshot? {
    if case .loaded(let snap) = loadState { return snap }
    return nil
  }

  /// Per the spec, unknown-route users may target either route explicitly.
  var currentRoute: ModelRouteStandard.Route? { snapshot?.route }

  // MARK: Read

  func refresh() async {
    loadState = .loading
    let gatewayRunning = await probeGateway()
    do {
      let routeSnapshot = try makeSwitcher().read()
      loadState = .loaded(
        ModelRouteStandard.derive(from: routeSnapshot, gatewayRunning: gatewayRunning)
      )
    } catch {
      loadState = .failed(safeError(error))
    }
  }

  // MARK: Switch

  func switchToOfficial() async {
    await performSwitch(target: .official, attempt: { try makeSwitcher().switchToOpenAI() })
  }

  func switchToGateway() async {
    await performSwitch(target: .gateway, attempt: { try makeSwitcher().switchToGateway() })
  }

  private func performSwitch(
    target: ModelRouteStandard.Target,
    attempt: () throws -> RouteSwitchResult
  ) async {
    isSwitching = true
    defer { isSwitching = false }
    do {
      _ = try attempt()
      successMessage = ModelRouteStandard.Strings.success(
        target == .official ? .official : .gateway
      )
      errorMessage = nil
      await refresh()
    } catch {
      errorMessage = ModelRouteStandard.Strings.failurePrefix + "\n" + safeError(error)
      successMessage = nil
    }
  }

  // MARK: Preference

  /// Persists the picker's `officialModel` into the variant-isolated suite.
  /// Does NOT switch the route — that only happens via `switchToOfficial()`.
  func persistOfficialModel() {
    preferences.officialModel = officialModel
    preferences.save(defaults: defaults)
  }

  // MARK: Banner dismissal

  func dismissSuccess() { successMessage = nil }
  func dismissError() { errorMessage = nil }

  // MARK: Gateway probe

  static func probeGatewayHTTP() async -> Bool {
    let url = URL(string: "http://\(Paths.gatewayHost):\(Paths.gatewayPort)/health")
    guard let url else { return false }
    var request = URLRequest(url: url)
    request.timeoutInterval = 1.5
    do {
      let (_, response) = try await URLSession.shared.data(for: request)
      return (response as? HTTPURLResponse)?.statusCode == 200
    } catch {
      return false
    }
  }

  /// Keeps error text free of keys/tokens. `CodexRouteError` descriptions carry
  /// no secret payloads; this also guards against any unexpected error string.
  private func safeError(_ error: Error) -> String {
    error.localizedDescription.isEmpty ? "unknown error" : error.localizedDescription
  }
}