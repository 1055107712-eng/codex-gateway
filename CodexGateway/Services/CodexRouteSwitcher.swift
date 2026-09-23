import Foundation

/// Active Codex model route.
enum CodexRoute: Equatable {
  case openAI
  case gateway
}

/// State of the top-level `openai_base_url` key.
enum OpenAIBaseURLState: Equatable {
  case active(String)
  case commented(String)
  case absent
}

/// Snapshot of the routing-relevant fields read from `~/.codex/config.toml`.
///
/// Never carries any API key / token value.
struct CodexRouteSnapshot: Equatable {
  let modelProvider: String?
  let model: String?
  let openAIBaseURL: OpenAIBaseURLState

  var currentRoute: CodexRoute? {
    switch modelProvider {
    case "openai": return .openAI
    case "codexgateway": return .gateway
    default: return nil
    }
  }
}

/// Per-variant routing preferences.
///
/// `officialModel` is user-tunable so an OpenAI model upgrade does not require a
/// source change. Persisted into a UserDefaults suite unique to the variant
/// (`AppIdentity.userDefaultsSuite`) so CN Test and production never collide.
struct RoutePreferences: Equatable {
  static let defaultOfficialModel = "gpt-5.6-sol"
  static let defaultGatewayModel = "zhishu-auto/zhishu-auto"
  static let gatewayBaseURL = "http://127.0.0.1:8765/v1"
  static let officialModelKey = "codexgateway.routeSwitcher.officialModel"

  var officialModel: String

  init(officialModel: String = RoutePreferences.defaultOfficialModel) {
    self.officialModel = officialModel.isEmpty ? RoutePreferences.defaultOfficialModel : officialModel
  }

  /// The route switch is performed without a full TOML re-serialization.
  func disabledMarker(for url: String) -> String {
    "# \(url) # disabled by CodexGateway route switcher"
  }

  /// Loads preferences from the variant-isolated UserDefaults suite.
  static func load(defaults: UserDefaults = .init(suiteName: AppIdentity.userDefaultsSuite) ?? .standard) -> RoutePreferences {
    if let stored = defaults.string(forKey: officialModelKey), !stored.isEmpty {
      return RoutePreferences(officialModel: stored)
    }
    return RoutePreferences()
  }

  func save(defaults: UserDefaults = .init(suiteName: AppIdentity.userDefaultsSuite) ?? .standard) {
    defaults.set(officialModel, forKey: RoutePreferences.officialModelKey)
  }
}

/// Result of a route switch.
struct RouteSwitchResult: Equatable {
  let route: CodexRoute
  let backupPath: String?
}

/// Pure TOML line editor: switches only the top-level routing keys that live
/// before the first `[section]` header. Everything else is preserved byte-for-byte.
///
/// It deliberately does NOT parse/re-serialize the whole TOML, so provider
/// tables, `model_catalog_json`, comments and blank lines are untouched.
enum RouteLineEditor {
  enum Direction {
    case toOpenAI
    case toGateway
  }

  /// A top-level line that we are allowed to rewrite. Returns the matched key.
  static func targetKey(of line: String) -> String? {
    let trimmed = line
    let candidates = ["openai_base_url", "model_provider", "model"]
    for key in candidates {
      // Match `key = ...` or `# key = ...` at top level (start of line, optional comment).
      let pattern = "^(#\\s*)?" + NSRegularExpression.escapedPattern(for: key) + "\\s*="
      if let regex = try? NSRegularExpression(pattern: pattern),
         regex.firstMatch(in: trimmed, options: [], range: NSRange(location: 0, length: (trimmed as NSString).length)) != nil {
        return key
      }
    }
    return nil
  }

  /// A line that opens a TOML table section (`[foo]` / `[foo.bar]`).
  static func isSectionHeader(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    return trimmed.hasPrefix("[") && trimmed.contains("]")
  }

