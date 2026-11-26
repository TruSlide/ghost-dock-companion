// Scanner: reads Claude Code's local files (read-only) and builds a Snapshot.
// Sources and rules follow cosmos/docs/DATA_SPEC.md:
//   S1/S2 transcripts  ~/.claude/projects/<folder>/<sid>.jsonl (+ <sid>/subagents/**.jsonl)
//   S5 live registry   ~/.claude/sessions/<pid>.json   (status waiting/busy/idle)
//   S6 desktop meta    ~/Library/Application Support/Claude/claude-code-sessions/*/*/local_*.json
// It never writes anywhere under ~/.claude and never shows prompt or reply text.
// The only text it shows is session titles and the app's own short turn summaries (S6 postTurnSummary).

import Foundation
import Darwin
import Darwin.malloc

// MARK: - Basic types

enum Origin: Int, CaseIterable {
    case human, timer, peer, task, app, sdk, other

    init(raw: String) {
        switch raw {
        case "human": self = .human
        case "scheduled": self = .timer
        case "peer": self = .peer
        case "task_notification": self = .task
        case "host_synthetic": self = .app
        case "sdk": self = .sdk
        default: self = .other
        }
    }

    var phrase: String {
        switch self {
        case .human: return "you"
        case .timer: return "a timer"
        case .peer: return "messages from another session"
        case .task: return "background tasks"
        case .app: return "app events"
        case .sdk: return "its parent session"
        case .other: return "automatic turns"
        }
    }

    var chip: String {
        switch self {
        case .human: return "You"
        case .timer: return "Timer"
        case .peer: return "Other session"
        case .task: return "Background task"
        case .app: return "App event"
        case .sdk: return "Parent session"
        case .other: return "Automatic"
        }
    }
}

struct Tokens: Equatable {
    var input = 0, output = 0, cacheWrite = 0, cacheRead = 0
    var fresh: Int { input + output + cacheWrite }
    var total: Int { fresh + cacheRead }
    static func += (a: inout Tokens, b: Tokens) {
        a.input += b.input; a.output += b.output; a.cacheWrite += b.cacheWrite; a.cacheRead += b.cacheRead
    }
}

struct Spend { var time: Date; var tokens: Tokens }

final class SessionLog {
    let sid: String
    var spends: [String: Spend] = [:]        // message.id -> entry with the largest output (DATA_SPEC §4)
    var turnTimes: [Date] = []               // turn starts, sorted
    var turnOrigins: [Origin] = []
    var lastTurnIndex = Int.min
    var lastHumanAt: Date?
    var lastCoreAt: Date?
    var cwd: String?
    var recurringTimers = 0
    var timerSpec: String?
    var pendingCron: [String: String] = [:]  // tool_use_id -> cron spec (recurring creates, not yet confirmed)
    var pendingDelete: Set<String> = []
    var loopAt: Date?                        // last ScheduleWakeup (self-paced /loop)

    init(sid: String) { self.sid = sid }

    func addTurn(_ t: Date, _ o: Origin) {
        if let last = turnTimes.last, t < last {
            let i = turnTimes.firstIndex { $0 > t } ?? turnTimes.count
            turnTimes.insert(t, at: i); turnOrigins.insert(o, at: i)
        } else {
            turnTimes.append(t); turnOrigins.append(o)
        }
    }

    /// Origin of the turn that was running at time t.
    func origin(at t: Date) -> Origin {
        var lo = 0, hi = turnTimes.count - 1, ans = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if turnTimes[mid] <= t { ans = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return ans >= 0 ? turnOrigins[ans] : .other
    }
}

// MARK: - Snapshot

enum Mood: Int { case calm, call, burning, needs }

struct Item: Identifiable, Equatable {
    enum Kind { case approve, answer, call, review, burn }
    var id: String { key }
    let key: String
    let sid: String
    let kind: Kind
    let title: String
    let project: String
    let since: Date
    var detail: String? = nil
    var ask: String? = nil
    var burn = Tokens()
    var burnTurns = 0
    var localId: String? = nil    // desktop app session id (local_…), for the claude:// deep link
    var buckets: [Int] = []       // 12 x 15 min, oldest first (automatic tokens)
    var causes: [Origin] = []
    var timer: String? = nil
    var loop = false
    var active = false
    var lastAuto: Date? = nil
}

struct HourPoint: Identifiable {
    var id: String { "\(who)-\(hour.timeIntervalSince1970)" }
    let hour: Date
    let who: String
    let value: Double
}

struct Snapshot {
    var needs: [Item] = []
    var calls: [Item] = []
    var reviews: [Item] = []
    var burns: [Item] = []
    var hours: [HourPoint] = []
    var todayOwner = 0
    var todayAuto = 0
    var liveCount = 0
    var updated = Date()
    var scanned = false
    var scanMs = 0
    var files = 0

