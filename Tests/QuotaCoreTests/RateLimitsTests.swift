import Foundation
import Testing

@testable import QuotaCore

private func decode(_ text: String) throws -> RateLimitResponse {
  try JSONDecoder().decode(RateLimitResponse.self, from: Data(text.utf8))
}
private func fixture(_ name: String) throws -> RateLimitResponse {
  let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
  return try JSONDecoder().decode(RateLimitResponse.self, from: Data(contentsOf: url))
}
@Test func currentMultiBucket() throws {
  let r = try fixture("current")
  #expect(r.rateLimits?.primary?.usedPercent == 24)
  #expect(r.rateLimits?.secondary?.usedPercent == 4)
}
@Test func legacyZeroAndConsumed() throws {
  let r = try fixture("legacy")
  #expect(r.rateLimits?.primary?.usedPercent == 0)
  #expect(r.rateLimits?.secondary?.usedPercent == 100)
}
@Test func optionalResetMissingOrInvalid() throws {
  for reset in ["", ",\"resetsAt\":null", ",\"resetsAt\":\"invalid\"", ",\"resetsAt\":-1"] {
    let r = try decode(
      "{\"rateLimits\":{\"primary\":{\"usedPercent\":0,\"windowDurationMins\":300\(reset)}}}")
    #expect(r.rateLimits?.primary?.usedPercent == 0)
    #expect(r.rateLimits?.primary?.resetsAt == nil)
  }
}
@Test func partialDoesNotLoseValidWindow() throws {
  let r = try decode(
    #"{"rateLimits":{"primary":{"usedPercent":"bad"},"secondary":{"usedPercent":12,"windowDurationMins":10080}}}"#
  )
  #expect(r.rateLimits?.primary == nil)
  #expect(r.rateLimits?.secondary?.usedPercent == 12)
}
@Test func unknownWindowsAndBuckets() throws {
  let r = try decode(
    #"{"rateLimitsByLimitId":{"other":{"primary":{"usedPercent":10,"windowDurationMins":300}}},"rateLimits":{"primary":{"usedPercent":90,"windowDurationMins":300}}}"#
  )
  #expect(r.rateLimits == nil)
  for duration in ["15", "null"] {
    let r = try decode(
      "{\"rateLimits\":{\"primary\":{\"usedPercent\":10,\"windowDurationMins\":\(duration)}}}")
    #expect(r.rateLimits?.primary == nil)
  }
}
@Test func swappedWindowsNormalizeByDuration() throws {
  let r = try decode(
    #"{"rateLimits":{"secondary":{"usedPercent":10,"windowDurationMins":300},"primary":{"usedPercent":20,"windowDurationMins":10080}}}"#
  )
  #expect(r.rateLimits?.primary?.usedPercent == 10)
  #expect(r.rateLimits?.secondary?.usedPercent == 20)
}
@Test func invalidEnvelope() {
  for text in ["{}", "[]", "null", #"{"rateLimits":42}"#, #"{"rateLimitsByLimitId":[]}"#] {
    #expect(throws: (any Error).self) { try decode(text) }
  }
}
@Test func invalidPercentNeverInvented() throws {
  for value in ["null", "-1", "101", "\"0\""] {
    let r = try decode(
      "{\"rateLimits\":{\"primary\":{\"usedPercent\":\(value),\"windowDurationMins\":300}}}")
    #expect(r.rateLimits?.primary == nil)
  }
}
@Test func executableDiscovery() {
  #expect(
    CodexExecutable.resolve { $0 == CodexExecutable.candidates[0] } == CodexExecutable.candidates[0]
  )
  #expect(CodexExecutable.resolve { $0 == "/opt/homebrew/bin/codex" } == "/opt/homebrew/bin/codex")
  #expect(CodexExecutable.resolve { _ in false } == nil)
}
@Test func launchFailure() async {
  let client = CodexAppServerClient(executable: "/nonexistent/ai-quota-test")
  await #expect(throws: (any Error).self) { try await client.readRateLimits() }
}
@Test func processExitDoesNotHang() async {
  let client = CodexAppServerClient(timeout: .seconds(1), executable: "/usr/bin/true")
  await #expect(throws: (any Error).self) { try await client.readRateLimits() }
  await #expect(throws: (any Error).self) { try await client.readRateLimits() }
}

