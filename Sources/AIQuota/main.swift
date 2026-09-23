import AppKit
import Foundation
import ServiceManagement
import UserNotifications

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
            .appendingPathComponent("Library/Application Support/AIQuota/claude-usage.json")
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
            if statusLine.capturedAt >= desktop.capturedAt { return statusLine }
            let statusLineIsRecent = Date().timeIntervalSince1970 - statusLine.capturedAt <= statusLine.maxAge
            guard statusLineIsRecent else { return desktop }
            return ClaudeReading(
                sessionUsed: desktop.sessionUsed,
                weeklyUsed: desktop.weeklyUsed,
                sessionReset: statusLine.sessionReset,
                weeklyReset: statusLine.weeklyReset,
                capturedAt: desktop.capturedAt,
                source: "Claude Desktop + Claude Code",
                maxAge: desktop.maxAge
            )
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
        settings["statusLine"] = ["type": "command", "command": "\(quoted) --claude-statusline", "refreshInterval": 60]
        let updated = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try updated.write(to: settingsURL, options: .atomic)
    }

}

@MainActor
private final class QuotaController: NSObject, NSMenuDelegate {
    private enum DisplayMode: String { case available, used }
    private enum Provider { case codex, claude }
    private enum ProviderMode: String { case alternating, both, codex, claude }
    private enum WindowMode: String { case both, session, weekly }

    private let menu = NSMenu()
    private let primaryStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let secondaryStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let codexItem = NSMenuItem(title: "ChatGPT : connexion…", action: nil, keyEquivalent: "")
    private let claudeItem = NSMenuItem(title: "Claude : en attente d’une session", action: nil, keyEquivalent: "")
    private let codexAgeItem = NSMenuItem(title: "ChatGPT : aucune mesure", action: nil, keyEquivalent: "")
    private let claudeAgeItem = NSMenuItem(title: "Claude : aucune mesure", action: nil, keyEquivalent: "")
    private let chatgptSessionResetItem = NSMenuItem(title: "ChatGPT 5 h : en attente", action: nil, keyEquivalent: "")
    private let chatgptWeeklyResetItem = NSMenuItem(title: "ChatGPT 7 j : en attente", action: nil, keyEquivalent: "")
    private let claudeSessionResetItem = NSMenuItem(title: "Claude 5 h : en attente", action: nil, keyEquivalent: "")
    private let claudeWeeklyResetItem = NSMenuItem(title: "Claude 7 j : en attente", action: nil, keyEquivalent: "")
    private let alertThresholdItem = NSMenuItem(title: "Seuil actuel : désactivé", action: nil, keyEquivalent: "")
    private let countdownItem = NSMenuItem(title: "Prochain changement : 10 s", action: nil, keyEquivalent: "")
    private let client = CodexAppServerClient()
    private var refreshTimer: Timer?
    private var cycleTimer: Timer?
    private var codexLimits: RateLimitResponse?
    private var codexCapturedAt: TimeInterval?
    private var alertThreshold = UserDefaults.standard.integer(forKey: "quotaAlertThreshold")
    private var alertsAuthorized = false
    private var alertedWindows = Set<String>()
    private var displayMode: DisplayMode = UserDefaults.standard.string(forKey: "quotaDisplayMode") == "used" ? .used : .available
    private var providerMode = ProviderMode(rawValue: UserDefaults.standard.string(forKey: "quotaProviderMode") ?? "") ?? .alternating
    private var windowMode = WindowMode(rawValue: UserDefaults.standard.string(forKey: "quotaWindowMode") ?? "") ?? .both
    private var cycleSeconds: Int = {
        let saved = UserDefaults.standard.integer(forKey: "quotaCycleSeconds")
        return (2...300).contains(saved) ? saved : 10
    }()
    private var remainingCycleSeconds = 10
    private var showCountdown = UserDefaults.standard.bool(forKey: "quotaShowCountdown")
    private var refreshEnabled = UserDefaults.standard.object(forKey: "quotaRefreshEnabled") as? Bool ?? true
    private var refreshSeconds: Int = {
        let saved = UserDefaults.standard.integer(forKey: "quotaRefreshSeconds")
        return [30, 60, 300].contains(saved) ? saved : 60
    }()
    private var currentProvider: Provider = .codex
    private lazy var codexIcon = providerIcon(.codex)
    private lazy var claudeIcon = providerIcon(.claude)

