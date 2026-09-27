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
  public let resetsAt: TimeInterval?
  public let resetCapturedAt: TimeInterval?

  public func isFresh(at now: TimeInterval) -> Bool {
    now >= capturedAt && now - capturedAt <= source.maxAge
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

  private struct StatusLimit: Codable {
    let usedPercentage: Double?
    let resetsAt: Double?

    enum CodingKeys: String, CodingKey {
      case usedPercentage = "used_percentage"
      case resetsAt = "resets_at"
    }

    init(usedPercentage: Double?, resetsAt: Double?) {
      self.usedPercentage = usedPercentage
      self.resetsAt = resetsAt
    }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      usedPercentage = try? container.decode(Double.self, forKey: .usedPercentage)
      resetsAt = try? container.decode(Double.self, forKey: .resetsAt)
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
  @discardableResult
  public static func captureStatusLine(
    input: Data, cacheURL: URL, capturedAt: TimeInterval = Date().timeIntervalSince1970
  ) throws -> String {
    guard capturedAt.isFinite, capturedAt > 0,
      let object = try? JSONSerialization.jsonObject(with: input) as? [String: Any]
    else {
      try saveStatus(rateLimits: nil, error: "invalid", capturedAt: capturedAt, to: cacheURL)
      return "Claude · données invalides"
    }

    guard let limitsValue = object["rate_limits"] else {
      try saveStatus(rateLimits: nil, error: nil, capturedAt: capturedAt, to: cacheURL)
      return "Claude · quotas en attente"
    }
    guard let rawLimits = limitsValue as? [String: Any] else {
      try saveStatus(rateLimits: nil, error: "invalid", capturedAt: capturedAt, to: cacheURL)
      return "Claude · données invalides"
    }

    func window(_ key: String) -> StatusLimit? {
      guard let raw = rawLimits[key] as? [String: Any] else { return nil }
      let percentage = jsonNumber(raw["used_percentage"])
      let validPercentage = percentage.flatMap { $0.isFinite && (0...100).contains($0) ? $0 : nil }
      let reset = jsonNumber(raw["resets_at"])
      let validReset = reset.flatMap {
        $0.isFinite && $0 > capturedAt && $0 < 253_402_300_800 ? $0 : nil
      }
      guard validPercentage != nil || validReset != nil else { return nil }
      return StatusLimit(usedPercentage: validPercentage, resetsAt: validReset)
    }

    let limits = StatusLimits(fiveHour: window("five_hour"), sevenDay: window("seven_day"))
    try saveStatus(rateLimits: limits, error: nil, capturedAt: capturedAt, to: cacheURL)
    return limits.fiveHour == nil && limits.sevenDay == nil
      ? "Claude · quotas en attente" : "Claude"
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
    let desktopData = desktopRead.data
    let statusData = statusRead.data
    let desktop: Parsed? = {
      guard let desktopData else { return nil }
      do { return try parseDesktop(desktopData, now: now) } catch let error as ClaudeQuotaError {
        errors.append(error)
        return nil
      } catch {
        errors.append(.malformed(ClaudeQuotaSource.desktop.rawValue))
        return nil
      }
    }()
    let status: Parsed? = {
      guard let statusData else { return nil }
      do { return try parseStatus(statusData, now: now) } catch let error as ClaudeQuotaError {
        errors.append(error)
        return nil
      } catch {
        errors.append(.malformed(ClaudeQuotaSource.code.rawValue))
        return nil
      }
    }()
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
    let reset: Double?
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
      let reset = window.resetsAt.flatMap {
        $0.isFinite && $0 > now && $0 < 253_402_300_800 ? $0 : nil
      }
      guard used != nil || reset != nil else { return nil }
      return Candidate(used: used, capturedAt: record.capturedAt, source: .code, reset: reset)
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
      return Candidate(used: value, capturedAt: capturedAt, source: .desktop, reset: nil)
    }
    return Parsed(
      fiveHour: candidate(sample.usage.fiveHour), sevenDay: candidate(sample.usage.sevenDay),
      error: nil)
  }

  private static func combine(_ desktop: Candidate?, _ code: Candidate?, now: Double)
    -> ClaudeQuotaWindow?
  {
    let candidates = [desktop, code].compactMap { $0 }.filter { $0.used != nil }
    let freshUsage = candidates.filter {
      $0.capturedAt <= now && now - $0.capturedAt <= $0.source.maxAge
    }
    let usage = (freshUsage.isEmpty ? candidates : freshUsage)
      .max(by: { $0.capturedAt < $1.capturedAt })
    let reset = code.flatMap { candidate in
      candidate.capturedAt <= now && now - candidate.capturedAt <= ClaudeQuotaSource.code.maxAge
        ? candidate.reset.map { (value: $0, capturedAt: candidate.capturedAt) } : nil
    }
    guard let usage else {
      guard let reset else { return nil }
      return ClaudeQuotaWindow(
        usedPercent: nil, capturedAt: reset.capturedAt, source: .code,
        resetsAt: reset.value, resetCapturedAt: reset.capturedAt)
    }
    return ClaudeQuotaWindow(
      usedPercent: usage.used, capturedAt: usage.capturedAt, source: usage.source,
      resetsAt: reset?.value, resetCapturedAt: reset?.capturedAt)
  }

  private static func saveStatus(
    rateLimits: StatusLimits?, error: String?, capturedAt: Double, to url: URL
  ) throws {
    let date = capturedAt.isFinite && capturedAt > 0 ? capturedAt : Date().timeIntervalSince1970
    let record = StatusRecord(rateLimits: rateLimits, capturedAt: date, captureError: error)
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
