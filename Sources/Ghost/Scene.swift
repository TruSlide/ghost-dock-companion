// The Ghost's scene: a shell of plates around a glowing eye, drawn in one fragment shader from a ShellSpec.
// When something waits, the Ghost "activates": the plates spin and part, the core lights up and the eye flares
// in the mood's colour (a tribute to the Ghost activation animation). When all is clear the shell closes again.
// One full-screen triangle, 30 fps, paused when hidden.

import AppKit
import MetalKit
import SwiftUI


// MARK: - Uniforms and mood colours

struct SceneUniforms {
    var time: Float = 0, attention: Float = 0, open: Float = 0, pulse: Float = 0
    var eyeCol = SIMD4<Float>(0.5, 0.83, 1, 1)
    var ghost = SIMD4<Float>(0.5, 0.5, 0.3, 1)
    var pose = SIMD4<Float>()
    var pose2 = SIMD4<Float>(0, 0, 0, 1)
    var shA = SIMD4<Float>(6, 1, 0, 0)
    var shB = SIMD4<Float>(1, 0.9, 0.08, 0)
    var base = SIMD4<Float>(0.8, 0.8, 0.82, 0.5)
    var accent = SIMD4<Float>(0.5, 0.5, 0.55, 0.5)
    var trim = SIMD4<Float>(0.35, 0.37, 0.4, 1)
    var patCol = SIMD4<Float>(0.5, 0.83, 1, 1)
    var shEye = SIMD4<Float>(0.5, 0.83, 1, 0.9)
    var misc = SIMD4<Float>()

    mutating func apply(_ s: ShellSpec) {
        shA = SIMD4(Float(s.plates), s.shapeIndex, s.patternIndex, s.eyeIndex)
        shB = SIMD4(Float(s.length), Float(s.width), Float(s.gap), Float(s.wear))
        base = s.col(s.base); base.w = Float(s.metallic)
        accent = s.col(s.accent); accent.w = Float(s.glow)
        trim = s.col(s.trim); trim.w = s.backRing ? 1 : 0
        patCol = s.col(s.patternColor); patCol.w = Float(s.patternScale)
        shEye.w = Float(s.facet)
    }
}

func rgb(_ hex: UInt32) -> SIMD4<Float> {
    SIMD4(Float((hex >> 16) & 255) / 255, Float((hex >> 8) & 255) / 255, Float(hex & 255) / 255, 1)
}

extension Mood {
    /// The eye's colour when the Ghost activates for this mood.
    var light: SIMD4<Float> {
        switch self {
        case .calm: return rgb(0x7FD4FF)
        case .call: return rgb(0xF0B357)
        case .burning: return rgb(0xFF7A4D)
        case .needs: return rgb(0xFFD28A)
        }
    }
    var attention: Float { switch self { case .calm: return 0; case .call: return 0.45; case .burning: return 0.6; case .needs: return 1 } }
}

// MARK: - GPU

final class OrbGPU {
    static let shared = OrbGPU()
    let device: MTLDevice?
    let queue: MTLCommandQueue?
    private init() { device = MTLCreateSystemDefaultDevice(); queue = device?.makeCommandQueue() }
}

// MARK: - Renderer

final class SceneRenderer: NSObject, MTKViewDelegate {
    enum Phase { case idle, active, toActive(CFTimeInterval), toIdle(CFTimeInterval) }

    var mood: Mood = .calm { didSet { if mood != oldValue, view?.isPaused == true, view?.window != nil { view?.draw() } } }
    weak var view: MTKView?