  /// Returns a rewritten line for a target key according to the direction.
  static func rewrite(key: String, direction: Direction, preferences: RoutePreferences) -> String {
    switch (key, direction) {
    case ("model_provider", .toOpenAI):
      return "model_provider = \"openai\""
    case ("model_provider", .toGateway):
      return "model_provider = \"codexgateway\""
    case ("model", .toOpenAI):
      return "model = \"\(preferences.officialModel)\""
    case ("model", .toGateway):
      return "model = \"\(RoutePreferences.defaultGatewayModel)\""
    case ("openai_base_url", .toGateway):
      return "openai_base_url = \"\(RoutePreferences.gatewayBaseURL)\""
    case ("openai_base_url", .toOpenAI):
      return "# openai_base_url = \"\(RoutePreferences.gatewayBaseURL)\" # disabled by CodexGateway route switcher"
    default:
      return ""
    }
  }

  /// Rewrites top-level routing lines in place, preserving every other byte.
  ///
  /// - Parameters:
  ///   - lines: the config split into physical lines (with separators retained).
  ///   - direction: target switch direction.
  ///   - preferences: routing preferences (officialModel).
  /// - Returns: new lines where only the matched top-level target keys changed,
  ///   and any missing top-level key inserted before the first section header.
  static func apply(
    direction: Direction,
    to lines: [String],
    preferences: RoutePreferences = RoutePreferences()
  ) -> [String] {
    var sectionHeaderIndex: Int?
    for (i, line) in lines.enumerated() where isSectionHeader(line) {
      sectionHeaderIndex = i
      break
    }
    let topLevelRange = 0..<(sectionHeaderIndex ?? lines.count)

    var rewritten = lines
    var foundKeys = Set<String>()
    let wantedKeyOrder = ["model_provider", "model", "openai_base_url"]

    for i in topLevelRange {
      guard let key = targetKey(of: rewritten[i]) else { continue }
      foundKeys.insert(key)
      rewritten[i] = rewrite(key: key, direction: direction, preferences: preferences) + lineEnding(of: rewritten[i])
    }

    // Insert any top-level routing key that is entirely absent. Prefer inserting
    // before the first section header; if the file has no section header (only
    // top-level keys/comments), append at the end instead.
    let missing = wantedKeyOrder.filter { !foundKeys.contains($0) }
    if !missing.isEmpty {
      let insertionLines: [String] = missing.reduce(into: [String]()) { acc, key in
        acc.append(rewrite(key: key, direction: direction, preferences: preferences) + "\n")
      }
      if let insertAt = sectionHeaderIndex {
        let previousLine = insertAt > 0 ? rewritten[insertAt - 1] : ""
        if !previousLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          rewritten.insert("\n", at: insertAt)
        }
        rewritten.insert(contentsOf: insertionLines, at: sectionHeaderIndex!)
      } else {
        if let last = rewritten.last, !last.isEmpty {
          rewritten.append("")
        }
        rewritten.append(contentsOf: insertionLines)
      }
    }
    return rewritten
  }

  /// Extracts the line-terminating characters so rewrites keep the same EOL.
  private static func lineEnding(of line: String) -> String {
    if line.hasSuffix("\r\n") { return "\r\n" }
    if line.hasSuffix("\n") { return "\n" }
    return ""
  }
}

/// Thrown route-switch errors. Messages carry NO secret/token payloads.
enum CodexRouteError: LocalizedError {
  case configUnreadable(String)
  case configNotModified
  case rollbackFailed(String)

  var errorDescription: String? {
    switch self {
    case .configUnreadable(let path):
      return "Could not read Codex config at \(path)."
    case .configNotModified:
      return "Route switch produced no change; config left untouched."
    case .rollbackFailed(let reason):
      return "Post-write verification failed and rollback was not completed: \(reason)."
    }
  }
}

/// Safe, atomic route switcher for `~/.codex/config.toml`.
///
/// Guarantees (per write):
/// 1. reads original bytes
/// 2. creates `config.toml.codexgateway-ui.bak.<timestamp>`
/// 3. edits only the top-level region before the first `[section]`
/// 4. never re-serializes the whole TOML
/// 5. leaves provider sections & `model_catalog_json` untouched
/// 6. writes a temp file, fsync, atomically renames
/// 7. restores the backup on write failure
/// 8. re-reads and verifies after the write
///
/// Never reads or logs any API key / token.
struct CodexRouteSwitcher {
  let configPath: String
  let preferences: RoutePreferences
  private let fileManager: FileManager

  init(
    configPath: String = Paths.codexConfig,
    preferences: RoutePreferences = RoutePreferences.load(),
    fileManager: FileManager = .default
  ) {
    self.configPath = configPath
    self.preferences = preferences
    self.fileManager = fileManager
  }