    private func providerIcon(_ provider: Provider) -> NSImage? {
        let path = provider == .codex
            ? "/Applications/ChatGPT.app/Contents/Resources/chatgptTemplate@2x.png"
            : "/Applications/Claude.app/Contents/Resources/TrayIconTemplate@2x.png"
        guard let source = NSImage(contentsOfFile: path) else { return nil }
        let size = NSSize(width: 17, height: 17)
        let bounds = NSRect(origin: .zero, size: size)
        let glyph = NSImage(size: size)
        glyph.lockFocus()
        source.draw(in: NSRect(x: 2.5, y: 2.5, width: 12, height: 12))
        NSColor.white.setFill()
        bounds.fill(using: .sourceIn)
        glyph.unlockFocus()

        let image = NSImage(size: size)
        image.lockFocus()
        let color = provider == .codex
            ? NSColor(red: 0.16, green: 0.52, blue: 0.96, alpha: 1)
            : NSColor(red: 0.86, green: 0.43, blue: 0.28, alpha: 1)
        color.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)).fill()
        glyph.draw(in: bounds)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    func start() {
        menu.delegate = self
        menu.addItem(codexItem)
        menu.addItem(chatgptSessionResetItem)
        menu.addItem(chatgptWeeklyResetItem)
        menu.addItem(codexAgeItem)
        menu.addItem(.separator())
        menu.addItem(claudeItem)
        menu.addItem(claudeSessionResetItem)
        menu.addItem(claudeWeeklyResetItem)
        menu.addItem(claudeAgeItem)
        menu.addItem(.separator())
        let displayMenu = NSMenu()
        for (title, selector) in [("Pourcentage disponible", #selector(showAvailable)), ("Pourcentage utilisé", #selector(showUsed))] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            displayMenu.addItem(item)
        }
        menu.setSubmenu(displayMenu, for: menu.addItem(withTitle: "Afficher", action: nil, keyEquivalent: ""))

        let providerMenu = NSMenu()
        for (title, selector) in [
            ("Défilement automatique", #selector(showAlternating)),
            ("ChatGPT et Claude côte à côte", #selector(showBothProviders)),
            ("ChatGPT seulement", #selector(showCodexOnly)),
            ("Claude seulement", #selector(showClaudeOnly))
        ] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            providerMenu.addItem(item)
        }
        menu.setSubmenu(providerMenu, for: menu.addItem(withTitle: "Services affichés", action: nil, keyEquivalent: ""))

        let windowMenu = NSMenu()
        for (title, selector) in [
            ("5 h et 7 j", #selector(showBothWindows)),
            ("5 h seulement", #selector(showSessionOnly)),
            ("7 j seulement", #selector(showWeeklyOnly))
        ] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            windowMenu.addItem(item)
        }
        menu.setSubmenu(windowMenu, for: menu.addItem(withTitle: "Quotas affichés", action: nil, keyEquivalent: ""))

        let speedMenu = NSMenu()
        speedMenu.addItem(countdownItem)
        speedMenu.addItem(.separator())
        for (title, selector) in [
            ("Toutes les 5 secondes", #selector(cycleEvery5)),
            ("Toutes les 10 secondes", #selector(cycleEvery10)),
            ("Toutes les 20 secondes", #selector(cycleEvery20))
        ] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            speedMenu.addItem(item)
        }
        speedMenu.addItem(withTitle: "Durée personnalisée…", action: #selector(customizeCycle), keyEquivalent: "").target = self
        speedMenu.addItem(.separator())
        speedMenu.addItem(withTitle: "Afficher le compte à rebours", action: #selector(toggleCountdown), keyEquivalent: "").target = self
        menu.setSubmenu(speedMenu, for: menu.addItem(withTitle: "Vitesse du défilement", action: nil, keyEquivalent: ""))

        let refreshMenu = NSMenu()
        for (title, selector) in [
            ("Activée", #selector(toggleAutoRefresh)),
            ("Toutes les 30 secondes", #selector(refreshEvery30)),
            ("Toutes les 1 minute", #selector(refreshEvery60)),
            ("Toutes les 5 minutes", #selector(refreshEvery300))
        ] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            refreshMenu.addItem(item)
        }
        menu.setSubmenu(refreshMenu, for: menu.addItem(withTitle: "Actualisation automatique", action: nil, keyEquivalent: ""))

        menu.addItem(withTitle: "Lancer à l’ouverture de session", action: #selector(toggleLaunchAtLogin), keyEquivalent: "").target = self
        let alertsMenu = NSMenu()
        alertsMenu.addItem(alertThresholdItem)
        alertsMenu.addItem(.separator())
        for (title, selector) in [
            ("Désactivées", #selector(disableAlerts)),
            ("Sous 10 % disponibles", #selector(alertBelow10)),
            ("Sous 20 % disponibles", #selector(alertBelow20)),
            ("Sous 30 % disponibles", #selector(alertBelow30))
        ] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            alertsMenu.addItem(item)
        }
        alertsMenu.addItem(withTitle: "Seuil personnalisé…", action: #selector(customizeAlertThreshold), keyEquivalent: "").target = self
        menu.setSubmenu(alertsMenu, for: menu.addItem(withTitle: "Alertes de quota", action: nil, keyEquivalent: ""))

        menu.addItem(withTitle: "Relier Claude Code (terminal)", action: #selector(enableClaude), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Actualiser", action: #selector(refresh), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Quitter AI Quota", action: #selector(quit), keyEquivalent: "q").target = self

        primaryStatusItem.menu = menu
        secondaryStatusItem.menu = menu
        primaryStatusItem.button?.imagePosition = .imageLeading
        secondaryStatusItem.button?.imagePosition = .imageLeading
        render()
        if alertThreshold > 0 { requestAlertAuthorization() }
        Task { [weak self] in
            guard let self else { return }
            await client.setRateLimitsChangedHandler { [weak self] data in
                Task { @MainActor in self?.updateCodex(data) }
            }
            await refreshAsync()
        }
        startRefreshTimer()
        startCycleTimer()
    }

    @objc private func refresh() {
        render()
        Task { await refreshAsync() }
    }

    func menuNeedsUpdate(_ menu: NSMenu) { render() }

    @objc private func toggleLaunchAtLogin() {
        do {
            let service = SMAppService.mainApp
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
            render()
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Impossible de modifier le lancement automatique"
            alert.runModal()
        }
    }

    @objc private func disableAlerts() { setAlertThreshold(0) }
    @objc private func alertBelow10() { setAlertThreshold(10) }
    @objc private func alertBelow20() { setAlertThreshold(20) }
    @objc private func alertBelow30() { setAlertThreshold(30) }

    @objc private func customizeAlertThreshold() {
        let alert = NSAlert()
        alert.messageText = "Seuil d’alerte personnalisé"
        alert.informativeText = "Choisis un pourcentage disponible entre 1 et 99. Une alerte sera envoyée en dessous de ce seuil."
        alert.addButton(withTitle: "Enregistrer")
        alert.addButton(withTitle: "Annuler")
        let field = NSTextField(string: String(alertThreshold > 0 ? alertThreshold : 10))
        field.frame = NSRect(x: 0, y: 0, width: 220, height: 24)
        alert.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let threshold = Int(value), (1...99).contains(threshold) else {
            let error = NSAlert()
            error.messageText = "Seuil invalide"
            error.informativeText = "Saisis un nombre entier entre 1 et 99 %."
            error.runModal()
            return
        }
        setAlertThreshold(threshold)
    }

    private func setAlertThreshold(_ threshold: Int) {
        alertThreshold = threshold
        alertedWindows.removeAll()
        alertsAuthorized = false
        UserDefaults.standard.set(threshold, forKey: "quotaAlertThreshold")
        if threshold > 0 { requestAlertAuthorization() }
        render()
    }

    private func requestAlertAuthorization() {
        Task {
            do {
                alertsAuthorized = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                render()
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }
    @objc private func showAvailable() { displayMode = .available; saveDisplayMode() }
    @objc private func showUsed() { displayMode = .used; saveDisplayMode() }
    private func saveDisplayMode() { UserDefaults.standard.set(displayMode.rawValue, forKey: "quotaDisplayMode"); render() }

    @objc private func showAlternating() { setProviderMode(.alternating) }
    @objc private func showBothProviders() { setProviderMode(.both) }
    @objc private func showCodexOnly() { setProviderMode(.codex) }
    @objc private func showClaudeOnly() { setProviderMode(.claude) }

    private func setProviderMode(_ mode: ProviderMode) {
        providerMode = mode
        currentProvider = .codex
        UserDefaults.standard.set(mode.rawValue, forKey: "quotaProviderMode")
        startCycleTimer()
        render()
    }

    @objc private func showBothWindows() { setWindowMode(.both) }
    @objc private func showSessionOnly() { setWindowMode(.session) }
    @objc private func showWeeklyOnly() { setWindowMode(.weekly) }

    private func setWindowMode(_ mode: WindowMode) {
        windowMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "quotaWindowMode")
        render()
    }

    @objc private func cycleEvery5() { setCycleSeconds(5) }
    @objc private func cycleEvery10() { setCycleSeconds(10) }
    @objc private func cycleEvery20() { setCycleSeconds(20) }

    @objc private func customizeCycle() {
        let alert = NSAlert()
        alert.messageText = "Durée du défilement"
        alert.informativeText = "Choisis un nombre de secondes entre 2 et 300."
        alert.addButton(withTitle: "Enregistrer")
        alert.addButton(withTitle: "Annuler")
        let field = NSTextField(string: String(cycleSeconds))
        field.frame = NSRect(x: 0, y: 0, width: 220, height: 24)
        alert.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let seconds = Int(value), (2...300).contains(seconds) else {
            let error = NSAlert()
            error.messageText = "Durée invalide"
            error.informativeText = "Saisis un nombre entier entre 2 et 300 secondes."
            error.runModal()
            return
        }
        setCycleSeconds(seconds)
    }

    @objc private func toggleCountdown() {
        showCountdown.toggle()
        UserDefaults.standard.set(showCountdown, forKey: "quotaShowCountdown")
        render()
    }

    private func setCycleSeconds(_ seconds: Int) {
        cycleSeconds = seconds
        UserDefaults.standard.set(seconds, forKey: "quotaCycleSeconds")
        startCycleTimer()
        render()
    }

    private func startCycleTimer() {
        cycleTimer?.invalidate()
        remainingCycleSeconds = cycleSeconds
        guard providerMode == .alternating else {
            countdownItem.title = "Défilement inactif"
            return
        }
        countdownItem.title = "Prochain changement : \(remainingCycleSeconds) s"
        let timer = Timer(timeInterval: 1, target: self, selector: #selector(advanceProvider), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        cycleTimer = timer
    }

    @objc private func advanceProvider() {
        guard providerMode == .alternating else { return }
        remainingCycleSeconds -= 1
        if remainingCycleSeconds <= 0 {
            currentProvider = currentProvider == .codex ? .claude : .codex
            remainingCycleSeconds = cycleSeconds
            render()
        } else if showCountdown {
            render()
        }
        countdownItem.title = "Prochain changement : \(remainingCycleSeconds) s"
    }

    @objc private func toggleAutoRefresh() {
        refreshEnabled.toggle()
        UserDefaults.standard.set(refreshEnabled, forKey: "quotaRefreshEnabled")
        startRefreshTimer()
        if refreshEnabled { refresh() }
        render()
    }

    @objc private func refreshEvery30() { setRefreshSeconds(30) }
    @objc private func refreshEvery60() { setRefreshSeconds(60) }
    @objc private func refreshEvery300() { setRefreshSeconds(300) }

    private func setRefreshSeconds(_ seconds: Int) {
        refreshSeconds = seconds
        refreshEnabled = true
        UserDefaults.standard.set(seconds, forKey: "quotaRefreshSeconds")
        UserDefaults.standard.set(true, forKey: "quotaRefreshEnabled")
        startRefreshTimer()
        refresh()
        render()
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        guard refreshEnabled else { return }
        let timer = Timer(timeInterval: TimeInterval(refreshSeconds), target: self, selector: #selector(refresh), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

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
        catch { codexItem.title = "ChatGPT : \(error.localizedDescription)"; render() }
        render()
    }

    private func updateCodex(_ data: RateLimitResponse) {
        codexLimits = data
        codexCapturedAt = Date().timeIntervalSince1970
        render()
    }

    private func render() {
        let codexSession = codexLimits?.rateLimits.primary
        let codexWeek = codexLimits?.rateLimits.secondary
        let claude = ClaudeBridge.read()
        let now = Date().timeIntervalSince1970
        let label = displayMode == .available ? "disponible" : "utilisé"

        menu.item(withTitle: "Afficher")?.submenu?.item(withTitle: "Pourcentage disponible")?.state = displayMode == .available ? .on : .off
        menu.item(withTitle: "Afficher")?.submenu?.item(withTitle: "Pourcentage utilisé")?.state = displayMode == .used ? .on : .off
        let providerMenu = menu.item(withTitle: "Services affichés")?.submenu
        providerMenu?.item(withTitle: "Défilement automatique")?.state = providerMode == .alternating ? .on : .off
        providerMenu?.item(withTitle: "ChatGPT et Claude côte à côte")?.state = providerMode == .both ? .on : .off
        providerMenu?.item(withTitle: "ChatGPT seulement")?.state = providerMode == .codex ? .on : .off
        providerMenu?.item(withTitle: "Claude seulement")?.state = providerMode == .claude ? .on : .off
        let windowMenu = menu.item(withTitle: "Quotas affichés")?.submenu
        windowMenu?.item(withTitle: "5 h et 7 j")?.state = windowMode == .both ? .on : .off
        windowMenu?.item(withTitle: "5 h seulement")?.state = windowMode == .session ? .on : .off
        windowMenu?.item(withTitle: "7 j seulement")?.state = windowMode == .weekly ? .on : .off
        let speedMenu = menu.item(withTitle: "Vitesse du défilement")?.submenu
        speedMenu?.item(withTitle: "Toutes les 5 secondes")?.state = cycleSeconds == 5 ? .on : .off
        speedMenu?.item(withTitle: "Toutes les 10 secondes")?.state = cycleSeconds == 10 ? .on : .off
        speedMenu?.item(withTitle: "Toutes les 20 secondes")?.state = cycleSeconds == 20 ? .on : .off
        speedMenu?.item(withTitle: "Durée personnalisée…")?.state = [5, 10, 20].contains(cycleSeconds) ? .off : .on
        speedMenu?.item(withTitle: "Afficher le compte à rebours")?.state = showCountdown ? .on : .off
        let refreshMenu = menu.item(withTitle: "Actualisation automatique")?.submenu
        refreshMenu?.item(withTitle: "Activée")?.state = refreshEnabled ? .on : .off
        refreshMenu?.item(withTitle: "Toutes les 30 secondes")?.state = refreshSeconds == 30 ? .on : .off
        refreshMenu?.item(withTitle: "Toutes les 1 minute")?.state = refreshSeconds == 60 ? .on : .off
        refreshMenu?.item(withTitle: "Toutes les 5 minutes")?.state = refreshSeconds == 300 ? .on : .off
        menu.item(withTitle: "Lancer à l’ouverture de session")?.state = SMAppService.mainApp.status == .enabled ? .on : .off
        let alertsMenu = menu.item(withTitle: "Alertes de quota")?.submenu
        alertsMenu?.item(withTitle: "Désactivées")?.state = alertThreshold == 0 ? .on : .off
        alertsMenu?.item(withTitle: "Sous 10 % disponibles")?.state = alertThreshold == 10 ? .on : .off
        alertsMenu?.item(withTitle: "Sous 20 % disponibles")?.state = alertThreshold == 20 ? .on : .off
        alertsMenu?.item(withTitle: "Sous 30 % disponibles")?.state = alertThreshold == 30 ? .on : .off
        alertsMenu?.item(withTitle: "Seuil personnalisé…")?.state = alertThreshold > 0 && ![10, 20, 30].contains(alertThreshold) ? .on : .off
        alertThresholdItem.title = alertThreshold > 0 ? "Seuil actuel : \(alertThreshold) % disponibles" : "Seuil actuel : désactivé"

        let codexFresh = codexCapturedAt.map { now - $0 <= max(300, TimeInterval(refreshSeconds * 2)) } ?? false
        let claudeFresh = claude.map { now - $0.capturedAt <= $0.maxAge } ?? false
        codexAgeItem.title = "ChatGPT · dernière mesure : \(ageText(codexCapturedAt, now: now))\(codexFresh ? "" : " · ancienne")"
        claudeAgeItem.title = "Claude · dernière mesure : \(ageText(claude?.capturedAt, now: now))\(claudeFresh ? "" : " · ancienne")"
        chatgptSessionResetItem.title = "ChatGPT 5 h · \(resetText(codexSession?.resetsAt, fresh: codexFresh))"
        chatgptWeeklyResetItem.title = "ChatGPT 7 j · \(resetText(codexWeek?.resetsAt, fresh: codexFresh))"
        let claudeFallback = claude?.source == "Claude Desktop" ? "non fourni par Claude Desktop" : "indisponible"
        claudeSessionResetItem.title = "Claude 5 h · \(resetText(claude?.sessionReset, fresh: claudeFresh, fallback: claudeFallback))"
        claudeWeeklyResetItem.title = "Claude 7 j · \(resetText(claude?.weeklyReset, fresh: claudeFresh, fallback: claudeFallback))"
        if codexFresh {
            if let value = codexSession?.usedPercent { checkAlert(provider: .codex, window: "5h", used: value) }
            if let value = codexWeek?.usedPercent { checkAlert(provider: .codex, window: "7j", used: value) }
        }
        if claudeFresh {
            if let value = claude?.sessionUsed { checkAlert(provider: .claude, window: "5h", used: value) }
            if let value = claude?.weeklyUsed { checkAlert(provider: .claude, window: "7j", used: value) }
        }

        func texts(for provider: Provider) -> (String, String, [NSRange]) {
            let sessionUsed = provider == .codex ? codexSession?.usedPercent : claude?.sessionUsed
            let weeklyUsed = provider == .codex ? codexWeek?.usedPercent : claude?.weeklyUsed
            let sessionReset = provider == .codex ? codexSession?.resetsAt : claude?.sessionReset
            let weeklyReset = provider == .codex ? codexWeek?.resetsAt : claude?.weeklyReset
            let fresh = provider == .codex ? codexFresh : claudeFresh
            let sessionValid = fresh && (sessionReset.map { $0 > now } ?? true)
            let weeklyValid = fresh && (weeklyReset.map { $0 > now } ?? true)
            let sessionText = sessionValid ? sessionUsed.map(number) ?? "—" : "—"
            let weeklyText = weeklyValid ? weeklyUsed.map(number) ?? "—" : "—"
            let title: String
            switch windowMode {
            case .both: title = "5h \(sessionText) · 7j \(weeklyText)"
            case .session: title = "5h \(sessionText)"
            case .weekly: title = "7j \(weeklyText)"
            }
            let name = provider == .codex ? "ChatGPT" : "Claude"
            let capturedAt = provider == .codex ? codexCapturedAt : claude?.capturedAt
            var redRanges: [NSRange] = []
            for (prefix, text, used, visible) in [
                ("5h ", sessionText, sessionUsed, windowMode != .weekly && sessionValid),
                ("7j ", weeklyText, weeklyUsed, windowMode != .session && weeklyValid)
            ] where visible && (used.map { 100 - $0 < 10 } ?? false) {
                let full = title as NSString
                let range = full.range(of: prefix + text)
                if range.location != NSNotFound {
                    redRanges.append(NSRange(location: range.location + (prefix as NSString).length, length: (text as NSString).length))
                }
            }
            return (title, "\(name) : 5h \(sessionText), 7j \(weeklyText) \(label) · mesure \(ageText(capturedAt, now: now))", redRanges)
        }

        func show(_ provider: Provider, on statusItem: NSStatusItem) {
            let content = texts(for: provider)
            statusItem.button?.image = provider == .codex ? codexIcon : claudeIcon
            let title = NSMutableAttributedString(string: content.0)
            for range in content.2 { title.addAttribute(.foregroundColor, value: NSColor.systemRed, range: range) }
            statusItem.button?.attributedTitle = title
            statusItem.button?.toolTip = content.1
        }

        switch providerMode {
        case .alternating:
            show(currentProvider, on: primaryStatusItem)
            if showCountdown, let button = primaryStatusItem.button {
                let title = NSMutableAttributedString(attributedString: button.attributedTitle)
                title.append(NSAttributedString(string: " · \(remainingCycleSeconds)s"))
                button.attributedTitle = title
            }
            secondaryStatusItem.isVisible = false
        case .both:
            show(.codex, on: primaryStatusItem)
            show(.claude, on: secondaryStatusItem)
            secondaryStatusItem.isVisible = true
        case .codex:
            show(.codex, on: primaryStatusItem)
            secondaryStatusItem.isVisible = false
        case .claude:
            show(.claude, on: primaryStatusItem)
            secondaryStatusItem.isVisible = false
        }
        if let session = codexSession {
            codexItem.title = "ChatGPT · 5h \(codexFresh ? number(session.usedPercent) : "—") · 7j \(codexFresh ? (codexWeek.map { number($0.usedPercent) } ?? "—") : "—") \(label)"
        }
        if let claude {
            let stale = now - claude.capturedAt > claude.maxAge
            let prefix = stale ? "Claude · mesure ancienne" : "Claude"
            claudeItem.title = "\(prefix) · 5h \(claude.sessionUsed.map(number) ?? "—") · 7j \(claude.weeklyUsed.map(number) ?? "—") · \(claude.source) à \(formatted(claude.capturedAt))"
        }
    }

    private func number(_ used: Double) -> String {
        let value = displayMode == .available ? max(0, 100 - used).rounded(.down) : used.rounded()
        return "\(Int(value))%"
    }

    private func formatted(_ timestamp: TimeInterval) -> String {
        Date(timeIntervalSince1970: timestamp).formatted(date: .abbreviated, time: .shortened)
    }

    private func resetText(_ timestamp: TimeInterval?, fresh: Bool, fallback: String = "indisponible") -> String {
        guard let timestamp else { return fallback }
        guard fresh else { return "mesure ancienne, date non fiable" }
        guard timestamp > Date().timeIntervalSince1970 else { return "en attente d’un nouveau relevé" }
        let date = Date(timeIntervalSince1970: timestamp)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.timeZone = .current
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        let zone = formatter.timeZone.abbreviation(for: date) ?? ""
        return "reset le \(formatter.string(from: date)) \(zone)"
    }

    private func ageText(_ timestamp: TimeInterval?, now: TimeInterval) -> String {
        guard let timestamp else { return "aucune" }
        let seconds = max(0, Int(now - timestamp))
        if seconds < 60 { return "à l’instant" }
        if seconds < 3_600 { return "il y a \(seconds / 60) min" }
        return "il y a \(seconds / 3_600) h \((seconds % 3_600) / 60) min"
    }

    private func checkAlert(provider: Provider, window: String, used: Double) {
        guard alertThreshold > 0 else { return }
        let key = "\(provider)-\(window)"
        let available = max(0, 100 - used)
        if available >= Double(alertThreshold) {
            alertedWindows.remove(key)
            return
        }
        guard alertsAuthorized, alertedWindows.insert(key).inserted else { return }
        let name = provider == .codex ? "ChatGPT" : "Claude"
        let content = UNMutableNotificationContent()
        content.title = "Quota \(name) faible"
        content.body = "\(window) : \(Int(available.rounded(.down))) % disponibles (seuil : \(alertThreshold) %)."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "quota-\(key)", content: content, trigger: nil)
        Task { try? await UNUserNotificationCenter.current().add(request) }
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
            throw NSError(domain: "AIQuota", code: 1, userInfo: [NSLocalizedDescriptionKey: "Composant ChatGPT introuvable."])
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
        _ = try await request(method: "initialize", params: ["clientInfo": ["name": "ai_quota", "title": "AI Quota", "version": "2.0"]])
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
                else { continuation.resume(throwing: NSError(domain: "AIQuota", code: 2, userInfo: [NSLocalizedDescriptionKey: "Réponse ChatGPT invalide."])) }
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
} else if CommandLine.arguments.contains("--login-status") {
    print(SMAppService.mainApp.status == .enabled ? "enabled" : "disabled")
    exit(SMAppService.mainApp.status == .enabled ? EXIT_SUCCESS : EXIT_FAILURE)
} else if CommandLine.arguments.contains("--unregister-login") {
    do { try SMAppService.mainApp.unregister() }
    catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        exit(EXIT_FAILURE)
    }
} else if CommandLine.arguments.contains("--register-login") {
    do { try SMAppService.mainApp.register() }
    catch {
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
