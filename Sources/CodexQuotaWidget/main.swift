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

    static func read() -> ClaudeSample? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(ClaudeSample.self, from: data)
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
    private enum Window: CaseIterable { case session, weekly }

    private let menu = NSMenu()
    private var statusItems: [String: NSStatusItem] = [:]
    private let codexItem = NSMenuItem(title: "Codex : connexion…", action: nil, keyEquivalent: "")
    private let claudeItem = NSMenuItem(title: "Claude : en attente d’une session", action: nil, keyEquivalent: "")
    private let client = CodexAppServerClient()
    private var timer: Timer?
    private var codexLimits: RateLimitResponse?
    private var displayMode: DisplayMode = UserDefaults.standard.string(forKey: "quotaDisplayMode") == "used" ? .used : .available

    private func providerIcon(_ provider: Provider) -> NSImage? {
        let image: NSImage?
        if provider == .codex {
            let iconPath = Bundle.main.resourceURL?.appendingPathComponent("CodexQuota.icns").path
            if let iconPath, FileManager.default.fileExists(atPath: iconPath) {
                image = NSImage(contentsOfFile: iconPath)
            } else {
                image = NSWorkspace.shared.icon(forFile: "/Applications/ChatGPT.app")
            }
        } else {
            image = NSWorkspace.shared.icon(forFile: "/Applications/Claude.app")
        }
        image?.size = NSSize(width: 16, height: 16)
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
        menu.addItem(withTitle: "Activer les quotas Claude Code", action: #selector(enableClaude), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Actualiser", action: #selector(refresh), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Quitter Quota Widget", action: #selector(quit), keyEquivalent: "q").target = self

        for provider in Provider.allCases {
            let icon = providerIcon(provider)
            for window in Window.allCases {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                item.button?.image = icon
                item.button?.imagePosition = .imageLeading
                item.menu = menu
                statusItems[key(provider, window)] = item
            }
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

    private func key(_ provider: Provider, _ window: Window) -> String { "\(provider)-\(window)" }

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
            for window in Window.allCases {
                guard let button = statusItems[key(provider, window)]?.button else { continue }
                let used: Double?
                let reset: TimeInterval?
                switch (provider, window) {
                case (.codex, .session): used = codexSession?.usedPercent; reset = codexSession?.resetsAt
                case (.codex, .weekly): used = codexWeek?.usedPercent; reset = codexWeek?.resetsAt
                case (.claude, .session): used = claude?.rate_limits.five_hour?.used_percentage; reset = claude?.rate_limits.five_hour?.resets_at
                case (.claude, .weekly): used = claude?.rate_limits.seven_day?.used_percentage; reset = claude?.rate_limits.seven_day?.resets_at
                }
                let sampleIsFresh = provider == .codex || (claude.map { now - $0.captured_at <= 900 } ?? false)
                let valid = sampleIsFresh && (reset.map { $0 > now } ?? false)
                let value = valid ? used.map { displayMode == .available ? max(0, 100 - $0) : $0 } : nil
                let text = value.map { "\(Int($0.rounded()))%" } ?? "—"
                let name = provider == .codex ? "Codex" : "Claude"
                let period = window == .session ? "5h" : "7j"
                button.title = "\(period) \(text)"
                button.toolTip = "\(name) · \(period) : \(text) \(label)" + (reset.map { " · reset \(formatted($0))" } ?? "")
            }
        }
        if let session = codexSession {
            codexItem.title = "Codex · 5h \(number(session.usedPercent)) · 7j \(codexWeek.map { number($0.usedPercent) } ?? "—") \(label)"
        }
        if let claude {
            let stale = now - claude.captured_at > 900
            let prefix = stale ? "Claude · dernière mesure" : "Claude"
            claudeItem.title = "\(prefix) · 5h \(claude.rate_limits.five_hour.map { number($0.used_percentage) } ?? "—") · 7j \(claude.rate_limits.seven_day.map { number($0.used_percentage) } ?? "—") · \(formatted(claude.captured_at))"
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
