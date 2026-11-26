// SwiftUI views: the panel (menu bar and floating), cards, charts, settings, hover bubble, badge.
// House defaults: follow the system light/dark setting, calm teal with an amber accent, SF Pro, balanced spacing.

import AppKit
import Charts
import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
    static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { ap in
            let h = ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((h >> 16) & 255) / 255, green: CGFloat((h >> 8) & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: 1)
        })
    }
}

enum Ink {
    static let teal = Color.dyn(0x2F6F8F, 0x5FA8C9)
    static let sky = Color.dyn(0x5FA8C9, 0x7FC0DB)
    static let amber = Color.dyn(0xC7831F, 0xF0B357)
    static let coral = Color.dyn(0xC15F3C, 0xE8875F)
    static let ok = Color.dyn(0x2E8B6A, 0x4FB38A)

    static func mood(_ m: Mood) -> Color {
        switch m {
        case .calm: return teal
        case .call: return amber
        case .burning: return coral
        case .needs: return amber
        }
    }
}

// MARK: - Panel

struct PanelView: View {
    @ObservedObject var store: Store
    var floating = false

    var body: some View {
        let s = store.snap
        VStack(spacing: 0) {
            header(s)
            if store.showSettings {
                SettingsPane(store: store)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ShellsCard(store: store, shells: store.shells)
                        StatStrip(s: s)
                        if !s.needs.isEmpty {
                            SectionBlock(title: "Needs you now", tint: Ink.amber) {
                                ForEach(s.needs) { ItemCard(item: $0, store: store) }
                            }
                        }
                        if !s.hotBurns.isEmpty {
                            SectionBlock(title: "Working while you're away", tint: Ink.coral) {
                                ForEach(s.hotBurns) { BurnCard(item: $0, store: store) }
                            }
                        }
                        if !s.calls.isEmpty {
                            SectionBlock(title: "Your call", tint: Ink.amber) {
                                ForEach(s.calls) { ItemCard(item: $0, store: store) }
                            }
                        }
                        if !s.reviews.isEmpty {
                            SectionBlock(title: "Ready to review", tint: Ink.teal) {
                                ForEach(s.reviews) { ItemCard(item: $0, store: store) }
                            }
                        }
                        let quiet = s.burns.filter { !$0.active }
                        if !quiet.isEmpty {
                            SectionBlock(title: "Worked on its own · last 24 h", tint: Ink.coral) {
                                VStack(spacing: 0) {
                                    ForEach(quiet) { QuietBurnRow(item: $0) }
                                }
                                .modifier(CardBackground(tint: Ink.coral))
                            }
                        }
                        if s.needs.isEmpty && s.calls.isEmpty && s.hotBurns.isEmpty && s.scanned {
                            QuietCard()
                        }
                        TodayChart(s: s)
                        if !store.todos.isEmpty {
                            SectionBlock(title: "To do · \(store.todoList)", tint: Ink.teal) {
                                TodoList(items: store.todos)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
                .scrollIndicators(.never)
            }
            footer
        }
        .frame(width: 404, height: 640)
        .modifier(GlassIfFloating(on: floating, tint: Ink.mood(s.mood)))
    }

    private func header(_ s: Snapshot) -> some View {
        HStack(spacing: 14) {
            OrbView(mood: s.mood, shellId: store.shells.currentId)
                .frame(width: 62, height: 62)
            VStack(alignment: .leading, spacing: 4) {
                Text(Voice.headline(s))
                    .font(.system(size: 17, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                Text(Voice.subline(s))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .background(
            LinearGradient(colors: [Ink.mood(s.mood).opacity(0.16), .clear], startPoint: .top, endPoint: .bottom)
                .animation(.easeInOut(duration: 0.8), value: s.mood)
        )
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if let until = store.snoozeUntil, until > Date() {
                Button { store.snooze(0) } label: {
                    Label("Snoozed until \(until.formatted(date: .omitted, time: .shortened))", systemImage: "bell.slash.fill")
                }
                .help("Turn reminders back on")
            } else {
                Menu {
                    Button("30 minutes") { store.snooze(1800) }
                    Button("1 hour") { store.snooze(3600) }
                    Button("3 hours") { store.snooze(3 * 3600) }
                } label: { Label("Snooze", systemImage: "bell.slash") }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            Spacer()
            Button { withAnimation(.snappy) { store.showSettings.toggle() } } label: {
                Image(systemName: store.showSettings ? "xmark.circle" : "gearshape")
            }
            .help(store.showSettings ? "Close settings" : "Settings")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .help("Quit Ghost")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(.quaternary.opacity(0.25))
    }
}

private struct GlassIfFloating: ViewModifier {
    let on: Bool
    let tint: Color
    func body(content: Content) -> some View {
        if on {
            content
                .background(.regularMaterial.opacity(0.55), in: .rect(cornerRadius: 26, style: .continuous))
                .glassEffect(.regular.tint(tint.opacity(0.06)), in: .rect(cornerRadius: 26, style: .continuous))
                .clipShape(.rect(cornerRadius: 26, style: .continuous))
        } else {
            content
        }
    }
}

// MARK: - Pieces

struct SectionBlock<Content: View>: View {
    let title: String
    let tint: Color
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 6, height: 6)
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
            }
            content
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

struct CardBackground: ViewModifier {
    var tint: Color = .primary
    func body(content: Content) -> some View {
        content
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(tint.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(tint.opacity(0.12), lineWidth: 1))
    }
}

struct StatStrip: View {
    let s: Snapshot
    var body: some View {
        HStack(spacing: 8) {
            tile(value: "\(s.waitingCount)", label: "waiting on you", tint: s.waitingCount > 0 ? Ink.amber : Ink.teal)
            tile(value: Voice.tokens(s.hotBurns.reduce(0) { $0 + $1.burn.total }), label: "used while away", tint: s.hotBurns.isEmpty ? Ink.teal : Ink.coral)
            tile(value: share, label: "ran on its own", tint: Ink.sky)
        }
    }
    private var share: String {
        let t = s.todayOwner + s.todayAuto
        return t == 0 ? "–" : "\(Int((Double(s.todayAuto) / Double(t) * 100).rounded()))%"
    }
    private func tile(value: String, label: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
                .contentTransition(.numericText())
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .padding(.horizontal, 11)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.08)))
    }
}

struct ItemCard: View {
    let item: Item
    @ObservedObject var store: Store
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            ZStack {
                Circle().fill(tint.opacity(0.16))
                Image(systemName: icon).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(tint)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(2)
                Text(meta)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if let ask = item.ask {
                    Text(ask).font(.system(size: 12)).lineLimit(4).padding(.top, 2)
                } else if let d = item.detail, item.kind == .call || item.kind == .review {
                    Text(d).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3).padding(.top, 2)
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 8) {
                Button("Open") { store.openClaude(item.localId) }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                if item.kind == .call || item.kind == .review {
                    Button { store.dismiss(item) } label: { Image(systemName: "checkmark") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.tertiary)
                        .help("Mark as handled")
                        .opacity(hover ? 1 : 0.5)
                }
            }
        }
        .modifier(CardBackground(tint: tint))
        .scaleEffect(hover ? 1.01 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hover)
        .onHover { hover = $0 }
    }

    private var tint: Color {
        switch item.kind {
        case .approve, .answer, .call: return Ink.amber
        case .review: return Ink.teal
        case .burn: return Ink.coral
        }
    }
    private var icon: String {
        switch item.kind {
        case .approve: return "hand.raised.fill"
        case .answer: return "questionmark.bubble.fill"
        case .call: return "signpost.right.fill"
        case .review: return "eye.fill"
        case .burn: return "flame.fill"
        }
    }
    private var meta: String {
        var p: [String] = []
        if !item.project.isEmpty { p.append(item.project) }
        switch item.kind {
        case .approve: p.append("waiting for approval \(Voice.ago(item.since))")
        case .answer: p.append("waiting for an answer \(Voice.ago(item.since))")
        default: p.append(Voice.ago(item.since) + " ago")
        }
        return p.joined(separator: " · ")
    }
}

struct BurnCard: View {
    let item: Item
    @ObservedObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                    Text("you left it \(Voice.ago(item.since)) ago" + (item.project.isEmpty ? "" : " · \(item.project)"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open") { store.openClaude(item.localId) }.buttonStyle(.glass).controlSize(.small)
            }
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(Voice.tokens(item.burn.total))
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Ink.coral)
                        .contentTransition(.numericText())
                    Text("tokens · \(item.burnTurns) turn\(item.burnTurns == 1 ? "" : "s") · \(Voice.tokens(item.burn.fresh)) new")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                Chart {
                    ForEach(Array(item.buckets.enumerated()), id: \.offset) { i, v in
                        BarMark(x: .value("t", i), y: .value("tokens", v), width: .ratio(0.62))
                            .foregroundStyle(LinearGradient(colors: [Ink.coral, Ink.amber.opacity(0.7)], startPoint: .bottom, endPoint: .top))
                            .cornerRadius(2)
                    }
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 40)
                .help("Tokens used on its own, in 15-minute steps over the last 3 hours")
            }
            FlowChips(chips: chips)
        }
        .modifier(CardBackground(tint: Ink.coral))
    }

    private var chips: [(String, String)] {
        var c: [(String, String)] = []
        if let t = item.timer { c.append(("timer", "Timer · \(t)")) }
        if item.loop { c.append(("arrow.triangle.2.circlepath", "Self-paced loop")) }
        for o in item.causes where !(o == .timer && item.timer != nil) {
            c.append((icon(o), o.chip))
        }
        if !item.active { c.append(("moon.zzz", "Quiet now")) }
        return c
    }
    private func icon(_ o: Origin) -> String {
        switch o {
        case .timer: return "timer"
        case .peer: return "bubble.left.and.bubble.right"
        case .task: return "gearshape.2"
        case .app: return "app.badge"
        case .sdk: return "arrow.turn.down.right"
        default: return "bolt"
        }
    }
}

