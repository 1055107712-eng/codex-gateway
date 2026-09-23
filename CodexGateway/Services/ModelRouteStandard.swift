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

  /// Centralized copy so views need not reach into L10n directly. Every string
  /// delegates to the single `L10nTable` source (Phase 4) — there is no second
  /// translation table here, so switching the UI language updates this section
  /// automatically through `L10n.shared`.
  enum Strings {
    static var sectionTitle: String { L10n.shared.text(.modelRoute) }
    static var sectionSubtitle: String { L10n.shared.text(.modelRouteSubtitle) }

    static var currentRouteTitle: String { L10n.shared.text(.currentRoute) }
    static var routeOfficial: String { L10n.shared.text(.routeOfficial) }
    static var routeGateway: String { L10n.shared.text(.routeGateway) }
    static var routeUnknown: String { L10n.shared.text(.routeUnknown) }

    static var currentModelTitle: String { L10n.shared.text(.currentModel) }
    static var modelProviderTitle: String { L10n.shared.text(.modelProvider) }
    static var gatewayAddressTitle: String { L10n.shared.text(.gatewayAddress) }
    static var gatewayStatusTitle: String { L10n.shared.text(.gatewayStatus) }
    static var gatewayRunning: String { L10n.shared.text(.running) }
    static var gatewayNotRunning: String { L10n.shared.text(.notRunning) }

    static var officialModelTitle: String { L10n.shared.text(.officialModel) }
    static var officialModelHelp: String { L10n.shared.text(.officialModelHelp) }

    static var switchToOfficial: String { L10n.shared.text(.switchToOfficial) }
    static var switchToGateway: String { L10n.shared.text(.switchToGateway) }
    static var refreshStatus: String { L10n.shared.text(.refreshStatus) }

    static func confirmSwitch(_ target: Target) -> String {
      switch target {
      case .official: return L10n.shared.text(.confirmSwitchOpenAI)
      case .gateway: return L10n.shared.text(.confirmSwitchGateway)
      }
    }

    static func success(_ route: Route) -> String {
      switch route {
      case .official: return L10n.shared.text(.successOpenAI)
      case .gateway: return L10n.shared.text(.successGateway)
      case .unknown: return ""
      }
    }

    static var failurePrefix: String { L10n.shared.text(.failurePrefix) }
    static var failureRolledBack: String { L10n.shared.text(.failurePrefix) }
    static var loading: String { L10n.shared.text(.loadingRoute) }
  }
}