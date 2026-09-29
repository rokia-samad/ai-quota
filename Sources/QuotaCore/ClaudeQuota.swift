import CoreFoundation
import Foundation

public enum ClaudeQuotaSource: String, Sendable {
  case desktop = "Claude Desktop"
  case code = "Claude Code"

  public var maxAge: TimeInterval {
    switch self {
    case .desktop: 1800
    case .code: 900
    }
  }
}

public struct ClaudeQuotaWindow: Sendable {
  public let usedPercent: Double?
  public let capturedAt: TimeInterval
  public let source: ClaudeQuotaSource
  /// Latest reset reported by Claude Code for this window, kept once passed so that usage
  /// measured before it can be recognized as belonging to the previous window.
  public let resetsAt: TimeInterval?
  /// When Claude Code reported `resetsAt`, which may precede the usage measurement.
  public let resetCapturedAt: TimeInterval?
  /// An earlier reset that had already happened when `resetsAt` replaced it.
  public let previousResetAt: TimeInterval?

  public func isFresh(at now: TimeInterval) -> Bool {
    now >= capturedAt && now - capturedAt <= source.maxAge && !predatesReset(at: now)
  }

  /// The window was reset after this usage was measured: it no longer describes the current one.
  public func predatesReset(at now: TimeInterval) -> Bool {
    [resetsAt, previousResetAt].contains { reset in
      reset.map { capturedAt < $0 && $0 <= now } ?? false
    }
  }

  public func freshReset(at now: TimeInterval) -> TimeInterval? {
    guard let resetsAt, let resetCapturedAt,
      resetsAt > now, now >= resetCapturedAt, now - resetCapturedAt <= ClaudeQuotaSource.code.maxAge
    else { return nil }
    return resetsAt
  }
}

public struct ClaudeQuotaReading: Sendable {
  public let fiveHour: ClaudeQuotaWindow?
  public let sevenDay: ClaudeQuotaWindow?

  public var latestMeasurement: (capturedAt: TimeInterval, source: ClaudeQuotaSource)? {
    [fiveHour, sevenDay]
      .compactMap { $0 }
      .max(by: { $0.capturedAt < $1.capturedAt })
      .map { ($0.capturedAt, $0.source) }
  }
}

public enum ClaudeQuotaError: Error, LocalizedError, Equatable {
  case unreadable(String)
  case malformed(String)
  case cacheWriteFailed

  public var errorDescription: String? {
    switch self {
    case .unreadable(let source): "\(source) : lecture impossible"
    case .malformed(let source): "\(source) : données invalides"
    case .cacheWriteFailed: "Cache AI Quota inaccessible"
    }
  }
}

public enum ClaudeQuota {
  /// Year 10000: later "timestamps" are garbage rather than dates.
  private static let maxTimestamp: Double = 253_402_300_800

  private struct StatusRecord: Codable {
    let rateLimits: StatusLimits?
    let capturedAt: Double
    let captureError: String?
    enum CodingKeys: String, CodingKey {
      case rateLimits = "rate_limits"
      case capturedAt = "captured_at"
      case captureError = "capture_error"
    }
  }

  private struct StatusLimits: Codable {
    let fiveHour: StatusLimit?
    let sevenDay: StatusLimit?
    enum CodingKeys: String, CodingKey {
      case fiveHour = "five_hour"
      case sevenDay = "seven_day"
    }
  }

  /// Cached window. Usage is always from the record's `captured_at`; resets may be carried over
  /// from earlier status lines, so they keep their own observation time.
  private struct StatusLimit: Codable {
    let usedPercentage: Double?
    let resetsAt: Double?
    /// Absent in caches written before resets were carried over: the record's `captured_at`.
    let resetCapturedAt: Double?
    let previousResetAt: Double?

    enum CodingKeys: String, CodingKey {
      case usedPercentage = "used_percentage"
      case resetsAt = "resets_at"
      case resetCapturedAt = "reset_captured_at"
      case previousResetAt = "previous_resets_at"
    }