struct QuietBurnRow: View {
    let item: Item
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "flame").font(.system(size: 12)).foregroundStyle(Ink.coral.opacity(0.7)).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Text("\(item.burnTurns) turn\(item.burnTurns == 1 ? "" : "s") · \(item.causes.map { $0.chip }.joined(separator: ", ")) · stopped \(item.lastAuto.map { Voice.ago($0) } ?? "") ago")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(Voice.tokens(item.burn.total))
                .font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(Ink.coral)
        }
        .padding(.vertical, 5)
    }
}

struct FlowChips: View {
    let chips: [(String, String)]
    var body: some View {
        HStack(spacing: 6) {
            ForEach(chips.prefix(4), id: \.1) { c in
                Label(c.1, systemImage: c.0)
                    .font(.system(size: 10.5, weight: .medium))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
            }
        }
        .labelStyle(.titleAndIcon)
    }
}

struct QuietCard: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 22))
                .foregroundStyle(Ink.ok)
                .symbolEffect(.bounce, options: .nonRepeating)
            VStack(alignment: .leading, spacing: 2) {
                Text("You're clear.").font(.system(size: 13.5, weight: .semibold))
                Text("No session is waiting on you, and none is spending tokens on its own. I'll tell you if that changes.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .modifier(CardBackground(tint: Ink.ok))
    }
}

