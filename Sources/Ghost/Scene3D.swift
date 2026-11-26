// The Ghost in 3D: the parts modelled in Blender (blender/build_ghost.py → Resources/GhostParts.usdz), assembled
// live in SceneKit from a ShellSpec and posed every frame from the same SceneUniforms the 2D shader used.
// Plate count, shape, length, width, gap and back ring set the geometry; base, accent, trim, pattern, eye,
// metallic, wear, glow and facet set the materials (shader modifiers keyed on the plate UV: t root→tip, v across).

import AppKit
import SceneKit

enum GhostParts {
    /// The USDZ, from the app bundle, or from the source tree for `swift run` and the CLI checks.
    static let template: SCNNode? = {
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Resources/GhostParts.usdz")
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        let candidates = [Bundle.main.url(forResource: "GhostParts", withExtension: "usdz"),
                          exe.appendingPathComponent("../../Resources/GhostParts.usdz"), here].compactMap { $0 }
        for u in candidates where FileManager.default.fileExists(atPath: u.path) {
            if let s = try? SCNScene(url: u) { return s.rootNode }
        }
        GhostLog.write("GhostParts.usdz missing")
        return nil
    }()

    static func geometry(_ name: String) -> SCNGeometry? {
        var found: SCNGeometry?
        template?.enumerateChildNodes { n, stop in
            if n.name == name, let g = n.geometry { found = g; stop.pointee = true }
        }
        return found
    }
}

/// Sprite textures for the light effects.
enum GlowTex {
    static func make(_ size: Int = 128, _ draw: (CGContext, CGFloat) -> Void) -> NSImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(ctx, CGFloat(size))
        return NSImage(cgImage: ctx.makeImage()!, size: NSSize(width: size, height: size))
    }
    static let radial = make { c, s in
        let g = CGGradient(colorsSpace: nil, colors: [CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 0.35), CGColor(gray: 1, alpha: 0)] as CFArray,
                           locations: [0, 0.25, 1])!
        c.drawRadialGradient(g, startCenter: CGPoint(x: s / 2, y: s / 2), startRadius: 0, endCenter: CGPoint(x: s / 2, y: s / 2), endRadius: s / 2, options: [])
    }
    static let ring = make(256) { c, s in
        let g = CGGradient(colorsSpace: nil, colors: [CGColor(gray: 1, alpha: 0), CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 0)] as CFArray,
                           locations: [0.78, 0.88, 0.98])!
        c.drawRadialGradient(g, startCenter: CGPoint(x: s / 2, y: s / 2), startRadius: 0, endCenter: CGPoint(x: s / 2, y: s / 2), endRadius: s / 2, options: [])
    }
    static let sparkle = make { c, s in
        let m = s / 2
        let g = CGGradient(colorsSpace: nil, colors: [CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
        c.drawRadialGradient(g, startCenter: CGPoint(x: m, y: m), startRadius: 0, endCenter: CGPoint(x: m, y: m), endRadius: s * 0.16, options: [])
        c.setFillColor(CGColor(gray: 1, alpha: 0.55))
        c.fill(CGRect(x: m - 1.2, y: 4, width: 2.4, height: s - 8)); c.fill(CGRect(x: 4, y: m - 1.2, width: s - 8, height: 2.4))
    }
    static let white = make(4) { c, s in c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: s, height: s)) }
    /// A soft studio sky for metal reflections.
    static let sky: NSImage = {
        let w = 256, h = 128
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let g = CGGradient(colorsSpace: nil, colors: [CGColor(red: 0.95, green: 0.97, blue: 1, alpha: 1), CGColor(red: 0.45, green: 0.5, blue: 0.6, alpha: 1),
                                                      CGColor(red: 0.12, green: 0.13, blue: 0.16, alpha: 1), CGColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1)] as CFArray,
                           locations: [0, 0.35, 0.55, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: CGFloat(h)), end: CGPoint(x: 0, y: 0), options: [])
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.9))
        ctx.fill(CGRect(x: 60, y: 92, width: 40, height: 14))                       // a softbox, upper left
        return NSImage(cgImage: ctx.makeImage()!, size: NSSize(width: w, height: h))
    }()
}

private let hashFn = "fract(sin(dot(%@, float2(127.1, 311.7))) * 43758.5453)"
private func h(_ p: String) -> String { String(format: hashFn, p) }