    var hotBurns: [Item] { burns.filter { $0.active } }
    var waitingCount: Int { needs.count + calls.count }

    var mood: Mood {
        if !needs.isEmpty { return .needs }
        if !hotBurns.isEmpty { return .burning }
        if !calls.isEmpty { return .call }
        return .calm
    }
}

// MARK: - Scanner

final class Scanner {
    struct Config {
        var awayMinutes: Int
        var dismissed: Set<String>
    }

    private struct Tail { var offset: UInt64; var carry: Data; let sid: String; let ship: Bool }
    private struct S5 { let pid: Int32; let sid: String; let cwd: String?; let status: String; let waitingFor: String?; let since: Date; let name: String?; let live: Bool }
    private struct S6 {
        let localId: String; let title: String?; let archived: Bool
        let category: String?; let detail: String?; let needsAction: String?; let summarizes: String?
        let lastActivity: Date; let cliIds: [String]
    }

    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var tails: [String: Tail] = [:]
    private(set) var logs: [String: SessionLog] = [:]
    private var s6Cache: [String: (Date, S6?)] = [:]
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let isoPlain = ISO8601DateFormatter()
    private let horizon: TimeInterval = 26 * 3600
    private let mainCap: UInt64 = 8 << 20
    private let shipCap: UInt64 = 2 << 20

    private let pAssistant = Data("\"type\":\"assistant\"".utf8)
    private let pUser = Data("\"type\":\"user\"".utf8)
    private let pToolResult = Data("\"type\":\"tool_result\"".utf8)
    private var lastFiles = 0

    /// One cycle. `full` also tails the transcripts (slower); otherwise only the registry and desktop metadata.
    func cycle(full: Bool, cfg: Config) -> Snapshot {
        let t0 = Date()
        if full { scanTranscripts() }
        let reg = readRegistry()
        let desk = readDesktop()
        var s = build(reg: reg, desk: desk, cfg: cfg)
        s.scanned = true
        s.scanMs = Int(Date().timeIntervalSince(t0) * 1000)
        s.files = lastFiles
        return s
    }

    // MARK: transcripts

    private func scanTranscripts() {
        let fm = FileManager.default
        let root = home.appendingPathComponent(".claude/projects")
        let cutoff = Date().addingTimeInterval(-horizon)
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        var count = 0
        for dir in dirs {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { continue }
            for u in items where u.pathExtension == "jsonl" {
                let sid = u.deletingPathExtension().lastPathComponent
                guard let mt = modDate(u), mt > cutoff || tails[u.path] != nil else { continue }
                count += 1
                autoreleasepool { tail(u, sid: sid, ship: false) }
                // Ships (subagents) of a recent session.
                let sub = dir.appendingPathComponent(sid).appendingPathComponent("subagents")
                if let en = fm.enumerator(at: sub, includingPropertiesForKeys: [.contentModificationDateKey]) {
                    for case let f as URL in en where f.pathExtension == "jsonl" {
                        guard let m2 = modDate(f), m2 > cutoff || tails[f.path] != nil else { continue }
                        count += 1
                        autoreleasepool { tail(f, sid: sid, ship: true) }
                    }
                }
            }
        }
        lastFiles = count
        prune()
        malloc_zone_pressure_relief(nil, 0)   // hand freed pages back to macOS after the big first read
    }

