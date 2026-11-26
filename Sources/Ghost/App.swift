// Ghost: a small floating companion on the Mac (a fan tribute to the Destiny Ghost) that tells the owner when a
// Claude session needs them, when a decision is waiting, and when an idle session spends tokens on its own.
// Its shell can be swapped, and a new one designed by asking the Ghost in its panel (Claude writes the spec).
//
//   Ghost              run the app (menu bar glyph + the Ghost over the Dock)
//   Ghost --dump       print one scan to the terminal and exit (for checks)
//   Ghost --icon P     render the app icon PNG to path P and exit
//   Ghost --sheet D    write contact sheets (acts, activation, every shell) to folder D
//   Ghost --say [T] [B] show a message through the running Ghost (reads Claude Code hook JSON on stdin if no args)
//   Ghost --design "…" ask Claude for a shell spec, print it as JSON and exit (no app state changed)

import AppKit
import Combine
import SwiftUI
import simd
import UserNotifications

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--dump") { Dump.run(); return }
        if let i = args.firstIndex(of: "--icon"), i + 1 < args.count { IconMaker.run(path: args[i + 1]); return }
        if let i = args.firstIndex(of: "--sheet"), i + 1 < args.count { GhostSheet.run(dir: args[i + 1]); return }
        if let i = args.firstIndex(of: "--design"), i + 1 < args.count { DesignCLI.run(args[i + 1]); return }
        if let i = args.firstIndex(of: "--say") { SayCLI.run(Array(args[(i + 1)...])); return }
        GhostApp.main()
    }
}

struct GhostApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        MenuBarExtra {
            PanelView(store: delegate.store)
        } label: {
            MenuLabel(store: delegate.store)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuLabel: View {
    @ObservedObject var store: Store
    var body: some View {
        let n = store.snap.waitingCount
        let hot = !store.snap.hotBurns.isEmpty
        HStack(spacing: 2) {
            Image(nsImage: SparkGlyph.image(bold: n > 0 || hot))
            if n > 0 { Text("\(n)") }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let store = Store()
    private var orb: OrbWindowController?
    private var hotkeys: Hotkeys?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        store.requestNotifications()
        store.onShowOrb = { [weak self] show in self?.setOrb(show) }
        store.onPulse = { [weak self] n in self?.orb?.pulse(n) }
        store.onSay = { [weak self] t, b, id in
            guard let orb = self?.orb else { return false }
            orb.say(title: t, body: b, localId: id); return true
        }
        // Claude notifications from outside (the Claude Code Notification hook runs `Ghost --say`): shown by the Ghost.
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("local.ghostshell.say"), object: nil, queue: .main) { [weak self] n in
            let raw = n.object as? String ?? ""
            Task { @MainActor in self?.store.say(raw) }
        }
        setOrb(store.showOrb)
        store.start()
        // Test hook: `notifyutil`-style distributed note toggles the panel (no data in it, nothing returned).
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("local.ghostshell.toggle"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.orb?.toggleDetail() }
        }
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("local.ghostshell.act"), object: nil, queue: .main) { [weak self] n in
            let name = n.object as? String
            Task { @MainActor in self?.orb?.act(name) }
        }
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("local.ghostshell.mood"), object: nil, queue: .main) { [weak self] n in
            let name = n.object as? String
            Task { @MainActor in self?.orb?.force(name) }
        }
        // Test hook: ask the designer from outside (same path as the panel's box): swift tools/design.swift "a shell of autumn leaves"
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("local.ghostshell.design"), object: nil, queue: .main) { [weak self] n in
            let text = n.object as? String
            Task { @MainActor in if let text { self?.store.designShell(text) } }
        }
        hotkeys = Hotkeys(summon: { [weak self] in self?.summon() }, panel: { [weak self] in self?.summonPanel() })
        GhostLog.write("launch")
    }

    /// ⌃⌥G: bring the Ghost to the Dock (it transmats in), or send it away if it is there.
    func summon() {
        if store.showOrb { store.showOrb = false; return }
        store.showOrb = true
        orb?.act("transmat")
    }

    /// ⌃⌥⇧G: open or close the panel, summoning the Ghost first if it is away.
    func summonPanel() {
        if !store.showOrb { store.showOrb = true }
        orb?.toggleDetail()
    }

    private func setOrb(_ show: Bool) {
        if show, orb == nil { orb = OrbWindowController(store: store) }
        if !show { orb?.close(); orb = nil }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let localId = response.notification.request.content.userInfo["localId"] as? String
        Task { @MainActor in
            if action == "snooze" { self.store.snooze(1800) } else { self.store.openClaude(localId) }
        }
        completionHandler()
    }
}

