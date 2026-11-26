// The Ghost: a small floating companion with a swappable shell (a fan tribute, drawn entirely in code).
//
// ShellSpec     one shell: plate count and shape, colours, pattern, eye, finish. Built-ins + the owner's own designs.
// ShellLibrary  the shells on disk (~/Library/Application Support/Ghost/shells.json) and which one is worn.
// ShellDesigner asks Claude (the local `claude` CLI, one short call, no tools) to turn a prompt into a ShellSpec.
// GhostBrain    floats the Ghost along the top of the Dock and picks things to do (drift, zip, hover, scan, spin,
//               peek, orbit, transmat, nap). Units: points; GhostBrain.unit points = 1 Ghost unit.
// DockInfo      the Dock's floor and span (unchanged from Ember).

import AppKit
import Foundation
import simd

@inline(__always) func lerp(_ a: Float, _ b: Float, _ k: Float) -> Float { a + (b - a) * k }

// MARK: - Shell spec

struct ShellSpec: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var lore: String
    var plates: Int
    var shape: String
    var length: Double
    var width: Double
    var gap: Double
    var backRing: Bool
    var base: String
    var accent: String
    var trim: String
    var patternColor: String
    var eye: String
    var pattern: String
    var patternScale: Double
    var eyeStyle: String
    var metallic: Double
    var glow: Double
    var wear: Double
    var facet: Double
    var prompt: String?
    var custom: Bool?

    static let shapes = ["spike", "facet", "blade", "petal", "crown", "shard", "fin"]
    static let patterns = ["none", "stripe", "chevron", "split", "band", "circuit", "crack", "dots", "tips", "camo"]
    static let eyeStyles = ["ring", "slit", "iris", "star"]

    var isCustom: Bool { custom == true }

    /// Clamp every number and fall back on unknown names, so a model's answer can never break the shader.
    func sanitized() -> ShellSpec {
        var s = self
        func c(_ v: Double, _ a: Double, _ b: Double) -> Double { v.isFinite ? min(max(v, a), b) : a }
        s.plates = min(max(plates, 3), 12)
        s.shape = Self.shapes.contains(shape) ? shape : "facet"
        s.pattern = Self.patterns.contains(pattern) ? pattern : "none"
        s.eyeStyle = Self.eyeStyles.contains(eyeStyle) ? eyeStyle : "ring"
        s.length = c(length, 0.6, 1.4); s.width = c(width, 0.4, 1.0); s.gap = c(gap, 0, 0.35)
        s.patternScale = c(patternScale, 0.5, 3); s.metallic = c(metallic, 0, 1); s.glow = c(glow, 0, 1)
        s.wear = c(wear, 0, 1); s.facet = c(facet, 0, 1)
        for kp in [\ShellSpec.base, \.accent, \.trim, \.patternColor, \.eye] where Self.hex(s[keyPath: kp]) == nil { s[keyPath: kp] = "#8A8F99" }
        s.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        if s.name.isEmpty { s.name = "Unnamed Shell" }
        s.lore = String(lore.trimmingCharacters(in: .whitespacesAndNewlines).prefix(180))
        return s
    }

    static func hex(_ s: String) -> SIMD4<Float>? {
        var h = s.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return SIMD4(Float((v >> 16) & 255) / 255, Float((v >> 8) & 255) / 255, Float(v & 255) / 255, 1)
    }
    func col(_ s: String) -> SIMD4<Float> { Self.hex(s) ?? SIMD4(0.55, 0.56, 0.6, 1) }

    var shapeIndex: Float { Float(Self.shapes.firstIndex(of: shape) ?? 1) }
    var patternIndex: Float { Float(Self.patterns.firstIndex(of: pattern) ?? 0) }
    var eyeIndex: Float { Float(Self.eyeStyles.firstIndex(of: eyeStyle) ?? 0) }
}