    /// Stage mode (the Ghost floating over the Dock). Without a brain: a still Ghost in the middle (panel header, thumbnails).
    var brain: GhostBrain?
    /// A fixed shell for thumbnails; nil = the shell being worn.
    var shell: ShellSpec?
    /// Fixed opening for still renders (nil = from the phase machine).
    var fixedOpen: Float?
    var onTick: ((Float) -> Void)?
    static let canvasPts: Float = 200
    static let floorUV: Float = 0.04
    /// While something waits: active for activeHold seconds, then idle for idleHold seconds, and again.
    let activeHold: CFTimeInterval = 30
    let idleHold: CFTimeInterval = 120
    private var activeSince: CFTimeInterval = 0
    private var nextActiveAt: CFTimeInterval?
    private(set) var hitRect = SIMD4<Float>(0.3, 0.1, 0.4, 0.4)
    var isIdle: Bool { if case .idle = phase { return true }; return false }
    private(set) var phase: Phase = .idle
    private var eye = rgb(0x7FD4FF)
    private let start = CACurrentMediaTime()
    private var last = CACurrentMediaTime()
    private var pulseStart: CFTimeInterval?
    private var pulsesLeft = 0
    private let toActiveDur: CFTimeInterval = 2.4
    private let toIdleDur: CFTimeInterval = 1.8
    private var stillSpin: Float = 0
    private var primed = false
    var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func pulse(_ times: Int) {
        if brain != nil, case .idle = phase, mood != .calm { nextActiveAt = 0; return }
        guard !reduceMotion else { return }
        pulsesLeft = times
        pulseStart = CACurrentMediaTime()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    private func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(1, max(0, (x - a) / (b - a))); return t * t * (3 - 2 * t)
    }

    /// Advances the state machine; returns activation progress (0 idle .. 1 active).
    private func progress(now: CFTimeInterval) -> Float {
        var want = mood != .calm
        if mood == .calm { nextActiveAt = nil }
        if brain != nil, want {
            switch phase {
            case .active: want = now - activeSince < activeHold
            case .idle: want = now >= (nextActiveAt ?? 0)
            default: break
            }
        }
        switch phase {
        case .idle:
            if want { if reduceMotion { phase = .active; activeSince = now; return 1 }; phase = .toActive(now); GhostLog.write("activate") }
            return 0
        case .active:
            if !want { if reduceMotion { phase = .idle; return 0 }; phase = .toIdle(now); GhostLog.write("deactivate") }
            return 1
        case .toActive(let s):
            let p = Float((now - s) / toActiveDur)
            if p >= 1 { phase = .active; activeSince = now; pulse(mood == .needs ? 3 : 1); return 1 }
            return p
        case .toIdle(let s):
            let p = Float((now - s) / toIdleDur)
            if p >= 1 { phase = .idle; if mood != .calm { nextActiveAt = now + idleHold }; return 0 }
            return 1 - p
        }
    }

    func frame(now: CFTimeInterval) -> SceneUniforms {
        let dt = Float(min(now - last, 0.1)); last = now
        if brain != nil { onTick?(dt) }
        let q = fixedOpen ?? progress(now: now)
        let motion: Float = reduceMotion ? 0 : 1
        let t = Float(now - start) * motion + 11
        let spec = shell ?? ShellState.current

        // Eye colour: the shell's own while idle, the mood's as it activates.
        let own = spec.col(spec.eye)
        let target = q > 0.05 ? (own + (mood.light - own) * 0.75) : own
        eye = reduceMotion || brain == nil || !primed ? target : eye + (target - eye) * min(1, dt * 2.5)
        primed = true

        var pulse: Float = 0
        if let ps = pulseStart {
            let p = Float((now - ps) / 1.5)
            if p >= 1 { pulsesLeft -= 1; pulseStart = pulsesLeft > 0 ? now : nil } else { pulse = p }
        }

        var u = SceneUniforms()
        u.apply(spec)
        u.time = t
        u.attention = mood.attention * q
        u.pulse = pulse
        // The activation: plates spin one turn as they part, then keep turning slowly while open.
        let k = smooth(0, 1, q)
        let activeSpin = k * 2 * .pi * 0.75 + (q >= 1 ? Float(now - activeSince) * 0.5 * motion : 0)
        let breathe = q >= 1 ? 0.06 * sin(t * 1.6) : 0
        u.shEye = SIMD4(mood.light.x, mood.light.y, mood.light.z, u.shEye.w)
        u.pose2.w = motion

        dust.removeAll(keepingCapacity: true)
        if let b = brain {
            let W = Self.canvasPts
            let R = GhostRig.radius
            let cy = Self.floorUV + (GhostRig.hoverPts + b.hop - b.pose.sink) / W
            let cx = 0.5 + b.dx / W
            u.ghost = SIMD4(cx, cy, R, b.pose.vis)
            u.open = max(b.pose.open, k * 0.85 + breathe)
            u.pose = SIMD4(b.pose.roll * (1 - k), b.pose.yaw * (1 - k), b.pose.lookX * (1 - k), b.pose.lookY * (1 - k) + 0.1 * k)
            u.pose2 = SIMD4(b.pose.blink * (1 - k), b.spin + activeSpin, b.pose.scan * (1 - k), motion)
            for m in b.motes {
                let fade = min(1, m.age / 0.15) * (1 - smooth(m.life * 0.6, m.life, m.age))
                let tw: Float = 0.75 + 0.25 * sin(t * 7 + m.x * 0.37)
                dust.append(SIMD4(0.5 + (m.x - b.x) / W, Self.floorUV + m.y / W, m.size, fade * tw))
            }
            u.misc.x = Float(dust.count)
            let reach = R * (1.05 + 0.4 * u.open)
            hitRect = SIMD4(cx - reach, cy - reach, reach * 2, reach * 2)
        } else {
            stillSpin += dt * 0.35 * motion
            u.ghost = SIMD4(0.5, 0.5, shell == nil ? 0.30 : 0.33, 1)
            u.open = fixedOpen ?? (k * 0.7 + breathe)
            u.pose2 = SIMD4(0, (fixedOpen != nil ? 0 : stillSpin) + activeSpin, 0, motion)
        }
        u.eyeCol = SIMD4(eye.x, eye.y, eye.z, 1 + 0.3 * k)
        return u
    }