// MARK: - Floating orb

/// The orb's root view: handles click, drag and hover itself, so its subviews never take the mouse.
final class OrbContainer: NSView {
    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var onMoved: (() -> Void)?
    var onDragStart: (() -> Void)?
    /// The clickable part of the view (the fox or the orb), in view coordinates; nil = most of the view.
    var hitRect: (() -> NSRect?)?
    private var inside = false
    private var downAt: NSPoint?
    private var originAtDown: NSPoint?
    private var dragged = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return clickable.contains(local) ? self : nil
    }
    private var clickable: NSRect { hitRect?() ?? bounds.insetBy(dx: bounds.width * 0.08, dy: bounds.height * 0.06) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    private func track(_ event: NSEvent?) {
        let p = event.map { convert($0.locationInWindow, from: nil) } ?? NSPoint(x: -1, y: -1)
        let now = clickable.contains(p)
        if now != inside { inside = now; onHover?(now) }
    }
    override func mouseEntered(with event: NSEvent) { track(event) }
    override func mouseMoved(with event: NSEvent) { track(event) }
    override func mouseExited(with event: NSEvent) { inside = false; onHover?(false) }

    override func mouseDown(with event: NSEvent) {
        downAt = NSEvent.mouseLocation
        originAtDown = window?.frame.origin
        dragged = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let d = downAt, let o = originAtDown, let w = window else { return }
        let p = NSEvent.mouseLocation
        if !dragged && hypot(p.x - d.x, p.y - d.y) < 3 { return }
        if !dragged { dragged = true; onHover?(false); onDragStart?() }
        w.setFrameOrigin(NSPoint(x: o.x + p.x - d.x, y: o.y + p.y - d.y))
    }
    override func mouseUp(with event: NSEvent) {
        if dragged { onMoved?() } else { onClick?() }
        downAt = nil
    }
}

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class OrbWindowController {
    private let store: Store
    private let window: NSPanel
    private let metal: OrbMTKView
    private var bubble: NSPanel?
    private var detail: KeyPanel?
    private var outsideMonitor: Any?
    private var keyMonitor: Any?
    private var sub: AnyCancellable?
    private let size: CGFloat = 200
    private let brain: GhostBrain
    private var floorY: CGFloat = 0
    private var dockAge: Float = 99
    private var lastOrigin = NSPoint(x: -9999, y: -9999)
    private var overlay: NSPanel?
    private let overlayView = ScanOverlayView()
    private var senseAge: Float = 0, targetsAge: Float = 99
    private var sensing = false
    private var ppi: CGFloat = 110
    private var message: NSPanel?
    private var messageHide: DispatchWorkItem?
    private var scanLevel: CGFloat = 0

    init(store: Store) {
        self.store = store
        let st = DockInfo.stage()
        let savedX = UserDefaults.standard.object(forKey: "ghostX") as? Double
        let span = Float(st.span.lowerBound)...Float(st.span.upperBound)
        let startX = Float(savedX ?? Double((st.span.lowerBound + st.span.upperBound) / 2))
        brain = GhostBrain(x: min(max(startX, span.lowerBound), span.upperBound), range: span)
        floorY = st.floor
        GhostLog.write("stage floor=\(Int(st.floor)) span=\(Int(st.span.lowerBound))...\(Int(st.span.upperBound)) dockW=\(Int(DockInfo.estimatedWidth() ?? -1))")
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isMovable = false
        window.hidesOnDeactivate = false

        let container = OrbContainer(frame: NSRect(x: 0, y: 0, width: size, height: size))
        metal = OrbMTKView(frame: container.bounds)
        metal.autoresizingMask = [.width, .height]
        container.addSubview(metal)
        let badge = NSHostingView(rootView: BadgeView(store: store))
        badge.frame = container.bounds
        badge.autoresizingMask = [.width, .height]
        container.addSubview(badge)
        window.contentView = container

        container.onClick = { [weak self] in self?.toggleDetail() }
        container.onHover = { [weak self] on in self?.hover(on) }
        container.onMoved = { [weak self] in self?.dropped() }
        container.onDragStart = { [weak self] in self?.brain.pickUp() }
        container.hitRect = { [weak self] in
            guard let self else { return nil }
            let r = self.metal.renderer.hitRect
            let w = self.size
            return NSRect(x: CGFloat(r.x) * w, y: CGFloat(r.y) * w, width: CGFloat(r.z) * w, height: CGFloat(r.w) * w).insetBy(dx: -4, dy: -4)
        }

        applyStage(st)
        if let sy = UserDefaults.standard.object(forKey: "ghostY") as? Double { brain.y = min(max(Float(sy), brain.rangeY.lowerBound), brain.rangeY.upperBound) }
        metal.renderer.brain = brain
        metal.renderer.onTick = { [weak self] dt in self?.tick(dt) }
        place()
        window.orderFrontRegardless()
        let ov = NSPanel(contentRect: st.screen?.frame ?? .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        ov.isOpaque = false; ov.backgroundColor = .clear; ov.hasShadow = false; ov.ignoresMouseEvents = true
        ov.level = .floating
        ov.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        overlayView.frame = NSRect(origin: .zero, size: ov.frame.size)
        overlayView.autoresizingMask = [.width, .height]
        ov.contentView = overlayView
        overlay = ov
        ppi = Sense.pointsPerInch(st.screen)
        if !Sense.trusted() { _ = Sense.trusted(prompt: true); GhostLog.write("accessibility not granted: text-box avoidance off, scans whole windows") }
        metal.renderer.mood = store.snap.mood
        sub = store.$snap.sink { [weak self] s in self?.metal.renderer.mood = self?.forced ?? s.mood }
    }

    /// Test hook: start an act now ("drift", "scan", "spin", "transmat", ...).
    func act(_ name: String?) {
        guard let name, let a = GhostBrain.Act(rawValue: name) else { return }
        brain.start(a)
    }

    /// One frame: refresh the Dock now and then, run the brain, and move the window with the Ghost.
    private func tick(_ dt: Float) {
        dockAge += dt
        if dockAge > 15 {
            dockAge = 0
            let st = DockInfo.stage()
            floorY = st.floor
            applyStage(st)
            ppi = Sense.pointsPerInch(st.screen)
            if let s = st.screen, overlay?.frame != s.frame { overlay?.setFrame(s.frame, display: false) }
        }
        sense(dt)
        followPointer()
        let listening = detail?.isVisible == true
        brain.listening = listening
        brain.frozen = !metal.renderer.isIdle || listening || metal.renderer.reduceMotion
        brain.update(dt)
        if !brain.held { place() }
        drawScan(dt)
    }

    /// The Ghost may roam the whole screen the Dock is on, from the Dock up to the menu bar.
    private func applyStage(_ st: (screen: NSScreen?, floor: CGFloat, span: ClosedRange<CGFloat>)) {
        let vf = st.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        brain.floor = Float(st.floor)
        brain.range = Float(vf.minX + 60)...Float(vf.maxX - 60)
        let top = vf.maxY - st.floor - size * (1 - CGFloat(SceneRenderer.floorUV))
        brain.rangeY = 0...Float(max(0, top))
    }

    /// Poll the focused text box (4 times a second) and the front window's elements (every 5 s), off the main thread.
    private func sense(_ dt: Float) {
        senseAge += dt; targetsAge += dt
        guard !sensing, senseAge > 0.25 else { return }
        senseAge = 0
        let wantTargets = targetsAge > 5 && brain.act != .scan
        if wantTargets { targetsAge = 0 }
        sensing = true
        Task.detached(priority: .utility) {
            let box = Sense.focusedTextBox()
            let targets = wantTargets ? Sense.scanTargets() : nil
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.sensing = false
                self.brain.avoid = box.map { [$0] } ?? []
                if let targets { self.brain.scanTargets = targets }
            }
        }
    }

    /// The eye in screen points, where it is drawn now.
    private func eyePoint() -> CGPoint {
        let f = window.frame
        return CGPoint(x: f.minX + size / 2 + CGFloat(brain.dx), y: f.minY + size * CGFloat(SceneRenderer.floorUV) + CGFloat(GhostRig.hoverPts + brain.hop))
    }

    /// Within 2 real inches of the eye, the Ghost watches the pointer.
    private func followPointer() {
        let m = NSEvent.mouseLocation, e = eyePoint()
        let d = SIMD2<Float>(Float(m.x - e.x), Float(m.y - e.y))
        let dist = simd_length(d)
        if dist < Float(2 * ppi), dist > 6 { brain.pointer = d / dist * min(1, dist / 60) } else { brain.pointer = nil }
    }

    /// The blue scanning light over the element the Ghost is scanning.
    private func drawScan(_ dt: Float) {
        guard let ov = overlay else { return }
        let on = brain.scanRect != nil && brain.pose.vis > 0.5
        scanLevel += ((on ? 1 : 0) - scanLevel) * (1 - CGFloat(exp(-8 * dt)))
        if scanLevel < 0.01 { if ov.isVisible { overlayView.rect = nil; ov.orderOut(nil) }; return }
        if !ov.isVisible { ov.order(.below, relativeTo: window.windowNumber) }
        if let r = brain.scanRect { overlayView.rect = r }
        overlayView.k = CGFloat(brain.scanK)
        overlayView.eye = eyePoint()
        overlayView.level = scanLevel
        overlayView.needsDisplay = true
    }

    // Messages: Claude notifications shown by the Ghost instead of macOS banners.
    func say(title: String, body: String, localId: String?) {
        pulse(3)
        if brain.act == .nap { brain.start(.hover) }
        let card = MessageCard(title: title, text: body,
                               open: { [weak self] in self?.store.openClaude(localId); self?.hideMessage() },
                               snooze: { [weak self] in self?.store.snooze(1800); self?.hideMessage() },
                               close: { [weak self] in self?.hideMessage() })
        if message == nil {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            message = p
        }
        guard let p = message else { return }
        let host = NSHostingView(rootView: card)
        p.contentView = host
        let sz = host.fittingSize
        let f = window.frame, vf = window.screen?.visibleFrame ?? f
        var x = f.midX + 40
        if x + sz.width > vf.maxX - 6 { x = f.midX - 40 - sz.width }
        let y = min(max(eyePoint().y + 10, vf.minY + 6), vf.maxY - sz.height - 6)
        p.setFrame(NSRect(x: x, y: y, width: sz.width, height: sz.height), display: true)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; p.animator().alphaValue = 1 }
        messageHide?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.hideMessage() }
        messageHide = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 14, execute: w)
        GhostLog.write("ghost message")
    }

    private func hideMessage() {
        guard let p = message, p.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; p.animator().alphaValue = 0 }, completionHandler: { p.orderOut(nil) })
    }

    private func place() {
        let o = NSPoint(x: (CGFloat(brain.x) - size / 2).rounded(), y: (floorY - size * CGFloat(SceneRenderer.floorUV) + CGFloat(brain.y + brain.drop)).rounded())
        guard o != lastOrigin else { return }
        lastOrigin = o
        window.setFrameOrigin(o)
        if bubble?.isVisible == true { bubble?.orderOut(nil) }
    }

    private func dropped() {
        let f = window.frame
        brain.release(height: Float(f.minY - (floorY - size * CGFloat(SceneRenderer.floorUV))), at: Float(f.midX))
        UserDefaults.standard.set(Double(f.midX), forKey: "ghostX")
        UserDefaults.standard.set(Double(brain.y), forKey: "ghostY")
        if detail?.isVisible == true { positionDetail() }
    }

    func pulse(_ n: Int) { metal.renderer.pulse(n) }

    /// Test hook: force a mood ("calm", "call", "burning", "needs"); anything else returns to live data.
    var forced: Mood?
    func force(_ name: String?) {
        forced = ["calm": .calm, "call": .call, "burning": .burning, "needs": .needs][name ?? ""]
        metal.renderer.mood = forced ?? store.snap.mood
    }

    func close() {
        closeDetail()
        bubble?.orderOut(nil)
        message?.orderOut(nil)
        overlay?.orderOut(nil)
        window.orderOut(nil)
    }

    // Hover bubble
    private func hover(_ on: Bool) {
        guard on, detail?.isVisible != true else { bubble?.orderOut(nil); return }
        if bubble == nil {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
            p.level = .floating; p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            p.contentView = NSHostingView(rootView: BubbleView(store: store))
            bubble = p
        }
        guard let b = bubble, let hv = b.contentView else { return }
        let fs = hv.fittingSize
        let f = window.frame
        let screen = window.screen?.visibleFrame ?? f
        var x = f.minX - fs.width + 14
        if x < screen.minX { x = f.maxX - 14 }
        b.setFrame(NSRect(x: x, y: f.midY - fs.height / 2, width: fs.width, height: fs.height), display: true)
        b.alphaValue = 0
        b.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; b.animator().alphaValue = 1 }
    }

    // Detail panel
    func toggleDetail() {
        if detail?.isVisible == true { closeDetail() } else { openDetail() }
    }

    private func openDetail() {
        bubble?.orderOut(nil)
        if detail == nil {
            let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 404, height: 640),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            p.contentView = NSHostingView(rootView: PanelView(store: store, floating: true))
            detail = p
        }
        guard let p = detail else { return }
        positionDetail()
        p.alphaValue = 0
        p.makeKeyAndOrderFront(nil)
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; p.animator().alphaValue = 1 }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.closeDetail() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { Task { @MainActor in self?.closeDetail() }; return nil }
            return e
        }
    }

    private func positionDetail() {
        guard let p = detail else { return }
        let f = window.frame
        let vf = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? f
        let w: CGFloat = 404, h: CGFloat = 640
        var x = f.maxX - w - 6
        var y = f.minY - h + 6
        if y < vf.minY { y = f.maxY - 6 }
        if y + h > vf.maxY { y = vf.maxY - h }
        x = min(max(x, vf.minX + 6), vf.maxX - w - 6)
        y = max(y, vf.minY + 6)
        p.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
    }

    private func closeDetail() {
        if let m = outsideMonitor { NSEvent.removeMonitor(m); outsideMonitor = nil }
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        guard let p = detail, p.isVisible else { return }
        store.showSettings = false
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; p.animator().alphaValue = 0 }, completionHandler: { p.orderOut(nil) })
    }
}

