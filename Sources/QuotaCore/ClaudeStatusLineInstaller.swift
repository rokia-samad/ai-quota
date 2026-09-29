import Foundation

public enum ClaudeStatusLineInstallError: Error, LocalizedError, Equatable {
  case unreadable
  case invalidSettings
  case alreadyConfigured

  public var errorDescription: String? {
    switch self {
    case .unreadable:
      "Impossible de lire les réglages de Claude Code. Aucun réglage n’a été modifié."
    case .invalidSettings:
      "Le fichier settings.json de Claude Code n’est pas un objet JSON valide."
    case .alreadyConfigured:
      "Une ligne de statut Claude est déjà configurée. Consulte le README pour la relier au widget sans écraser ta configuration."
    }
  }
}

public enum ClaudeStatusLineInstaller {
  /// Adds the AI Quota status-line command to Claude Code's settings, never replacing an existing
  /// status line nor rewriting a file that cannot be parsed.
  public static func install(settingsURL: URL, executablePath: String) throws {
    // Write through a symlinked settings file (dotfile managers) instead of replacing the link.
    let target = settingsURL.resolvingSymlinksInPath()
    let data: Data
    if FileManager.default.fileExists(atPath: target.path) {
      do { data = try Data(contentsOf: target) } catch {
        throw ClaudeStatusLineInstallError.unreadable
      }
    } else {
      data = Data("{}".utf8)
    }
    guard var settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
      throw ClaudeStatusLineInstallError.invalidSettings
    }
    if settings["statusLine"] != nil { throw ClaudeStatusLineInstallError.alreadyConfigured }
    settings["statusLine"] = [
      "type": "command", "command": "\(shellQuoted(executablePath)) --claude-statusline",
      "refreshInterval": 60,
    ]
    let updated = try JSONSerialization.data(
      withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try FileManager.default.createDirectory(
      at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try updated.write(to: target, options: .atomic)
  }

  static func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