    private var dust: [SIMD4<Float>] = []

    static var msaa = ProcessInfo.processInfo.environment["GHOST_NOMSAA"] == nil
    private lazy var stage = Ghost3D(device: OrbGPU.shared.device)

    func render(_ cb: MTLCommandBuffer, _ rpd: MTLRenderPassDescriptor, size: CGSize, now: CFTimeInterval) {
        let u = frame(now: now)
        stage.stillView = brain == nil
        stage.apply(u, spec: shell ?? ShellState.current, dust: dust)
        stage.render(commandBuffer: cb, pass: rpd, size: size, time: now)
    }

    func draw(in view: MTKView) {
        guard let q = OrbGPU.shared.queue, let rpd = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cb = q.makeCommandBuffer() else { return }
        render(cb, rpd, size: view.drawableSize, now: CACurrentMediaTime())
        cb.present(drawable)
        cb.commit()
    }

    /// A still of the stage (the brain is not advanced here).
    static func renderStage(size: Int, brain: GhostBrain, shell: ShellSpec? = nil, mood: Mood = .calm, progress: Float = 0) -> CGImage? {
        let r = SceneRenderer()
        r.brain = brain; r.shell = shell; r.mood = mood
        let now = CACurrentMediaTime()
        if progress >= 1 { r.phase = .active; r.activeSince = now } else if progress > 0 { r.phase = .toActive(now - Double(progress) * r.toActiveDur) }
        else if mood != .calm { r.nextActiveAt = now + 999 }
        r.last = now
        return r.capture(size: size, now: now)
    }

    /// A still Ghost in the middle of the canvas: thumbnails, the icon and checks.
    static func renderShell(_ shell: ShellSpec?, size: Int, mood: Mood = .calm, open: Float = 0, spin: Float = 0.3) -> CGImage? {
        let r = SceneRenderer()
        r.shell = shell; r.mood = mood; r.fixedOpen = open; r.stillSpin = spin
        let now = CACurrentMediaTime()
        r.last = now
        return r.capture(size: size, now: now)
    }