// MARK: - Command-line helpers

enum Dump {
    static func run() {
        func fp() -> String {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
            return "\(info.phys_footprint >> 20) MB"
        }
        if CommandLine.arguments.contains("-m") {
            print("start \(fp())")
            let sc = Scanner()
            _ = sc.cycle(full: false, cfg: .init(awayMinutes: 20, dismissed: []))
            print("registry+desktop \(fp())")
            _ = sc.cycle(full: true, cfg: .init(awayMinutes: 20, dismissed: []))
            print("after full scan \(fp()) · sessions \(sc.logs.count) · spends \(sc.logs.values.reduce(0) { $0 + $1.spends.count })")
            return
        }
        let sc = Scanner()
        let away = UserDefaults(suiteName: "local.ghostshell")?.integer(forKey: "awayMin") ?? 0
        let s = sc.cycle(full: true, cfg: .init(awayMinutes: away > 0 ? away : 20, dismissed: []))
        print("scan \(s.scanMs) ms · \(s.files) files · \(s.liveCount) live sessions · mood \(s.mood)")
        print("NEEDS YOU (\(s.needs.count))")
        for i in s.needs { print("  \(i.kind) · \(i.title) · \(i.project) · \(Voice.ago(i.since)) · link=\(i.localId?.prefix(14) ?? "none")") }
        print("YOUR CALL (\(s.calls.count))")
        for i in s.calls { print("  \(i.title) · \(Voice.ago(i.since)) ago · ask=\(i.ask != nil) · link=\(i.localId?.prefix(14) ?? "none")") }
        print("READY TO REVIEW (\(s.reviews.count))")
        print("WORKING WHILE AWAY (\(s.burns.count), active \(s.hotBurns.count))")
        for i in s.burns {
            print("  \(i.title) · link=\(i.localId?.prefix(14) ?? "none") · away \(Voice.ago(i.since)) · \(Voice.tokens(i.burn.total)) total / \(Voice.tokens(i.burn.fresh)) new · \(i.burnTurns) turns · causes \(i.causes.map { $0.chip }) · timer \(i.timer ?? "-") · loop \(i.loop) · active \(i.active)")
        }
        print("24 H: you \(Voice.tokens(s.todayOwner)) · on its own \(Voice.tokens(s.todayAuto))")
        guard CommandLine.arguments.contains("-v") else { return }
        let cut = Date().addingTimeInterval(-24 * 3600)
        var rows: [(String, Int, Int, String, String)] = []
        for (sid, log) in sc.logs {
            var own = 0, auto = 0
            var by: [Origin: Int] = [:]
            for sp in log.spends.values where sp.time > cut {
                let o = log.origin(at: sp.time)
                if o == .human { own += sp.tokens.total } else { auto += sp.tokens.total; by[o, default: 0] += sp.tokens.total }
            }
            let h = log.lastHumanAt.map { Voice.ago($0) } ?? "never"
            let br = by.sorted { $0.value > $1.value }.map { "\($0.key.chip)=\(Voice.tokens($0.value))" }.joined(separator: " ")
            rows.append((String(sid.prefix(8)), own, auto, h, br + " timers=\(log.recurringTimers) turns=\(log.turnTimes.count)"))
        }
        for r in rows.sorted(by: { $0.2 > $1.2 }).prefix(12) {
            print("  \(r.0) you \(Voice.tokens(r.1)) · auto \(Voice.tokens(r.2)) · last human \(r.3) · \(r.4)")
        }
    }
}

