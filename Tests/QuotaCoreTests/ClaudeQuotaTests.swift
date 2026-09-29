import Foundation
import Testing

@testable import QuotaCore

private let claudeNow: TimeInterval = 1_700_000_000

private func claudeFixture(_ name: String) throws -> Data {
  let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
  return try Data(contentsOf: url)
}

private func claudeRead(
  desktop: Data? = nil, status: Data? = nil, now: TimeInterval = claudeNow
) throws -> ClaudeQuotaReading? {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let desktopURL = directory.appendingPathComponent("desktop.json")
  let statusURL = directory.appendingPathComponent("status.json")
  try desktop?.write(to: desktopURL)
  try status?.write(to: statusURL)
  return try ClaudeQuota.read(desktopURL: desktopURL, statusURL: statusURL, now: now)
}

@Test func desktopReadingPreservesZeroAndOneHundredPercent() throws {
  let reading = try claudeRead(desktop: claudeFixture("claude-desktop-valid"))!
  #expect(reading.fiveHour?.usedPercent == 0)
  #expect(reading.sevenDay?.usedPercent == 100)
  #expect(reading.fiveHour?.source == .desktop)
}

@Test func codeStatusLineHasValidatedUsageAndResetTimes() throws {
  let reading = try claudeRead(status: claudeFixture("claude-status-valid"))!
  #expect(reading.fiveHour?.usedPercent == 0)
  #expect(reading.sevenDay?.usedPercent == 100)
  #expect(reading.fiveHour?.freshReset(at: claudeNow) == 1_700_001_000)
  #expect(reading.sevenDay?.freshReset(at: claudeNow) == 1_700_005_000)
}

@Test func newestUsageWinsAndDesktopFillsMissingWindow() throws {
  let desktop = try claudeFixture("claude-desktop-valid")
  let status = Data(
    #"{"rate_limits":{"five_hour":{"used_percentage":35,"resets_at":1700001000}},"captured_at":1699999995}"#
      .utf8
  )
  let reading = try claudeRead(desktop: desktop, status: status)!
  #expect(reading.fiveHour?.usedPercent == 35)
  #expect(reading.fiveHour?.source == .code)
  #expect(reading.sevenDay?.usedPercent == 100)
  #expect(reading.sevenDay?.source == .desktop)
}