    init(
      usedPercentage: Double?, resetsAt: Double?, resetCapturedAt: Double?, previousResetAt: Double?
    ) {
      self.usedPercentage = usedPercentage
      self.resetsAt = resetsAt
      self.resetCapturedAt = resetCapturedAt
      self.previousResetAt = previousResetAt
    }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      usedPercentage = try? container.decode(Double.self, forKey: .usedPercentage)
      resetsAt = try? container.decode(Double.self, forKey: .resetsAt)
      resetCapturedAt = try? container.decode(Double.self, forKey: .resetCapturedAt)
      previousResetAt = try? container.decode(Double.self, forKey: .previousResetAt)
    }
  }

  /// Resets known for a window, validated against the time they were observed.
  private struct KnownResets {
    let resetsAt: Double?
    let capturedAt: Double
    let previous: Double?

    init?(_ limit: StatusLimit?, recordCapturedAt: Double) {
      guard let limit else { return nil }
      let observed = limit.resetCapturedAt ?? recordCapturedAt
      guard observed.isFinite, observed > 0, observed <= recordCapturedAt else { return nil }
      resetsAt = limit.resetsAt.flatMap {
        $0.isFinite && $0 > observed && $0 < maxTimestamp ? $0 : nil
      }
      previous = limit.previousResetAt.flatMap {
        $0.isFinite && $0 > 0 && $0 <= observed ? $0 : nil
      }
      capturedAt = observed
      if resetsAt == nil && previous == nil { return nil }
    }
  }

  private struct DesktopHistory: Decodable {
    struct Sample: Decodable {
      let timestamp: Double
      let usage: Usage
      enum CodingKeys: String, CodingKey {
        case timestamp = "t"
        case usage = "u"
      }
    }
    struct Usage: Decodable {
      let fiveHour: Double?
      let sevenDay: Double?

      enum CodingKeys: String, CodingKey {
        case fiveHour = "fh"
        case sevenDay = "sd"
      }

      init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fiveHour = try? container.decode(Double.self, forKey: .fiveHour)
        sevenDay = try? container.decode(Double.self, forKey: .sevenDay)
      }
    }
    let samples: [Sample]
  }

  /// Consumes Claude Code's documented status-line JSON and saves only quota data.
  ///
  /// Usage comes only from this status line. Resets reported earlier are carried over, because a
  /// reset that already happened still dates older usage (Desktop's in particular).
  @discardableResult
  public static func captureStatusLine(
    input: Data, cacheURL: URL, capturedAt: TimeInterval = Date().timeIntervalSince1970
  ) throws -> String {
    let date = capturedAt.isFinite && capturedAt > 0 ? capturedAt : Date().timeIntervalSince1970
    var rawLimits: [String: Any] = [:]
    var error: String? = "invalid"
    if capturedAt.isFinite, capturedAt > 0,
      let object = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any]
    {
      switch object["rate_limits"] {
      case nil: error = nil
      case let limits as [String: Any]:
        rawLimits = limits
        error = nil
      default: break
      }
    }

    let previous = (try? Data(contentsOf: cacheURL))
      .flatMap { try? JSONDecoder().decode(StatusRecord.self, from: $0) }
    var observed = false
    func window(_ key: String, previous old: StatusLimit?) -> StatusLimit? {
      let raw = rawLimits[key] as? [String: Any]
      let used = jsonNumber(raw?["used_percentage"])
        .flatMap { $0.isFinite && (0...100).contains($0) ? $0 : nil }
      let reset = jsonNumber(raw?["resets_at"])
        .flatMap { $0.isFinite && $0 > date && $0 < maxTimestamp ? $0 : nil }
      if used != nil || reset != nil { observed = true }

      let known = previous.flatMap { KnownResets(old, recordCapturedAt: $0.capturedAt) }
      var resetsAt = known?.resetsAt
      var resetCapturedAt = known?.capturedAt
      var previousReset = known?.previous
      if let reset {
        // A superseded reset that already happened remains a fact about older usage.
        if let passed = resetsAt, passed <= date, passed != reset {
          previousReset = max(previousReset ?? passed, passed)
        }
        resetsAt = reset
        resetCapturedAt = date
      }
      guard used != nil || resetsAt != nil || previousReset != nil else { return nil }
      return StatusLimit(
        usedPercentage: used, resetsAt: resetsAt, resetCapturedAt: resetCapturedAt,
        previousResetAt: previousReset)
    }

    let fiveHour = window("five_hour", previous: previous?.rateLimits?.fiveHour)
    let sevenDay = window("seven_day", previous: previous?.rateLimits?.sevenDay)
    let limits =
      fiveHour == nil && sevenDay == nil
      ? nil : StatusLimits(fiveHour: fiveHour, sevenDay: sevenDay)
    try saveStatus(
      StatusRecord(rateLimits: limits, capturedAt: date, captureError: error), to: cacheURL)
    if error != nil { return "Claude · données invalides" }
    return observed ? "Claude" : "Claude · quotas en attente"
  }

  public static func read(
    desktopURL: URL, statusURL: URL, now: TimeInterval = Date().timeIntervalSince1970
  ) throws -> ClaudeQuotaReading? {
    guard now.isFinite, now > 0 else { throw ClaudeQuotaError.malformed("Claude") }
    var errors: [ClaudeQuotaError] = []
    let desktopRead = readOptional(desktopURL, source: ClaudeQuotaSource.desktop.rawValue)
    let statusRead = readOptional(statusURL, source: ClaudeQuotaSource.code.rawValue)
    if let error = desktopRead.error { errors.append(error) }
    if let error = statusRead.error { errors.append(error) }
    func parse(
      _ data: Data?, _ source: ClaudeQuotaSource, _ parser: (Data, Double) throws -> Parsed?
    ) -> Parsed? {
      guard let data else { return nil }
      do { return try parser(data, now) } catch {
        errors.append(error as? ClaudeQuotaError ?? .malformed(source.rawValue))
        return nil
      }
    }
    let desktop = parse(desktopRead.data, .desktop, parseDesktop)
    let status = parse(statusRead.data, .code, parseStatus)
    let fiveHour = combine(desktop?.fiveHour, status?.fiveHour, now: now)
    let sevenDay = combine(desktop?.sevenDay, status?.sevenDay, now: now)
    if fiveHour == nil && sevenDay == nil {
      if let error = status?.error { throw ClaudeQuotaError.malformed(error) }
      if let error = errors.first { throw error }
      return nil
    }
    return ClaudeQuotaReading(fiveHour: fiveHour, sevenDay: sevenDay)
  }

  private static func readOptional(_ url: URL, source: String) -> (
    data: Data?, error: ClaudeQuotaError?
  ) {
    do { return (try Data(contentsOf: url), nil) } catch {
      if !FileManager.default.fileExists(atPath: url.path) { return (nil, nil) }
      return (nil, .unreadable(source))
    }
  }

  private struct Candidate {
    let used: Double?
    let capturedAt: Double
    let source: ClaudeQuotaSource
    var resets: KnownResets? = nil
  }

  private struct Parsed {
    let fiveHour: Candidate?
    let sevenDay: Candidate?
    let error: String?
  }

  private static func parseStatus(_ data: Data, now: Double) throws -> Parsed {
    guard let record = try? JSONDecoder().decode(StatusRecord.self, from: data) else {
      throw ClaudeQuotaError.malformed(ClaudeQuotaSource.code.rawValue)
    }
    guard record.capturedAt.isFinite, record.capturedAt > 0, record.capturedAt <= now + 60 else {
      throw ClaudeQuotaError.malformed(ClaudeQuotaSource.code.rawValue)
    }
    guard let limits = record.rateLimits else {
      return Parsed(
        fiveHour: nil, sevenDay: nil,
        error: record.captureError == nil ? nil : ClaudeQuotaSource.code.rawValue)
    }
    func candidate(_ window: StatusLimit?) -> Candidate? {
      guard let window else { return nil }
      let used = window.usedPercentage.flatMap { $0.isFinite && (0...100).contains($0) ? $0 : nil }
      let resets = KnownResets(window, recordCapturedAt: record.capturedAt)
      guard used != nil || resets != nil else { return nil }
      return Candidate(used: used, capturedAt: record.capturedAt, source: .code, resets: resets)
    }
    return Parsed(
      fiveHour: candidate(limits.fiveHour), sevenDay: candidate(limits.sevenDay),
      error: record.captureError == nil ? nil : ClaudeQuotaSource.code.rawValue)
  }

  private static func parseDesktop(_ data: Data, now: Double) throws -> Parsed? {
    guard let history = try? JSONDecoder().decode(DesktopHistory.self, from: data) else {
      throw ClaudeQuotaError.malformed(ClaudeQuotaSource.desktop.rawValue)
    }
    guard let sample = history.samples.max(by: { $0.timestamp < $1.timestamp }) else { return nil }
    let capturedAt = sample.timestamp / 1000
    guard capturedAt.isFinite, capturedAt > 0, capturedAt <= now + 60 else {
      throw ClaudeQuotaError.malformed(ClaudeQuotaSource.desktop.rawValue)
    }
    func candidate(_ value: Double?) -> Candidate? {
      guard let value, value.isFinite, (0...100).contains(value) else { return nil }
      return Candidate(used: value, capturedAt: capturedAt, source: .desktop)
    }
    return Parsed(
      fiveHour: candidate(sample.usage.fiveHour), sevenDay: candidate(sample.usage.sevenDay),
      error: nil)
  }

  private static func combine(_ desktop: Candidate?, _ code: Candidate?, now: Double)
    -> ClaudeQuotaWindow?
  {
    // Only Claude Code reports resets; Desktop usage is checked against them too.
    let resets = code?.resets
    let resetCapturedAt = resets?.resetsAt == nil ? nil : resets?.capturedAt
    let windows = [desktop, code].compactMap { $0 }.filter { $0.used != nil }.map {
      ClaudeQuotaWindow(
        usedPercent: $0.used, capturedAt: $0.capturedAt, source: $0.source,
        resetsAt: resets?.resetsAt, resetCapturedAt: resetCapturedAt,
        previousResetAt: resets?.previous)
    }
    let freshWindows = windows.filter { $0.isFresh(at: now) }
    if let usage = (freshWindows.isEmpty ? windows : freshWindows)
      .max(by: { $0.capturedAt < $1.capturedAt })
    {
      return usage
    }
    // A reset alone is shown only when the latest status line reported it; one carried over from
    // an earlier line only dates usage, so that line's "no quota" state stays visible.
    guard let resets, let reset = resets.resetsAt, resets.capturedAt == code?.capturedAt else {
      return nil
    }
    let resetOnly = ClaudeQuotaWindow(
      usedPercent: nil, capturedAt: resets.capturedAt, source: .code,
      resetsAt: reset, resetCapturedAt: resets.capturedAt, previousResetAt: resets.previous)
    return resetOnly.freshReset(at: now) == nil ? nil : resetOnly
  }

  private static func saveStatus(_ record: StatusRecord, to url: URL) throws {
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      let data = try JSONEncoder().encode(record)
      try data.write(to: url, options: .atomic)
    } catch { throw ClaudeQuotaError.cacheWriteFailed }
  }

  private static func jsonNumber(_ value: Any?) -> Double? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
      return nil
    }
    return number.doubleValue
  }
}