/// Still frames of every state and figure, for checks: Ember --frames <dir>
/// Contact sheets for checks: every act on the stage, the activation, and every built-in shell.
enum GhostSheet {
    static let samples: [(GhostBrain.Act, [Float])] = [
        (.drift, [1.2]), (.zip, [0.5]), (.hover, [1.5]), (.scan, [2.0, 3.0]), (.spin, [1.2]), (.peek, [1.5]),
        (.orbit, [0.7, 1.3]), (.transmat, [0.5, 1.6]), (.nap, [4.0])]

    static func sheet(_ shots: [(String, CGImage)], cell: Int, cols: Int, to url: URL) {
        let rows = (shots.count + cols - 1) / cols
        let W = cols * cell, H = rows * (cell + 26)
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(CGColor(red: 0.16, green: 0.17, blue: 0.21, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        for (i, (label, img)) in shots.enumerated() {
            let x = (i % cols) * cell, y = H - (i / cols + 1) * (cell + 26)
            ctx.setFillColor(CGColor(red: 0.30, green: 0.32, blue: 0.38, alpha: 1))
            ctx.fill(CGRect(x: x + 4, y: y + 26 + 10, width: cell - 8, height: 3))
            ctx.draw(img, in: CGRect(x: x, y: y + 26, width: cell, height: cell))
            (label as NSString).draw(at: NSPoint(x: x + 10, y: y + 6), withAttributes: [.font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.white])
        }
        NSGraphicsContext.current = nil
        if let out = ctx.makeImage() { try? NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])?.write(to: url) }
    }