private func noise(_ out: String, _ p: String) -> String {
    """
    { float2 nI = floor(\(p)); float2 nF = fract(\(p)); float2 nU = nF * nF * (3.0 - 2.0 * nF);
      \(out) = mix(mix(\(h("nI")), \(h("nI + float2(1.0, 0.0)")), nU.x), mix(\(h("nI + float2(0.0, 1.0)")), \(h("nI + float2(1.0, 1.0)")), nU.x), nU.y); }
    """
}

/// Transmat: the Ghost breaks into flickering cells (shared by every solid part).
private let transmatFragment = """
#pragma arguments
float4 fx;
#pragma body
if (fx.x < 0.999) {
    float2 tc = floor(_surface.position.xy * 70.0) + floor(fx.y * 24.0) * 0.37;
    float th = \(h("tc"));
    float keep = step(th, fx.x) * smoothstep(0.0, 0.3, fx.x) + fx.x * fx.x * 0.3;
    if (keep < 0.02) discard_fragment();
    _output.color *= keep;
}
"""

private let shellSurface = """
#pragma arguments
float4 baseC;
float4 accentC;
float4 trimC;
float4 patC;
float4 shP;
float4 shM;
#pragma body
float2 st = _surface.diffuseTexcoord;
float t = st.x; float v = st.y * 2.0 - 1.0; float av = abs(v);
int pat = int(shP.x + 0.5); float sc = max(shP.y, 0.3);
float m = 0.0; float emit = 0.0;
float nA = 0.0; float nB = 0.0; float nW = 0.0;
\(noise("nA", "st * float2(7.0, 3.0) * sc"))
\(noise("nB", "st * float2(14.0, 6.0) * sc + 5.0"))
\(noise("nW", "st * float2(40.0, 14.0)"))
float fb = nA * 0.66 + nB * 0.34;
if (pat == 1) m = step(av, 0.28);
else if (pat == 2) m = step(fract((t * 2.5 - av * 0.6) * sc), 0.5);
else if (pat == 3) m = step(0.0, v);
else if (pat == 4) m = step(abs(t - 0.55), 0.12);
else if (pat == 5) {
    float g = min(abs(fract(t * 4.0 * sc) - 0.5), abs(fract(v * 1.5 * sc + 0.5) - 0.5));
    emit = (1.0 - smoothstep(0.0, 0.06, g)) * step(0.12, t) * step(av, 0.85);
} else if (pat == 6) emit = 1.0 - smoothstep(0.0, 0.045, abs(fb - 0.5));
else if (pat == 7) { float2 c = float2(fract(t * 4.0 * sc), fract(v * 1.2 * sc + 0.5)) - 0.5; m = step(length(c), 0.26) * step(0.1, t); }
else if (pat == 8) m = step(0.66, t);
else if (pat == 9) m = step(0.52, fb);
float3 col = mix(baseC.rgb, accentC.rgb, m);
col *= 0.9 + 0.12 * t;
float edge = clamp(smoothstep(0.80, 0.97, av) + smoothstep(0.92, 1.0, t), 0.0, 1.0);
col = mix(col, trimC.rgb, edge * 0.85);
float scuff = smoothstep(0.62, 0.80, nW * 0.6 + fb * 0.4) * shP.z;
col = mix(col, col * 0.55 + 0.2, scuff * 0.85);
_surface.diffuse = float4(col, 1.0);
_surface.metalness = clamp(shM.x * (1.0 - 0.6 * scuff) + edge * 0.2, 0.0, 1.0);
_surface.roughness = clamp(0.52 - 0.32 * shM.x + 0.35 * scuff, 0.08, 1.0);
_surface.emission = float4(patC.rgb * emit * (0.7 + 0.8 * shP.w), 1.0);
"""

private let coreSurface = """
#pragma arguments
float4 eyeC;
float4 coreP;
float4 trimC;
#pragma body
float2 st = _surface.diffuseTexcoord;
float lon = abs(fract(st.x * coreP.x + coreP.y * coreP.x / 6.2831853 * 1.3) - 0.5);
float seam = exp(-pow(lon * 18.0, 2.0)) + exp(-pow((abs(st.y - 0.5) - 0.2) * 60.0, 2.0));
float front = pow(max(_surface.normal.z, 0.0), 3.0);
_surface.diffuse = float4(mix(float3(0.07, 0.08, 0.10), trimC.rgb * 0.4, 0.3), 1.0);
_surface.metalness = 0.85;
_surface.roughness = 0.32;
_surface.emission = float4(eyeC.rgb * (seam * (0.08 + 0.8 * coreP.z) + front * coreP.z * 0.45) * eyeC.w, 1.0);
"""

