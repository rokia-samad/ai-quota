import AppKit
import Foundation

private struct UsageWindow: Decodable, Sendable {
    let usedPercent: Double
    let windowDurationMins: Int
    let resetsAt: TimeInterval
}

private struct RateLimits: Decodable, Sendable {
    let primary: UsageWindow?
    let secondary: UsageWindow?
}

private struct RateLimitResponse: Decodable, Sendable {
    let rateLimits: RateLimits
}

private struct ClaudeWindow: Codable {
    let used_percentage: Double
    let resets_at: TimeInterval
}

private struct ClaudeLimits: Codable {
    let five_hour: ClaudeWindow?
    let seven_day: ClaudeWindow?
}

private struct ClaudeSample: Codable {
    let rate_limits: ClaudeLimits
    let captured_at: TimeInterval
}

private struct ClaudeHistory: Decodable {
    struct Usage: Decodable {
        let fh: Double?
        let sd: Double?
    }

    struct Sample: Decodable {
        let t: TimeInterval
        let u: Usage
    }

    let samples: [Sample]
}

private struct ClaudeReading {
    let sessionUsed: Double?
    let weeklyUsed: Double?
    let sessionReset: TimeInterval?
    let weeklyReset: TimeInterval?
    let capturedAt: TimeInterval
    let source: String
    let maxAge: TimeInterval
}

private enum ClaudeBridge {
    static var cacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexQuotaWidget/claude-usage.json")
    }

    static func captureStatusLine() {
        guard let input = try? FileHandle.standardInput.readToEnd(),
              let object = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else { return }
        if let limits = object["rate_limits"] as? [String: Any],
           let limitsData = try? JSONSerialization.data(withJSONObject: limits),
           let decoded = try? JSONDecoder().decode(ClaudeLimits.self, from: limitsData),
           decoded.five_hour != nil || decoded.seven_day != nil {
            let sample = ClaudeSample(rate_limits: decoded, captured_at: Date().timeIntervalSince1970)
            if let data = try? JSONEncoder().encode(sample) {
                try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: cacheURL, options: .atomic)
            }
        }
        print("Claude Code")
    }

    static func read() -> ClaudeReading? {
        let statusLine: ClaudeReading? = {
            guard let data = try? Data(contentsOf: cacheURL),
                  let sample = try? JSONDecoder().decode(ClaudeSample.self, from: data) else { return nil }
            return ClaudeReading(
                sessionUsed: sample.rate_limits.five_hour?.used_percentage,
                weeklyUsed: sample.rate_limits.seven_day?.used_percentage,
                sessionReset: sample.rate_limits.five_hour?.resets_at,
                weeklyReset: sample.rate_limits.seven_day?.resets_at,
                capturedAt: sample.captured_at,
                source: "Claude Code",
                maxAge: 900
            )
        }()

        let desktop: ClaudeReading? = {
            let path = "Library/Application Support/Claude/plan-usage-history.json"
            let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(path)
            guard let data = try? Data(contentsOf: url),
                  let history = try? JSONDecoder().decode(ClaudeHistory.self, from: data),
                  let sample = history.samples.max(by: { $0.t < $1.t }) else { return nil }
            return ClaudeReading(
                sessionUsed: sample.u.fh,
                weeklyUsed: sample.u.sd,
                sessionReset: nil,
                weeklyReset: nil,
                capturedAt: sample.t / 1_000,
                source: "Claude Desktop",
                maxAge: 1_800
            )
        }()

        if let statusLine, let desktop {
            return statusLine.capturedAt >= desktop.capturedAt ? statusLine : desktop
        }
        return statusLine ?? desktop
    }

    static func installStatusLine() throws {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
        let data = (try? Data(contentsOf: settingsURL)) ?? Data("{}".utf8)
        guard var settings = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "ClaudeBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "Le fichier settings.json de Claude Code n’est pas un objet JSON valide."])
        }
        if settings["statusLine"] != nil {
            throw NSError(domain: "ClaudeBridge", code: 2, userInfo: [NSLocalizedDescriptionKey: "Une ligne de statut Claude est déjà configurée. Consulte le README pour la relier au widget sans écraser ta configuration."])
        }
        let executable = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
        let quoted = "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "'"
        settings["statusLine"] = ["type": "command", "command": "\(quoted) --claude-statusline"]
        let updated = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try updated.write(to: settingsURL, options: .atomic)
    }
}

@MainActor
private final class QuotaController: NSObject {
    private enum DisplayMode: String { case available, used }
    private enum Provider: CaseIterable { case codex, claude }

    private let menu = NSMenu()
    private var statusItems: [Provider: NSStatusItem] = [:]
    private let codexItem = NSMenuItem(title: "Codex : connexion…", action: nil, keyEquivalent: "")
    private let claudeItem = NSMenuItem(title: "Claude : en attente d’une session", action: nil, keyEquivalent: "")
    private let client = CodexAppServerClient()
    private var timer: Timer?
    private var codexLimits: RateLimitResponse?
    private var displayMode: DisplayMode = UserDefaults.standard.string(forKey: "quotaDisplayMode") == "used" ? .used : .available

