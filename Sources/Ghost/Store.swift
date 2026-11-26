// Store: owns the scan loop, the settings, the reminder rules and the notifications.

import AppKit
import Combine
import EventKit
import ServiceManagement
import SwiftUI
import UserNotifications

enum GhostLog {
    private static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Ghost.log")
    /// Flags and counts only. Never titles or text.
    static func write(_ s: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}

@MainActor
final class Store: ObservableObject {
    @Published var snap = Snapshot()
    @Published var showSettings = false
    @Published var todos: [String] = []
    @Published var todoAccess = true
    @Published var snoozeUntil: Date?

    @Published var showOrb: Bool { didSet { d.set(showOrb, forKey: "showOrb"); onShowOrb?(showOrb) } }
    @Published var notify: Bool { didSet { d.set(notify, forKey: "notify") } }
    @Published var needEvery: Int { didSet { d.set(needEvery, forKey: "needEvery") } }
    @Published var callEvery: Int { didSet { d.set(callEvery, forKey: "callEvery") } }
    @Published var awayMin: Int { didSet { d.set(awayMin, forKey: "awayMin") } }
    @Published var alertTokens: Int { didSet { d.set(alertTokens, forKey: "alertTokens") } }
    @Published var todoList: String { didSet { d.set(todoList, forKey: "todoList"); loadTodos() } }
    @Published var designModel: String { didSet { d.set(designModel, forKey: "designModel") } }
    /// The shells (built-in and designed) and the one being worn.
    let shells = ShellLibrary()
    /// Shell designer state: busy, and the Ghost's last line.
    @Published var designing = false
    @Published var ghostLine = ""
    @Published var launchAtLogin: Bool { didSet { d.set(launchAtLogin, forKey: "launchAtLogin"); applyLogin() } }

    var onShowOrb: ((Bool) -> Void)?
    var onPulse: ((Int) -> Void)?
    /// Show a message through the Ghost; returns false when the Ghost is away (then a macOS banner is used).
    var onSay: ((String, String, String?) -> Bool)?

    private let d = UserDefaults.standard
    private let scanner = Scanner()
    private let q = DispatchQueue(label: "ghost.scan", qos: .utility)
    private var timers: [Timer] = []
    private var tick = 0
    private var busy = false
    private var primed = false
    private var dismissed: Set<String>
    private struct Memo { var last: Date; var count: Int; var level: Int }
    private var memo: [String: Memo] = [:]
    private let ek = EKEventStore()

    init() {
        d.register(defaults: ["showOrb": true, "notify": true, "needEvery": 10, "callEvery": 60, "awayMin": 20,
                              "alertTokens": 500_000, "todoList": "Claude to do", "launchAtLogin": false, "designModel": "haiku"])
        showOrb = d.bool(forKey: "showOrb")
        notify = d.bool(forKey: "notify")
        needEvery = d.integer(forKey: "needEvery")
        callEvery = d.integer(forKey: "callEvery")
        awayMin = d.integer(forKey: "awayMin")
        alertTokens = d.integer(forKey: "alertTokens")
        todoList = d.string(forKey: "todoList") ?? "Claude to do"
        launchAtLogin = d.bool(forKey: "launchAtLogin")
        designModel = d.string(forKey: "designModel") ?? "haiku"
        dismissed = Set(d.stringArray(forKey: "dismissed") ?? [])
    }

    /// Asks Claude (one short call through the local CLI) to design a shell from the owner's words, then wears it.
    func designShell(_ prompt: String) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !designing else { return }
        designing = true
        ghostLine = "Hold still, Guardian. Drafting a shell…"
        let model = designModel
        Task {
            let r = await ShellDesigner.design(text, model: model)
            await MainActor.run {
                self.designing = false
                switch r {
                case .success(let spec):
                    self.shells.add(spec)
                    self.ghostLine = "“\(spec.lore)” — \(spec.name)"
                case .failure(let e):
                    self.ghostLine = e.description
                }
            }
        }
    }