private let eyeFragment = """
#pragma arguments
float4 eyeC;
float4 eyeP;
#pragma body
float2 st = _surface.diffuseTexcoord;
float2 pl = (st - 0.5) * 0.42;
pl.y /= max(1.0 - 0.75 * eyeP.z, 0.15);
float rl = length(pl);
float I = eyeC.w;
int es = int(eyeP.x + 0.5);
float light = 0.0;
if (es == 0) light = exp(-pow((rl - 0.135) * 38.0, 2.0)) + exp(-rl * rl * 900.0) * 1.6;
else if (es == 1) light = exp(-pl.x * pl.x * 1400.0) * smoothstep(0.17, 0.12, abs(pl.y)) + exp(-rl * rl * 900.0);
else if (es == 2) {
    float spokes = 0.5 + 0.5 * cos(atan2(pl.y, pl.x) * 12.0 + eyeP.y * 0.6);
    light = smoothstep(0.19, 0.16, rl) * smoothstep(0.04, 0.07, rl) * (0.35 + 0.65 * spokes) + exp(-rl * rl * 1200.0) * 1.8;
} else {
    float a = eyeP.y * 0.4; float2 q = abs(float2(pl.x * cos(a) - pl.y * sin(a), pl.x * sin(a) + pl.y * cos(a)));
    light = (exp(-q.x * 60.0) * exp(-q.y * q.y * 900.0) + exp(-q.y * 60.0) * exp(-q.x * q.x * 900.0)) * smoothstep(0.2, 0.1, rl) + exp(-rl * rl * 900.0);
}
float3 c = eyeC.rgb * exp(-rl * rl * 22.0) * 0.25 * I + mix(eyeC.rgb, float3(1.0), 0.3 * smoothstep(0.8, 1.8, light)) * light * I * (1.0 + 0.25 * eyeP.w);
float2 gp = pl - float2(-0.08, 0.10);
c += float3(1.0) * exp(-dot(gp, gp) * 900.0) * 0.5;
c *= step(rl, 0.21);
_output.color = float4(c, 1.0);
"""

final class Ghost3D {
    let scene = SCNScene()
    let renderer: SCNRenderer
    private let camera = SCNNode()
    private let body = SCNNode()
    private let front = SCNNode(), back = SCNNode(), eye = SCNNode()
    private var frontSlides: [SCNNode] = [], backSlides: [SCNNode] = []
    private let eyeLight = SCNNode(), eyeGlow = SCNNode(), aura = SCNNode(), pulseRing = SCNNode()
    private let beamPivot = SCNNode(), beam = SCNNode()
    private var motes: [SCNNode] = []
    private let shellMat = SCNMaterial(), coreMat = SCNMaterial(), trimMat = SCNMaterial(), lensMat = SCNMaterial(), eyeMat = SCNMaterial()
    private let beamMat = SCNMaterial()
    private var built: ShellSpec?