@Test func freshDesktopWinsOverNewerButStaleCodeUsage() throws {
  let desktopCapturedAt = claudeNow - 25 * 60
  let codeCapturedAt = claudeNow - 20 * 60
  let desktop = Data(
    #"{"samples":[{"t":\#(desktopCapturedAt * 1_000),"u":{"fh":50}}]}"#.utf8)
  let status = Data(
    #"{"rate_limits":{"five_hour":{"used_percentage":25}},"captured_at":\#(codeCapturedAt)}"#.utf8)

  let reading = try claudeRead(desktop: desktop, status: status)!

  #expect(reading.fiveHour?.source == .desktop)
  #expect(reading.fiveHour?.usedPercent == 50)
  #expect(reading.fiveHour?.isFresh(at: claudeNow) == true)
}

@Test func freshCodeWinsOverOlderFreshDesktopUsage() throws {
  let desktopCapturedAt = claudeNow - 10 * 60
  let codeCapturedAt = claudeNow - 5 * 60
  let desktop = Data(
    #"{"samples":[{"t":\#(desktopCapturedAt * 1_000),"u":{"fh":50}}]}"#.utf8)
  let status = Data(
    #"{"rate_limits":{"five_hour":{"used_percentage":25}},"captured_at":\#(codeCapturedAt)}"#.utf8)

  let reading = try claudeRead(desktop: desktop, status: status)!

  #expect(reading.fiveHour?.source == .code)
  #expect(reading.fiveHour?.usedPercent == 25)
  #expect(reading.fiveHour?.isFresh(at: claudeNow) == true)
}

@Test func missingAndPartialWindowsStayUnavailable() throws {
  let status = Data(
    #"{"rate_limits":{"five_hour":{"used_percentage":22}},"captured_at":1699999995}"#.utf8)
  let reading = try claudeRead(status: status)!
  #expect(reading.fiveHour?.usedPercent == 22)
  #expect(reading.fiveHour?.resetsAt == nil)
  #expect(reading.sevenDay == nil)
}

@Test func impossiblePercentagesAndBooleanAreRejected() throws {
  let data = Data(
    #"{"rate_limits":{"five_hour":{"used_percentage":-1},"seven_day":{"used_percentage":101},"spend_limit":{"used_percentage":true}},"captured_at":1699999995}"#
      .utf8
  )
  #expect(try claudeRead(status: data) == nil)
}

@Test func invalidResetDoesNotDiscardValidUsage() throws {
  for reset in ["\"invalid\"", "-1", "1699999990", "true"] {
    let data = Data(
      "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":44,\"resets_at\":\(reset)}},\"captured_at\":1699999995}"
        .utf8
    )
    let reading = try claudeRead(status: data)!
    #expect(reading.fiveHour?.usedPercent == 44)
    #expect(reading.fiveHour?.resetsAt == nil)
  }
}

@Test func staleDesktopAndCodeMeasurementsAreMarkedStale() throws {
  let desktop = Data(#"{"samples":[{"t":1699997000000,"u":{"fh":50,"sd":60}}]}"#.utf8)
  let status = Data(
    #"{"rate_limits":{"five_hour":{"used_percentage":25,"resets_at":1700001000}},"captured_at":1699990000}"#
      .utf8
  )
  let reading = try claudeRead(desktop: desktop, status: status)!
  #expect(reading.fiveHour?.usedPercent == 50)
  #expect(reading.fiveHour?.isFresh(at: claudeNow) == false)
  #expect(reading.sevenDay?.isFresh(at: claudeNow) == false)
  #expect(reading.fiveHour?.freshReset(at: claudeNow) == nil)
}

@Test func currentStatusLineResetCanAccompanyOlderDesktopUsage() throws {
  let desktop = Data(#"{"samples":[{"t":1699997000000,"u":{"fh":50}}]}"#.utf8)
  let status = Data(
    #"{"rate_limits":{"five_hour":{"resets_at":1700001000}},"captured_at":1699999995}"#.utf8
  )
  let reading = try claudeRead(desktop: desktop, status: status)!
  #expect(reading.fiveHour?.usedPercent == 50)
  #expect(reading.fiveHour?.isFresh(at: claudeNow) == false)
  #expect(reading.fiveHour?.freshReset(at: claudeNow) == 1_700_001_000)
}

@Test func missingFilesMeansFirstUseAndCorruptFilesReportErrors() throws {
  #expect(try claudeRead() == nil)
  #expect(throws: ClaudeQuotaError.malformed("Claude Desktop")) {
    try claudeRead(desktop: Data("{broken".utf8))
  }
  #expect(throws: ClaudeQuotaError.malformed("Claude Code")) {
    try claudeRead(status: Data("{broken".utf8))
  }
}

@Test func validSourceSurvivesCorruptOtherSource() throws {
  let reading = try claudeRead(
    desktop: Data("{broken".utf8), status: claudeFixture("claude-status-valid"))!
  #expect(reading.fiveHour?.usedPercent == 0)
}

@Test func statusLineCaptureCachesOnlyQuotaFields() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let cache = directory.appendingPathComponent("claude-usage.json")
  let input = Data(
    #"{"session_id":"must-not-be-cached","rate_limits":{"five_hour":{"used_percentage":100,"resets_at":1700001000}},"model":{"display_name":"private"}}"#
      .utf8
  )
  #expect(
    try ClaudeQuota.captureStatusLine(input: input, cacheURL: cache, capturedAt: claudeNow)
      == "Claude")
  let stored = try String(contentsOf: cache, encoding: .utf8)
  #expect(!stored.contains("session_id"))
  #expect(!stored.contains("private"))
  let reading = try ClaudeQuota.read(
    desktopURL: directory.appendingPathComponent("missing.json"), statusURL: cache,
    now: claudeNow + 10)!
  #expect(reading.fiveHour?.usedPercent == 100)
}

@Test func malformedStatusLineClearsOldCacheAndReportsUnavailable() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let cache = directory.appendingPathComponent("claude-usage.json")
  try claudeFixture("claude-status-valid").write(to: cache)
  #expect(
    try ClaudeQuota.captureStatusLine(
      input: Data("invalid".utf8), cacheURL: cache, capturedAt: claudeNow)
      == "Claude · données invalides")
  #expect(throws: ClaudeQuotaError.malformed("Claude Code")) {
    try ClaudeQuota.read(
      desktopURL: directory.appendingPathComponent("missing.json"), statusURL: cache, now: claudeNow
    )
  }
}