    func start() {
        if launchAtLogin != (SMAppService.mainApp.status == .enabled) { applyLogin() }   // keep the login item in step with the setting
        refresh()
        timers.append(Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 90, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.loadTodos() }
        })
        loadTodos()
    }

    // MARK: scanning

    func refresh() {
        guard !busy else { return }
        busy = true
        let full = tick % 5 == 0          // transcripts every 20 s, registry every 4 s
        tick += 1
        let cfg = Scanner.Config(awayMinutes: awayMin, dismissed: dismissed)
        let scanner = self.scanner
        q.async {
            let s = scanner.cycle(full: full, cfg: cfg)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.busy = false
                self.apply(s, full: full)
            }
        }
    }

    private func apply(_ s: Snapshot, full: Bool) {
        let old = snap
        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) { snap = s }
        if full { GhostLog.write("scan ms=\(s.scanMs) files=\(s.files) live=\(s.liveCount) needs=\(s.needs.count) calls=\(s.calls.count) burns=\(s.hotBurns.count)") }
        if old.scanned {
            if s.needs.count > old.needs.count { onPulse?(3) }
            else if s.calls.count > old.calls.count || s.hotBurns.count > old.hotBurns.count { onPulse?(1) }
        }
        evaluate(s)
    }

    // MARK: reminders

    private func evaluate(_ s: Snapshot) {
        let now = Date()
        var due: [(Item, Bool)] = []

        func check(_ it: Item, every: Int, max: Int, announce: Bool) {
            if var m = memo[it.key] {
                if m.count < max, now.timeIntervalSince(m.last) >= Double(every * 60) {
                    due.append((it, true)); m.last = now; m.count += 1; memo[it.key] = m
                }
            } else {
                memo[it.key] = Memo(last: now, count: 1, level: 0)
                if announce { due.append((it, false)) }
            }
        }
        for it in s.needs { check(it, every: needEvery, max: 6, announce: true) }
        for it in s.calls { check(it, every: callEvery, max: 3, announce: primed || now.timeIntervalSince(it.since) < 1800) }
        for it in s.burns where it.active {
            let lvl = it.burn.total / max(alertTokens, 1)
            var m = memo[it.key] ?? Memo(last: .distantPast, count: 0, level: 0)
            if lvl >= 1 && lvl > m.level { due.append((it, false)); m.level = lvl; m.last = now }
            memo[it.key] = m
        }
        primed = true

        let snoozed = snoozeUntil.map { now < $0 } ?? false
        guard notify, !snoozed, !due.isEmpty else { return }
        if due.count == 1 {
            let (t, b) = Voice.note(due[0].0, reminder: due[0].1)
            post(id: due[0].0.key + "#\(Int(now.timeIntervalSince1970))", title: t, body: b, localId: due[0].0.localId)
        } else {
            let (t, b) = Voice.summary(due.map { $0.0 })
            post(id: "summary#\(Int(now.timeIntervalSince1970))", title: t, body: b)
        }
        GhostLog.write("notify items=\(due.count)")
    }

    func requestNotifications() {
        let c = UNUserNotificationCenter.current()
        let open = UNNotificationAction(identifier: "open", title: "Open session", options: [.foreground])
        let snooze = UNNotificationAction(identifier: "snooze", title: "Snooze 30 min", options: [])
        c.setNotificationCategories([UNNotificationCategory(identifier: "ghost", actions: [open, snooze], intentIdentifiers: [])])
        c.requestAuthorization(options: [.alert, .sound, .badge]) { ok, _ in GhostLog.write("notifications granted=\(ok)") }
    }

    private func post(id: String, title: String, body: String, localId: String? = nil) {
        if onSay?(title, body, localId) == true { return }
        let c = UNMutableNotificationContent()
        if let localId { c.userInfo = ["localId": localId] }
        c.title = title
        c.body = body
        c.sound = .default
        c.categoryIdentifier = "ghost"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }

    /// A message from outside (`Ghost --say`): JSON {"title", "body"}; shown by the Ghost, or as a banner if it is away.
    func say(_ raw: String) {
        guard let d = raw.data(using: .utf8), let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: String],
              let body = j["body"], !body.isEmpty else { return }
        let title = String((j["title"] ?? "Claude").prefix(80))
        post(id: "say#\(Int(Date().timeIntervalSince1970))", title: title, body: String(body.prefix(240)))
    }

    func snooze(_ seconds: TimeInterval) {
        snoozeUntil = seconds > 0 ? Date().addingTimeInterval(seconds) : nil
    }

    func dismiss(_ it: Item) {
        dismissed.insert(it.key)
        d.set(Array(dismissed.suffix(400)), forKey: "dismissed")
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            snap.calls.removeAll { $0.key == it.key }
            snap.reviews.removeAll { $0.key == it.key }
        }
    }

    // MARK: actions

    /// Opens the item's own session in the Claude app (claude://claude.ai/epitaxy/<local id>, verified 2026-11-25);
    /// with no known session id, just brings the app forward.
    func openClaude(_ localId: String? = nil) {
        if let id = localId, id.hasPrefix("local_"), let link = URL(string: "claude://claude.ai/epitaxy/" + id),
           NSWorkspace.shared.open(link) { return }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func applyLogin() {
        do {
            if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { GhostLog.write("login item error \(error.localizedDescription)") }
        GhostLog.write("login item status=\(SMAppService.mainApp.status.rawValue) want=\(launchAtLogin)")
    }

    // MARK: Reminders list ("Claude to do")

    func loadTodos() {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        switch status {
        case .notDetermined:
            ek.requestFullAccessToReminders { granted, _ in
                DispatchQueue.main.async { [weak self] in
                    self?.todoAccess = granted
                    if granted { self?.fetchTodos() }
                }
            }
        case .fullAccess:
            todoAccess = true
            fetchTodos()
        default:
            todoAccess = false
        }
    }

    private func fetchTodos() {
        let cals = ek.calendars(for: .reminder).filter { $0.title == todoList }
        guard !cals.isEmpty else { todos = []; return }
        let pred = ek.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: cals)
        ek.fetchReminders(matching: pred) { rs in
            let titles = (rs ?? []).compactMap { $0.title }.filter { !$0.isEmpty }
            DispatchQueue.main.async { [weak self] in self?.todos = titles }
        }
    }
}

