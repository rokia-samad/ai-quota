import AppKit
import Foundation

struct UsageWindow: Decodable {
    let usedPercent: Int
    let windowDurationMins: Int
    let resetsAt: TimeInterval
}

struct RateLimits: Decodable {
    let primary: UsageWindow?
    let secondary: UsageWindow?
}

struct RateLimitResponse: Decodable {
    let rateLimits: RateLimits
}

@MainActor
final class QuotaController: NSObject {
    private enum DisplayMode: String {
        case available, used
    }

    private enum WindowMode: String {
        case short, weekly
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let summaryItem = NSMenuItem(title: "Connexion à Codex…", action: nil, keyEquivalent: "")
    private let detailItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let updatedItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let client = CodexAppServerClient()
    private var refreshTimer: Timer?
    private var latestLimits: RateLimitResponse?
    private var displayMode: DisplayMode = UserDefaults.standard.string(forKey: "quotaDisplayMode") == DisplayMode.used.rawValue ? .used : .available
    private var windowMode: WindowMode = UserDefaults.standard.string(forKey: "quotaWindowMode") == WindowMode.weekly.rawValue ? .weekly : .short

    func start() {
        statusItem.button?.title = "Codex —"
        statusItem.button?.toolTip = "Quota Codex"
        menu.addItem(summaryItem)
        menu.addItem(detailItem)
        menu.addItem(updatedItem)
        menu.addItem(.separator())
        let modeMenu = NSMenu()
        let available = NSMenuItem(title: "Pourcentage disponible", action: #selector(showAvailable), keyEquivalent: "")
        let used = NSMenuItem(title: "Pourcentage utilisé", action: #selector(showUsed), keyEquivalent: "")
        available.target = self
        used.target = self
        modeMenu.addItem(available)
        modeMenu.addItem(used)
        menu.setSubmenu(modeMenu, for: menu.addItem(withTitle: "Afficher dans la barre de menus", action: nil, keyEquivalent: ""))
        let windowMenu = NSMenu()
        let shortWindow = NSMenuItem(title: "Fenêtre de 5 h", action: #selector(showShortWindow), keyEquivalent: "")
        let weeklyWindow = NSMenuItem(title: "Fenêtre hebdomadaire", action: #selector(showWeeklyWindow), keyEquivalent: "")
        shortWindow.target = self
        weeklyWindow.target = self
        windowMenu.addItem(shortWindow)
        windowMenu.addItem(weeklyWindow)
        menu.setSubmenu(windowMenu, for: menu.addItem(withTitle: "Fenêtre affichée", action: nil, keyEquivalent: ""))
        menu.addItem(withTitle: "Actualiser", action: #selector(refresh), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Quitter Codex Quota", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem.menu = menu

        Task { [weak self] in
            guard let self else { return }
            await client.setRateLimitsChangedHandler { [weak self] data in
                Task { @MainActor in self?.display(data) }
            }
            await refreshAsync()
        }
        refreshTimer = Timer.scheduledTimer(timeInterval: 60, target: self, selector: #selector(refresh), userInfo: nil, repeats: true)
    }

    @objc private func refresh() { Task { await refreshAsync() } }

    @objc private func showAvailable() { setDisplayMode(.available) }
    @objc private func showUsed() { setDisplayMode(.used) }
    @objc private func showShortWindow() { setWindowMode(.short) }
    @objc private func showWeeklyWindow() { setWindowMode(.weekly) }

    private func setDisplayMode(_ mode: DisplayMode) {
        displayMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "quotaDisplayMode")
        if let latestLimits { display(latestLimits) }
    }

    private func setWindowMode(_ mode: WindowMode) {
        windowMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "quotaWindowMode")
        if let latestLimits { display(latestLimits) }
    }

    private func refreshAsync() async {
        do {
            let data = try await client.readRateLimits()
            display(data)
        } catch {
            statusItem.button?.title = "Codex !"
            summaryItem.title = "Codex indisponible"
            detailItem.title = "Ouvre Codex et vérifie que tu es connecté."
            updatedItem.title = error.localizedDescription
        }
    }

    private func display(_ data: RateLimitResponse) {
        latestLimits = data
        guard let primary = data.rateLimits.primary else {
            statusItem.button?.title = "Codex —"
            summaryItem.title = "Aucun quota disponible"
            return
        }
        let primaryRemaining = max(0, 100 - primary.usedPercent)
        let modeLabel = displayMode == .available ? "disponible" : "utilisé"
        let selectedWindow = windowMode == .weekly ? (data.rateLimits.secondary ?? primary) : primary
        let selectedRemaining = max(0, 100 - selectedWindow.usedPercent)
        let selectedValue = displayMode == .available ? selectedRemaining : selectedWindow.usedPercent
        statusItem.button?.title = "Codex \(selectedValue)%"
        let primaryValue = displayMode == .available ? primaryRemaining : primary.usedPercent
        summaryItem.title = "Fenêtre \(duration(primary.windowDurationMins)) : \(primaryValue)% \(modeLabel) · reset \(time(primary.resetsAt))"
        if let secondary = data.rateLimits.secondary {
            let secondaryRemaining = max(0, 100 - secondary.usedPercent)
            let secondaryValue = displayMode == .available ? secondaryRemaining : secondary.usedPercent
            detailItem.title = "Fenêtre \(duration(secondary.windowDurationMins)) : \(secondaryValue)% \(modeLabel) · reset \(time(secondary.resetsAt))"
        } else {
            detailItem.title = "Aucune seconde fenêtre de quota."
        }
        updatedItem.title = "Mis à jour à \(Date.now.formatted(date: .omitted, time: .shortened))"
        updateModeCheckmarks()
        updateWindowCheckmarks()
    }

    private func updateModeCheckmarks() {
        guard let modeMenu = menu.item(withTitle: "Afficher dans la barre de menus")?.submenu else { return }
        modeMenu.item(withTitle: "Pourcentage disponible")?.state = displayMode == .available ? .on : .off
        modeMenu.item(withTitle: "Pourcentage utilisé")?.state = displayMode == .used ? .on : .off
    }

    private func updateWindowCheckmarks() {
        guard let windowMenu = menu.item(withTitle: "Fenêtre affichée")?.submenu else { return }
        windowMenu.item(withTitle: "Fenêtre de 5 h")?.state = windowMode == .short ? .on : .off
        windowMenu.item(withTitle: "Fenêtre hebdomadaire")?.state = windowMode == .weekly ? .on : .off
    }

    private func duration(_ minutes: Int) -> String {
        if minutes % 10_080 == 0 { return "\(minutes / 10_080) sem." }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440) j" }
        if minutes % 60 == 0 { return "\(minutes / 60) h" }
        return "\(minutes) min"
    }

    private func time(_ timestamp: TimeInterval) -> String {
        Date(timeIntervalSince1970: timestamp).formatted(date: .abbreviated, time: .shortened)
    }

    @objc private func quit() { NSApplication.shared.terminate(nil) }
}

actor CodexAppServerClient {
    private var process: Process?
    private var input: FileHandle?
    private var continuations: [Int: CheckedContinuation<Data, Error>] = [:]
    private var nextID = 1
    private var onRateLimitsChanged: (@Sendable (RateLimitResponse) -> Void)?

    func setRateLimitsChangedHandler(_ handler: @escaping @Sendable (RateLimitResponse) -> Void) {
        onRateLimitsChanged = handler
    }

    func readRateLimits() async throws -> RateLimitResponse {
        try await connectIfNeeded()
        let response = try await call(method: "account/rateLimits/read")
        return try JSONDecoder().decode(RateLimitResponse.self, from: response)
    }

    private func connectIfNeeded() async throws {
        if process?.isRunning == true { return }
        let executable = ["/Applications/ChatGPT.app/Contents/Resources/codex", "/usr/local/bin/codex", "/opt/homebrew/bin/codex"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        guard let executable else { throw NSError(domain: "CodexQuota", code: 1, userInfo: [NSLocalizedDescriptionKey: "L’exécutable Codex est introuvable."]) }

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
        _ = try await request(method: "initialize", params: ["clientInfo": ["name": "codex_quota_widget", "title": "Codex Quota Widget", "version": "1.0"]])
        send(["method": "initialized", "params": [:]])
    }

    private var buffer = Data()
    private func consume(_ chunk: Data) {
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let id = object["id"] as? Int, let continuation = continuations.removeValue(forKey: id) {
                if let result = object["result"], let data = try? JSONSerialization.data(withJSONObject: result) { continuation.resume(returning: data) }
                else { continuation.resume(throwing: NSError(domain: "CodexQuota", code: 2, userInfo: [NSLocalizedDescriptionKey: "Réponse Codex invalide."])) }
            } else if object["method"] as? String == "account/rateLimits/updated",
                      let params = object["params"], let data = try? JSONSerialization.data(withJSONObject: params),
                      let limits = try? JSONDecoder().decode(RateLimitResponse.self, from: data) {
                onRateLimitsChanged?(limits)
            }
        }
    }

    private func call(method: String) async throws -> Data { try await request(method: method, params: [:]) }

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

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = QuotaController()
controller.start()
app.run()