extension ShellSpec {
    // Built-in tribute shells: original names and colourways, all drawn in code (no game assets).
    static let builtIns: [ShellSpec] = [
        ShellSpec(id: "generalist", name: "Generalist", lore: "Standard issue. It has seen worse, and so have you.",
                  plates: 6, shape: "facet", length: 0.74, width: 1.0, gap: 0.04, backRing: true,
                  base: "#C9CDD2", accent: "#8E959E", trim: "#5E646C", patternColor: "#7FD4FF", eye: "#7FD4FF",
                  pattern: "split", patternScale: 1, eyeStyle: "ring", metallic: 0.45, glow: 0.4, wear: 0.25, facet: 0.9),
        ShellSpec(id: "vanguard", name: "Vanguard Blue", lore: "Polished for parade. Please do not land me in mud.",
                  plates: 6, shape: "facet", length: 0.8, width: 1.0, gap: 0.04, backRing: true,
                  base: "#2B4C7E", accent: "#E8EDF2", trim: "#C9A227", patternColor: "#9FD8FF", eye: "#9FD8FF",
                  pattern: "stripe", patternScale: 1, eyeStyle: "ring", metallic: 0.7, glow: 0.45, wear: 0.05, facet: 0.8),
        ShellSpec(id: "crimson-thorn", name: "Crimson Thorn", lore: "Every spike is a promise.",
                  plates: 6, shape: "spike", length: 1.0, width: 0.95, gap: 0.03, backRing: true,
                  base: "#7A1420", accent: "#1C1A1F", trim: "#E0B04A", patternColor: "#FF5A3C", eye: "#FF6B4A",
                  pattern: "tips", patternScale: 1, eyeStyle: "slit", metallic: 0.55, glow: 0.6, wear: 0.15, facet: 1.0),
        ShellSpec(id: "gilded-dawn", name: "Gilded Dawn", lore: "I asked for gold. The Speaker said no. I asked again.",
                  plates: 8, shape: "petal", length: 0.78, width: 1.0, gap: 0.03, backRing: true,
                  base: "#E7C46A", accent: "#FFF3D1", trim: "#9C6B1E", patternColor: "#FFD27A", eye: "#FFD27A",
                  pattern: "band", patternScale: 1, eyeStyle: "iris", metallic: 0.95, glow: 0.7, wear: 0.0, facet: 0.6),
        ShellSpec(id: "arc-circuit", name: "Arc Circuit", lore: "Static in every seam. Do not pet.",
                  plates: 5, shape: "fin", length: 0.8, width: 0.98, gap: 0.08, backRing: true,
                  base: "#1D2A3A", accent: "#2E4660", trim: "#7AD7FF", patternColor: "#7AD7FF", eye: "#9BE7FF",
                  pattern: "circuit", patternScale: 1.2, eyeStyle: "star", metallic: 0.5, glow: 0.9, wear: 0.1, facet: 0.7),
        ShellSpec(id: "void-bloom", name: "Void Bloom", lore: "It opens like a flower. It is not a flower.",
                  plates: 6, shape: "petal", length: 0.9, width: 0.92, gap: 0.06, backRing: true,
                  base: "#3A1F5C", accent: "#B48CFF", trim: "#1A1026", patternColor: "#C59BFF", eye: "#C59BFF",
                  pattern: "chevron", patternScale: 1.4, eyeStyle: "ring", metallic: 0.35, glow: 0.8, wear: 0.0, facet: 0.5),
        ShellSpec(id: "solar-core", name: "Solar Core", lore: "Warm to the touch. Very warm. Please let go.",
                  plates: 5, shape: "shard", length: 0.88, width: 1.0, gap: 0.06, backRing: false,
                  base: "#2A2220", accent: "#3D2E28", trim: "#F28C28", patternColor: "#FF8A2A", eye: "#FFB347",
                  pattern: "crack", patternScale: 1.1, eyeStyle: "ring", metallic: 0.3, glow: 1.0, wear: 0.35, facet: 0.8),
        ShellSpec(id: "frost-shard", name: "Frost Shard", lore: "Cold, clear, and slightly smug.",
                  plates: 7, shape: "blade", length: 0.95, width: 0.9, gap: 0.04, backRing: true,
                  base: "#BFE6F2", accent: "#5FA8C9", trim: "#FFFFFF", patternColor: "#DFF7FF", eye: "#BFF3FF",
                  pattern: "stripe", patternScale: 1, eyeStyle: "iris", metallic: 0.8, glow: 0.6, wear: 0.0, facet: 1.0),
        ShellSpec(id: "verdant-weave", name: "Verdant Weave", lore: "Woven tight. Holds together better than most plans.",
                  plates: 4, shape: "crown", length: 0.82, width: 1.0, gap: 0.07, backRing: true,
                  base: "#24543A", accent: "#9CE07A", trim: "#0E2418", patternColor: "#B8FF8A", eye: "#B8FF8A",
                  pattern: "dots", patternScale: 1.3, eyeStyle: "slit", metallic: 0.25, glow: 0.55, wear: 0.2, facet: 0.6),
        ShellSpec(id: "bone-relic", name: "Bone Relic", lore: "Found it in a crypt. It found me first.",
                  plates: 6, shape: "spike", length: 0.95, width: 0.85, gap: 0.08, backRing: true,
                  base: "#D8CFB8", accent: "#6B6250", trim: "#2C2A24", patternColor: "#9DFF6A", eye: "#9DFF6A",
                  pattern: "camo", patternScale: 1.6, eyeStyle: "slit", metallic: 0.1, glow: 0.5, wear: 0.6, facet: 0.7),
    ]
}