    init(device: MTLDevice?) {
        renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.autoenablesDefaultLighting = false
        scene.background.contents = NSColor.clear
        scene.lightingEnvironment.contents = GlowTex.sky
        scene.lightingEnvironment.intensity = 1.1

        let cam = SCNCamera()
        cam.usesOrthographicProjection = true
        cam.orthographicScale = 0.5
        cam.zNear = 0.1; cam.zFar = 20
        camera.camera = cam
        camera.position = SCNVector3(0.5, 0.5, 10)
        scene.rootNode.addChildNode(camera)
        renderer.pointOfView = camera

        func light(_ type: SCNLight.LightType, _ intensity: CGFloat, _ color: NSColor, _ euler: SCNVector3) {
            let l = SCNLight(); l.type = type; l.intensity = intensity; l.color = color
            let n = SCNNode(); n.light = l; n.eulerAngles = euler; scene.rootNode.addChildNode(n)
        }
        light(.directional, 1700, NSColor(red: 1, green: 0.97, blue: 0.92, alpha: 1), SCNVector3(-0.75, -0.55, 0))   // key, upper left
        light(.directional, 450, NSColor(red: 0.7, green: 0.8, blue: 1, alpha: 1), SCNVector3(0.3, 0.9, 0))          // fill, right
        light(.directional, 1300, NSColor(red: 0.8, green: 0.9, blue: 1, alpha: 1), SCNVector3(-2.6, 0.4, 0))         // rim, from behind
        light(.ambient, 120, .white, SCNVector3Zero)

        scene.rootNode.addChildNode(body)
        for n in [back, front, eye] { body.addChildNode(n) }

        for m in [shellMat, coreMat, trimMat, lensMat] {
            m.lightingModel = .physicallyBased
            m.diffuse.contents = GlowTex.white
            m.emission.contents = NSColor.black
            m.metalness.contents = 0.5; m.roughness.contents = 0.4
        }
        shellMat.shaderModifiers = [.surface: shellSurface, .fragment: transmatFragment]
        coreMat.shaderModifiers = [.surface: coreSurface, .fragment: transmatFragment]
        trimMat.shaderModifiers = [.fragment: transmatFragment]
        trimMat.metalness.contents = 0.9; trimMat.roughness.contents = 0.28
        lensMat.diffuse.contents = NSColor(white: 0.02, alpha: 1); lensMat.metalness.contents = 0; lensMat.roughness.contents = 0.05
        lensMat.shaderModifiers = [.fragment: transmatFragment]
        eyeMat.lightingModel = .constant
        eyeMat.diffuse.contents = GlowTex.white
        eyeMat.blendMode = .add
        eyeMat.writesToDepthBuffer = false
        eyeMat.shaderModifiers = [.fragment: eyeFragment]

        if let g = GhostParts.geometry("Core")?.copy() as? SCNGeometry {
            g.materials = [coreMat]; let n = SCNNode(geometry: g); body.addChildNode(n)
        }
        if let g = GhostParts.geometry("EyeHousing")?.copy() as? SCNGeometry {
            g.materials = [trimMat]; let n = SCNNode(geometry: g); n.position.z = 0.52; eye.addChildNode(n)
        }
        if let g = GhostParts.geometry("EyeLens")?.copy() as? SCNGeometry {
            g.materials = [lensMat]; let n = SCNNode(geometry: g); n.position.z = 0.53; eye.addChildNode(n)
        }
        if let g = GhostParts.geometry("EyeLight")?.copy() as? SCNGeometry {
            g.materials = [eyeMat]; eyeLight.geometry = g; eyeLight.position.z = 0.612; eyeLight.renderingOrder = 10; eye.addChildNode(eyeLight)
        }

        func sprite(_ node: SCNNode, _ tex: NSImage, _ size: CGFloat, depth: Bool) {
            let p = SCNPlane(width: size, height: size)
            let m = SCNMaterial()
            m.lightingModel = .constant; m.diffuse.contents = tex; m.blendMode = .add
            m.writesToDepthBuffer = false; m.readsFromDepthBuffer = depth
            m.shaderModifiers = [.fragment: "#pragma arguments\nfloat4 tint;\n#pragma body\n_output.color.rgb *= tint.rgb * tint.a;\n_output.color.a *= tint.a * 0.45;\n"]
            p.materials = [m]
            node.geometry = p
            node.renderingOrder = 20
        }
        sprite(aura, GlowTex.radial, 3.2, depth: false); aura.position.z = -0.6; aura.renderingOrder = -5; body.addChildNode(aura)
        sprite(eyeGlow, GlowTex.radial, 1.5, depth: false); eyeGlow.position.z = 0.7; eye.addChildNode(eyeGlow)
        sprite(pulseRing, GlowTex.ring, 2, depth: false); pulseRing.position.z = 0.2; body.addChildNode(pulseRing)

        // Scan beam: an open cone from the eye, light lines running down it.
        let cone = SCNCone(topRadius: 0.06, bottomRadius: 0.9, height: 3)
        beamMat.lightingModel = .constant; beamMat.diffuse.contents = GlowTex.white; beamMat.blendMode = .add
        beamMat.writesToDepthBuffer = false; beamMat.isDoubleSided = true
        beamMat.shaderModifiers = [.fragment: """
        #pragma arguments
        float4 beamP;
        #pragma body
        float2 st = _surface.diffuseTexcoord;
        float lines = 0.75 + 0.25 * smoothstep(0.3, 0.7, fract(st.y * 7.0 - beamP.w * 2.5));
        float fade = smoothstep(0.0, 0.12, st.y) * (1.0 - st.y * 0.75);
        float edge = 1.0 - abs(_surface.normal.z) * 0.6;
        _output.color = float4(beamP.rgb * lines * fade * edge, 1.0);
        """]
        cone.materials = [beamMat]
        beam.geometry = cone; beam.position = SCNVector3(0, -1.6, 0)
        beamPivot.addChildNode(beam); beamPivot.position.z = 0.6
        eye.addChildNode(beamPivot)

        for _ in 0..<48 {
            let n = SCNNode(); sprite(n, GlowTex.sparkle, 1, depth: false); n.isHidden = true
            scene.rootNode.addChildNode(n); motes.append(n)
        }
    }

