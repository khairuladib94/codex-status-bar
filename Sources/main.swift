import Cocoa

// Reads $CODEX_HOME/statusbar/state.json (written by Codex hooks) and renders a
// compact activity indicator in the macOS menu bar. No window, no dock icon.

final class StatusController: NSObject, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    let codexHome: String = ProcessInfo.processInfo.environment["CODEX_HOME"]
        ?? (NSHomeDirectory() as NSString).appendingPathComponent(".codex")
    lazy var statePath = (codexHome as NSString).appendingPathComponent("statusbar/state.json")
    lazy var sessionsDir = (codexHome as NSString).appendingPathComponent("statusbar/sessions.d")
    let codexAppBundleID = "com.openai.codex"

    var lastMTime: Date = .distantPast
    var pollTimer: Timer?
    var animTimer: Timer?
    var frameIdx = 0

    // Self-quit lifecycle: we're launched by the SessionStart hook; we decide when to
    // leave (see checkLifecycle). No background/login item — the check only runs while
    // we're already alive.
    let launchedAt = Date()
    var notNeededSince: Date?
    var observedCodexApp = false
    let launchGrace: TimeInterval = 5   // settle time after launch before we may quit
    let idleQuitDelay: TimeInterval = 3 // "not needed" must persist this long before quitting
    let staleActivityAge: TimeInterval = 15 * 60
    let staleWaitingAge: TimeInterval = 30 * 60
    let stalePermissionAge: TimeInterval = 10 * 60

    var current: [String: Any] = [:]
    var activeBase = ""        // label without the elapsed clock
    var startedAt: Double = 0  // unix seconds the current turn began (0 = no clock)
    var activeColor: NSColor? = nil
    var lastRenderKey = ""

    struct SessionStatus {
        let id: String
        let state: [String: Any]
        let modified: Date
    }

    let brand = NSColor(srgbRed: 0.06, green: 0.62, blue: 0.49, alpha: 1)
    let codexTemplate = StatusController.loadCodexTemplate()
    let codexActiveTemplates = StatusController.loadActiveCodexTemplates()

    var quotaLines: [String] = []
    var quotaLoading = false
    var quotaRefreshID = 0

    // Active work cycles through generated Codex marks, shrinking before each swap.
    enum TransitionSpeed: String {
        case slow, normal, fast

        var title: String {
            switch self {
            case .slow: return "Slow"
            case .normal: return "Normal"
            case .fast: return "Fast"
            }
        }

        var framesPerIcon: Int {
            switch self {
            case .slow: return 72
            case .normal: return 48
            case .fast: return 30
            }
        }
    }

    enum ColorScheme: String {
        case system, codex

        var title: String {
            switch self {
            case .system: return "System"
            case .codex: return "Codex Green"
            }
        }

        var color: NSColor? {
            switch self {
            case .system: return nil
            case .codex: return NSColor(srgbRed: 0.06, green: 0.62, blue: 0.49, alpha: 1)
            }
        }
    }

    var transitionSpeed: TransitionSpeed = .normal
    var colorScheme: ColorScheme = .system
    var showStatusText = true
    var showTimer = true
    var showPausedTimer = true
    var iconColor: NSColor? { colorScheme.color } // nil => render as an adaptive system template
    var framesPerIcon: Int { transitionSpeed.framesPerIcon }
    let iconSwapDip: CGFloat = 0.18
    var frameCount: Int { max(1, codexActiveTemplates.count * framesPerIcon) }
    let fps: Double = 24

    override init() {
        super.init()
        let d = UserDefaults.standard
        if d.object(forKey: "showStatusText") != nil { showStatusText = d.bool(forKey: "showStatusText") }
        if d.object(forKey: "showTimer") != nil { showTimer = d.bool(forKey: "showTimer") }
        if d.object(forKey: "showPausedTimer") != nil { showPausedTimer = d.bool(forKey: "showPausedTimer") }
        if let raw = d.string(forKey: "colorScheme"), let scheme = ColorScheme(rawValue: raw) {
            colorScheme = scheme
        } else if d.object(forKey: "iconSystem") != nil {
            colorScheme = d.bool(forKey: "iconSystem") ? .system : .codex
        } else if let raw = d.string(forKey: "iconStyle"), raw == "codex" {
            colorScheme = .codex
        }
        if let raw = d.string(forKey: "transitionSpeed"), let speed = TransitionSpeed(rawValue: raw) { transitionSpeed = speed }
        menu.delegate = self
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseUp])
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(codexAppTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
        render(label: "", color: iconColor, animate: false, startedAt: 0)
        let t = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
        tick()
        ensureHooksInstalled()
    }

    // Wire up the Codex hooks ourselves by running the bundled installer, so the
    // user just drags the app in and opens it — no manual Terminal step. Runs on first
    // install AND whenever the version changes, so upgrades pick up new/changed hooks and
    // retire old artifacts (e.g. the 0.0.2 background watcher). install.js is idempotent.
    func ensureHooksInstalled() {
        let d = UserDefaults.standard
        let current = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
        let installKey = "installedVersion:\(codexHome)"
        guard d.string(forKey: installKey) != current || !installedHookHelpersCurrent() else { return }
        guard let installer = Bundle.main.path(forResource: "install", ofType: "js") else { return }
        DispatchQueue.global().async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/zsh") // login shell so `node` is on PATH
            task.arguments = ["-lc", "node \"\(installer)\""]
            task.environment = ProcessInfo.processInfo.environment.merging(["CODEX_HOME": self.codexHome]) { current, _ in current }
            try? task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0 { UserDefaults.standard.set(current, forKey: installKey) }
        }
    }

    func installedHookHelpersCurrent() -> Bool {
        for name in ["update", "lifecycle"] {
            guard let bundled = Bundle.main.path(forResource: name, ofType: "js") else { return false }
            let installed = (codexHome as NSString).appendingPathComponent("statusbar/\(name).js")
            guard let bundledData = FileManager.default.contents(atPath: bundled),
                  let installedData = FileManager.default.contents(atPath: installed),
                  bundledData == installedData else {
                return false
            }
        }
        return true
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let colorItem = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        let colorMenu = NSMenu()
        for scheme in [ColorScheme.system, .codex] {
            let it = NSMenuItem(title: scheme.title, action: #selector(chooseColorScheme(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = scheme.rawValue
            it.state = colorScheme == scheme ? .on : .off
            colorMenu.addItem(it)
        }
        colorItem.submenu = colorMenu
        menu.addItem(colorItem)

        let speedItem = NSMenuItem(title: "Animation Speed", action: nil, keyEquivalent: "")
        let speedMenu = NSMenu()
        for speed in [TransitionSpeed.slow, .normal, .fast] {
            let it = NSMenuItem(title: speed.title, action: #selector(chooseTransitionSpeed(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = speed.rawValue
            it.state = transitionSpeed == speed ? .on : .off
            speedMenu.addItem(it)
        }
        speedItem.submenu = speedMenu
        menu.addItem(speedItem)

        let textItem = NSMenuItem(title: "Show Status Text", action: #selector(toggleStatusText), keyEquivalent: "")
        textItem.target = self
        textItem.state = showStatusText ? .on : .off
        menu.addItem(textItem)

        let timerItem = NSMenuItem(title: "Show Elapsed Time", action: #selector(toggleTimer), keyEquivalent: "")
        timerItem.target = self
        timerItem.state = showTimer ? .on : .off
        menu.addItem(timerItem)

        let pausedTimerItem = NSMenuItem(title: "Show Paused Elapsed Time", action: #selector(togglePausedTimer), keyEquivalent: "")
        pausedTimerItem.target = self
        pausedTimerItem.state = showPausedTimer ? .on : .off
        menu.addItem(pausedTimerItem)

        menu.addItem(.separator())
        let q = NSMenuItem(title: "Quit Codex Status Bar", action: #selector(quit), keyEquivalent: "q")
        q.target = self
        menu.addItem(q)
    }

    @objc func quit() { NSApp.terminate(nil) }

    @objc func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            statusItem.popUpMenu(menu)
            return
        }

        startQuotaRefresh()
        statusItem.popUpMenu(codexContextMenu())
    }

    @objc func openCodex() {
        let ws = NSWorkspace.shared
        if let url = ws.urlForApplication(withBundleIdentifier: codexAppBundleID) {
            ws.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    func codexContextMenu() -> NSMenu {
        let codexMenu = NSMenu()
        let openItem = NSMenuItem(title: "Open Codex", action: #selector(openCodex), keyEquivalent: "")
        openItem.target = self
        codexMenu.addItem(openItem)

        let activeId = current["sessionId"] as? String
        let threads = recentThreads()
        let activeThreads = activeThreads(from: threads, fallbackId: activeId)

        addThreadSection(title: "Active Sessions", threads: activeThreads, to: codexMenu, firstSection: false)

        let activeIds = Set(activeThreads.map(\.id))
        let recent = threads.filter { !activeIds.contains($0.id) }
        addThreadSection(title: "Recent Sessions", threads: Array(recent.prefix(8)), to: codexMenu, firstSection: codexMenu.items.isEmpty)

        if !codexMenu.items.isEmpty { codexMenu.addItem(.separator()) }

        let newThread = NSMenuItem(title: "New Thread", action: #selector(openNewCodexThread), keyEquivalent: "")
        newThread.target = self
        codexMenu.addItem(newThread)

        codexMenu.addItem(.separator())
        let quotaItem = NSMenuItem(title: quotaLoading ? "Checking Codex quota..." : "Refresh Codex quota", action: #selector(checkQuota), keyEquivalent: "")
        quotaItem.target = self
        codexMenu.addItem(quotaItem)
        for line in quotaLines {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            codexMenu.addItem(item)
        }
        return codexMenu
    }

    func addThreadSection(title: String, threads: [RecentThread], to menu: NSMenu, firstSection: Bool) {
        guard !threads.isEmpty else { return }
        if !firstSection { menu.addItem(.separator()) }

        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let visible = Array(threads.prefix(5))
        let overflow = Array(threads.dropFirst(5))
        for thread in visible {
            menu.addItem(threadMenuItem(thread))
        }

        if !overflow.isEmpty {
            let more = NSMenuItem(title: "More...", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for thread in overflow {
                submenu.addItem(threadMenuItem(thread))
            }
            more.submenu = submenu
            menu.addItem(more)
        }
    }

    func threadMenuItem(_ thread: RecentThread) -> NSMenuItem {
        let item = NSMenuItem(title: truncated(thread.title, max: 48), action: #selector(openCodexThread(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = thread.id
        return item
    }

    struct RecentThread {
        let id: String
        let title: String
        let updatedAt: String
    }

    func recentThreads() -> [RecentThread] {
        let path = (codexHome as NSString).appendingPathComponent("session_index.jsonl")
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }

        var seen = Set<String>()
        var threads: [RecentThread] = []
        for line in raw.split(separator: "\n").reversed() {
            guard let data = String(line).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = obj["id"] as? String,
                  !seen.contains(id) else { continue }
            seen.insert(id)
            let title = (obj["thread_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled Thread"
            let updatedAt = obj["updated_at"] as? String ?? ""
            threads.append(RecentThread(id: id, title: title, updatedAt: updatedAt))
            if threads.count >= 30 { break }
        }
        return threads
    }

    func activeThreads(from recent: [RecentThread], fallbackId: String?) -> [RecentThread] {
        let byId = Dictionary(uniqueKeysWithValues: recent.map { ($0.id, $0) })
        var seen = Set<String>()
        var active: [RecentThread] = []

        for id in activeSessionIds() where !seen.contains(id) {
            seen.insert(id)
            if let thread = byId[id] {
                active.append(thread)
            } else {
                let title = id == fallbackId
                    ? ((current["project"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Current Thread")
                    : "Current Thread"
                active.append(RecentThread(id: id, title: title, updatedAt: ""))
            }
        }

        if let fallbackId, !seen.contains(fallbackId), isCurrentStateActive() {
            let title = byId[fallbackId]?.title
                ?? (current["project"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? "Current Thread"
            active.append(RecentThread(id: fallbackId, title: title, updatedAt: ""))
        }

        return active
    }

    func activeSessionIds(recentWithin seconds: TimeInterval = 30 * 60) -> [String] {
        activeSessionStatuses(recentWithin: seconds)
            .filter { effectiveState(from: $0.state) != nil }
            .sorted { $0.modified > $1.modified }
            .map(\.id)
    }

    func isCurrentStateActive() -> Bool {
        switch current["state"] as? String {
        case "thinking", "tool", "permission", "waiting":
            return true
        default:
            return false
        }
    }

    func truncated(_ text: String, max: Int) -> String {
        let chars = Array(text)
        guard chars.count > max else { return text }
        return String(chars.prefix(max - 1)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    @objc func openNewCodexThread() {
        openCodexURL("codex://threads/new")
    }

    @objc func openCodexThread(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else {
            openCodex()
            return
        }
        openCodexURL("codex://threads/\(id)")
    }

    func openCodexURL(_ raw: String) {
        if let url = URL(string: raw) {
            NSWorkspace.shared.open(url)
        } else {
            openCodex()
        }
    }

    @objc func quitCodex() {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == codexAppBundleID }
        for app in apps {
            app.terminate()
        }
    }

    @objc func checkQuota() {
        startQuotaRefresh()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.statusItem.popUpMenu(self.codexContextMenu())
        }
    }

    @discardableResult
    func startQuotaRefresh() -> Bool {
        guard !quotaLoading else { return false }
        quotaLoading = true
        quotaRefreshID += 1
        let refreshID = quotaRefreshID

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let lines = self.loadQuotaLines()
            DispatchQueue.main.async { [weak self] in
                guard let self, refreshID == self.quotaRefreshID else { return }
                self.quotaLines = lines
                self.quotaLoading = false
            }
        }
        return true
    }

    func loadQuotaLines() -> [String] {
        guard let helper = Bundle.main.path(forResource: "quota", ofType: "js") else {
            return ["Quota helper is missing"]
        }

        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-lc", "node \"\(helper)\""]
        task.environment = ProcessInfo.processInfo.environment.merging(["CODEX_HOME": codexHome]) { current, _ in current }
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let raw = String(data: data, encoding: .utf8),
                  let jsonData = raw.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
                  let obj = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                return ["Quota unavailable", "Open Codex and run /status"]
            }
            return formatQuota(obj)
        } catch {
            return ["Quota unavailable", "Open Codex and run /status"]
        }
    }

    func formatQuota(_ obj: [String: Any]) -> [String] {
        if let message = obj["message"] as? String {
            var lines = [message]
            if let details = obj["details"] as? String, !details.isEmpty {
                lines.append(details)
            }
            return lines
        }

        var lines: [String] = []
        let source = obj["source"] as? String ?? "unknown"
        let email = obj["accountEmail"] as? String
        let plan = obj["planType"] as? String
        let name = obj["limitName"] as? String ?? obj["limitId"] as? String
        let heading = [name, plan].compactMap { $0 }.joined(separator: " / ")
        if let email, !email.isEmpty {
            lines.append(email)
        } else {
            lines.append(heading.isEmpty ? "Quota (\(source))" : "\(heading) (\(source))")
        }

        if let primary = obj["primary"] as? [String: Any] {
            lines.append(formatWindow(primary, fallback: "Primary"))
        }
        if let secondary = obj["secondary"] as? [String: Any] {
            lines.append(formatWindow(secondary, fallback: "Secondary"))
        }
        if let limit = obj["individualLimit"] as? [String: Any],
           let remaining = limit["remainingPercent"] as? NSNumber,
           let used = limit["used"] as? String,
           let cap = limit["limit"] as? String {
            lines.append("Spend: \(remaining.intValue)% left (\(used)/\(cap))")
        }
        if lines.count == 1 {
            lines.append("No live bucket details")
        }
        return lines
    }

    func formatWindow(_ win: [String: Any], fallback: String) -> String {
        let mins = (win["windowDurationMins"] as? NSNumber)?.intValue ?? 0
        let name: String
        if mins >= 10080 { name = "7d" }
        else if mins >= 300 { name = "5h" }
        else { name = fallback }

        let used = (win["usedPercent"] as? NSNumber)?.intValue ?? 0
        let remaining = (win["remainingPercent"] as? NSNumber)?.intValue ?? max(0, 100 - used)
        var text = "\(name): \(remaining)% left (\(used)% used)"
        if let reset = resetText(win["resetsAt"]) {
            text += ", resets \(reset)"
        }
        return text
    }

    func resetText(_ value: Any?) -> String? {
        guard let number = value as? NSNumber else { return nil }
        let raw = number.doubleValue
        let seconds = raw > 10_000_000_000 ? raw / 1000.0 : raw
        let date = Date(timeIntervalSince1970: seconds)
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    @objc func toggleTimer() {
        showTimer.toggle()
        UserDefaults.standard.set(showTimer, forKey: "showTimer")
        applyTitle()
    }

    @objc func togglePausedTimer() {
        showPausedTimer.toggle()
        UserDefaults.standard.set(showPausedTimer, forKey: "showPausedTimer")
        evaluate()
    }

    @objc func toggleStatusText() {
        showStatusText.toggle()
        UserDefaults.standard.set(showStatusText, forKey: "showStatusText")
        applyTitle()
    }

    @objc func chooseColorScheme(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let scheme = ColorScheme(rawValue: raw) else { return }
        colorScheme = scheme
        UserDefaults.standard.set(scheme.rawValue, forKey: "colorScheme")
        frameIdx = 0
        evaluate()
    }

    @objc func chooseTransitionSpeed(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let speed = TransitionSpeed(rawValue: raw) else { return }
        transitionSpeed = speed
        UserDefaults.standard.set(speed.rawValue, forKey: "transitionSpeed")
        frameIdx = 0
        evaluate()
    }

    // MARK: state polling

    func tick() {
        checkLifecycle()
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: statePath),
              let m = attrs[.modificationDate] as? Date else {
            evaluate(); return
        }
        if m != lastMTime {
            lastMTime = m
            if let data = fm.contents(atPath: statePath),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                current = obj
            }
        }
        evaluate()
    }

    func evaluate() {
        let threads = recentThreads()
        let selected = visibleActiveSessionState() ?? effectiveState(from: current).map {
            ($0.state, $0.label, $0.startedAt, current["project"] as? String ?? "", current["sessionId"] as? String ?? "")
        }
        guard let selected else {
            render(label: "", color: iconColor, animate: false, startedAt: 0, tooltip: nil)
            return
        }

        let eff = selected.state
        let label = displayLabel(statusLabel: selected.label)
        let started = selected.startedAt
        let tooltip = tooltipText(
            threadTitle: threadTitle(for: selected.sessionId, from: threads),
            project: selected.project
        )

        switch eff {
        case "thinking":  render(label: label.isEmpty ? "Thinking..." : label, color: iconColor, animate: true,  startedAt: started, tooltip: tooltip)
        case "tool":      render(label: label.isEmpty ? "Working..."  : label, color: iconColor, animate: true,  startedAt: started, tooltip: tooltip)
        case "permission":render(label: label.isEmpty ? "Awaiting permission" : label, color: .systemYellow, animate: false, startedAt: showPausedTimer ? started : 0, dot: true, tooltip: tooltip)
        case "waiting":   render(label: label.isEmpty ? "Needs input" : label, color: .systemBlue, animate: false, startedAt: showPausedTimer ? started : 0, dot: true, tooltip: tooltip)
        default:          render(label: "", color: iconColor, animate: false, startedAt: 0, tooltip: nil)
        }
    }

    func visibleActiveSessionState() -> (state: String, label: String, startedAt: Double, project: String, sessionId: String)? {
        activeSessionStatuses()
            .compactMap { status -> (state: String, label: String, startedAt: Double, project: String, sessionId: String, sortTime: Double)? in
                guard let eff = effectiveState(from: status.state) else { return nil }
                let started = eff.startedAt
                let ts = (status.state["ts"] as? NSNumber)?.doubleValue ?? 0
                let sortTime = started > 0 ? started : (ts > 0 ? ts : status.modified.timeIntervalSince1970)
                let project = status.state["project"] as? String ?? ""
                let sessionId = status.state["sessionId"] as? String ?? status.id
                return (eff.state, eff.label, started, project, sessionId, sortTime)
            }
            .sorted { $0.sortTime > $1.sortTime }
            .first
            .map { ($0.state, $0.label, $0.startedAt, $0.project, $0.sessionId) }
    }

    func displayLabel(statusLabel: String) -> String {
        statusLabel.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func threadTitle(for sessionId: String, from threads: [RecentThread]) -> String? {
        guard !sessionId.isEmpty else { return nil }
        return threads.first { $0.id == sessionId }?.title
    }

    func tooltipText(threadTitle: String?, project: String) -> String? {
        let title = (threadTitle ?? "Current Thread").trimmingCharacters(in: .whitespacesAndNewlines)
        let projectName = project.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return projectName.isEmpty ? nil : projectName }
        if projectName.isEmpty {
            return title
        }
        return "\(title)\n\(projectName)"
    }

    func effectiveState(from stateObject: [String: Any], expireStaleActivity: Bool = true) -> (state: String, label: String, startedAt: Double)? {
        let state = stateObject["state"] as? String ?? "idle"
        var label = stateObject["label"] as? String ?? ""
        let ts = (stateObject["ts"] as? NSNumber)?.doubleValue ?? 0
        let started = (stateObject["startedAt"] as? NSNumber)?.doubleValue ?? 0
        let age = Date().timeIntervalSince1970 - ts

        var eff = state
        // The Stop hook fires on normal completion, but NOT when you interrupt (Esc/Stop).
        // In that case Codex may append an interrupted line to the
        // transcript and the turn ends — detect that so we don't stay stuck on "thinking".
        if state == "thinking" || state == "tool" {
            if expireStaleActivity && age > staleActivityAge { eff = "idle"; label = "" } // absolute safety net
            else if let tr = stateObject["transcript"] as? String,
                    let last = lastLine(ofFileAt: tr),
                    last.contains("interrupted by user") {
                eff = "idle"; label = ""
            }
        }

        if state == "permission", age > stalePermissionAge {
            eff = "idle"; label = ""
        }

        if state == "waiting", age > staleWaitingAge {
            eff = "idle"; label = ""
        }

        if (state == "permission" || state == "waiting"), eff == state {
            if started == 0, let previousStarted = stateObject["previousStartedAt"] as? NSNumber {
                return (eff, label, previousStarted.doubleValue)
            }
        }

        switch eff {
        case "thinking", "tool", "permission", "waiting":
            return (eff, label, started)
        default:
            return nil
        }
    }

    func activeSessionStatuses(recentWithin seconds: TimeInterval = 30 * 60) -> [SessionStatus] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: sessionsDir) else { return [] }
        let keepWhileRunning = codexAppRunning()
        let staleCutoff = Date().addingTimeInterval(-30 * 60)
        let recentCutoff = Date().addingTimeInterval(-seconds)

        return files.compactMap { file -> SessionStatus? in
            let path = (sessionsDir as NSString).appendingPathComponent(file)
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let modified = attrs[.modificationDate] as? Date else { return nil }
            if !keepWhileRunning && modified < staleCutoff {
                try? fm.removeItem(atPath: path)
                return nil
            }
            guard (keepWhileRunning || modified >= recentCutoff),
                  let data = fm.contents(atPath: path),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return SessionStatus(id: file, state: obj, modified: modified)
        }
    }

    // MARK: self-quit lifecycle

    // True while the Codex app is running. Cheap and needs no permission.
    func codexAppRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == codexAppBundleID }
    }

    @objc func codexAppTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == codexAppBundleID else { return }
        clearActiveSessions()
        NSApp.terminate(nil)
    }

    func clearActiveSessions() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: sessionsDir) else { return }
        for file in files {
            try? fm.removeItem(atPath: (sessionsDir as NSString).appendingPathComponent(file))
        }
    }

    // Active Codex sessions = files in sessions.d/. While Codex is running, keep
    // existing session records alive; once it is not running, only very recent hook
    // activity may keep the icon alive.
    func sessionCount(recentWithin seconds: TimeInterval = 30 * 60) -> Int {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: sessionsDir) else { return 0 }
        let keepWhileRunning = codexAppRunning()
        let staleCutoff = Date().addingTimeInterval(-30 * 60)
        let recentCutoff = Date().addingTimeInterval(-seconds)
        var count = 0
        for file in files {
            let path = (sessionsDir as NSString).appendingPathComponent(file)
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let modified = attrs[.modificationDate] as? Date else { continue }
            if !keepWhileRunning && modified < staleCutoff {
                try? fm.removeItem(atPath: path)
            } else if keepWhileRunning || modified >= recentCutoff {
                count += 1
            }
        }
        return count
    }

    // Stay while Codex is open OR a recent session is active; otherwise quit after a
    // short debounce.
    func checkLifecycle() {
        let now = Date()
        if now.timeIntervalSince(launchedAt) < launchGrace { return }
        if codexAppRunning() {
            observedCodexApp = true
            _ = sessionCount()
            notNeededSince = nil
            return
        }
        if observedCodexApp {
            clearActiveSessions()
        } else if sessionCount(recentWithin: 45) > 0 {
            notNeededSince = nil
            return
        }
        if let since = notNeededSince {
            if now.timeIntervalSince(since) >= idleQuitDelay { NSApp.terminate(nil) }
        } else {
            notNeededSince = now
        }
    }

    // Read the last non-empty line of a (possibly large) file by tailing ~8KB.
    func lastLine(ofFileAt path: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let chunk: UInt64 = 8192
        try? fh.seek(toOffset: size > chunk ? size - chunk : 0)
        guard let data = try? fh.readToEnd(), let s = String(data: data, encoding: .utf8) else { return nil }
        return s.split(separator: "\n").last { !$0.isEmpty }.map(String.init)
    }

    // MARK: render

    func render(label: String, color: NSColor?, animate: Bool, startedAt: Double, dot: Bool = false, tooltip: String? = nil) {
        guard let button = statusItem.button else { return }
        button.contentTintColor = nil // we paint the icon color ourselves; template-tint is unreliable
        let renderKey = [
            label,
            tooltip ?? "",
            color?.hexKey ?? "system",
            animate ? "animate" : "still",
            dot ? "dot" : "mark",
            String(Int(startedAt))
        ].joined(separator: "|")

        if renderKey == lastRenderKey {
            button.toolTip = tooltip
            applyTitle()
            return
        }

        lastRenderKey = renderKey
        activeBase = label
        activeColor = color
        self.startedAt = startedAt
        button.toolTip = tooltip

        if animate {
            if animTimer == nil {
                let t = Timer(timeInterval: 1.0 / fps, repeats: true) { [weak self] _ in self?.animStep() }
                RunLoop.main.add(t, forMode: .common)
                animTimer = t
            }
        } else {
            animTimer?.invalidate(); animTimer = nil
            frameIdx = 0
            button.image = dot ? dotIcon(color: color, pulse: startedAt > 0) : restingIcon(color: color)
        }
        applyTitle()
        if button.image == nil { button.image = dot ? dotIcon(color: color, pulse: startedAt > 0) : restingIcon(color: color) }
    }

    // Active work breathes each mark, dips small, then swaps to the next mark.
    func animStep() {
        frameIdx = (frameIdx + 1) % frameCount
        statusItem.button?.image = iconImage(color: activeColor, frame: frameIdx)
        applyTitle() // refresh the elapsed clock
    }

    func applyTitle() {
        guard let button = statusItem.button else { return }
        guard showStatusText, !activeBase.isEmpty else {
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString(string: "")
            return
        }

        var title = " \(activeBase)"
        if showTimer, startedAt > 0 {
            title += " \(elapsedText(since: startedAt))"
        }
        button.imagePosition = .imageLeft
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
                .kern: -0.1,
                .foregroundColor: NSColor.labelColor
            ]
        )
    }

    func elapsedText(since unixSeconds: Double) -> String {
        let elapsed = max(0, Int(Date().timeIntervalSince1970 - unixSeconds))
        let hours = elapsed / 3600
        let minutes = (elapsed % 3600) / 60
        let seconds = elapsed % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    // MARK: icon

    static func loadCodexTemplate() -> NSImage {
        loadTemplate(named: "codexTemplate") ?? NSImage(size: NSSize(width: 18, height: 18))
    }

    static func loadActiveCodexTemplates() -> [NSImage] {
        let names = (1...6).map { String(format: "codexImagegen%02d", $0) }
        let images = names.compactMap(loadTemplate(named:))
        return images.isEmpty ? [loadCodexTemplate()] : images
    }

    static func loadTemplate(named name: String) -> NSImage? {
        let bundle = Bundle.main
        let path = bundle.path(forResource: "\(name)@2x", ofType: "png")
            ?? bundle.path(forResource: name, ofType: "png")
        if let path, let image = NSImage(contentsOfFile: path) {
            let cleaned = removingFaintAlpha(from: image)
            cleaned.isTemplate = false
            return cleaned
        }
        return nil
    }

    static func removingFaintAlpha(from image: NSImage, threshold: UInt8 = 18) -> NSImage {
        var proposed = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else {
            return image
        }

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            return image
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        for offset in stride(from: 0, to: pixels.count, by: bytesPerPixel) where pixels[offset + 3] <= threshold {
            pixels[offset] = 0
            pixels[offset + 1] = 0
            pixels[offset + 2] = 0
            pixels[offset + 3] = 0
        }

        guard let cleaned = context.makeImage() else { return image }
        return NSImage(cgImage: cleaned, size: image.size)
    }

    func iconImage(color: NSColor?, frame: Int) -> NSImage {
        let local = (CGFloat(frame % framesPerIcon) + 0.5) / CGFloat(framesPerIcon)
        let progress = CGFloat(frame % frameCount) / CGFloat(frameCount)
        let env = morphEnvelope(local)
        let scale = iconSwapDip + (1.06 - iconSwapDip) * env
        let rotation = 7 * sin(local * CGFloat.pi * 2) * env
        return codexIcon(
            template: iconTemplate(for: frame),
            color: color,
            scale: scale,
            rotationDegrees: rotation,
            dotsPhase: progress,
            dotsOpacity: 0.35 + 0.65 * env
        )
    }

    func morphEnvelope(_ local: CGFloat) -> CGFloat {
        if local < 0.28 {
            return smoothstep(local / 0.28)
        }
        if local > 0.72 {
            return smoothstep((1 - local) / 0.28)
        }
        return 1
    }

    func smoothstep(_ value: CGFloat) -> CGFloat {
        let u = max(0, min(1, value))
        return u * u * (3 - 2 * u)
    }

    func iconTemplate(for frame: Int) -> NSImage {
        guard !codexActiveTemplates.isEmpty else { return codexTemplate }
        return codexActiveTemplates[(frame / framesPerIcon) % codexActiveTemplates.count]
    }

    // Draw the Codex template mark about center. A nil color produces an adaptive
    // template image for the menu bar.
    func codexIcon(
        template: NSImage? = nil,
        color: NSColor?,
        scale: CGFloat,
        rotationDegrees: CGFloat,
        dotsPhase: CGFloat? = nil,
        dotsOpacity: CGFloat = 1
    ) -> NSImage {
        let s: CGFloat = 18
        let mark = template ?? codexTemplate
        let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
            let draw = {
                let dw = s * scale
                let r = NSRect(x: (s - dw) / 2, y: (s - dw) / 2, width: dw, height: dw)
                mark.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1.0)
            }
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by: s / 2, yBy: s / 2)
            transform.rotate(byDegrees: rotationDegrees)
            transform.translateX(by: -s / 2, yBy: -s / 2)
            transform.concat()
            if let c = color {
                let dw = s * scale
                let r = NSRect(x: (s - dw) / 2, y: (s - dw) / 2, width: dw, height: dw)
                let canvas = NSRect(x: 0, y: 0, width: s, height: s)
                mark.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1.0)
                c.setFill()
                canvas.fill(using: .sourceIn)
            } else {
                draw()
            }
            NSGraphicsContext.restoreGraphicsState()
            if let dotsPhase {
                self.drawOrbitDots(color: color, phase: dotsPhase, opacity: dotsOpacity, size: s)
            }
            return true
        }
        img.isTemplate = (color == nil)
        return img
    }

    func restingIcon(color: NSColor?) -> NSImage { codexIcon(color: color, scale: 1.0, rotationDegrees: 0) }

    func drawOrbitDots(color: NSColor?, phase: CGFloat, opacity: CGFloat, size: CGFloat) {
        let center = NSPoint(x: size / 2, y: size / 2)
        let base = color ?? .black
        let radius: CGFloat = 7.1
        let count = 4
        for i in 0..<count {
            let offset = CGFloat(i) / CGFloat(count)
            let angle = (phase + offset) * CGFloat.pi * 2
            let shimmer = 0.5 + 0.5 * sin((phase * 2 + offset) * CGFloat.pi * 2)
            let diameter = 0.9 + 0.9 * shimmer
            let alpha = max(0, min(1, opacity * (0.35 + 0.65 * shimmer)))
            base.withAlphaComponent(alpha).setFill()
            let x = center.x + cos(angle) * radius - diameter / 2
            let y = center.y + sin(angle) * radius - diameter / 2
            NSBezierPath(ovalIn: NSRect(x: x, y: y, width: diameter, height: diameter)).fill()
        }
    }

    // A small filled dot — used for the paused "awaiting permission" state.
    func dotIcon(color: NSColor?, pulse: Bool = false) -> NSImage {
        let s: CGFloat = 18, d: CGFloat = 9
        let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
            if pulse {
                (color ?? .systemYellow).withAlphaComponent(0.18).setFill()
                NSBezierPath(ovalIn: NSRect(x: 2.5, y: 2.5, width: 13, height: 13)).fill()
            }
            (color ?? .systemYellow).setFill()
            NSBezierPath(ovalIn: NSRect(x: (s - d) / 2, y: (s - d) / 2, width: d, height: d)).fill()
            return true
        }
        img.isTemplate = (color == nil)
        return img
    }

    // Paint `color` through a frame mask's alpha, so the same frames recolor (clay/red).
    func tint(_ set: [NSImage], color: NSColor?, frame: Int) -> NSImage {
        let s: CGFloat = 18
        guard !set.isEmpty else { return NSImage(size: NSSize(width: s, height: s)) }
        let mask = set[frame % set.count]
        let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { rect in
            if let c = color {
                c.setFill()
                rect.fill()
                mask.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1.0)
            } else {
                mask.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            }
            return true
        }
        img.isTemplate = (color == nil) // nil => adaptive black/white in the menu bar
        return img
    }
}

private extension NSColor {
    var hexKey: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(
            format: "%.3f,%.3f,%.3f,%.3f",
            c.redComponent,
            c.greenComponent,
            c.blueComponent,
            c.alphaComponent
        )
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = StatusController()
app.run()