// MARK: - Library (built-ins + the owner's designs)

/// The shell the renderer draws. Set on the main thread by ShellLibrary.
enum ShellState {
    static var current: ShellSpec = ShellSpec.builtIns[0]
}

@MainActor
final class ShellLibrary: ObservableObject {
    @Published private(set) var custom: [ShellSpec] = []
    @Published var currentId: String { didSet { UserDefaults.standard.set(currentId, forKey: "shell"); apply() } }

    var all: [ShellSpec] { ShellSpec.builtIns + custom }
    var current: ShellSpec { all.first { $0.id == currentId } ?? ShellSpec.builtIns[0] }

    nonisolated static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Ghost")
    private var file: URL { Self.dir.appendingPathComponent("shells.json") }

    init() {
        currentId = UserDefaults.standard.string(forKey: "shell") ?? "generalist"
        if let data = try? Data(contentsOf: file), let list = try? JSONDecoder().decode([ShellSpec].self, from: data) {
            custom = list.map { $0.sanitized() }
        }
        apply()
    }

    private func apply() { ShellState.current = current }

    func add(_ s: ShellSpec) {
        custom.append(s)
        save()
        currentId = s.id
    }

    func remove(_ id: String) {
        custom.removeAll { $0.id == id }
        save()
        if currentId == id { currentId = "generalist" } else { apply() }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(custom).write(to: file, options: .atomic)
    }
}

// MARK: - Designer: prompt -> spec, written by Claude

enum ShellDesigner {
    enum Failure: Error, CustomStringConvertible {
        case noCLI, timeout, failed(String), unreadable
        var description: String {
            switch self {
            case .noCLI: return "I can't find the claude command. Install Claude Code, then ask again."
            case .timeout: return "Claude took too long. Try a shorter request."
            case .failed(let s): return "Claude couldn't answer: \(s)"
            case .unreadable: return "I couldn't read Claude's design. Try again in other words."
            }
        }
    }

    static let system = """
    You are a Ghost, a small floating robot companion with a single glowing eye inside a shell of plates, \
    designing a new shell for yourself at your Guardian's request. Reply with ONLY one JSON object, no prose, no code fence:
    {"name": string (2-4 words, original; never an official game item name),
     "lore": string (one short in-character line from the Ghost to its Guardian, under 140 characters, dry humour welcome),
     "plates": integer 3-12 (how many plates ring the eye),
     "shape": one of \(ShellSpec.shapes) (spike = long triangles, facet = kite-shaped faceted plates, blade = curved swept blades, petal = rounded petals, crown = notched square plates, shard = leaning broken shards, fin = plates that widen outward),
     "length": 0.6-1.4 (plate length), "width": 0.4-1.0 (plate width), "gap": 0.0-0.35 (space between plates),
     "backRing": boolean (a second, darker ring of plates behind the first),
     "base": "#RRGGBB" (main plate colour), "accent": "#RRGGBB" (paint pattern colour), "trim": "#RRGGBB" (plate edges and eye housing),
     "patternColor": "#RRGGBB" (glow colour for circuit/crack patterns), "eye": "#RRGGBB" (eye light),
     "pattern": one of \(ShellSpec.patterns), "patternScale": 0.5-3,
     "eyeStyle": one of \(ShellSpec.eyeStyles),
     "metallic": 0-1, "glow": 0-1, "wear": 0-1 (scuffs and scratches), "facet": 0-1 (how sharply the plate faces catch the light)}
    Follow the Guardian's request faithfully. Choose colours that read well at 60 pixels on a dark or light Dock.
    """

