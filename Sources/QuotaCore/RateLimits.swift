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
  /// Metered bucket served by the multi-bucket view and tracked by the widget.
  public static let codexLimitID = "codex"

  public let limitId: String?
  public let primary: UsageWindow?
  public let secondary: UsageWindow?
  enum CodingKeys: String, CodingKey { case limitId, primary, secondary }

  init(limitId: String?, primary: UsageWindow?, secondary: UsageWindow?) {
    self.limitId = limitId
    self.primary = primary
    self.secondary = secondary
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    limitId = try? c.decode(String.self, forKey: .limitId)
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

  public init(rateLimits: RateLimits?) { self.rateLimits = rateLimits }

  /// Applies an `account/rateLimits/updated` notification, which is a sparse snapshot of a
  /// single bucket: windows it omits keep their last value. Returns nil when the update carries
  /// nothing for the `codex` bucket, so the current reading stays untouched.
  public func applying(_ update: RateLimitResponse) -> RateLimitResponse? {
    guard let limits = update.rateLimits,
      limits.limitId == nil || limits.limitId == RateLimits.codexLimitID
    else { return nil }
    return RateLimitResponse(
      rateLimits: RateLimits(
        limitId: limits.limitId ?? rateLimits?.limitId,
        primary: limits.primary ?? rateLimits?.primary,
        secondary: limits.secondary ?? rateLimits?.secondary))
  }
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    if c.contains(.rateLimitsByLimitId),
      !((try? c.decodeNil(forKey: .rateLimitsByLimitId)) ?? false)
    {
      let buckets = try c.nestedContainer(keyedBy: BucketKey.self, forKey: .rateLimitsByLimitId)
      rateLimits = try buckets.decodeIfPresent(
        RateLimits.self, forKey: BucketKey(stringValue: RateLimits.codexLimitID)!)
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

/// A Codex reading with the time it was received.
public struct CodexMeasurement: Sendable {
  public let reading: RateLimitResponse
  public let capturedAt: TimeInterval

  public init(reading: RateLimitResponse, capturedAt: TimeInterval) {
    self.reading = reading
    self.capturedAt = capturedAt
  }

  /// Current for 5 minutes, or two refresh intervals when that is longer.
  public func isFresh(at now: TimeInterval, refreshInterval: TimeInterval) -> Bool {
    now - capturedAt <= max(300, refreshInterval * 2)
  }

  /// Applies a sparse `account/rateLimits/updated` notification received at `now`. It only
  /// completes a reading still current, so an old window it omits is never re-stamped as fresh.
  /// Returns nil when the notification carries nothing for the `codex` bucket.
  public static func applying(
    _ update: RateLimitResponse, to current: CodexMeasurement?, at now: TimeInterval,
    refreshInterval: TimeInterval
  ) -> CodexMeasurement? {
    let base = current.flatMap {
      $0.isFresh(at: now, refreshInterval: refreshInterval) ? $0.reading : nil
    }
    guard let merged = (base ?? RateLimitResponse(rateLimits: nil)).applying(update) else {
      return nil
    }
    return CodexMeasurement(reading: merged, capturedAt: now)
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