@Test func statusLineWithNoQuotaMarksWaitingInsteadOfKeepingOldReading() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let cache = directory.appendingPathComponent("claude-usage.json")
  try claudeFixture("claude-status-valid").write(to: cache)
  let input = Data(#"{"rate_limits":{},"session_id":"ignored"}"#.utf8)
  #expect(
    try ClaudeQuota.captureStatusLine(input: input, cacheURL: cache, capturedAt: claudeNow)
      == "Claude · quotas en attente")
  #expect(
    try ClaudeQuota.read(
      desktopURL: directory.appendingPathComponent("missing.json"), statusURL: cache, now: claudeNow
    ) == nil)
}

@Test func codeUsageIsNotCurrentOnceItsResetPassed() throws {
  let status = Data(
    #"{"rate_limits":{"five_hour":{"used_percentage":90,"resets_at":1700000100}},"captured_at":1699999995}"#
      .utf8)
  let before = try claudeRead(status: status, now: claudeNow + 50)!
  #expect(before.fiveHour?.isFresh(at: claudeNow + 50) == true)
  for now in [claudeNow + 100, claudeNow + 200] {
    let after = try claudeRead(status: status, now: now)!
    #expect(after.fiveHour?.usedPercent == 90)
    #expect(after.fiveHour?.isFresh(at: now) == false)
    #expect(after.fiveHour?.freshReset(at: now) == nil)
  }
}

@Test func cachedReadingExpiresWhenResetPassesLater() throws {
  let status = Data(
    #"{"rate_limits":{"five_hour":{"used_percentage":90,"resets_at":1700000100}},"captured_at":1699999995}"#
      .utf8)
  let reading = try claudeRead(status: status)!
  #expect(reading.fiveHour?.isFresh(at: claudeNow) == true)
  #expect(reading.fiveHour?.isFresh(at: claudeNow + 100) == false)
}