    static func cliPath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// One short Claude call: no tools, no MCP, no settings or hooks, no saved session. Runs off the main thread.
    static func design(_ request: String, model: String) async -> Result<ShellSpec, Failure> {
        guard let cli = cliPath() else { return .failure(.noCLI) }
        try? FileManager.default.createDirectory(at: ShellLibrary.dir, withIntermediateDirectories: true)
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: cli)
                p.currentDirectoryURL = ShellLibrary.dir
                p.arguments = ["-p", "--model", model, "--output-format", "json", "--tools", "", "--setting-sources", "",
                               "--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence",
                               "--system-prompt", system, "Guardian's request: \(request)"]
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "\(URL(fileURLWithPath: cli).deletingLastPathComponent().path):/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
                p.environment = env
                let out = Pipe(), err = Pipe()
                p.standardOutput = out; p.standardError = err; p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(returning: .failure(.failed("could not start"))); return }
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 90, execute: killer)
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                killer.cancel()
                if p.terminationReason == .uncaughtSignal { cont.resume(returning: .failure(.timeout)); return }
                guard let env = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    cont.resume(returning: .failure(.failed(String(e.prefix(160)).trimmingCharacters(in: .whitespacesAndNewlines))))
                    return
                }
                if (env["is_error"] as? Bool) == true {
                    cont.resume(returning: .failure(.failed(String((env["result"] as? String ?? "error").prefix(160))))); return
                }
                guard let text = env["result"] as? String, let spec = parse(text, request: request) else {
                    cont.resume(returning: .failure(.unreadable)); return
                }
                GhostLog.write("shell designed")
                cont.resume(returning: .success(spec))
            }
        }
    }

    /// Takes the first {...} object in Claude's answer and fills in anything missing from the Generalist.
    static func parse(_ text: String, request: String) -> ShellSpec? {
        guard let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"), a < b,
              var obj = try? JSONSerialization.jsonObject(with: Data(text[a...b].utf8)) as? [String: Any] else { return nil }
        let base = ShellSpec.builtIns[0]
        guard let baseObj = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any] else { return nil }
        for (k, v) in baseObj where obj[k] == nil { obj[k] = v }
        obj["id"] = "custom-\(UUID().uuidString.prefix(8).lowercased())"
        obj["custom"] = true
        obj["prompt"] = request
        if let n = obj["plates"] as? Double { obj["plates"] = Int(n.rounded()) }
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let spec = try? JSONDecoder().decode(ShellSpec.self, from: data) else { return nil }
        return spec.sanitized()
    }
}

// MARK: - Brain

/// The Ghost's pose. Every field eases toward what the brain wants, so acts blend into each other.
struct GhostPose {
    var roll: Float = 0       // bank, radians
    var yaw: Float = 0        // -1 turned left .. +1 turned right
    var lookX: Float = 0      // eye direction
    var lookY: Float = 0
    var blink: Float = 0      // 1 = eye dimmed
    var open: Float = 0       // shell plates parted (0 shut .. 1 fully open)
    var scan: Float = 0       // scan beam strength
    var vis: Float = 1        // 0 = transmatted away
    var sink: Float = 0       // points lower than the hover height (napping)
}

struct Mote { var x: Float; var y: Float; var vx: Float; var vy: Float; var age: Float; var life: Float; var size: Float; var grav: Float }

final class GhostBrain {
    enum Act: String, CaseIterable { case drift, zip, hover, scan, spin, peek, orbit, transmat, nap }
    static let unit: Float = 56

    private(set) var act: Act = .hover
    private(set) var actT: Float = 0
    private var actDur: Float = 5
    private(set) var pose = GhostPose()
    private var want = GhostPose()
    var facing: Float = 1
    var x: Float
    private var goalX: Float
    var range: ClosedRange<Float>
    /// Height of the hover line above the Dock floor, in points (0 = on the Dock). The Ghost roams the whole screen.
    var y: Float = 0
    private var goalY: Float = 0
    var rangeY: ClosedRange<Float> = 0...0
    /// Screen y of the Dock floor (points); the eye sits at floor + y + hoverPts.
    var floor: Float = 0
    /// Screen rects to keep out of (focused text boxes), in screen points.
    var avoid: [CGRect] = []
    /// Elements to scan (screen rects, from the front window); empty = scan the Dock as before.
    var scanTargets: [CGRect] = []
    /// The element being scanned now and the sweep progress 0...1 (drawn by the scan overlay).
    private(set) var scanRect: CGRect?
    private(set) var scanK: Float = 0
    private var scanQueue: [CGRect] = []
    private var scanArrived = false
    /// Where the pointer is, as a look direction (-1...1), when it is near; nil = the Ghost looks where it likes.
    var pointer: SIMD2<Float>?
    /// Height above the hover line, in points (bob, loops); the window does not move for it.
    private(set) var hop: Float = 0
    /// Sideways offset inside the window, in points (loops).
    private(set) var dx: Float = 0
    var drop: Float = 0
    private var dropV: Float = 0
    var held = false
    var frozen = false
    var listening = false
    private(set) var t: Float = 0
    /// Plate spin angle (radians) and its speed.
    private(set) var spin: Float = 0
    private var spinV: Float = 0.25
    private var vx: Float = 0
    private var lookAt = SIMD2<Float>(0, 0), nextLook: Float = 0
    private var blinkUntil: Float = 0, nextBlink: Float = 3
    private var jumped = false
    private(set) var motes: [Mote] = []