  // MARK: Read

  func read() throws -> CodexRouteSnapshot {
    guard let data = fileManager.contents(atPath: configPath),
          let text = String(data: data, encoding: .utf8) else {
      throw CodexRouteError.configUnreadable(configPath)
    }
    var modelProvider: String?
    var model: String?
    var baseURL: OpenAIBaseURLState = .absent

    for line in text.components(separatedBy: "\n") {
      if RouteLineEditor.isSectionHeader(line) { break }
      guard let key = RouteLineEditor.targetKey(of: line) else { continue }
      let commented = line.uppercased().trimmingCharacters(in: .whitespaces).hasPrefix("#")
      guard let value = valueAfterEquals(in: line) else { continue }
      switch key {
      case "model_provider":
        modelProvider = commented ? nil : unquote(value)
      case "model":
        model = commented ? nil : unquote(value)
      case "openai_base_url":
        if commented {
          baseURL = OpenAIBaseURLState.commented(unquote(value))
        } else {
          baseURL = OpenAIBaseURLState.active(unquote(value))
        }
      default:
        break
      }
      // Only top-level keys before the first section header are considered.
    }
    return CodexRouteSnapshot(modelProvider: modelProvider, model: model, openAIBaseURL: baseURL)
  }

  private func valueAfterEquals(in line: String) -> String? {
    guard let eq = line.firstIndex(of: "=") else { return nil }
    let after = line[line.index(after: eq)...]
    let trimmed = after.trimmingCharacters(in: .whitespaces)
    // Return the raw value including quote chars; `unquote(_:)` strips them.
    guard trimmed.hasPrefix("\"") else {
      // bare value; stop before any trailing inline comment
      if let hash = trimmed.firstIndex(of: "#") {
        return String(trimmed[..<hash]).trimmingCharacters(in: .whitespaces)
      }
      return trimmed
    }
    // Value is quoted: scan forward in the SAME string coordinate space and
    // return the whole `"..."` token (both quotes) for `unquote` to strip.
    guard let close = trimmed[trimmed.index(after: trimmed.startIndex)...].firstIndex(of: "\"") else {
      return String(trimmed)
    }
    return String(trimmed[...close])
  }

  private func unquote(_ raw: String) -> String {
    var s = raw.trimmingCharacters(in: .whitespaces)
    while s.hasPrefix("\""), s.hasSuffix("\""), s.count >= 2 {
      s.removeFirst(); s.removeLast()
    }
    return s
  }

  // MARK: Write

  /// Switches routing to the requested route with backup + atomic write + verify.
  @discardableResult
  func switchTo(_ route: CodexRoute) throws -> RouteSwitchResult {
    let direction: RouteLineEditor.Direction = (route == .openAI) ? .toOpenAI : .toGateway

    guard let originalData = fileManager.contents(atPath: configPath),
          let originalText = String(data: originalData, encoding: .utf8) else {
      throw CodexRouteError.configUnreadable(configPath)
    }

    // 2. Backup before any write.
    let backupPath = makeBackupPath()
    try? fileManager.createDirectory(
      atPath: (backupPath as NSString).deletingLastPathComponent,
      withIntermediateDirectories: true
    )
    try originalData.write(to: URL(fileURLWithPath: backupPath), options: [.atomic])

    // 3–5. Edit only the top-level region.
    let originalLines = originalText.components(separatedBy: .newlines)
    let newLines = RouteLineEditor.apply(direction: direction, to: originalLines, preferences: preferences)
    var newText = newLines.joined(separator: "\n")
    if newText != originalText {
      // Restore exactly the original trailing-newline termination instead of
      // unconditionally appending, so repeated switches don't accumulate blanks.
      let originalHadTrailingNewline = originalText.hasSuffix("\n")
      while newText.hasSuffix("\n") { newText.removeLast() }
      if originalHadTrailingNewline { newText += "\n" }
    }
    guard newText != originalText else {
      // Idempotent: already in the desired state — still keep the backup for traceability.
      return RouteSwitchResult(route: route, backupPath: backupPath)
    }

    // 6. Atomic write via temp file + rename.
    let tempURL = URL(fileURLWithPath: configPath + ".codexgateway-ui.tmp")
    do {
      fileManager.createFile(atPath: tempURL.path, contents: nil)
      let handle = try FileHandle(forWritingTo: tempURL)
      try handle.seek(toOffset: 0)
      try handle.truncate(atOffset: 0)
      try handle.write(contentsOf: Data(newText.utf8))
      try handle.synchronize()
      try handle.close()
    } catch {
      try? fileManager.removeItem(at: tempURL)
      try restore(backupPath: backupPath)
      throw error
    }
    do {
      _ = try fileManager.replaceItemAt(
        URL(fileURLWithPath: configPath),
        withItemAt: tempURL,
        backupItemName: nil,
        options: []
      )
    } catch {
      try? fileManager.removeItem(at: tempURL)
      try restore(backupPath: backupPath)
      throw error
    }

    // 7–8. Verify by re-reading.
    do {
      try verify(after: route, originalData: originalData, originalText: originalText)
    } catch {
      try restore(backupPath: backupPath)
      throw error
    }
    return RouteSwitchResult(route: route, backupPath: backupPath)
  }

