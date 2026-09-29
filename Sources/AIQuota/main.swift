import AppKit
import Foundation
import ServiceManagement
import UserNotifications

import QuotaCore

private enum ClaudeBridge {
    static var cacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AIQuota/claude-usage.json")
    }

    static var desktopURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
    }

    static func captureStatusLine() {
        let input = (try? FileHandle.standardInput.readToEnd()) ?? Data()
        do {
            print(try ClaudeQuota.captureStatusLine(input: input, cacheURL: cacheURL))
        } catch {
            print("AI Quota · cache Claude inaccessible")
            FileHandle.standardError.write(Data("Cache AI Quota inaccessible\n".utf8))
        }
    }

    static func read() throws -> ClaudeQuotaReading? {
        try ClaudeQuota.read(desktopURL: desktopURL, statusURL: cacheURL)
    }

    static func installStatusLine() throws {
        try ClaudeStatusLineInstaller.install(
            settingsURL: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json"),
            executablePath: Bundle.main.executableURL?.path ?? CommandLine.arguments[0])
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
    private let claudeItem = NSMenuItem(title: "Claude · en attente d’une première mesure", action: nil, keyEquivalent: "")
    private let codexAgeItem = NSMenuItem(title: "ChatGPT : aucune mesure", action: nil, keyEquivalent: "")
    private let claudeAgeItem = NSMenuItem(title: "Claude · en attente d’une première mesure", action: nil, keyEquivalent: "")
    private let chatgptSessionResetItem = NSMenuItem(title: "ChatGPT 5 h : en attente", action: nil, keyEquivalent: "")
    private let chatgptWeeklyResetItem = NSMenuItem(title: "ChatGPT 7 j : en attente", action: nil, keyEquivalent: "")
    private let claudeSessionResetItem = NSMenuItem(title: "Claude 5 h : en attente", action: nil, keyEquivalent: "")
    private let claudeWeeklyResetItem = NSMenuItem(title: "Claude 7 j : en attente", action: nil, keyEquivalent: "")
    private let alertThresholdItem = NSMenuItem(title: "Seuil actuel : désactivé", action: nil, keyEquivalent: "")
    private let countdownItem = NSMenuItem(title: "Prochain changement : 10 s", action: nil, keyEquivalent: "")
    private let client = CodexAppServerClient()
    private var refreshTimer: Timer?
    private var cycleTimer: Timer?
    private var codexError: String?
    private var claude: ClaudeQuotaReading?
    private var claudeError: String?
    private var codex: CodexMeasurement?
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
    /// Options showing a checkmark, each with the rule deciding its state.
    private var checkableItems: [(item: NSMenuItem, isOn: @MainActor () -> Bool)] = []

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
        func addDisplayHeading(_ title: String) {
            let heading = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            heading.isEnabled = false
            displayMenu.addItem(heading)
        }
        addDisplayHeading("Pourcentage")
        addOption("Disponible", #selector(showAvailable), to: displayMenu) { [unowned self] in displayMode == .available }
        addOption("Utilisé", #selector(showUsed), to: displayMenu) { [unowned self] in displayMode == .used }
        displayMenu.addItem(.separator())
        addDisplayHeading("Services")
        addOption("Défilement automatique", #selector(showAlternating), to: displayMenu) { [unowned self] in providerMode == .alternating }
        addOption("ChatGPT et Claude côte à côte", #selector(showBothProviders), to: displayMenu) { [unowned self] in providerMode == .both }
        addOption("ChatGPT seulement", #selector(showCodexOnly), to: displayMenu) { [unowned self] in providerMode == .codex }
        addOption("Claude seulement", #selector(showClaudeOnly), to: displayMenu) { [unowned self] in providerMode == .claude }
        displayMenu.addItem(.separator())
        addDisplayHeading("Fenêtres de quota")
        addOption("5 h et 7 j", #selector(showBothWindows), to: displayMenu) { [unowned self] in windowMode == .both }
        addOption("5 h seulement", #selector(showSessionOnly), to: displayMenu) { [unowned self] in windowMode == .session }
        addOption("7 j seulement", #selector(showWeeklyOnly), to: displayMenu) { [unowned self] in windowMode == .weekly }
        displayMenu.addItem(.separator())
        addDisplayHeading("Défilement")
        displayMenu.addItem(countdownItem)
        addOption("Toutes les 5 secondes", #selector(cycleEvery5), to: displayMenu) { [unowned self] in cycleSeconds == 5 }
        addOption("Toutes les 10 secondes", #selector(cycleEvery10), to: displayMenu) { [unowned self] in cycleSeconds == 10 }
        addOption("Toutes les 20 secondes", #selector(cycleEvery20), to: displayMenu) { [unowned self] in cycleSeconds == 20 }
        addOption("Durée personnalisée…", #selector(customizeCycle), to: displayMenu) { [unowned self] in ![5, 10, 20].contains(cycleSeconds) }
        addOption("Afficher le compte à rebours", #selector(toggleCountdown), to: displayMenu) { [unowned self] in showCountdown }
        menu.setSubmenu(displayMenu, for: menu.addItem(withTitle: "Affichage", action: nil, keyEquivalent: ""))

        let refreshMenu = NSMenu()
        addOption("Activée", #selector(toggleAutoRefresh), to: refreshMenu) { [unowned self] in refreshEnabled }
        addOption("Toutes les 30 secondes", #selector(refreshEvery30), to: refreshMenu) { [unowned self] in refreshSeconds == 30 }
        addOption("Toutes les 1 minute", #selector(refreshEvery60), to: refreshMenu) { [unowned self] in refreshSeconds == 60 }
        addOption("Toutes les 5 minutes", #selector(refreshEvery300), to: refreshMenu) { [unowned self] in refreshSeconds == 300 }
        menu.setSubmenu(refreshMenu, for: menu.addItem(withTitle: "Actualisation", action: nil, keyEquivalent: ""))

        let alertsMenu = NSMenu()
        alertsMenu.addItem(alertThresholdItem)
        alertsMenu.addItem(.separator())
        addOption("Désactivées", #selector(disableAlerts), to: alertsMenu) { [unowned self] in alertThreshold == 0 }
        addOption("Sous 10 % disponibles", #selector(alertBelow10), to: alertsMenu) { [unowned self] in alertThreshold == 10 }
        addOption("Sous 20 % disponibles", #selector(alertBelow20), to: alertsMenu) { [unowned self] in alertThreshold == 20 }
        addOption("Sous 30 % disponibles", #selector(alertBelow30), to: alertsMenu) { [unowned self] in alertThreshold == 30 }
        addOption("Seuil personnalisé…", #selector(customizeAlertThreshold), to: alertsMenu) { [unowned self] in
            alertThreshold > 0 && ![10, 20, 30].contains(alertThreshold)
        }
        menu.setSubmenu(alertsMenu, for: menu.addItem(withTitle: "Alertes de quota", action: nil, keyEquivalent: ""))

        addOption("Lancer à l’ouverture de session", #selector(toggleLaunchAtLogin), to: menu) { SMAppService.mainApp.status == .enabled }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Relier Claude Code", action: #selector(enableClaude), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Actualiser maintenant", action: #selector(refresh), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Quitter AI Quota", action: #selector(quit), keyEquivalent: "q").target = self

        primaryStatusItem.menu = menu
        secondaryStatusItem.menu = menu
        primaryStatusItem.button?.imagePosition = .imageLeading
        secondaryStatusItem.button?.imagePosition = .imageLeading
        reloadClaude()
        render()
        if alertThreshold > 0 { requestAlertAuthorization() }
        Task { [weak self] in
            guard let self else { return }
            await client.setRateLimitsChangedHandler { [weak self] data in
                Task { @MainActor in
                    switch data {
                    case .success(let update): self?.applyCodexUpdate(update)
                    case .failure(let error): self?.failCodex(error)
                    }
                }
            }
            await refreshAsync()
        }
        startRefreshTimer()
        startCycleTimer()
    }

    private func addOption(_ title: String, _ selector: Selector, to menu: NSMenu, isOn: @escaping @MainActor () -> Bool) {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        checkableItems.append((item, isOn))
    }

    @objc private func refresh() {
        reloadClaude()
        render()
        Task { await refreshAsync() }
    }

    /// Opening the menu picks up a newer Claude measurement; menu-only states are updated here too.
    func menuNeedsUpdate(_ menu: NSMenu) {
        reloadClaude()
        for (item, isOn) in checkableItems { item.state = isOn() ? .on : .off }
        alertThresholdItem.title = alertThreshold > 0 ? "Seuil actuel : \(alertThreshold) % disponibles" : "Seuil actuel : désactivé"
        render()
    }

    /// The only place reading Claude's files: renders (countdown, display changes) use this cached reading.
    private func reloadClaude() {
        do {
            claude = try ClaudeBridge.read()
            claudeError = nil
        } catch {
            claude = nil
            claudeError = error.localizedDescription
        }
    }

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
        // A menu item title would be overwritten by the next render, so report the outcome in an alert.
        let alert = NSAlert()
        do {
            try ClaudeBridge.installStatusLine()
            alert.messageText = "Claude Code relié"
            alert.informativeText = "Envoie un message dans Claude Code pour recevoir les quotas."
        } catch {
            alert.alertStyle = .warning
            alert.messageText = "Impossible de relier Claude Code"
            alert.informativeText = error.localizedDescription
        }
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func refreshAsync() async {
        do { updateCodex(try await client.readRateLimits()) }
        catch { failCodex(error) }
    }

    private func failCodex(_ error: any Error) {
        codexError = error.localizedDescription
        codex = nil
        render()
    }

    private func applyCodexUpdate(_ update: RateLimitResponse) {
        let current = codexError == nil ? codex : nil
        guard let merged = CodexMeasurement.applying(
            update, to: current, at: Date().timeIntervalSince1970, refreshInterval: TimeInterval(refreshSeconds))
        else { return }
        codexError = nil
        codex = merged
        render()
    }

    private func isCodexFresh(at now: TimeInterval) -> Bool {
        codexError == nil && (codex?.isFresh(at: now, refreshInterval: TimeInterval(refreshSeconds)) ?? false)
    }

    private func updateCodex(_ data: RateLimitResponse) {
        codexError = nil
        codex = CodexMeasurement(reading: data, capturedAt: Date().timeIntervalSince1970)
        render()
    }

    private func render() {
        let codexSession = codex?.reading.rateLimits?.primary
        let codexWeek = codex?.reading.rateLimits?.secondary
        let now = Date().timeIntervalSince1970
        let label = displayMode == .available ? "disponible" : "utilisé"

        let codexFresh = isCodexFresh(at: now)
        let claudeFiveFresh = claude?.fiveHour?.isFresh(at: now) ?? false
        let claudeSevenFresh = claude?.sevenDay?.isFresh(at: now) ?? false
        let claudeFiveHasFreshReset = claude?.fiveHour?.freshReset(at: now) != nil
        let claudeSevenHasFreshReset = claude?.sevenDay?.freshReset(at: now) != nil
        let claudeMeasurement = claude?.latestMeasurement
        let claudeFresh = claudeFiveFresh || claudeSevenFresh
        codexAgeItem.title = "ChatGPT · dernière mesure : \(ageText(codex?.capturedAt, now: now))\(codexFresh ? "" : " · ancienne")"
        if let claudeMeasurement {
            claudeAgeItem.title = "Claude · \(claudeMeasurement.source.rawValue) · mesure \(claudeFresh ? "" : "ancienne · ")\(ageText(claudeMeasurement.capturedAt, now: now))"
        } else {
            claudeAgeItem.title = claudeError.map { "Claude · \($0)" } ?? "Claude · en attente d’une première mesure"
        }
        chatgptSessionResetItem.title = "ChatGPT 5 h · \(resetText(codexSession?.resetsAt, fresh: codexFresh))"
        chatgptWeeklyResetItem.title = "ChatGPT 7 j · \(resetText(codexWeek?.resetsAt, fresh: codexFresh))"
        claudeSessionResetItem.title = "Claude 5 h · \(resetText(claude?.fiveHour?.freshReset(at: now), fresh: claudeFiveHasFreshReset))"
        claudeWeeklyResetItem.title = "Claude 7 j · \(resetText(claude?.sevenDay?.freshReset(at: now), fresh: claudeSevenHasFreshReset))"
        if codexFresh {
            if let value = codexSession?.usedPercent { checkAlert(provider: .codex, window: "5h", used: value) }
            if let value = codexWeek?.usedPercent { checkAlert(provider: .codex, window: "7j", used: value) }
        }
        if claudeFiveFresh, let value = claude?.fiveHour?.usedPercent {
            checkAlert(provider: .claude, window: "5h", used: value)
        }
        if claudeSevenFresh, let value = claude?.sevenDay?.usedPercent {
            checkAlert(provider: .claude, window: "7j", used: value)
        }

        func texts(for provider: Provider) -> (String, String, [NSRange]) {
            let sessionUsed = provider == .codex ? codexSession?.usedPercent : claude?.fiveHour?.usedPercent
            let weeklyUsed = provider == .codex ? codexWeek?.usedPercent : claude?.sevenDay?.usedPercent
            let sessionValid = provider == .codex ? codexFresh : claudeFiveFresh
            let weeklyValid = provider == .codex ? codexFresh : claudeSevenFresh
            let sessionText = sessionValid ? sessionUsed.map(number) ?? "—" : "—"
            let weeklyText = weeklyValid ? weeklyUsed.map(number) ?? "—" : "—"
            let title: String
            switch windowMode {
            case .both: title = "5 h \(sessionText) · 7 j \(weeklyText)"
            case .session: title = "5 h \(sessionText)"
            case .weekly: title = "7 j \(weeklyText)"
            }
            let name = provider == .codex ? "ChatGPT" : "Claude"
            let capturedAt = provider == .codex ? codex?.capturedAt : claude?.latestMeasurement?.capturedAt
            var redRanges: [NSRange] = []
            for (prefix, text, used, visible) in [
                ("5 h ", sessionText, sessionUsed, windowMode != .weekly && sessionValid),
                ("7 j ", weeklyText, weeklyUsed, windowMode != .session && weeklyValid)
            ] where visible && (used.map { 100 - $0 < 10 } ?? false) {
                let full = title as NSString
                let range = full.range(of: prefix + text)
                if range.location != NSNotFound {
                    redRanges.append(NSRange(location: range.location + (prefix as NSString).length, length: (text as NSString).length))
                }
            }
            let sessionLabel = sessionValid ? "\(sessionText) \(label)" : "indisponible"
            let weeklyLabel = weeklyValid ? "\(weeklyText) \(label)" : "indisponible"
            return (title, "\(name) · 5 h \(sessionLabel) · 7 j \(weeklyLabel) · mesure \(ageText(capturedAt, now: now))", redRanges)
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
        func summary(_ used: Double?, fresh: Bool) -> String {
            guard fresh, let used else { return "indisponible" }
            return "\(number(used)) \(label)"
        }
        codexItem.title = "ChatGPT · 5 h \(summary(codexSession?.usedPercent, fresh: codexFresh)) · 7 j \(summary(codexWeek?.usedPercent, fresh: codexFresh))"
        if let claude {
            claudeItem.title = "Claude · 5 h \(summary(claude.fiveHour?.usedPercent, fresh: claudeFiveFresh)) · 7 j \(summary(claude.sevenDay?.usedPercent, fresh: claudeSevenFresh))"
        } else {
            claudeItem.title = claudeError.map { "Claude · \($0)" } ?? "Claude · en attente d’une première mesure"
        }
        if let codexError { codexItem.title = "ChatGPT : \(codexError)" }
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

    @objc private func quit() {
        Task { await client.shutdown(); NSApplication.shared.terminate(nil) }
    }
}

if CommandLine.arguments.contains("--diagnose-codex") {
    Task {
        do {
            let client = CodexAppServerClient()
            let reading = try await client.readRateLimits()
            await client.shutdown()
            print("Codex · 5h \(reading.rateLimits?.primary.map { String($0.usedPercent) } ?? "—")% · 7j \(reading.rateLimits?.secondary.map { String($0.usedPercent) } ?? "—")%")
            exit(EXIT_SUCCESS)
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
    RunLoop.main.run()
} else if CommandLine.arguments.contains("--claude-statusline") {
    ClaudeBridge.captureStatusLine()
} else if CommandLine.arguments.contains("--diagnose-claude") {
    do {
        guard let reading = try ClaudeBridge.read() else {
            print("Aucune mesure Claude disponible ; une première réponse éligible est nécessaire.")
            exit(EXIT_FAILURE)
        }
        let now = Date().timeIntervalSince1970
        func value(_ window: ClaudeQuotaWindow?) -> String {
            guard let window, window.isFresh(at: now), let used = window.usedPercent else { return "indisponible" }
            return "\(Int(used.rounded())) % utilisé"
        }
        let measurement = reading.latestMeasurement
        let timestamp = measurement.map { Date(timeIntervalSince1970: $0.capturedAt).formatted(date: .abbreviated, time: .shortened) } ?? "indisponible"
        print("\(measurement?.source.rawValue ?? "Claude") · 5 h \(value(reading.fiveHour)) · 7 j \(value(reading.sevenDay)) · mesure \(timestamp)")
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
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