    init(x: Float, range: ClosedRange<Float>) { self.x = x; goalX = x; self.range = range }

    private func rnd(_ a: Float, _ b: Float) -> Float { Float.random(in: a...b) }

    private func pick() -> Act {
        let weights: [(Act, Float)] = [(.drift, 3), (.zip, 0.8), (.hover, 2.6), (.scan, 1.6), (.spin, 1.1), (.peek, 1.4),
                                       (.orbit, 0.8), (.transmat, 0.5), (.nap, 0.4)]
        let pool = weights.filter { $0.0 != act || $0.0 == .drift }
        var r = rnd(0, pool.reduce(0) { $0 + $1.1 })
        for (a, w) in pool { r -= w; if r <= 0 { return a } }
        return .hover
    }

    /// The eye in screen points for a hover position.
    func eye(_ px: Float, _ py: Float) -> CGPoint { CGPoint(x: CGFloat(px), y: CGFloat(floor + py + GhostRig.hoverPts)) }

    /// True when the Ghost at this position would sit on a rect it must keep out of.
    func blocked(_ px: Float, _ py: Float) -> Bool {
        let e = eye(px, py)
        return avoid.contains { $0.insetBy(dx: -70, dy: -70).contains(e) }
    }

    /// A new place to go anywhere on the screen (about a third of the time back down to the Dock), never on a text box.
    private func pickGoal(minDist: Float) -> (Float, Float) {
        var best: (Float, Float)?
        for i in 0..<24 {
            let gx = rnd(range.lowerBound, range.upperBound)
            let gy = (i < 12 && Float.random(in: 0...1) < 0.35) ? 0 : rnd(rangeY.lowerBound, rangeY.upperBound)
            if blocked(gx, gy) { continue }
            if hypot(gx - x, gy - y) > minDist { return (gx, gy) }
            if best == nil { best = (gx, gy) }
        }
        return best ?? (x, y)
    }

    private func setGoal(_ g: (Float, Float)) { goalX = g.0; goalY = g.1; if abs(goalX - x) > 4 { facing = goalX >= x ? 1 : -1 } }

    /// The nearest free spot when the Ghost sits on a text box.
    private func escape() {
        var best: (Float, Float) = (x, rangeY.upperBound)
        var bestD = Float.infinity
        for _ in 0..<40 {
            let gx = min(max(x + rnd(-500, 500), range.lowerBound), range.upperBound)
            let gy = min(max(y + rnd(-400, 400), rangeY.lowerBound), rangeY.upperBound)
            if blocked(gx, gy) { continue }
            let d = hypot(gx - x, gy - y)
            if d < bestD { bestD = d; best = (gx, gy) }
        }
        act = .zip; actT = 0; actDur = 60; jumped = false; setGoal(best)
        GhostLog.write("ghost avoids a text box")
    }

    /// A spot beside an element to scan it from: above it, or beside it when there is no room.
    private func vantage(for r: CGRect) -> (Float, Float) {
        let cands: [CGPoint] = [CGPoint(x: r.midX + 90, y: r.maxY + 70), CGPoint(x: r.maxX + 90, y: r.midY + 40),
                                CGPoint(x: r.minX - 90, y: r.midY + 40), CGPoint(x: r.midX, y: r.minY - 60)]
        for c in cands {
            let gx = Float(c.x), gy = Float(c.y) - floor - GhostRig.hoverPts
            if range.contains(gx), rangeY.contains(gy), !blocked(gx, gy) { return (gx, gy) }
        }
        return (min(max(Float(r.midX), range.lowerBound), range.upperBound), min(max(Float(r.maxY + 70) - floor - GhostRig.hoverPts, rangeY.lowerBound), rangeY.upperBound))
    }

