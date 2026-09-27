import Foundation

public actor CodexAppServerClient {
  private var process: Process?
  private var input: FileHandle?
  private var continuations: [Int: CheckedContinuation<Data, Error>] = [:]
  private var nextID = 1
  private var onRateLimitsChanged: (@Sendable (Result<RateLimitResponse, any Error>) -> Void)?
  private var buffer = Data()
  private var connection: Task<Void, Error>?
  private var generation = UUID()
  private let timeout: Duration
  private let executable: String?

  public init(timeout: Duration = .seconds(20), executable: String? = nil) {
    self.timeout = timeout
    self.executable = executable
  }

  public func setRateLimitsChangedHandler(
    _ handler: @escaping @Sendable (Result<RateLimitResponse, any Error>) -> Void
  ) { onRateLimitsChanged = handler }

  public func shutdown() { disconnect(generation) }

  public func readRateLimits() async throws -> RateLimitResponse {
    try await connectIfNeeded()
    let response = try await request(method: "account/rateLimits/read", params: [:])
    return try JSONDecoder().decode(RateLimitResponse.self, from: response)
  }

  private func connectIfNeeded() async throws {
    if let connection { return try await connection.value }
    if process?.isRunning == true { return }
    let pending = Task { try await self.start() }
    connection = pending
    defer { connection = nil }
    try await pending.value
  }

  private func start() async throws {
    guard let executable = executable ?? CodexExecutable.resolve() else {
      throw NSError(
        domain: "AIQuota", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Composant ChatGPT introuvable."])
    }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: executable)
    task.arguments = ["app-server"]
    let stdin = Pipe()
    let stdout = Pipe()
    task.standardInput = stdin
    task.standardOutput = stdout
    task.standardError = FileHandle.nullDevice
    generation = UUID()
    let current = generation
    task.terminationHandler = { [weak self] _ in Task { await self?.disconnect(current) } }
    try task.run()
    process = task
    input = stdin.fileHandleForWriting
    let (chunks, stream) = AsyncStream<Data>.makeStream()
    stdout.fileHandleForReading.readabilityHandler = { handle in
      let chunk = handle.availableData
      if chunk.isEmpty {
        stream.finish()
        handle.readabilityHandler = nil
      } else {
        stream.yield(chunk)
      }
    }
    Task { [weak self] in
      for await chunk in chunks { await self?.consume(chunk, generation: current) }
    }
    do {
      _ = try await request(
        method: "initialize",
        params: ["clientInfo": ["name": "ai_quota", "title": "AI Quota", "version": "2.0"]])
      send(["method": "initialized", "params": [:]])
    } catch {
      disconnect(current)
      throw error
    }
  }

  private func consume(_ chunk: Data, generation current: UUID) {
    guard current == generation else { return }
    buffer.append(chunk)
    while let newline = buffer.firstIndex(of: 10) {
      let line = buffer.prefix(upTo: newline)
      buffer.removeSubrange(...newline)
      guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
        continue
      }
      if let id = object["id"] as? Int, let continuation = continuations.removeValue(forKey: id) {
        if let result = object["result"],
          let data = try? JSONSerialization.data(withJSONObject: result)
        {
          continuation.resume(returning: data)
        } else {
          let code = (object["error"] as? [String: Any])?["code"] as? Int ?? 2
          continuation.resume(
            throwing: NSError(
              domain: "AIQuota", code: code,
              userInfo: [
                NSLocalizedDescriptionKey:
                  "Échec du service Codex (code \(code)). Vérifie la connexion du compte dans Codex/ChatGPT."
              ]))
        }
      } else if object["method"] as? String == "account/rateLimits/updated" {
        do {
          guard let params = object["params"] else { throw CocoaError(.coderReadCorrupt) }
          let data = try JSONSerialization.data(withJSONObject: params)
          onRateLimitsChanged?(
            .success(try JSONDecoder().decode(RateLimitResponse.self, from: data)))
        } catch {
          onRateLimitsChanged?(.failure(CocoaError(.coderReadCorrupt)))
        }
      }
    }
  }

  private func request(method: String, params: [String: Any]) async throws -> Data {
    let id = nextID
    nextID += 1
    return try await withCheckedThrowingContinuation { continuation in
      continuations[id] = continuation
      send(["method": method, "id": id, "params": params])
      Task {
        try? await Task.sleep(for: timeout)
        if continuations[id] != nil { disconnect(generation) }
      }
    }
  }

  private func disconnect(_ current: UUID) {
    guard generation == current else { return }
    generation = UUID()
    let pending = continuations
    continuations.removeAll()
    process?.terminate()
    process = nil
    input = nil
    buffer.removeAll()
    for continuation in pending.values {
      continuation.resume(
        throwing: NSError(
          domain: "AIQuota", code: 3,
          userInfo: [
            NSLocalizedDescriptionKey:
              "Service Codex interrompu ou délai dépassé. Réessaie l’actualisation."
          ]))
    }
  }

  private func send(_ object: [String: Any]) {
    guard let input, let data = try? JSONSerialization.data(withJSONObject: object) else { return }
    do { try input.write(contentsOf: data + Data([10])) } catch { disconnect(generation) }
  }
}