    static func run(dir: String) {
        let d = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let cell = 300
        var shots: [(String, CGImage)] = []
        for (act, times) in samples {
            for tt in times {
                let b = GhostBrain(x: 1000, range: 600...1400)
                b.start(act)
                var tt0: Float = 0
                while tt0 < tt { b.update(1 / 60); tt0 += 1 / 60; if b.act != act && act != .drift && act != .zip { break } }
                if let img = SceneRenderer.renderStage(size: cell, brain: b) { shots.append(("\(act.rawValue) \(String(format: "%.1f", tt))s", img)) }
            }
        }
        let b = GhostBrain(x: 1000, range: 600...1400)
        for _ in 0..<60 { b.update(1 / 60) }
        for (p, m) in [(Float(0.25), Mood.needs), (0.5, .needs), (0.8, .needs), (1.0, .needs), (1.0, .call), (1.0, .burning)] {
            if let img = SceneRenderer.renderStage(size: cell, brain: b, mood: m, progress: p) { shots.append(("activate \(Int(p * 100))% \(m)", img)) }
        }
        sheet(shots, cell: cell, cols: 6, to: d.appendingPathComponent("ghost-acts.png"))
        var shells: [(String, CGImage)] = []
        for s in ShellSpec.builtIns {
            if let img = SceneRenderer.renderShell(s, size: cell) { shells.append((s.name, img)) }
            if let img = SceneRenderer.renderShell(s, size: cell, mood: .needs, open: 0.85, spin: 1.1) { shells.append((s.name + " · open", img)) }
        }
        sheet(shells, cell: cell, cols: 6, to: d.appendingPathComponent("ghost-shells.png"))
        print("sheets written")
    }
}