@Test func desktopUsageIsCheckedAgainstCodeReset() throws {
  // The Code measurement is older than its 15-minute freshness, yet its reset remains a fact.
  let status = Data(
    #"{"rate_limits":{"five_hour":{"used_percentage":70,"resets_at":1699999700}},"captured_at":1699998500}"#
      .utf8)
  let before = Data(#"{"samples":[{"t":1699999600000,"u":{"fh":80}}]}"#.utf8)
  let stale = try claudeRead(desktop: before, status: status)!
  #expect(stale.fiveHour?.source == .desktop)
  #expect(stale.fiveHour?.isFresh(at: claudeNow) == false)

  let after = Data(#"{"samples":[{"t":1699999800000,"u":{"fh":5}}]}"#.utf8)
  let current = try claudeRead(desktop: after, status: status)!
  #expect(current.fiveHour?.usedPercent == 5)
  #expect(current.fiveHour?.isFresh(at: claudeNow) == true)
}

@Test func expiredResetOnlyWindowIsDropped() throws {
  let status = Data(
    #"{"rate_limits":{"five_hour":{"resets_at":1699999998}},"captured_at":1699999995}"#.utf8)
  #expect(try claudeRead(status: status) == nil)
}

/// Feeds successive status lines into one cache, then reads it with an optional Desktop history.
private struct StatusLineCache {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  var cache: URL { directory.appendingPathComponent("claude-usage.json") }

  @discardableResult
  func capture(_ json: String, at time: TimeInterval) throws -> String {
    try ClaudeQuota.captureStatusLine(input: Data(json.utf8), cacheURL: cache, capturedAt: time)
  }

  func read(desktop: String? = nil, now: TimeInterval) throws -> ClaudeQuotaReading? {
    let desktopURL = directory.appendingPathComponent("desktop.json")
    if let desktop { try Data(desktop.utf8).write(to: desktopURL) }
    return try ClaudeQuota.read(desktopURL: desktopURL, statusURL: cache, now: now)
  }

  func remove() { try? FileManager.default.removeItem(at: directory) }
}

private func desktopSample(at time: TimeInterval, fiveHour: Int = 80, sevenDay: Int = 40) -> String
{
  #"{"samples":[{"t":\#(Int(time * 1_000)),"u":{"fh":\#(fiveHour),"sd":\#(sevenDay)}}]}"#
}

@Test func statusLineWithoutQuotaKeepsResetsButNotUsage() throws {
  let status = StatusLineCache()
  defer { status.remove() }
  try status.capture(
    #"{"rate_limits":{"five_hour":{"used_percentage":90,"resets_at":1700000100}}}"#, at: claudeNow)
  #expect(
    try status.capture(#"{"session_id":"x"}"#, at: claudeNow + 200) == "Claude · quotas en attente")

  // No Code usage survives and a carried reset alone does not replace the waiting state.
  #expect(try status.read(now: claudeNow + 210) == nil)
  let stored = try String(contentsOf: status.cache, encoding: .utf8)
  #expect(!stored.contains("used_percentage"))

  // The passed reset is still a fact: Desktop usage from before it stays outdated.
  let before = try status.read(desktop: desktopSample(at: claudeNow + 50), now: claudeNow + 210)!
  #expect(before.fiveHour?.source == .desktop)
  #expect(before.fiveHour?.resetsAt == 1_700_000_100)
  #expect(before.fiveHour?.isFresh(at: claudeNow + 210) == false)

  let after = try status.read(desktop: desktopSample(at: claudeNow + 150), now: claudeNow + 210)!
  #expect(after.fiveHour?.usedPercent == 80)
  #expect(after.fiveHour?.isFresh(at: claudeNow + 210) == true)
}

@Test func invalidStatusLineStillReportsErrorAndKeepsResets() throws {
  let status = StatusLineCache()
  defer { status.remove() }
  try status.capture(
    #"{"rate_limits":{"five_hour":{"used_percentage":90,"resets_at":1700000100}}}"#, at: claudeNow)
  #expect(try status.capture("invalid", at: claudeNow + 200) == "Claude · données invalides")
  #expect(throws: ClaudeQuotaError.malformed("Claude Code")) {
    try status.read(now: claudeNow + 210)
  }
  let desktop = try status.read(desktop: desktopSample(at: claudeNow + 50), now: claudeNow + 210)!
  #expect(desktop.fiveHour?.isFresh(at: claudeNow + 210) == false)
}

@Test func fiveHourAndSevenDayResetsAreCarriedIndependently() throws {
  let status = StatusLineCache()
  defer { status.remove() }
  try status.capture(
    #"{"rate_limits":{"five_hour":{"used_percentage":10,"resets_at":1700001000},"seven_day":{"used_percentage":20,"resets_at":1700500000}}}"#,
    at: claudeNow)
  // Only five_hour, with a percentage but no reset: both known resets survive.
  try status.capture(#"{"rate_limits":{"five_hour":{"used_percentage":15}}}"#, at: claudeNow + 60)
  var reading = try status.read(now: claudeNow + 70)!
  #expect(reading.fiveHour?.usedPercent == 15)
  #expect(reading.fiveHour?.resetsAt == 1_700_001_000)
  #expect(reading.fiveHour?.resetCapturedAt == claudeNow)
  #expect(reading.sevenDay == nil)

  // Only seven_day, a reset without percentage: five_hour's reset is kept for Desktop usage.
  try status.capture(
    #"{"rate_limits":{"seven_day":{"resets_at":1700600000}}}"#, at: claudeNow + 120)
  reading = try status.read(desktop: desktopSample(at: claudeNow + 100), now: claudeNow + 130)!
  #expect(reading.fiveHour?.source == .desktop)
  #expect(reading.fiveHour?.resetsAt == 1_700_001_000)
  #expect(reading.sevenDay?.freshReset(at: claudeNow + 130) == 1_700_600_000)
  #expect(reading.sevenDay?.resetCapturedAt == claudeNow + 120)
}

@Test func supersededPassedResetStillDatesOlderUsage() throws {
  let status = StatusLineCache()
  defer { status.remove() }
  try status.capture(
    #"{"rate_limits":{"five_hour":{"used_percentage":90,"resets_at":1700000100}}}"#, at: claudeNow)
  // After the reset, a new window reset is reported without any percentage.
  try status.capture(
    #"{"rate_limits":{"five_hour":{"resets_at":1700018100}}}"#, at: claudeNow + 200)
  let reading = try status.read(desktop: desktopSample(at: claudeNow + 50), now: claudeNow + 210)!
  #expect(reading.fiveHour?.resetsAt == 1_700_018_100)
  #expect(reading.fiveHour?.previousResetAt == 1_700_000_100)
  #expect(reading.fiveHour?.isFresh(at: claudeNow + 210) == false)
}

@Test func cacheWithoutResetObservationTimeStaysReadable() throws {
  // Format written before resets were carried over.
  let reading = try claudeRead(status: claudeFixture("claude-status-valid"))!
  #expect(reading.fiveHour?.resetCapturedAt == 1_699_999_995)
  #expect(reading.fiveHour?.freshReset(at: claudeNow) == 1_700_001_000)
}
