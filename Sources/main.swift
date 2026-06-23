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
    let launchGrace: TimeInterval = 5   // settle time after launch before we may quit
    let idleQuitDelay: TimeInterval = 3 // "not needed" must persist this long before quitting

    var current: [String: Any] = [:]
    var activeBase = ""        // label without the elapsed clock
    var startedAt: Double = 0  // unix seconds the current turn began (0 = no clock)
    var activeColor: NSColor? = nil

    let brand = NSColor(srgbRed: 0.06, green: 0.62, blue: 0.49, alpha: 1)
    let amber = NSColor(srgbRed: 0.95, green: 0.73, blue: 0.18, alpha: 1) // "awaiting permission" yellow dot
    let codexTemplate: NSImage = StatusController.loadCodexTemplate()

    var quotaLines: [String] = []
    var quotaLoading = false

    // Animation styles are kept as a persisted preference, but both render the
    // Codex template mark so the menu bar never falls back to the old upstream art.
    enum AnimStyle: String { case web, code }
    var animStyle: AnimStyle = .code
    var showStatusText = true
    var showTimer = true
    var iconSystem = true // false = brand green; true = adaptive black/white (template image)
    var iconColor: NSColor? { iconSystem ? nil : brand } // nil => render as an adaptive template
    let frameCount = 40
    var fps: Double { 14 }

    override init() {
        super.init()
        let d = UserDefaults.standard
        if d.object(forKey: "showStatusText") != nil { showStatusText = d.bool(forKey: "showStatusText") }
        if d.object(forKey: "showTimer") != nil { showTimer = d.bool(forKey: "showTimer") }
        if d.object(forKey: "iconSystem") != nil { iconSystem = d.bool(forKey: "iconSystem") }
        if let s = d.string(forKey: "animStyle"), let st = AnimStyle(rawValue: s) { animStyle = st }
        menu.delegate = self
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
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
        guard d.string(forKey: installKey) != current,
              let installer = Bundle.main.path(forResource: "install", ofType: "js") else { return }
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

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let openItem = NSMenuItem(title: "Open Codex", action: #selector(openCodex), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let quotaItem = NSMenuItem(title: quotaLoading ? "Checking Codex quota..." : "Refresh Codex quota", action: #selector(checkQuota), keyEquivalent: "")
        quotaItem.target = self
        menu.addItem(quotaItem)
        for line in quotaLines {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())

        for (style, name) in [(AnimStyle.web, "Codex Morph"), (AnimStyle.code, "Codex Spin")] {
            let it = NSMenuItem(title: name, action: #selector(chooseStyle(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = style.rawValue
            it.state = animStyle == style ? .on : .off
            menu.addItem(it)
        }

        menu.addItem(.separator())
        for (sys, name) in [(false, "Codex Green"), (true, "System")] {
            let it = NSMenuItem(title: name, action: #selector(chooseColor(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = sys
            it.state = iconSystem == sys ? .on : .off
            menu.addItem(it)
        }

        menu.addItem(.separator())
        let textItem = NSMenuItem(title: "Show Status Text", action: #selector(toggleStatusText), keyEquivalent: "")
        textItem.target = self
        textItem.state = showStatusText ? .on : .off
        menu.addItem(textItem)

        let timerItem = NSMenuItem(title: "Show Elapsed Time", action: #selector(toggleTimer), keyEquivalent: "")
        timerItem.target = self
        timerItem.state = showTimer ? .on : .off
        menu.addItem(timerItem)

        menu.addItem(.separator())
        let q = NSMenuItem(title: "Quit Codex Status Bar", action: #selector(quit), keyEquivalent: "q")
        q.target = self
        menu.addItem(q)
    }

    @objc func quit() { NSApp.terminate(nil) }

    @objc func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            statusItem.popUpMenu(codexContextMenu())
            return
        }

        refreshQuotaNow()
        statusItem.popUpMenu(menu)
    }

    @objc func openCodex() {
        let ws = NSWorkspace.shared
        if let url = ws.urlForApplication(withBundleIdentifier: codexAppBundleID) {
            ws.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    func codexContextMenu() -> NSMenu {
        let codexMenu = NSMenu()
        let activeId = current["sessionId"] as? String
        let threads = recentThreads()
        let activeThreads = activeThreads(from: threads, fallbackId: activeId)

        addThreadSection(title: "Active", threads: activeThreads, to: codexMenu, firstSection: true)

        let activeIds = Set(activeThreads.map(\.id))
        let recent = threads.filter { !activeIds.contains($0.id) }
        addThreadSection(title: "Recent", threads: Array(recent.prefix(8)), to: codexMenu, firstSection: codexMenu.items.isEmpty)

        if !codexMenu.items.isEmpty { codexMenu.addItem(.separator()) }

        let newThread = NSMenuItem(title: "New Thread", action: #selector(openNewCodexThread), keyEquivalent: "")
        newThread.target = self
        codexMenu.addItem(newThread)

        codexMenu.addItem(.separator())
        let openItem = NSMenuItem(title: "Open Codex", action: #selector(openCodex), keyEquivalent: "")
        openItem.target = self
        codexMenu.addItem(openItem)

        codexMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Codex", action: #selector(quitCodex), keyEquivalent: "")
        quitItem.target = self
        codexMenu.addItem(quitItem)
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
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: sessionsDir) else { return [] }
        let staleCutoff = Date().addingTimeInterval(-30 * 60)
        let recentCutoff = Date().addingTimeInterval(-seconds)

        return files.compactMap { file -> (String, Date)? in
            let path = (sessionsDir as NSString).appendingPathComponent(file)
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let modified = attrs[.modificationDate] as? Date else { return nil }
            if modified < staleCutoff {
                try? fm.removeItem(atPath: path)
                return nil
            }
            guard modified >= recentCutoff else { return nil }
            return (file, modified)
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
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
        guard !quotaLoading else { return }
        refreshQuotaNow()
        menu.cancelTracking()
        statusItem.popUpMenu(menu)
    }

    func refreshQuotaNow() {
        guard !quotaLoading else { return }
        quotaLoading = true
        quotaLines = loadQuotaLines()
        quotaLoading = false
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

    @objc func toggleStatusText() {
        showStatusText.toggle()
        UserDefaults.standard.set(showStatusText, forKey: "showStatusText")
        applyTitle()
    }

    @objc func chooseColor(_ sender: NSMenuItem) {
        guard let sys = sender.representedObject as? Bool else { return }
        iconSystem = sys
        UserDefaults.standard.set(iconSystem, forKey: "iconSystem")
        evaluate() // re-render the current state in the new color
    }

    @objc func chooseStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let st = AnimStyle(rawValue: raw) else { return }
        animStyle = st
        UserDefaults.standard.set(raw, forKey: "animStyle")
        animTimer?.invalidate(); animTimer = nil // recreate at the new style's fps
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
        let state = current["state"] as? String ?? "idle"
        var label = current["label"] as? String ?? ""
        let ts = (current["ts"] as? NSNumber)?.doubleValue ?? 0
        let started = (current["startedAt"] as? NSNumber)?.doubleValue ?? 0
        let age = Date().timeIntervalSince1970 - ts

        var eff = state
        // The Stop hook fires on normal completion, but NOT when you interrupt (Esc/Stop).
        // In that case Codex may append an interrupted line to the
        // transcript and the turn ends — detect that so we don't stay stuck on "thinking".
        if state == "thinking" || state == "tool" {
            if age > 900 { eff = "idle"; label = "" } // absolute safety net
            else if let tr = current["transcript"] as? String,
                    let last = lastLine(ofFileAt: tr),
                    last.contains("interrupted by user") {
                eff = "idle"; label = ""
            }
        }

        switch eff {
        case "thinking":  render(label: label.isEmpty ? "Thinking..." : label, color: iconColor, animate: true,  startedAt: started)
        case "tool":      render(label: label.isEmpty ? "Working..."  : label, color: iconColor, animate: true,  startedAt: started)
        case "permission":render(label: "Awaiting permission", color: amber, animate: false, startedAt: 0, dot: true)
        case "waiting":   render(label: label.isEmpty ? "Waiting" : label, color: iconColor, animate: false, startedAt: 0)
        default:          render(label: "", color: iconColor, animate: false, startedAt: 0)
        }
    }

    // MARK: self-quit lifecycle

    // True while the Codex app is running. Cheap and needs no permission.
    func codexAppRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == codexAppBundleID }
    }

    // Active Codex sessions = recently touched files in sessions.d/. When Codex is
    // not running, only very recent hook activity is allowed to keep the icon alive.
    func sessionCount(recentWithin seconds: TimeInterval = 30 * 60) -> Int {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: sessionsDir) else { return 0 }
        let staleCutoff = Date().addingTimeInterval(-30 * 60)
        let recentCutoff = Date().addingTimeInterval(-seconds)
        var count = 0
        for file in files {
            let path = (sessionsDir as NSString).appendingPathComponent(file)
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let modified = attrs[.modificationDate] as? Date else { continue }
            if modified < staleCutoff {
                try? fm.removeItem(atPath: path)
            } else if modified >= recentCutoff {
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
            _ = sessionCount()
            notNeededSince = nil
            return
        }
        if sessionCount(recentWithin: 45) > 0 {
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

    func render(label: String, color: NSColor?, animate: Bool, startedAt: Double, dot: Bool = false) {
        guard let button = statusItem.button else { return }
        button.contentTintColor = nil // we paint the icon color ourselves; template-tint is unreliable
        activeBase = label
        activeColor = color
        self.startedAt = startedAt

        if animate {
            if animTimer == nil {
                let t = Timer(timeInterval: 1.0 / fps, repeats: true) { [weak self] _ in self?.animStep() }
                RunLoop.main.add(t, forMode: .common)
                animTimer = t
            }
        } else {
            animTimer?.invalidate(); animTimer = nil
            frameIdx = 0
            button.image = dot ? dotIcon(color: color) : restingIcon(color: color)
        }
        applyTitle()
        if button.image == nil { button.image = dot ? dotIcon(color: color) : restingIcon(color: color) }
    }

    // Reproduce the in-chat thinking spark: step through the active style's frames.
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
        let bundle = Bundle.main
        let path = bundle.path(forResource: "codexTemplate@2x", ofType: "png")
            ?? bundle.path(forResource: "codexTemplate", ofType: "png")
        if let path, let image = NSImage(contentsOfFile: path) {
            image.isTemplate = true
            return image
        }
        return NSImage(size: NSSize(width: 18, height: 18))
    }

    func iconImage(color: NSColor?, frame: Int) -> NSImage {
        let progress = CGFloat(frame % frameCount) / CGFloat(frameCount)
        if animStyle == .web {
            let wave = 0.5 + 0.5 * sin(progress * CGFloat.pi * 2)
            let scale = 0.70 + 0.42 * wave
            let rotation = 18 * sin(progress * CGFloat.pi * 2)
            return codexIcon(color: color, scale: scale, rotationDegrees: rotation)
        }
        let pulse = 0.92 + 0.12 * (0.5 + 0.5 * sin(progress * CGFloat.pi * 4))
        return codexIcon(color: color, scale: pulse, rotationDegrees: progress * 360)
    }

    // Draw the Codex template mark scaled and rotated about center. A nil color
    // produces an adaptive template image for the menu bar.
    func codexIcon(color: NSColor?, scale: CGFloat, rotationDegrees: CGFloat) -> NSImage {
        let s: CGFloat = 18
        let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
            let draw = {
                let dw = s * scale
                let r = NSRect(x: (s - dw) / 2, y: (s - dw) / 2, width: dw, height: dw)
                self.codexTemplate.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1.0)
            }
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by: s / 2, yBy: s / 2)
            transform.rotate(byDegrees: rotationDegrees)
            transform.translateX(by: -s / 2, yBy: -s / 2)
            transform.concat()
            if let c = color {
                let rect = NSRect(x: 0, y: 0, width: s, height: s)
                c.setFill()
                rect.fill()
                self.codexTemplate.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1.0)
            } else {
                draw()
            }
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        img.isTemplate = (color == nil)
        return img
    }

    func restingIcon(color: NSColor?) -> NSImage { codexIcon(color: color, scale: 1.0, rotationDegrees: 0) }

    // A small filled dot — used for the paused "awaiting permission" state.
    func dotIcon(color: NSColor?) -> NSImage {
        let s: CGFloat = 18, d: CGFloat = 9
        let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
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

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = StatusController()
app.run()