/// `Ghost --design "a shell made of autumn leaves"`: one designer call, the spec printed as JSON (for checks).
enum DesignCLI {
    static func run(_ prompt: String) {
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            switch await ShellDesigner.design(prompt, model: "haiku") {
            case .success(let s):
                let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                print(String(data: (try? enc.encode(s)) ?? Data(), encoding: .utf8) ?? "")
                if let img = SceneRenderer.renderShell(s, size: 400) {
                    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ghost-design.png")
                    try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: url)
                    print("render: \(url.path)")
                }
            case .failure(let e): print("failed: \(e)")
            }
            sem.signal()
        }
        sem.wait()
    }
}

enum IconMaker {
    static func run(path: String) {
        let size = 1024
        guard let orb = SceneRenderer.renderShell(nil, size: 760, open: 0.18, spin: 0.25) else { print("render failed"); return }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        // Rounded-square tile with a deep night gradient, then the Ghost.
        let inset: CGFloat = 100
        let tile = CGRect(x: inset, y: inset, width: CGFloat(size) - 2 * inset, height: CGFloat(size) - 2 * inset)
        let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
        ctx.saveGState()
        ctx.addPath(tilePath); ctx.clip()
        let g = CGGradient(colorsSpace: cs, colors: [CGColor(srgbRed: 0.09, green: 0.20, blue: 0.27, alpha: 1),
                                                     CGColor(srgbRed: 0.04, green: 0.09, blue: 0.13, alpha: 1)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
        ctx.restoreGState()
        let o = CGFloat(760)
        ctx.draw(orb, in: CGRect(x: (CGFloat(size) - o) / 2, y: (CGFloat(size) - o) / 2, width: o, height: o))
        guard let img = ctx.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: img)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("icon written")
    }
}

/// `Ghost --say`: hand a message to the running Ghost. With no arguments it reads the JSON a Claude Code hook sends
/// on stdin ({"message", "title", ...}) and passes on only the title and message.
enum SayCLI {
    static func run(_ args: [String]) {
        var title = "Claude", body = ""
        if args.count >= 2 { title = args[0]; body = args[1] }
        else if args.count == 1 { body = args[0] }
        else if let data = try? FileHandle.standardInput.readToEnd(),
                let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            body = j["message"] as? String ?? ""
            if let t = j["title"] as? String, !t.isEmpty { title = t }
        }
        guard !body.isEmpty, let out = try? JSONSerialization.data(withJSONObject: ["title": title, "body": body]),
              let str = String(data: out, encoding: .utf8) else { return }
        DistributedNotificationCenter.default().postNotificationName(Notification.Name("local.ghostshell.say"), object: str,
                                                                     userInfo: nil, deliverImmediately: true)
    }
}