  func switchToOpenAI() throws -> RouteSwitchResult {
    try switchTo(.openAI)
  }
  func switchToGateway() throws -> RouteSwitchResult {
    try switchTo(.gateway)
  }

  // MARK: Verification

  private func verify(after route: CodexRoute, originalData: Data, originalText: String) throws {
    let snapshot = try read()
    var valid = false
    switch route {
    case .openAI:
      valid = snapshot.modelProvider == "openai"
        && snapshot.model == preferences.officialModel
        && !(snapshot.openAIBaseURL == .active(RoutePreferences.gatewayBaseURL))
    case .gateway:
      valid = snapshot.modelProvider == "codexgateway"
        && snapshot.model == RoutePreferences.defaultGatewayModel
        && snapshot.openAIBaseURL == .active(RoutePreferences.gatewayBaseURL)
    }
    let stable = isProviderRegionUnchanged(original: originalText, current: readText() ?? "")
    guard valid else {
      throw CodexRouteError.configNotModified
    }
    // Byte-check that provider sections and model_catalog_json are unchanged.
    guard stable else {
      throw CodexRouteError.configNotModified
    }
  }

  private func readText() -> String? {
    guard let data = fileManager.contents(atPath: configPath) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  /// `[model_providers.*]` sections and `model_catalog_json` must be byte-identical.
  private func isProviderRegionUnchanged(original: String, current: String) -> Bool {
    providerStableBytes(original) == providerStableBytes(current)
  }

  /// Projection of the parts we promise never to touch: `[model_providers.*]`
  /// blocks plus every `model_catalog_json` line. The editor never rewrites
  /// these, so a YES answer proves they were left byte-identical.
  private func providerStableBytes(_ text: String) -> String {
    var out: [String] = []
    var inProviderTable = false
    for line in text.components(separatedBy: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      let isSection = RouteLineEditor.isSectionHeader(line)
      let isProviderSection = isSection && trimmed.hasPrefix("[model_providers.")
      if isSection {
        inProviderTable = isProviderSection
        if inProviderTable { out.append(line) }
        continue
      }
      if inProviderTable {
        out.append(line)
      } else if trimmed.hasPrefix("model_catalog_json=")
        || trimmed.hasPrefix("# model_catalog_json=")
        || trimmed.hasPrefix("model_catalog_json =")
        || trimmed.hasPrefix("# model_catalog_json =") {
        out.append(line)
      }
    }
    // Ignore a single trailing newline introduced by the atomic rewrite so that
    // provider-section comparison stays byte-faithful to content, not EOL.
    while (out.last?.isEmpty) == true {
      out.removeLast()
    }
    return out.joined(separator: "\n")
  }

  private func makeBackupPath() -> String {
    let ts = timestamp()
    return "\(configPath).codexgateway-ui.bak.\(ts)"
  }

  private func timestamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd-HHmmss-SSS"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f.string(from: Date())
  }

  private func restore(backupPath: String) throws {
    guard let backup = fileManager.contents(atPath: backupPath) else {
      throw CodexRouteError.rollbackFailed("backup missing at \(backupPath)")
    }
    do {
      try backup.write(to: URL(fileURLWithPath: configPath), options: [.atomic])
    } catch {
      throw CodexRouteError.rollbackFailed(error.localizedDescription)
    }
  }
}