struct TodayChart: View {
    let s: Snapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(Ink.sky).frame(width: 6, height: 6)
                Text("LAST 24 HOURS").font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
                Spacer()
                legend("You", Ink.teal)
                legend("On its own", Ink.coral)
            }
            Chart(s.hours) { p in
                AreaMark(x: .value("Hour", p.hour, unit: .hour), y: .value("Tokens", p.value), stacking: .standard)
                    .foregroundStyle(by: .value("Who", p.who))
                    .interpolationMethod(.catmullRom)
            }
            .chartForegroundStyleScale(domain: ["You", "On its own"], range: [
                LinearGradient(colors: [Ink.teal.opacity(0.85), Ink.sky.opacity(0.25)], startPoint: .top, endPoint: .bottom),
                LinearGradient(colors: [Ink.coral.opacity(0.9), Ink.amber.opacity(0.3)], startPoint: .top, endPoint: .bottom),
            ])
            .chartLegend(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                    AxisValueLabel { if let d = v.as(Double.self) { Text(Voice.tokens(Int(d))).font(.system(size: 9)) } }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                    AxisValueLabel(format: .dateTime.hour()).font(.system(size: 9))
                }
            }
            .frame(height: 116)
            Text(caption).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .modifier(CardBackground(tint: Ink.sky))
    }
    private var caption: String {
        let t = s.todayOwner + s.todayAuto
        guard t > 0 else { return "No tokens used in the last 24 hours." }
        return "\(Voice.tokens(t)) tokens in total, \(Voice.tokens(s.todayAuto)) of them on its own (timers, other sessions, background tasks). Cache re-reads are most of it."
    }
    private func legend(_ t: String, _ c: Color) -> some View {
        HStack(spacing: 4) { RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 8, height: 8); Text(t).font(.system(size: 10)).foregroundStyle(.secondary) }
    }
}