    // MARK: Shell

    private func build(_ s: ShellSpec) {
        built = s
        for n in front.childNodes + back.childNodes { n.removeFromParentNode() }
        frontSlides = []; backSlides = []
        guard let src = GhostParts.geometry("Plate_" + s.shape) ?? GhostParts.geometry("Plate_facet") else { return }
        let N = s.plates
        let w = Float(s.width * (1 - s.gap)) * sin(.pi / Float(N))
        func ring(_ parent: SCNNode, length: Float, offset: Float, isBack: Bool) -> [SCNNode] {
            let g = src.copy() as! SCNGeometry
            g.materials = [shellMat]
            var out: [SCNNode] = []
            for i in 0..<N {
                let pivot = SCNNode(); pivot.eulerAngles.z = CGFloat(offset + 2 * .pi * Float(i) / Float(N))
                let slide = SCNNode()
                let tilt = SCNNode()
                tilt.position = SCNVector3(0.22, 0, isBack ? 0.30 : 0.52)
                tilt.eulerAngles.y = CGFloat((isBack ? 58 : 38) * Float.pi / 180)
                let mesh = SCNNode(geometry: g)
                mesh.scale = SCNVector3(CGFloat(0.8 * length), CGFloat(w), CGFloat(0.7 + 0.6 * s.facet))
                tilt.addChildNode(mesh); slide.addChildNode(tilt); pivot.addChildNode(slide); parent.addChildNode(pivot)
                out.append(slide)
            }
            return out
        }
        frontSlides = ring(front, length: Float(s.length), offset: 0, isBack: false)
        if s.backRing { backSlides = ring(back, length: Float(s.length) * 0.9, offset: .pi / Float(N), isBack: true) }

        let v4 = { (c: SIMD4<Float>, w: Float) in NSValue(scnVector4: SCNVector4(CGFloat(c.x), CGFloat(c.y), CGFloat(c.z), CGFloat(w))) }
        shellMat.setValue(v4(s.col(s.base), 1), forKey: "baseC")
        shellMat.setValue(v4(s.col(s.accent), 1), forKey: "accentC")
        shellMat.setValue(v4(s.col(s.trim), 1), forKey: "trimC")
        shellMat.setValue(v4(s.col(s.patternColor), 1), forKey: "patC")
        shellMat.setValue(v4(SIMD4(Float(s.metallic), 0, 0, 0), 0), forKey: "shM")
        shellMat.setValue(v4(SIMD4(s.patternIndex, Float(s.patternScale), Float(s.wear), Float(s.glow)), 0), forKey: "shP")
        coreMat.setValue(v4(s.col(s.trim), 1), forKey: "trimC")
        let t = s.col(s.trim)
        trimMat.diffuse.contents = NSColor(srgbRed: CGFloat(t.x), green: CGFloat(t.y), blue: CGFloat(t.z), alpha: 1)
        trimMat.metalness.contents = 0.55 + 0.45 * s.metallic
        needsPrepare = true
    }
    private var needsPrepare = true

    // MARK: Pose

    /// Poses the Ghost from the frame's uniforms. dust: (x, y, size, alpha) in canvas UV.
    /// A three-quarter view for stills (panel thumbnails, the icon), so the plates read as solid.
    var stillView = false