    private func capture(size: Int, now: CFTimeInterval) -> CGImage? {
        let g = OrbGPU.shared
        guard let dev = g.device, let q = g.queue else { return nil }
        func tex(_ f: MTLPixelFormat, msaa: Bool, shared: Bool) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: size, height: size, mipmapped: false)
            if msaa && Self.msaa { d.textureType = .type2DMultisample; d.sampleCount = 4 }
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = shared ? .shared : .private
            return dev.makeTexture(descriptor: d)
        }
        guard let ms = tex(.bgra8Unorm, msaa: true, shared: false), let out = tex(.bgra8Unorm, msaa: false, shared: true),
              let depth = tex(.depth32Float, msaa: true, shared: false), let cb = q.makeCommandBuffer() else { return nil }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = ms
        if Self.msaa { rpd.colorAttachments[0].resolveTexture = out } else { rpd.colorAttachments[0].texture = out }
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rpd.colorAttachments[0].storeAction = Self.msaa ? .multisampleResolve : .store
        rpd.depthAttachment.texture = depth
        rpd.depthAttachment.loadAction = .clear
        rpd.depthAttachment.clearDepth = 1
        rpd.depthAttachment.storeAction = .dontCare
        render(cb, rpd, size: CGSize(width: size, height: size), now: now)
        cb.commit(); cb.waitUntilCompleted()
        let tex = out
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        tex.getBytes(&bytes, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let ctx = CGContext(data: &bytes, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info.rawValue) else { return nil }
        return ctx.makeImage()
    }
}

/// MTKView that pauses itself whenever it cannot be seen.
final class OrbMTKView: MTKView {
    let renderer = SceneRenderer()
    private var observers: [NSObjectProtocol] = []

    init(frame: CGRect) {
        super.init(frame: frame, device: OrbGPU.shared.device)
        colorPixelFormat = .bgra8Unorm
        depthStencilPixelFormat = .depth32Float
        sampleCount = 4
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        framebufferOnly = true
        preferredFramesPerSecond = 30
        wantsLayer = true
        layer?.isOpaque = false
        layer?.backgroundColor = .clear
        renderer.view = self
        delegate = renderer
        isPaused = true
        enableSetNeedsDisplay = false
    }

    required init(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        guard let w = window else { isPaused = true; return }
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: w, queue: .main) { [weak self] _ in self?.updatePause() })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.updatePause() })
        updatePause()
    }

    func updatePause() {
        let visible = window?.occlusionState.contains(.visible) ?? false
        isPaused = !visible || renderer.reduceMotion
        if visible && renderer.reduceMotion { draw() }
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
}

/// SwiftUI wrapper: the worn shell, still and centred (panel header).
struct OrbView: NSViewRepresentable {
    var mood: Mood
    var shellId: String = ""
    func makeNSView(context: Context) -> OrbMTKView { OrbMTKView(frame: .zero) }
    func updateNSView(_ v: OrbMTKView, context: Context) { v.renderer.mood = mood; if v.isPaused { v.draw() } }
}

/// Small template glyph of a Ghost for the menu bar: a ring of facets around an eye.
enum SparkGlyph {
    static func image(bold: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let c = CGPoint(x: rect.midX, y: rect.midY)
            let path = NSBezierPath()
            let n = 6
            let r0: CGFloat = 3.2, r1: CGFloat = bold ? 7.8 : 7.2
            for i in 0..<n {
                let a = CGFloat(i) / CGFloat(n) * 2 * .pi + .pi / 2
                let half = .pi / CGFloat(n) * 0.78
                let mid = (r0 + r1) * 0.5
                path.move(to: CGPoint(x: c.x + cos(a - half) * r0, y: c.y + sin(a - half) * r0))
                path.line(to: CGPoint(x: c.x + cos(a - half * 0.95) * mid, y: c.y + sin(a - half * 0.95) * mid))
                path.line(to: CGPoint(x: c.x + cos(a) * r1, y: c.y + sin(a) * r1))
                path.line(to: CGPoint(x: c.x + cos(a + half * 0.95) * mid, y: c.y + sin(a + half * 0.95) * mid))
                path.line(to: CGPoint(x: c.x + cos(a + half) * r0, y: c.y + sin(a + half) * r0))
                path.close()
            }
            path.appendOval(in: NSRect(x: c.x - 2.6, y: c.y - 2.6, width: 5.2, height: 5.2))
            path.appendOval(in: NSRect(x: c.x - 1.2, y: c.y - 1.2, width: 2.4, height: 2.4))
            path.windingRule = .evenOdd
            NSColor.black.setFill()
            path.fill()
            return true
        }
        img.isTemplate = true
        return img
    }
}