struct TodoList: View {
    let items: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(items.prefix(6).enumerated()), id: \.offset) { _, t in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "circle").font(.system(size: 11)).foregroundStyle(Ink.teal).padding(.top, 2)
                    Text(t).font(.system(size: 12.5)).lineLimit(2)
                }
            }
            if items.count > 6 {
                Text("and \(items.count - 6) more in Reminders").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(CardBackground(tint: Ink.teal))
    }
}

// MARK: - Settings

struct SettingsPane: View {
    @ObservedObject var store: Store
    var body: some View {
        Form {
            Section("Presence") {
                Toggle("Show the Ghost on the Dock", isOn: $store.showOrb)
                LabeledContent("Summon or dismiss", value: Hotkeys.summonLabel)
                LabeledContent("Open the panel", value: Hotkeys.panelLabel)
                Toggle("Open Ghost when I log in", isOn: $store.launchAtLogin)
            }
            Section("Shell designer") {
                Picker("Claude model", selection: $store.designModel) {
                    Text("Haiku (fast, cheapest)").tag("haiku")
                    Text("Sonnet (richer designs)").tag("sonnet")
                    Text("Opus (most careful)").tag("opus")
                }
                Text("Asking the Ghost for a shell makes one short call to Claude through your local claude command (no tools, nothing saved). Everything else stays on this Mac.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section("Reminders") {
                Toggle("Send notifications", isOn: $store.notify)
                Stepper("Needs-you reminder every \(store.needEvery) min", value: $store.needEvery, in: 2...60, step: 2)
                Stepper("Your-call reminder every \(store.callEvery) min", value: $store.callEvery, in: 15...240, step: 15)
            }
            Section("Working while you're away") {
                Stepper("You're away after \(store.awayMin) min", value: $store.awayMin, in: 5...120, step: 5)
                Picker("Alert at", selection: $store.alertTokens) {
                    Text("250k tokens").tag(250_000)
                    Text("500k tokens").tag(500_000)
                    Text("1M tokens").tag(1_000_000)
                    Text("2M tokens").tag(2_000_000)
                    Text("5M tokens").tag(5_000_000)
                }
            }
            Section("To do") {
                TextField("Reminders list", text: $store.todoList)
                if !store.todoAccess {
                    Text("Ghost has no access to Reminders. Turn it on in System Settings › Privacy & Security › Reminders.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Section {
                Text("Ghost reads Claude's local session files and never changes them. Only the shell designer uses AI, and only when you ask. A fan tribute; not affiliated with Bungie.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Orb window pieces

struct BadgeView: View {
    @ObservedObject var store: Store
    var body: some View {
        let n = store.snap.waitingCount
        ZStack(alignment: .topTrailing) {
            Color.clear
            if n > 0 {
                Text("\(n)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.black.opacity(0.8))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color(hex: 0xF0B357)))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.6), lineWidth: 1))
                    .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                    .padding(14)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.6), value: n)
        .allowsHitTesting(false)
    }
}

/// A Claude notification, shown by the Ghost beside it instead of a macOS banner.
struct MessageCard: View {
    let title: String
    let text: String
    let open: () -> Void
    let snooze: () -> Void
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 8)
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Dismiss")
            }
            Text(text).font(.system(size: 12)).lineLimit(4).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Open", action: open).controlSize(.small).buttonStyle(.borderedProminent)
                Button("Snooze 30 min", action: snooze).controlSize(.small)
            }
        }
        .frame(width: 260, alignment: .leading)
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .padding(6)
    }
}

struct BubbleView: View {
    @ObservedObject var store: Store
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Voice.headline(store.snap)).font(.system(size: 13, weight: .semibold))
            Text("Click to open · drag to move").font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .glassEffect(.regular, in: .capsule)
        .fixedSize()
        .padding(6)
    }
}


// MARK: - Shells: pick one, or ask the Ghost for a new one

/// Thumbnails rendered once per shell (still, slightly open).
@MainActor
enum ShellThumbs {
    private static var cache: [String: NSImage] = [:]
    static func image(_ s: ShellSpec) -> NSImage? {
        if let i = cache[s.id] { return i }
        guard let cg = SceneRenderer.renderShell(s, size: 132, open: 0.06, spin: 0.25) else { return nil }
        let i = NSImage(cgImage: cg, size: NSSize(width: 66, height: 66))
        cache[s.id] = i
        return i
    }
}

struct ShellsCard: View {
    @ObservedObject var store: Store
    @ObservedObject var shells: ShellLibrary
    @State private var prompt = ""
    @FocusState private var focused: Bool

    var body: some View {
        SectionBlock(title: "Shell · \(shells.current.name)", tint: Ink.sky) {
            VStack(alignment: .leading, spacing: 10) {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(shells.all) { s in
                                ShellTile(spec: s, selected: s.id == shells.currentId)
                                    .id(s.id)
                                    .onTapGesture { shells.currentId = s.id }
                                    .contextMenu {
                                        Button("Wear") { shells.currentId = s.id }
                                        if s.isCustom { Button("Delete", role: .destructive) { shells.remove(s.id) } }
                                    }
                                    .help(s.prompt.map { "\(s.name) · “\($0)”" } ?? s.name)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .scrollIndicators(.never)
                    .onAppear { proxy.scrollTo(shells.currentId, anchor: .center) }
                    .onChange(of: shells.currentId) { _, id in withAnimation { proxy.scrollTo(id, anchor: .center) } }
                }
                HStack(spacing: 8) {
                    TextField("Ask your Ghost for a new shell…", text: $prompt, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...3)
                        .focused($focused)
                        .onSubmit(send)
                        .disabled(store.designing)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 9).fill(.primary.opacity(0.06)))
                    if store.designing {
                        ProgressView().controlSize(.small).frame(width: 28)
                    } else {
                        Button(action: send) { Image(systemName: "sparkles") }
                            .buttonStyle(.glass)
                            .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty)
                            .help("Claude designs it; the Ghost wears it")
                    }
                }
                Text(store.ghostLine.isEmpty ? "“\(shells.current.lore)”" : store.ghostLine)
                    .font(.system(size: 11.5).italic())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .modifier(CardBackground(tint: Ink.sky))
        }
        .onAppear { focused = true }
    }

    private func send() {
        let p = prompt
        guard !p.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        store.designShell(p)
        prompt = ""
    }
}

struct ShellTile: View {
    let spec: ShellSpec
    let selected: Bool
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let img = ShellThumbs.image(spec) { Image(nsImage: img).resizable() } else { Color.clear }
            }
            .frame(width: 58, height: 58)
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: 0x0E1420).opacity(0.85)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Ink.sky : .white.opacity(0.08), lineWidth: selected ? 2 : 1))
            if spec.isCustom {
                Image(systemName: "sparkles").font(.system(size: 9, weight: .bold)).foregroundStyle(Ink.amber).padding(5)
            }
        }
    }
}