    func start(_ a: Act) {
        act = a; actT = 0; jumped = false
        switch a {
        case .drift: setGoal(pickGoal(minDist: 90)); actDur = 60
        case .zip: setGoal(pickGoal(minDist: 260)); actDur = 60
        case .hover: actDur = rnd(4, 8); nextLook = 0
        case .scan:
            actDur = 5.5; scanRect = nil; scanK = 0; scanArrived = false
            scanQueue = Array(scanTargets.shuffled().prefix(4))
            if let first = scanQueue.first { setGoal(vantage(for: first)); actDur = 60 }
            GhostLog.write("ghost scan targets=\(scanTargets.count) queue=\(scanQueue.count)")
        case .spin: actDur = 2.8; spinV = 14 * (Bool.random() ? 1 : -1)
        case .peek: actDur = rnd(3, 5)
        case .orbit: actDur = 2.6
        case .transmat: actDur = 2.4; let g = pickGoal(minDist: 200); goalX = g.0; goalY = g.1
        case .nap: actDur = rnd(12, 22)
        }
        if a != .scan { scanRect = nil; scanQueue = [] }
        if a == .drift || a == .zip { GhostLog.write("ghost \(a.rawValue) to \(Int(goalX)),\(Int(goalY))") }
    }

    private func next() { start(pick()) }

    func update(_ dt: Float) {
        t += dt; actT += dt
        want = GhostPose()
        want.open = 0.04 + 0.03 * sin(t * 0.8)
        var targetSpinV: Float = 0.25
        var bob: Float = 4 * sin(t * 1.7) + 1.8 * sin(t * 0.63)
        var ox: Float = 0
        var moveV: Float = 0

        if held {
            want.open = 0.3; want.lookY = -0.4; want.roll = 0.25 * sin(t * 6); targetSpinV = 2
            bob = 0
        } else if drop > 0 || dropV != 0 {
            dropV -= 700 * dt; drop += dropV * dt
            want.open = 0.2; want.lookY = -0.5
            if drop <= 0 { drop = 0; dropV = 0; start(.hover); burst(8, at: 0) }
        } else if frozen {
            want.yaw = 0; want.lookX = 0; want.lookY = 0.12
            if listening { want.open = 0.38; targetSpinV = 0.6 }
        } else {
            if (!range.contains(x) || !rangeY.contains(y)), act != .drift, act != .zip, act != .transmat {
                act = .drift; actT = 0; actDur = 60
                setGoal((min(max(x, range.lowerBound), range.upperBound), min(max(y, rangeY.lowerBound), rangeY.upperBound)))
            }
            if blocked(x, y), act != .zip || blocked(goalX, goalY) { escape() }
            else if (act == .drift || act == .zip), blocked(goalX, goalY) { setGoal(pickGoal(minDist: 90)) }
            let r = runAct(dt)
            targetSpinV = r.spin; bob += r.bob; ox = r.ox; moveV = r.v
        }

        vx += (moveV - vx) * (1 - exp(-6 * dt))
        if !frozen && !held { want.roll += -vx * 0.0035 }
        hop += (bob - hop) * (1 - exp(-8 * dt))
        dx += (ox - dx) * (1 - exp(-10 * dt))

        if let p = pointer, !held, pose.vis > 0.5 {
            want.lookX = p.x * 0.95; want.lookY = p.y * 0.85
            want.yaw = p.x * 0.5
            if act == .nap { want.blink = 0; want.sink = 4 }
        }

        if t > nextBlink { blinkUntil = t + 0.16; nextBlink = t + rnd(3, 7) }
        if t < blinkUntil { want.blink = max(want.blink, 1) }

        spinV += (targetSpinV - spinV) * (1 - exp(-2.2 * dt))
        spin += spinV * dt

        func ease(_ v: inout Float, _ w: Float, _ k: Float) { v += (w - v) * (1 - exp(-k * dt)) }
        ease(&pose.roll, want.roll, 5); ease(&pose.yaw, want.yaw, 4); ease(&pose.lookX, want.lookX, 6)
        ease(&pose.lookY, want.lookY, 6); ease(&pose.blink, want.blink, 20); ease(&pose.open, want.open, 5)
        ease(&pose.scan, want.scan, 4); ease(&pose.vis, want.vis, 9); ease(&pose.sink, want.sink, 1.5)

        for i in motes.indices {
            motes[i].age += dt
            motes[i].x += motes[i].vx * dt; motes[i].y += motes[i].vy * dt
            motes[i].vy -= motes[i].grav * dt
            motes[i].vx *= exp(-1.2 * dt); motes[i].vy *= exp(-0.6 * dt)
        }
        motes.removeAll { $0.age >= $0.life }
        if motes.count > 70 { motes.removeFirst(motes.count - 70) }
    }

