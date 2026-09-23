import Foundation

/// Pure, UI-agnostic state for the "Model Route" settings section.
///
/// Deliberately SwiftUI-free: everything here is Foundation only so it can be
/// unit-tested with `swiftc` on a CommandLineTools machine. It derives display
/// state from a `CodexRouteSnapshot` plus a gateway probe and never carries an
/// API key / token.
enum ModelRouteStandard {
  /// A route the user can target (used by the single-switch button and by the
  /// two explicit buttons shown when the current route is unknown).
  enum Target: Equatable {
    case official
    case gateway
  }

  enum Route: Equatable {
    case official
    case gateway
    case unknown
  }

  struct Snapshot: Equatable {
    let route: Route
    let model: String?
    let modelProvider: String?
    let openAIBaseURL: OpenAIBaseURLState
    let gatewayAddress: String
    let gatewayRunning: Bool
  }

  /// Maps a Codex route snapshot + gateway probe into display state.
  static func derive(from snapshot: CodexRouteSnapshot, gatewayRunning: Bool) -> Snapshot {
    let route: Route
    switch snapshot.modelProvider {
    case "openai": route = .official
    case "codexgateway": route = .gateway
    default: route = .unknown
    }
    return Snapshot(
      route: route,
      model: snapshot.model,
      modelProvider: snapshot.modelProvider,
      openAIBaseURL: snapshot.openAIBaseURL,
      gatewayAddress: "\(Paths.gatewayHost):\(Paths.gatewayPort)",
      gatewayRunning: gatewayRunning
    )
  }

  /// Centralized copy so Phase 4 (localization) can swap strings without
  /// touching views. The rest of the app is English today, so these match it.
  enum Strings {
    static let sectionTitle = "Model Route"
    static let sectionSubtitle = "Route Codex through OpenAI or your local CodexGateway."

    static let currentRouteTitle = "Current route"
    static let routeOfficial = "OpenAI official"
    static let routeGateway = "CodexGateway"
    static let routeUnknown = "Unknown"

    static let currentModelTitle = "Current model"
    static let modelProviderTitle = "model_provider"
    static let gatewayAddressTitle = "Gateway address"
    static let gatewayStatusTitle = "Gateway status"
    static let gatewayRunning = "Running"
    static let gatewayNotRunning = "Not running"

    static let officialModelTitle = "Official model"
    static let officialModelHelp = "Used when switching to OpenAI. Saving here does not switch the route."

    static let switchToOfficial = "Switch to Official GPT"
    static let switchToGateway = "Switch back to CodexGateway"
    static let refreshStatus = "Refresh status"

    static func confirmSwitch(_ target: Target) -> String {
      switch target {
      case .official:
        return "This will change Codex's model route and automatically create a backup of config.toml."
      case .gateway:
        return "This will restore the CodexGateway model route and automatically create a backup of config.toml."
      }
    }

    static func success(_ route: Route) -> String {
      switch route {
      case .official:
        return "Switched to OpenAI official.\nPlease restart Codex for the change to take full effect."
      case .gateway:
        return "Switched to CodexGateway.\nPlease restart Codex for the change to take full effect."
      case .unknown:
        return ""
      }
    }

    static let failurePrefix = "Could not modify Codex config."
    static let failureRolledBack = "Could not modify Codex config. The original config was restored."
    static let loading = "Reading route…"
  }
}