    func apply(_ u: SceneUniforms, spec: ShellSpec, dust: [SIMD4<Float>]) {
        if built != spec { build(spec)
        }
        let v4 = { (x: Float, y: Float, z: Float, w: Float) in NSValue(scnVector4: SCNVector4(CGFloat(x), CGFloat(y), CGFloat(z), CGFloat(w))) }
        let R = u.ghost.z, vis = u.ghost.w, open = u.open, spin = u.pose2.y
        body.position = SCNVector3(CGFloat(u.ghost.x), CGFloat(u.ghost.y), 0)
        body.scale = SCNVector3(CGFloat(R * 1.12), CGFloat(R * 1.12), CGFloat(R * 1.12))
        let yaw = u.pose.y, lookX = u.pose.z, lookY = u.pose.w
        body.eulerAngles = SCNVector3(CGFloat(-lookY * 0.18 + (stillView ? 0.28 : 0)), CGFloat(yaw * 0.75 + lookX * 0.15 + (stillView ? -0.42 : 0)), CGFloat(u.pose.x))
        eye.eulerAngles = SCNVector3(CGFloat(-lookY * 0.30), CGFloat(lookX * 0.30), 0)
        front.eulerAngles.z = CGFloat(spin)
        back.eulerAngles.z = CGFloat(-spin * 0.6)
        for s in frontSlides {
            s.position.x = CGFloat(open * 0.34)
            s.eulerAngles = SCNVector3(0, CGFloat(-0.35 * open), CGFloat(open * 0.35))
        }
        for s in backSlides {
            s.position.x = CGFloat(open * 0.8 * 0.34)
            s.eulerAngles = SCNVector3(0, CGFloat(-0.2 * open), CGFloat(-open * 0.28))
        }

        let blink = u.pose2.x
        let I = u.eyeCol.w * (1 - 0.85 * blink)
        let e = u.eyeCol
        let fx = v4(vis, u.time, open, Float(spec.metallic))
        for m in [shellMat, coreMat, trimMat, lensMat] { m.setValue(fx, forKey: "fx") }
        coreMat.setValue(v4(e.x, e.y, e.z, I), forKey: "eyeC")
        coreMat.setValue(v4(Float(spec.plates), spin, open, 0), forKey: "coreP")
        eyeMat.setValue(v4(e.x, e.y, e.z, I), forKey: "eyeC")
        eyeMat.setValue(v4(spec.eyeIndex, u.time, blink, open), forKey: "eyeP")

        let glowK = 0.5 + u.accent.w
        let fade = vis * vis
        eyeGlow.geometry?.firstMaterial?.setValue(v4(e.x, e.y, e.z, 0.55 * I * glowK * fade), forKey: "tint")
        aura.geometry?.firstMaterial?.setValue(v4(e.x, e.y, e.z, (0.05 + 0.2 * open + 0.12 * u.attention) * glowK * fade), forKey: "tint")
        if u.pulse > 0.0001 {
            pulseRing.isHidden = false
            let s = CGFloat(1.15 + u.pulse)
            pulseRing.scale = SCNVector3(s, s, s)
            pulseRing.geometry?.firstMaterial?.setValue(v4(u.shEye.x, u.shEye.y, u.shEye.z, (1 - u.pulse) * 0.9), forKey: "tint")
        } else { pulseRing.isHidden = true }

        let scan = u.pose2.z * vis
        beamPivot.isHidden = scan < 0.01
        if scan >= 0.01 {
            var d = SIMD2<Float>(u.pose.z, u.pose.w)
            if simd_length(d) < 1e-3 { d = SIMD2(0, -1) }
            d = simd_normalize(d)
            beamPivot.eulerAngles = SCNVector3(0, 0, CGFloat(atan2(d.y, d.x) + .pi / 2))
            beamMat.setValue(v4(0.36 * 0.6 * scan, 0.72 * 0.6 * scan, 0.6 * scan, u.time), forKey: "beamP") // blue scanning light
        }
        eyeLight.scale = SCNVector3(1, 1, 1)
        body.isHidden = vis < 0.01

        for (i, n) in motes.enumerated() {
            if i < dust.count {
                let d = dust[i]
                n.isHidden = false
                n.position = SCNVector3(CGFloat(d.x), CGFloat(d.y), 1)
                let s = CGFloat(d.z * 9)
                n.scale = SCNVector3(s, s, s)
                let tint = (SIMD3(e.x, e.y, e.z) + SIMD3(repeating: 1) * 0.8) / 1.8
                n.geometry?.firstMaterial?.setValue(v4(tint.x, tint.y, tint.z, d.w * 1.4), forKey: "tint")
            } else { n.isHidden = true }
        }
    }

    func render(commandBuffer: MTLCommandBuffer, pass: MTLRenderPassDescriptor, size: CGSize, time: CFTimeInterval) {
        // Rendering into an outside pass skips anything SceneKit has not prepared yet, so prepare it now.
        if needsPrepare { _ = renderer.prepare(scene.rootNode, shouldAbortBlock: nil); needsPrepare = false }
        renderer.render(atTime: time, viewport: CGRect(origin: .zero, size: size), commandBuffer: commandBuffer, passDescriptor: pass)
    }
}