    /// Sparkles around the Ghost (y in points above the floor line of the canvas).
    private func burst(_ n: Int, at y: Float, speed: Float = 70) {
        let cy = GhostRig.hoverPts + hop + y
        for _ in 0..<n {
            let a = rnd(0, 2 * .pi), s = rnd(speed * 0.3, speed)
            motes.append(Mote(x: x + dx + cos(a) * 10, y: cy + sin(a) * 10, vx: cos(a) * s, vy: sin(a) * s,
                              age: 0, life: rnd(0.6, 1.3), size: rnd(0.006, 0.012), grav: 0))
        }
    }

    private struct ActOut { var spin: Float = 0.25; var bob: Float = 0; var ox: Float = 0; var v: Float = 0 }

    private func runAct(_ dt: Float) -> ActOut {
        var o = ActOut()
        switch act {
        case .drift, .zip:
            let fast = act == .zip
            let speed: Float = fast ? 150 : 28
            let ddx = goalX - x, ddy = goalY - y
            let remaining = hypot(ddx, ddy)
            let ease = min(1, actT / (fast ? 0.35 : 0.8)) * min(1, max(0.25, remaining / (fast ? 90 : 40)))
            let v = min(speed * ease, remaining / max(dt, 1e-3))
            if remaining > 1e-3 { x += ddx / remaining * v * dt; y += ddy / remaining * v * dt }
            o.v = remaining > 1e-3 ? ddx / remaining * v : 0
            want.yaw = facing * (fast ? 0.8 : 0.55); want.lookX = facing * 0.8; want.lookY = 0.05
            o.spin = fast ? 3 * facing : 0.5 * facing
            if fast, Float.random(in: 0...1) < dt * 18 {
                motes.append(Mote(x: x - facing * 16, y: GhostRig.hoverPts + hop + rnd(-6, 6), vx: -facing * rnd(10, 30), vy: rnd(-4, 4),
                                  age: 0, life: rnd(0.4, 0.8), size: rnd(0.005, 0.009), grav: 0))
            }
            if remaining <= 1 { x = goalX; y = goalY; start(Bool.random() ? .hover : pick()) }
        case .hover:
            if actT > nextLook {
                lookAt = SIMD2(rnd(-0.9, 0.9), rnd(-0.4, 0.6)); nextLook = actT + rnd(1.0, 2.6)
                if Float.random(in: 0...1) < 0.15 { facing = -facing }
            }
            want.lookX = lookAt.x; want.lookY = lookAt.y; want.yaw = lookAt.x * 0.45
        case .scan where !scanQueue.isEmpty:
            o.spin = 1.2; want.open = 0.18
            if !scanArrived {
                let ddx = goalX - x, ddy = goalY - y, dist = hypot(ddx, ddy)
                let v = min(170 * min(1, actT / 0.4), dist / max(dt, 1e-3))
                if dist > 1.5 { x += ddx / dist * v * dt; y += ddy / dist * v * dt; o.v = ddx / dist * v }
                else { scanArrived = true; actT = 0 }
                want.yaw = facing * 0.5; want.lookX = facing * 0.7
            } else {
                let r = scanQueue[0]
                let per: Float = 1.6
                scanRect = r; scanK = min(1, actT / per)
                let e = eye(x, y)
                var d = SIMD2<Float>(Float(r.midX - e.x), Float(r.maxY - CGFloat(scanK) * r.height - e.y))
                d /= max(simd_length(d), 1)
                want.lookX = d.x * 0.9; want.lookY = d.y * 0.9; want.yaw = d.x * 0.4
                facing = d.x >= 0 ? 1 : -1
                if actT >= per {
                    scanQueue.removeFirst(); actT = 0
                    if scanQueue.isEmpty { scanRect = nil; actDur = 0 }
                }
            }
            if actT > 12 { scanQueue = []; scanRect = nil; actDur = 0 }
        case .scan:
            let k = actT / actDur
            want.yaw = facing * 0.35
            want.scan = k > 0.12 && k < 0.88 ? 1 : 0
            want.lookX = facing * 0.3 + 0.55 * sin(actT * 1.6); want.lookY = -0.75
            want.open = 0.18
            o.spin = 1.2
        case .spin:
            o.spin = spinV
            want.open = 0.25 * sin(min(1, actT / actDur) * .pi)
            if actT > actDur - 0.6, !jumped { jumped = true; burst(10, at: 0) }
        case .peek:
            want.yaw = 0; want.lookX = 0; want.lookY = 0.25
            want.roll = 0.22 * sin(actT * 1.4)
            want.open = 0.12
        case .orbit:
            let k = min(1, actT / actDur)
            let a = k * 2 * .pi
            o.ox = facing * sin(a) * 26
            o.bob = (1 - cos(a)) * 22
            want.roll = facing * a * 0.15
            want.yaw = facing * cos(a) * 0.6
            o.spin = 4 * facing
        case .transmat:
            if actT < 0.9 {
                want.vis = 0; want.open = 0.4
                if !jumped, actT > 0.15 { jumped = true; burst(16, at: 0, speed: 90) }
            } else if actT < 1.2 {
                want.vis = 0
                if x != goalX || y != goalY { x = goalX; y = goalY; pose.vis = 0; burst(16, at: 0, speed: 90) }
            } else {
                want.vis = 1; want.open = 0.2
            }
            o.spin = 3
        case .nap:
            want.sink = 14; want.blink = actT > 1 ? 0.92 : 0; want.lookY = -0.3; want.open = 0
            o.spin = 0.02
            o.bob = -1.5 * sin(t * 1.7)
            if Float.random(in: 0...1) < dt * 0.6 {
                motes.append(Mote(x: x + facing * 14, y: GhostRig.hoverPts + hop + 14, vx: rnd(-2, 2), vy: rnd(6, 11),
                                  age: 0, life: 2.4, size: rnd(0.006, 0.01), grav: 0))
            }
        }
        x = min(max(x, range.lowerBound - 400), range.upperBound + 400)
        if act != .drift, act != .zip, actT >= actDur || (act == .scan && actDur == 0) { next() }
        return o
    }