// MARK: - Voice: how the Ghost talks (short, kind, plain words)

enum Voice {
    static func short(_ s: String, _ n: Int = 42) -> String { s.count > n ? String(s.prefix(n - 1)) + "…" : s }

    static func tokens(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: n >= 10_000_000 ? "%.0fM" : "%.1fM", Double(n) / 1e6)
        case 1_000...: return "\(n / 1000)k"
        default: return "\(n)"
        }
    }

    static func ago(_ d: Date, now: Date = Date()) -> String {
        let m = Int(now.timeIntervalSince(d) / 60)
        if m < 1 { return "just now" }
        if m < 60 { return "\(m) min" }
        let h = m / 60, r = m % 60
        if h < 24 { return r == 0 || h >= 6 ? "\(h) h" : "\(h) h \(r) min" }
        return "\(h / 24) d"
    }

    static func greeting(_ now: Date = Date()) -> String {
        let h = Calendar.current.component(.hour, from: now)
        switch h {
        case 0..<5: return "Up late"
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        default: return "Good evening"
        }
    }

    static func headline(_ s: Snapshot) -> String {
        if !s.scanned { return "Looking around…" }
        if s.needs.count == 1 {
            let it = s.needs[0]
            return it.kind == .approve ? "“\(short(it.title, 34))” needs your OK." : "“\(short(it.title, 30))” has a question for you."
        }
        if s.needs.count > 1 { return "\(s.needs.count) sessions need you." }
        let hot = s.hotBurns
        if hot.count == 1 { return "“\(short(hot[0].title, 30))” is working while you're away." }
        if hot.count > 1 { return "\(hot.count) sessions are working while you're away." }
        if s.calls.count == 1 { return "One decision is waiting for you." }
        if s.calls.count > 1 { return "\(s.calls.count) decisions are waiting for you." }
        return "All quiet. Nothing is waiting on you."
    }

    static func subline(_ s: Snapshot) -> String {
        var parts = [greeting()]
        parts.append(s.liveCount == 1 ? "1 session open" : "\(s.liveCount) sessions open")
        let total = s.todayOwner + s.todayAuto
        if total > 0 { parts.append("\(tokens(total)) tokens in 24 h") }
        return parts.joined(separator: " · ")
    }

    static func causes(_ it: Item) -> String {
        var c = it.causes.map { $0.phrase }
        if it.timer != nil, !c.contains("a timer") { c.insert("a timer", at: 0) }
        if c.isEmpty { return "automatic turns" }
        if c.count == 1 { return c[0] }
        return c.dropLast().joined(separator: ", ") + " and " + c.last!
    }

    static func note(_ it: Item, reminder: Bool) -> (String, String) {
        let still = reminder ? " Still waiting after \(ago(it.since))." : ""
        switch it.kind {
        case .approve:
            return ("Needs your OK", "“\(short(it.title))” is waiting for your approval.\(still)")
        case .answer:
            return ("A question for you", "“\(short(it.title))” asked you something and is waiting.\(still)")
        case .call:
            let what = it.ask ?? it.detail ?? "It is waiting on a decision from you."
            return (reminder ? "Still your call" : "Your call", "“\(short(it.title))”: \(short(what, 140))")
        case .review:
            return ("Ready for you", "“\(short(it.title))” is ready to review.")
        case .burn:
            var b = "“\(short(it.title))” used \(tokens(it.burn.total)) tokens on its own since you left it \(ago(it.since)) ago, driven by \(causes(it))."
            if let t = it.timer { b += " Its timer runs \(t)." }
            return ("Working while you're away", b)
        }
    }

    static func summary(_ items: [Item]) -> (String, String) {
        let n = items.count
        let names = items.prefix(3).map { "“\(short($0.title, 28))”" }.joined(separator: ", ")
        let more = n > 3 ? " and \(n - 3) more" : ""
        let urgent = items.contains { $0.kind == .approve || $0.kind == .answer }
        return (urgent ? "\(n) things need you" : "\(n) things are waiting", names + more + ".")
    }
}
