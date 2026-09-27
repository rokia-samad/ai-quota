import Foundation

public struct UsageWindow: Decodable, Sendable {
  public let usedPercent: Double
  public let windowDurationMins: Int?
  public let resetsAt: TimeInterval?

  enum CodingKeys: String, CodingKey { case usedPercent, windowDurationMins, resetsAt }
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    usedPercent = try c.decode(Double.self, forKey: .usedPercent)
    guard usedPercent.isFinite, (0...100).contains(usedPercent) else {
      throw DecodingError.dataCorruptedError(
        forKey: .usedPercent, in: c, debugDescription: "Invalid percentage")
    }
    windowDurationMins = try? c.decode(Int.self, forKey: .windowDurationMins)
    let reset = try? c.decode(Double.self, forKey: .resetsAt)
    resetsAt = reset.flatMap { $0.isFinite && $0 > 0 && $0 < 253_402_300_800 ? $0 : nil }
  }
}

public struct RateLimits: Decodable, Sendable {
  public let primary: UsageWindow?
  public let secondary: UsageWindow?
  enum CodingKeys: String, CodingKey { case primary, secondary }
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let windows = [
      try? c.decode(UsageWindow.self, forKey: .primary),
      try? c.decode(UsageWindow.self, forKey: .secondary),
    ]
    // Labels in the UI are fixed to 5h/7j. Never relabel an unknown duration.
    primary = windows.compactMap { $0 }.first { $0.windowDurationMins == 300 }
    secondary = windows.compactMap { $0 }.first { $0.windowDurationMins == 10080 }
  }
}

public struct RateLimitResponse: Decodable, Sendable {
  public let rateLimits: RateLimits?
  enum CodingKeys: String, CodingKey { case rateLimits, rateLimitsByLimitId }
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    if c.contains(.rateLimitsByLimitId),
      !((try? c.decodeNil(forKey: .rateLimitsByLimitId)) ?? false)
    {
      let buckets = try c.nestedContainer(keyedBy: BucketKey.self, forKey: .rateLimitsByLimitId)
      rateLimits = try buckets.decodeIfPresent(
        RateLimits.self, forKey: BucketKey(stringValue: "codex")!)
    } else if c.contains(.rateLimits) {
      rateLimits = try c.decodeIfPresent(RateLimits.self, forKey: .rateLimits)
    } else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: c.codingPath, debugDescription: "Missing quota envelope"))
    }
  }
  private struct BucketKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
  }
}

public enum CodexExecutable {
  public static let candidates = [
    "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
    "/Applications/Codex.app/Contents/Resources/codex",
    "/Applications/ChatGPT.app/Contents/Resources/codex",
    "/usr/local/bin/codex", "/opt/homebrew/bin/codex",
  ]
  public static func resolve(
    isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
  ) -> String? {
    candidates.first(where: isExecutable)
  }
}