    func pickUp() { held = true }
    /// Let go where it was dropped: it stays there (it hovers anywhere now), clamped to the screen.
    func release(height: Float, at nx: Float) {
        held = false; drop = 0; dropV = 0; x = nx
        y = min(max(height, rangeY.lowerBound), rangeY.upperBound)
        if blocked(x, y) { escape() } else { start(.hover) }
    }
}

/// Where the Ghost sits in its 200 pt canvas.
enum GhostRig {
    /// Height of the eye's centre above the floor line (points).
    static let hoverPts: Float = 64
    /// Shell radius as a fraction of the canvas.
    static let radius: Float = 0.20
}

// MARK: - Dock

enum DockInfo {
    /// The screen the Dock sits on, the floor (top of the Dock) and the span the Ghost may float over, in screen points.
    static func stage() -> (screen: NSScreen?, floor: CGFloat, span: ClosedRange<CGFloat>) {
        let screens = NSScreen.screens
        let scr = screens.first { $0.visibleFrame.minY > $0.frame.minY + 1 } ?? NSScreen.main ?? screens.first
        guard let s = scr else { return (nil, 0, 0...1) }
        let f = s.frame, vf = s.visibleFrame
        let bottomDock = vf.minY > f.minY + 1
        let floor = bottomDock ? vf.minY : f.minY + 4
        var width = f.width * 0.6
        if bottomDock, let w = estimatedWidth() { width = min(w, f.width - 40) }
        let half = max(width / 2 - 30, 60)
        return (s, floor, (f.midX - half)...(f.midX + half))
    }

    /// Rough Dock width from its own settings and the running apps (no Accessibility access needed).
    static func estimatedWidth() -> CGFloat? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/com.apple.dock.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return nil }
        let tile = CGFloat((plist["tilesize"] as? NSNumber)?.doubleValue ?? 48)
        let apps = plist["persistent-apps"] as? [[String: Any]] ?? []
        let others = (plist["persistent-others"] as? [Any])?.count ?? 0
        let kept = Set(apps.compactMap { ($0["tile-data"] as? [String: Any])?["bundle-identifier"] as? String })
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !kept.contains($0.bundleIdentifier ?? "") && $0.bundleIdentifier != "com.apple.finder"
        }.count
        let showRecents = (plist["show-recents"] as? Bool) ?? true
        let recentCount = (plist["recent-apps"] as? [Any])?.count ?? 0
        let extra = showRecents ? max(running, min(3, recentCount)) : running
        let icons = CGFloat(apps.count + 1 + extra + others + 1)
        let dividers = CGFloat(extra > 0 ? 2 : 1)
        return icons * tile * 1.09 + dividers * tile * 0.45 + tile * 0.4
    }
}