    private func modDate(_ u: URL) -> Date? {
        (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private func tail(_ url: URL, sid: String, ship: Bool) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value else { return }
        var t: Tail
        var skipFirst = false
        if let existing = tails[url.path] {
            t = existing
            if size < t.offset { t = Tail(offset: 0, carry: Data(), sid: sid, ship: ship) } // rewritten
        } else {
            let cap = ship ? shipCap : mainCap
            let start = size > cap ? size - cap : 0
            skipFirst = start > 0
            t = Tail(offset: start, carry: Data(), sid: sid, ship: ship)
        }
        guard size > t.offset else { tails[url.path] = t; return }
        // Memory-mapped: the file's pages are paged in by macOS and never copied onto Ember's heap.
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return }
        let log = logs[sid] ?? { let l = SessionLog(sid: sid); logs[sid] = l; return l }()
        let end = min(Int(size), data.count)
        var start = Int(t.offset)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            func nextNL(_ from: Int) -> Int? {
                guard from < end, let p = memchr(base + from, 0x0A, end - from) else { return nil }
                return base.distance(to: UnsafeRawPointer(p))
            }
            if skipFirst, let nl = nextNL(start) { start = nl + 1 }
            while let nl = nextNL(start) {
                if nl - start > 30 { handle(UnsafeRawBufferPointer(rebasing: raw[start..<nl]), log: log, ship: ship) }
                start = nl + 1
            }
        }
        t.offset = UInt64(start)          // a partial last line is read again next time
        tails[url.path] = t
    }

    private func date(_ v: Any?) -> Date? {
        guard let s = v as? String else { return nil }
        return iso.date(from: s) ?? isoPlain.date(from: s)
    }

    // MARK: byte-level field reading (no full JSON parse for ordinary lines; far less memory churn)