    private func providerIcon(_ provider: Provider) -> NSImage? {
        let path = provider == .codex
            ? "/Applications/ChatGPT.app/Contents/Resources/chatgptTemplate@2x.png"
            : "/Applications/Claude.app/Contents/Resources/TrayIconTemplate@2x.png"
        guard let source = NSImage(contentsOfFile: path) else { return nil }
        let size = NSSize(width: 16, height: 16)
        let bounds = NSRect(origin: .zero, size: size)
        let image = NSImage(size: size)
        image.lockFocus()
        source.draw(in: bounds)
        let color = provider == .codex
            ? NSColor(red: 0.16, green: 0.52, blue: 0.96, alpha: 1)
            : NSColor(red: 0.86, green: 0.43, blue: 0.28, alpha: 1)
        color.setFill()
        bounds.fill(using: .sourceIn)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    func start() {
        menu.addItem(codexItem)
        menu.addItem(claudeItem)
        menu.addItem(.separator())
        let displayMenu = NSMenu()
        for (title, selector) in [("Pourcentage disponible", #selector(showAvailable)), ("Pourcentage utilisé", #selector(showUsed))] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            displayMenu.addItem(item)
        }
        menu.setSubmenu(displayMenu, for: menu.addItem(withTitle: "Afficher", action: nil, keyEquivalent: ""))
        menu.addItem(withTitle: "Relier Claude Code (terminal)", action: #selector(enableClaude), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Actualiser", action: #selector(refresh), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Quitter Quota Widget", action: #selector(quit), keyEquivalent: "q").target = self

        for provider in Provider.allCases {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.image = providerIcon(provider)
            item.button?.imagePosition = .imageLeading
            item.menu = menu
            statusItems[provider] = item
        }
        render()
        Task { [weak self] in
            guard let self else { return }
            await client.setRateLimitsChangedHandler { [weak self] data in
                Task { @MainActor in self?.updateCodex(data) }
            }
            await refreshAsync()
        }
        timer = Timer.scheduledTimer(timeInterval: 60, target: self, selector: #selector(refresh), userInfo: nil, repeats: true)
    }

    @objc private func refresh() { Task { await refreshAsync() } }
    @objc private func showAvailable() { displayMode = .available; saveDisplayMode() }
    @objc private func showUsed() { displayMode = .used; saveDisplayMode() }
    private func saveDisplayMode() { UserDefaults.standard.set(displayMode.rawValue, forKey: "quotaDisplayMode"); render() }

    @objc private func enableClaude() {
        do {
            try ClaudeBridge.installStatusLine()
            claudeItem.title = "Claude : activé. Envoie un message dans Claude Code pour recevoir les quotas."
        } catch {
            claudeItem.title = "Claude : \(error.localizedDescription)"
        }
    }

    private func refreshAsync() async {
        do { updateCodex(try await client.readRateLimits()) }
        catch { codexItem.title = "Codex : \(error.localizedDescription)"; render() }
        render()
    }

    private func updateCodex(_ data: RateLimitResponse) { codexLimits = data; render() }

    private func render() {
        let codexSession = codexLimits?.rateLimits.primary
        let codexWeek = codexLimits?.rateLimits.secondary
        let claude = ClaudeBridge.read()
        let now = Date().timeIntervalSince1970
        let label = displayMode == .available ? "disponible" : "utilisé"
        let options = menu.item(withTitle: "Afficher")?.submenu
        options?.item(withTitle: "Pourcentage disponible")?.state = displayMode == .available ? .on : .off
        options?.item(withTitle: "Pourcentage utilisé")?.state = displayMode == .used ? .on : .off
        for provider in Provider.allCases {
            guard let button = statusItems[provider]?.button else { continue }
            let sessionUsed = provider == .codex ? codexSession?.usedPercent : claude?.sessionUsed
            let weeklyUsed = provider == .codex ? codexWeek?.usedPercent : claude?.weeklyUsed
            let sessionReset = provider == .codex ? codexSession?.resetsAt : claude?.sessionReset
            let weeklyReset = provider == .codex ? codexWeek?.resetsAt : claude?.weeklyReset
            let fresh = provider == .codex || (claude.map { now - $0.capturedAt <= $0.maxAge } ?? false)
            let sessionValid = fresh && (sessionReset.map { $0 > now } ?? true)
            let weeklyValid = fresh && (weeklyReset.map { $0 > now } ?? true)
            let sessionText = sessionValid ? sessionUsed.map(number) ?? "—" : "—"
            let weeklyText = weeklyValid ? weeklyUsed.map(number) ?? "—" : "—"
            button.title = "5h \(sessionText) · 7j \(weeklyText)"
            let name = provider == .codex ? "ChatGPT / Codex" : "Claude"
            button.toolTip = "\(name) : 5h \(sessionText), 7j \(weeklyText) \(label)"
        }
        if let session = codexSession {
            codexItem.title = "Codex · 5h \(number(session.usedPercent)) · 7j \(codexWeek.map { number($0.usedPercent) } ?? "—") \(label)"
        }
        if let claude {
            let stale = now - claude.capturedAt > claude.maxAge
            let prefix = stale ? "Claude · mesure ancienne" : "Claude"
            claudeItem.title = "\(prefix) · 5h \(claude.sessionUsed.map(number) ?? "—") · 7j \(claude.weeklyUsed.map(number) ?? "—") · \(claude.source) à \(formatted(claude.capturedAt))"
        }
    }

    private func number(_ used: Double) -> String {
        "\(Int((displayMode == .available ? max(0, 100 - used) : used).rounded()))%"
    }

    private func formatted(_ timestamp: TimeInterval) -> String {
        Date(timeIntervalSince1970: timestamp).formatted(date: .abbreviated, time: .shortened)
    }

    @objc private func quit() { NSApplication.shared.terminate(nil) }
}

private actor CodexAppServerClient {
    private var process: Process?
    private var input: FileHandle?
    private var continuations: [Int: CheckedContinuation<Data, Error>] = [:]
    private var nextID = 1
    private var onRateLimitsChanged: (@Sendable (RateLimitResponse) -> Void)?
    private var buffer = Data()

    func setRateLimitsChangedHandler(_ handler: @escaping @Sendable (RateLimitResponse) -> Void) { onRateLimitsChanged = handler }

    func readRateLimits() async throws -> RateLimitResponse {
        try await connectIfNeeded()
        let response = try await request(method: "account/rateLimits/read", params: [:])
        return try JSONDecoder().decode(RateLimitResponse.self, from: response)
    }

    private func connectIfNeeded() async throws {
        if process?.isRunning == true { return }
        let candidates = ["/Applications/ChatGPT.app/Contents/Resources/codex", "/usr/local/bin/codex", "/opt/homebrew/bin/codex"]
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw NSError(domain: "QuotaWidget", code: 1, userInfo: [NSLocalizedDescriptionKey: "Exécutable Codex introuvable."])
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = ["app-server"]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        task.standardInput = stdin
        task.standardOutput = stdout
        task.standardError = stderr
        try task.run()
        process = task
        input = stdin.fileHandleForWriting
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            Task { await self?.consume(chunk) }
        }
        _ = try await request(method: "initialize", params: ["clientInfo": ["name": "quota_widget", "title": "Quota Widget", "version": "2.0"]])
        send(["method": "initialized", "params": [:]])
    }

    private func consume(_ chunk: Data) {
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let id = object["id"] as? Int, let continuation = continuations.removeValue(forKey: id) {
                if let result = object["result"], let data = try? JSONSerialization.data(withJSONObject: result) { continuation.resume(returning: data) }
                else { continuation.resume(throwing: NSError(domain: "QuotaWidget", code: 2, userInfo: [NSLocalizedDescriptionKey: "Réponse Codex invalide."])) }
            } else if object["method"] as? String == "account/rateLimits/updated",
                      let params = object["params"], let data = try? JSONSerialization.data(withJSONObject: params),
                      let limits = try? JSONDecoder().decode(RateLimitResponse.self, from: data) { onRateLimitsChanged?(limits) }
        }
    }

    private func request(method: String, params: [String: Any]) async throws -> Data {
        let id = nextID; nextID += 1
        return try await withCheckedThrowingContinuation { continuation in
            continuations[id] = continuation
            send(["method": method, "id": id, "params": params])
        }
    }

    private func send(_ object: [String: Any]) {
        guard let input, let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        input.write(data + Data([10]))
    }
}

if CommandLine.arguments.contains("--claude-statusline") {
    ClaudeBridge.captureStatusLine()
} else if CommandLine.arguments.contains("--diagnose-claude") {
    if let reading = ClaudeBridge.read() {
        print("\(reading.source) · 5h \(reading.sessionUsed.map { String(Int($0.rounded())) } ?? "—")% · 7j \(reading.weeklyUsed.map { String(Int($0.rounded())) } ?? "—")% · mesure \(Date(timeIntervalSince1970: reading.capturedAt))")
    } else {
        print("Aucune mesure Claude disponible.")
        exit(EXIT_FAILURE)
    }
} else if CommandLine.arguments.contains("--install-claude-statusline") {
    do {
        try ClaudeBridge.installStatusLine()
        print("Ligne de statut Claude Code activée.")
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        exit(EXIT_FAILURE)
    }
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let controller = QuotaController()
    controller.start()
    app.run()
}
