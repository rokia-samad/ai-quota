import Foundation
import Testing

@testable import QuotaCore

private func withSettingsDirectory(_ body: (URL) throws -> Void) throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  try body(directory)
}

private func settings(at url: URL) throws -> [String: Any] {
  try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
}

@Test func installCreatesSettingsWithQuotedCommand() throws {
  try withSettingsDirectory { directory in
    let url = directory.appendingPathComponent(".claude/settings.json")
    try ClaudeStatusLineInstaller.install(
      settingsURL: url, executablePath: "/Applications/AI Quota.app/Contents/MacOS/AIQuota")
    let statusLine = try settings(at: url)["statusLine"] as? [String: Any]
    #expect(
      statusLine?["command"] as? String
        == "'/Applications/AI Quota.app/Contents/MacOS/AIQuota' --claude-statusline")
    #expect(statusLine?["type"] as? String == "command")
    #expect(!(try String(contentsOf: url, encoding: .utf8)).contains(#"\/"#))
  }
}

@Test func installPreservesOtherSettings() throws {
  try withSettingsDirectory { directory in
    let url = directory.appendingPathComponent("settings.json")
    try Data(#"{"model":"opus","permissions":{"allow":["Bash(ls)"]}}"#.utf8).write(to: url)
    try ClaudeStatusLineInstaller.install(settingsURL: url, executablePath: "/bin/AIQuota")
    let saved = try settings(at: url)
    #expect(saved["model"] as? String == "opus")
    #expect((saved["permissions"] as? [String: Any])?["allow"] as? [String] == ["Bash(ls)"])
    #expect(saved["statusLine"] != nil)
  }
}

@Test func installNeverRewritesExistingOrInvalidSettings() throws {
  try withSettingsDirectory { directory in
    let url = directory.appendingPathComponent("settings.json")
    let cases: [(String, ClaudeStatusLineInstallError)] = [
      (#"{"statusLine":{"type":"command","command":"mine"}}"#, .alreadyConfigured),
      ("{broken", .invalidSettings), ("", .invalidSettings), ("[]", .invalidSettings),
    ]
    for (content, expected) in cases {
      try Data(content.utf8).write(to: url)
      #expect(throws: expected) {
        try ClaudeStatusLineInstaller.install(settingsURL: url, executablePath: "/bin/AIQuota")
      }
      #expect(try String(contentsOf: url, encoding: .utf8) == content)
    }
  }
}

@Test func installWritesThroughSymlinkedSettings() throws {
  try withSettingsDirectory { directory in
    let real = directory.appendingPathComponent("dotfiles/settings.json")
    try FileManager.default.createDirectory(
      at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: real)
    let link = directory.appendingPathComponent("settings.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    try ClaudeStatusLineInstaller.install(settingsURL: link, executablePath: "/bin/AIQuota")
    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == real.path)
    #expect(try settings(at: real)["statusLine"] != nil)
  }
}

@Test func shellQuotingEscapesApostrophes() {
  #expect(
    ClaudeStatusLineInstaller.shellQuoted("/Users/o'neil/AIQuota") == #"'/Users/o'\''neil/AIQuota'"#
  )
}