    private static func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }
    private let kUsage = bytes("\"usage\":{"), kMsgId = bytes("\"id\":\"msg_"), kTs = bytes("\"timestamp\":\"")
    private let kIn = bytes("\"input_tokens\":"), kOut = bytes("\"output_tokens\":")
    private let kCW = bytes("\"cache_creation_input_tokens\":"), kCR = bytes("\"cache_read_input_tokens\":")
    private let kSynth = bytes("\"model\":\"<synthetic>\""), kCwd = bytes("\"cwd\":\"")
    private let kOrigin = bytes("\"turnOrigin\":\""), kTurnIdx = bytes("\"turnIndex\":")
    private let kAssistant = bytes("\"type\":\"assistant\""), kUser = bytes("\"type\":\"user\""), kToolResult = bytes("\"type\":\"tool_result\"")
    private let kTimerTools = [bytes("\"name\":\"CronCreate\""), bytes("\"name\":\"CronDelete\""), bytes("\"name\":\"ScheduleWakeup\"")]

    private func find(_ b: UnsafeRawBufferPointer, _ k: [UInt8], from: Int = 0) -> Int? {
        guard from < b.count, let base = b.baseAddress else { return nil }
        return k.withUnsafeBytes { kb -> Int? in
            guard let p = memmem(base + from, b.count - from, kb.baseAddress!, k.count) else { return nil }
            return base.distance(to: UnsafeRawPointer(p))
        }
    }
    private func findLast(_ b: UnsafeRawBufferPointer, _ k: [UInt8]) -> Int? {
        var at: Int? = nil, from = 0
        while let i = find(b, k, from: from) { at = i; from = i + k.count }
        return at
    }
    private func int(_ b: UnsafeRawBufferPointer, _ k: [UInt8], from: Int) -> Int {
        guard let i = find(b, k, from: from) else { return 0 }
        var j = i + k.count, v = 0
        while j < b.count, b[j] >= 48, b[j] <= 57 { v = v * 10 + Int(b[j] - 48); j += 1 }
        return v
    }
    private func str(_ b: UnsafeRawBufferPointer, at i: Int, skip: Int) -> String? {
        var j = i + skip
        let s = j
        while j < b.count, b[j] != 0x22 { if b[j] == 0x5C { j += 1 }; j += 1 }
        guard j <= b.count, j > s else { return nil }
        return String(decoding: UnsafeRawBufferPointer(rebasing: b[s..<min(j, b.count)]), as: UTF8.self)
    }
    /// "2026-11-25T15:41:21.790Z" -> Date, without a formatter.
    private func stamp(_ b: UnsafeRawBufferPointer) -> Date? {
        guard let i = findLast(b, kTs) else { return nil }
        let s = i + kTs.count
        guard s + 19 <= b.count else { return nil }
        func n(_ o: Int, _ l: Int) -> Int { var v = 0; for k in 0..<l { v = v * 10 + Int(b[s + o + k]) - 48 }; return v }
        var t = tm()
        t.tm_year = Int32(n(0, 4) - 1900); t.tm_mon = Int32(n(5, 2) - 1); t.tm_mday = Int32(n(8, 2))
        t.tm_hour = Int32(n(11, 2)); t.tm_min = Int32(n(14, 2)); t.tm_sec = Int32(n(17, 2))
        var frac = 0.0
        if s + 23 <= b.count, b[s + 19] == 0x2E { frac = Double(n(20, 3)) / 1000 }
        return Date(timeIntervalSince1970: Double(timegm(&t)) + frac)
    }

    private func handle(_ b: UnsafeRawBufferPointer, log: SessionLog, ship: Bool) {
        do {
            if find(b, kAssistant) != nil {
                guard let ts = stamp(b) else { return }
                log.lastCoreAt = max(log.lastCoreAt ?? ts, ts)
                if log.cwd == nil, !ship, let i = find(b, kCwd) { log.cwd = str(b, at: i, skip: kCwd.count) }
                if find(b, kSynth) != nil { return }
                if let u = find(b, kUsage), let m = find(b, kMsgId), let id = str(b, at: m, skip: 6) {
                    var tk = Tokens()
                    tk.input = int(b, kIn, from: u); tk.output = int(b, kOut, from: u)
                    tk.cacheWrite = int(b, kCW, from: u); tk.cacheRead = int(b, kCR, from: u)
                    if let old = log.spends[id], old.tokens.output > tk.output { } else {
                        log.spends[id] = Spend(time: log.spends[id]?.time ?? ts, tokens: tk)
                    }
                }
                if !ship, kTimerTools.contains(where: { find(b, $0) != nil }) { timerTools(Data(b), log: log, ts: ts) }
                return
            }
            guard !ship, find(b, kUser) != nil else { return }
            if find(b, kToolResult) != nil {
                if !log.pendingCron.isEmpty || !log.pendingDelete.isEmpty, b.count < 40_000 { timerResults(Data(b), log: log) }
                return
            }
            guard let ts = stamp(b) else { return }
            log.lastCoreAt = max(log.lastCoreAt ?? ts, ts)
            if log.cwd == nil, let i = find(b, kCwd) { log.cwd = str(b, at: i, skip: kCwd.count) }
            guard let oi = find(b, kOrigin), let raw = str(b, at: oi, skip: kOrigin.count) else { return }
            let origin = Origin(raw: raw)
            var idx = log.lastTurnIndex == Int.min ? 0 : log.lastTurnIndex + 1
            if let ti = find(b, kTurnIdx) { idx = int(b, kTurnIdx, from: ti) }
            if idx != log.lastTurnIndex {
                log.addTurn(ts, origin)
                log.lastTurnIndex = idx
            }
            if origin == .human { log.lastHumanAt = max(log.lastHumanAt ?? ts, ts) }
        }
    }

    /// Rare lines (CronCreate / CronDelete / ScheduleWakeup): full parse.
    private func timerTools(_ line: Data, log: SessionLog, ts: Date) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let msg = obj["message"] as? [String: Any], let content = msg["content"] as? [[String: Any]] else { return }
        for c in content where (c["type"] as? String) == "tool_use" {
            let input = c["input"] as? [String: Any] ?? [:]
            let tid = c["id"] as? String ?? ""
            switch c["name"] as? String ?? "" {
            case "CronCreate": if (input["recurring"] as? Bool) != false { log.pendingCron[tid] = input["cron"] as? String ?? "" }
            case "CronDelete": log.pendingDelete.insert(tid)
            case "ScheduleWakeup": log.loopAt = (input["stop"] as? Bool) == true ? nil : ts
            default: break
            }
        }
    }

    private func timerResults(_ line: Data, log: SessionLog) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let msg = obj["message"] as? [String: Any], let content = msg["content"] as? [[String: Any]] else { return }
        for c in content where (c["type"] as? String) == "tool_result" {
            let tid = c["tool_use_id"] as? String ?? ""
            let err = (c["is_error"] as? Bool) == true
            if let spec = log.pendingCron.removeValue(forKey: tid), !err { log.recurringTimers += 1; log.timerSpec = spec }
            if log.pendingDelete.remove(tid) != nil, !err { log.recurringTimers = max(0, log.recurringTimers - 1) }
        }
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-horizon)
        for (sid, log) in logs {
            log.spends = log.spends.filter { $0.value.time > cutoff }
            if log.spends.isEmpty, (log.lastCoreAt ?? .distantPast) < cutoff { logs[sid] = nil }
        }
    }

    // MARK: registry (S5)

    private func readRegistry() -> [String: S5] {
        // EMBER_TEST_SESSIONS points the registry at a test folder (used only by checks).
        let dir = ProcessInfo.processInfo.environment["EMBER_TEST_SESSIONS"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".claude/sessions")
        var out: [String: S5] = [:]
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return out }
        for f in files where f.pathExtension == "json" {
            guard let d = try? Data(contentsOf: f),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let pid = o["pid"] as? Int, let sid = o["sessionId"] as? String else { continue }
            let alive = kill(pid_t(pid), 0) == 0 || errno == EPERM
            let ms = (o["statusUpdatedAt"] as? Double) ?? (o["updatedAt"] as? Double) ?? 0
            out[sid] = S5(pid: Int32(pid), sid: sid, cwd: o["cwd"] as? String,
                          status: o["status"] as? String ?? "", waitingFor: o["waitingFor"] as? String,
                          since: Date(timeIntervalSince1970: ms / 1000), name: o["name"] as? String, live: alive)
        }
        return out
    }

    // MARK: desktop metadata (S6)

    private func readDesktop() -> [String: S6] {
        let fm = FileManager.default
        let root = home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
        var byCli: [String: S6] = [:]
        guard let accts = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return byCli }
        for a in accts {
            guard let orgs = try? fm.contentsOfDirectory(at: a, includingPropertiesForKeys: nil) else { continue }
            for o in orgs {
                guard let files = try? fm.contentsOfDirectory(at: o, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
                for f in files where f.lastPathComponent.hasPrefix("local_") && f.pathExtension == "json" {
                    let mt = modDate(f) ?? .distantPast
                    if Date().timeIntervalSince(mt) > 30 * 3600 { continue }
                    var info: S6?
                    if let c = s6Cache[f.path], c.0 == mt { info = c.1 } else {
                        info = parseS6(f)
                        s6Cache[f.path] = (mt, info)
                    }
                    guard let i = info else { continue }
                    for id in i.cliIds where byCli[id] == nil || byCli[id]!.lastActivity < i.lastActivity { byCli[id] = i }
                }
            }
        }
        return byCli
    }

    private let kSid = bytes("\"sessionId\":\""), kCli = bytes("\"cliSessionId\":\""), kTitle = bytes("\"title\":\"")
    private let kTitleSrc = bytes("\"titleSource\":"), kArch = bytes("\"isArchived\":true"), kPTS = bytes("\"postTurnSummary\":{")
    private let kCat = bytes("\"status_category\":\""), kDet = bytes("\"status_detail\":\""), kNeed = bytes("\"needs_action\":\"")
    private let kSum = bytes("\"summarizes_uuid\":\""), kEdge = bytes("\"lastTurnEdgeAt\":"), kAct = bytes("\"lastActivityAt\":")
    private let kPrior = bytes("\"priorCliSessionIds\":[")

    private func unescape(_ s: String?) -> String? {
        guard let s, s.contains("\\") else { return s }
        return (try? JSONSerialization.jsonObject(with: Data(("\"" + s + "\"").utf8), options: .fragmentsAllowed)) as? String ?? s
    }

    /// Reads only the few fields Ember needs, straight from the mapped file (these files can be large).
    private func parseS6(_ f: URL) -> S6? {
        guard let data = try? Data(contentsOf: f, options: .alwaysMapped) else { return nil }
        return data.withUnsafeBytes { (b: UnsafeRawBufferPointer) -> S6? in
            guard let ci = find(b, kCli), let cli = str(b, at: ci, skip: kCli.count) else { return nil }
            let local = find(b, kSid).flatMap { str(b, at: $0, skip: kSid.count) } ?? cli
            var title: String?
            if let ts = find(b, kTitleSrc) {
                var at: Int? = nil, from = 0
                while let i = find(b, kTitle, from: from), i < ts { at = i; from = i + kTitle.count }
                if let at { title = unescape(str(b, at: at, skip: kTitle.count)) }
            } else if let at = find(b, kTitle) {       // no titleSource: the top-level title is the first one
                title = unescape(str(b, at: at, skip: kTitle.count))
            }
            var cat: String?, det: String?, need: String?, sum: String?
            if let p = find(b, kPTS) {
                let window = UnsafeRawBufferPointer(rebasing: b[p..<min(b.count, p + 6000)])
                cat = find(window, kCat).flatMap { str(window, at: $0, skip: kCat.count) }
                det = unescape(find(window, kDet).flatMap { str(window, at: $0, skip: kDet.count) })
                need = unescape(find(window, kNeed).flatMap { str(window, at: $0, skip: kNeed.count) })
                sum = find(window, kSum).flatMap { str(window, at: $0, skip: kSum.count) }
            }
            var ms = 0
            if let e = find(b, kEdge) { ms = int(b, kEdge, from: e) }
            if ms == 0, let e = find(b, kAct) { ms = int(b, kAct, from: e) }
            var ids = [cli]
            if let pr = find(b, kPrior) {
                var j = pr + kPrior.count
                while j < b.count, b[j] != 0x5D {          // until ']'
                    if b[j] == 0x22, let v = str(b, at: j, skip: 1) { ids.append(v); j += v.utf8.count + 2 } else { j += 1 }
                }
            }
            return S6(localId: local, title: title, archived: find(b, kArch) != nil,
                      category: cat, detail: det, needsAction: need, summarizes: sum,
                      lastActivity: Date(timeIntervalSince1970: Double(ms) / 1000), cliIds: ids)
        }
    }

    // MARK: build

    private func build(reg: [String: S5], desk: [String: S6], cfg: Config) -> Snapshot {
        let now = Date()
        var s = Snapshot()
        s.updated = now
        s.liveCount = reg.values.filter { $0.live }.count

        func title(_ sid: String) -> String {
            if let t = desk[sid]?.title, !t.isEmpty { return t }
            if let n = reg[sid]?.name, !n.isEmpty { return n }
            return "Session " + sid.prefix(8)
        }
        func project(_ sid: String) -> String {
            guard let c = reg[sid]?.cwd ?? logs[sid]?.cwd else { return "" }
            var p = c
            if let r = p.range(of: "/.claude/worktrees/") { p = String(p[..<r.lowerBound]) }
            return URL(fileURLWithPath: p).lastPathComponent
        }

        // 1. Needs you now: live registry status "waiting" (DATA_SPEC §3.1).
        var needSids = Set<String>()
        for r in reg.values where r.live && r.status == "waiting" {
            let wf = (r.waitingFor ?? "").lowercased()
            if wf.contains("dialog") { continue }
            let kind: Item.Kind = (wf.contains("permission") || wf.contains("sandbox")) ? .approve : .answer
            needSids.insert(r.sid)
            s.needs.append(Item(key: "need:\(r.sid):\(Int(r.since.timeIntervalSince1970))", sid: r.sid, kind: kind,
                                title: title(r.sid), project: project(r.sid), since: r.since, detail: r.waitingFor))
        }
        s.needs.sort { $0.since < $1.since }

        // 2. Your call / ready to review: the app's own turn summaries (S6).
        var seenLocal = Set<String>()
        for (cli, d) in desk where !d.archived && !seenLocal.contains(d.localId) {
            seenLocal.insert(d.localId)
            if needSids.contains(cli) || reg[cli]?.status == "busy" { continue }
            let age = now.timeIntervalSince(d.lastActivity)
            let key = "call:\(d.localId):\(d.summarizes ?? "")"
            if cfg.dismissed.contains(key) { continue }
            let ask = (d.needsAction ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if (d.category == "blocked" || !ask.isEmpty) && age < 24 * 3600 {
                s.calls.append(Item(key: key, sid: cli, kind: .call, title: d.title ?? title(cli), project: project(cli),
                                    since: d.lastActivity, detail: d.detail, ask: ask.isEmpty ? nil : ask))
            } else if d.category == "review_ready" && age < 12 * 3600 {
                s.reviews.append(Item(key: key, sid: cli, kind: .review, title: d.title ?? title(cli), project: project(cli),
                                      since: d.lastActivity, detail: d.detail))
            }
        }
        s.calls.sort { $0.since > $1.since }
        s.reviews.sort { $0.since > $1.since }

        // 3. Tokens: today's chart and sessions spending while the owner is away.
        let cal = Calendar.current
        let thisHour = cal.dateInterval(of: .hour, for: now)?.start ?? now
        let firstHour = thisHour.addingTimeInterval(-23 * 3600)
        var owner = [Double](repeating: 0, count: 24), auto = [Double](repeating: 0, count: 24)
        let away = TimeInterval(max(cfg.awayMinutes, 1) * 60)

        for (sid, log) in logs {
            for sp in log.spends.values where sp.time >= firstHour {
                let i = min(23, Int(sp.time.timeIntervalSince(firstHour) / 3600))
                if log.origin(at: sp.time) == .human { owner[i] += Double(sp.tokens.total) } else { auto[i] += Double(sp.tokens.total) }
            }
            guard let h = log.lastHumanAt, now.timeIntervalSince(h) >= away else { continue }
            if desk[sid]?.archived == true { continue }
            var t = Tokens(), buckets = [Int](repeating: 0, count: 12), causes = Set<Origin>()
            var lastAuto: Date?
            for sp in log.spends.values where sp.time > h {
                let o = log.origin(at: sp.time)
                if o == .human { continue }
                t += sp.tokens
                causes.insert(o)
                lastAuto = max(lastAuto ?? sp.time, sp.time)
                let b = Int(now.timeIntervalSince(sp.time) / 900)
                if b < 12 { buckets[11 - b] += sp.tokens.total }
            }
            guard t.total > 0, let la = lastAuto else { continue }
            let live = reg[sid]?.live ?? false
            let armed = live && log.recurringTimers > 0
            let looping = live && (log.loopAt.map { now.timeIntervalSince($0) < 3 * 3600 } ?? false)
            let active = now.timeIntervalSince(la) < 90 * 60 || armed || looping
            guard active || now.timeIntervalSince(la) < 24 * 3600 else { continue }
            let turns = log.turnTimes.filter { $0 > h }.count
            var it = Item(key: "burn:\(sid)", sid: sid, kind: .burn, title: title(sid), project: project(sid), since: h)
            it.burn = t; it.burnTurns = turns; it.buckets = buckets
            it.causes = causes.sorted { $0.rawValue < $1.rawValue }
            it.timer = armed ? Scanner.humanCron(log.timerSpec) : nil
            if it.timer == nil {
                // Timer made before the part of the file we read: infer its rhythm from the timer turns.
                var tt: [Date] = []
                for (i, t0) in log.turnTimes.enumerated() where t0 > h && log.turnOrigins[i] == .timer { tt.append(t0) }
                if tt.count >= 2 {
                    let gaps = zip(tt.dropFirst(), tt).map { $0.timeIntervalSince($1) }.sorted()
                    let mins = Int((gaps[gaps.count / 2] / 60).rounded())
                    if mins > 0 { it.timer = mins >= 55 && mins <= 65 ? "about every hour" : "about every \(mins) min" }
                }
            }
            it.loop = looping
            it.active = active
            it.lastAuto = la
            s.burns.append(it)
        }
        s.burns.sort { ($0.active ? 1 : 0, $0.burn.total) > ($1.active ? 1 : 0, $1.burn.total) }
        var quiet = 0
        s.burns = s.burns.filter { $0.active || { quiet += 1; return quiet <= 4 }() }
        for i in 0..<24 {
            let hr = firstHour.addingTimeInterval(Double(i) * 3600)
            s.hours.append(HourPoint(hour: hr, who: "You", value: owner[i]))
            s.hours.append(HourPoint(hour: hr, who: "On its own", value: auto[i]))
        }
        s.todayOwner = Int(owner.reduce(0, +))
        s.todayAuto = Int(auto.reduce(0, +))
        func link(_ a: inout [Item]) { for i in a.indices { a[i].localId = desk[a[i].sid]?.localId } }
        link(&s.needs); link(&s.calls); link(&s.reviews); link(&s.burns)
        return s
    }

    /// "17,47 * * * *" -> "twice an hour"; "*/5 * * * *" -> "every 5 min".
    static func humanCron(_ spec: String?) -> String? {
        guard let spec = spec else { return "a timer" }
        let f = spec.split(separator: " ").map(String.init)
        guard f.count == 5 else { return spec }
        let (m, h) = (f[0], f[1])
        if m.hasPrefix("*/") { return "every \(m.dropFirst(2)) min" }
        if h == "*" {
            let n = m.split(separator: ",").count
            switch n { case 1: return "every hour"; case 2: return "twice an hour"; default: return "\(n) times an hour" }
        }
        if h.hasPrefix("*/") { return "every \(h.dropFirst(2)) h" }
        return "on a schedule (\(spec))"
    }
}