private func mock(_ mode: String) throws -> URL {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let url = directory.appendingPathComponent(mode)
  let source = Bundle.module.url(
    forResource: "server", withExtension: "py", subdirectory: "Fixtures")!
  try FileManager.default.copyItem(at: source, to: url)
  try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
  return url
}
@Test func timeoutAndRetry() async throws {
  let url = try mock("silent")
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
  let client = CodexAppServerClient(timeout: .milliseconds(150), executable: url.path)
  await #expect(throws: (any Error).self) { try await client.readRateLimits() }
  await #expect(throws: (any Error).self) { try await client.readRateLimits() }
  await client.shutdown()
}
@Test func rpcFailureRedactsMessage() async throws {
  let url = try mock("error")
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
  let client = CodexAppServerClient(executable: url.path)
  do {
    _ = try await client.readRateLimits()
    Issue.record("Expected RPC failure")
  } catch {
    #expect((error as NSError).code == -32001)
    #expect(!error.localizedDescription.contains("secret-like"))
  }
  await client.shutdown()
}
@Test func concurrentReadsWaitForHandshakeAndSplitFrames() async throws {
  let url = try mock("success")
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
  let client = CodexAppServerClient(executable: url.path)
  async let first = client.readRateLimits()
  async let second = client.readRateLimits()
  let results = try await [first, second]
  #expect(results.allSatisfy { $0.rateLimits?.primary?.usedPercent == 0 })
  await client.shutdown()
}

@Test func invalidRetrieval() async throws {
  let url = try mock("invalid")
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
  let client = CodexAppServerClient(executable: url.path)
  await #expect(throws: (any Error).self) { try await client.readRateLimits() }
  await client.shutdown()
}
@Test func notificationUsesSameParser() async throws {
  let url = try mock("notification")
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
  let client = CodexAppServerClient(executable: url.path)
  let (events, continuation) = AsyncStream<RateLimitResponse>.makeStream()
  await client.setRateLimitsChangedHandler { result in
    if case .success(let reading) = result { continuation.yield(reading) }
  }
  _ = try await client.readRateLimits()
  continuation.finish()
  var count = 0
  for await reading in events {
    count += 1
    #expect(reading.rateLimits?.primary?.usedPercent == 0)
  }
  #expect(count == 1)
  await client.shutdown()
}
@Test func serverRequestIsNotTakenForResponse() async throws {
  let url = try mock("server-request")
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
  let client = CodexAppServerClient(executable: url.path)
  let reading = try await client.readRateLimits()
  #expect(reading.rateLimits?.primary?.usedPercent == 0)
  await client.shutdown()
}
@Test func brokenPipeFailsFastWithoutCrashing() async throws {
  let url = try mock("closed-stdin")
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
  let client = CodexAppServerClient(timeout: .seconds(10), executable: url.path)
  let start = ContinuousClock.now
  await #expect(throws: (any Error).self) { try await client.readRateLimits() }
  #expect(ContinuousClock.now - start < .seconds(5))
  await client.shutdown()
}

private func update(_ limits: String) throws -> RateLimitResponse {
  try decode("{\"rateLimits\":\(limits)}")
}
@Test func limitIdIsDecoded() throws {
  #expect(try fixture("current").rateLimits?.limitId == "codex")
}
@Test func sparseNotificationKeepsOmittedWindow() throws {
  let merged = try fixture("current").applying(
    update(#"{"limitId":"codex","primary":{"usedPercent":30,"windowDurationMins":300}}"#))
  #expect(merged?.rateLimits?.primary?.usedPercent == 30)
  #expect(merged?.rateLimits?.secondary?.usedPercent == 4)
}
@Test func notificationForAnotherBucketIsIgnored() throws {
  let current = try fixture("current")
  #expect(
    try current.applying(
      update(#"{"limitId":"other","primary":{"usedPercent":99,"windowDurationMins":300}}"#))
      == nil)
  #expect(try current.applying(update("null")) == nil)
}
@Test func unlabeledNotificationAppliesWithoutPriorReading() throws {
  let merged = RateLimitResponse(rateLimits: nil).applying(
    try update(#"{"secondary":{"usedPercent":12,"windowDurationMins":10080}}"#))
  #expect(merged?.rateLimits?.primary == nil)
  #expect(merged?.rateLimits?.secondary?.usedPercent == 12)
}
