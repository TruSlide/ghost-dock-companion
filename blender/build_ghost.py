# Ghost companion, phase 2: the original 3D Ghost, built in code.
# A tribute in the Ghost's design language (eye, core sphere, faceted plates that part and turn). Nothing here is
# taken, traced or extracted from game files: every mesh is generated from the numbers below.
#
# Run headless:
#   /Applications/Blender.app/Contents/MacOS/Blender -b --factory-startup -P blender/build_ghost.py -- [--render]
#
# Writes
#   Resources/GhostParts.usdz   parts the app assembles live in SceneKit (one plate mesh per ShellSpec shape,
#                               core, eye housing, lens, eye light), in SceneKit axes: +Y up, +Z toward the viewer.
#   blender/ghost.blend         the reference scene: a parametric Ghost built from a ShellSpec JSON, its
#                               materials, and one action per act (Idle, Activate, Scan, Spin, Transmat, Nap).
#   docs/sheets/blender-acts.png (with --render) an Eevee contact sheet of every action.
#
# Plate-local axes (shared with Scene3D.swift): x runs root (0) to tip (1), y across, z out of the face.
# The half-width at t is profile(t) * (0.22 + 0.8 t), so the app scales y by width * (1 - gap) * sin(pi / plates).

import bpy, bmesh, json, math, os, sys
from mathutils import Vector

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
ARGS = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []

SHAPES = ["spike", "facet", "blade", "petal", "crown", "shard", "fin"]

def profile(t, shape):
    if shape == "spike": return 1 - t
    if shape == "facet": return 0.62 + 0.38 * t / 0.42 if t < 0.42 else 1 - (t - 0.42) / 0.58
    if shape == "blade": return max(1 - t, 0) ** 0.65 * (1 - 0.25 * t)
    if shape == "petal": return math.sqrt(max(0.0, 1 - (1.6 * t - 0.6) ** 2))
    if shape == "crown": return 0.95
    if shape == "shard": return 1 - 0.9 * t
    s = min(max(t / 0.8, 0), 1); s = s * s * (3 - 2 * s)
    e = min(max((t - 0.86) / 0.14, 0), 1); e = e * e * (3 - 2 * e)
    return (0.4 + 0.6 * s) * (1 - 0.5 * e)                                     # fin

def plate_mesh(shape, nt=18, nv=9):
    """A solid plate: a ridged, slightly curled front face, a flat back, side walls. UV = (t, v)."""
    bm = bmesh.new()
    uv = bm.loops.layers.uv.new("st")
    front, back = [], []
    for i in range(nt + 1):
        t = i / nt
        hw = max(profile(t, shape), 0.02) * (0.22 + 0.8 * t)
        rf, rb = [], []
        for j in range(nv + 1):
            v = -1 + 2 * j / nv
            x = t
            if shape == "crown" and i == nt: x = 1 - 0.16 * (1 - abs(v))        # notched tip
            if shape == "shard" and i == nt: x = 1 - 0.12 * (v * 0.5 + 0.5)     # slanted tip
            yc = 0.0
            if shape == "blade": yc = 0.35 * hw * t * t
            if shape == "shard": yc = 0.45 * hw * t
            y = v * hw + yc
            ridge = 0.045 * (1 - abs(v)) * (0.6 + 0.4 * (1 - t))
            curl = -0.20 * (v * hw) ** 2
            zf = 0.028 + ridge + curl
            zb = -0.028 + curl * 0.9
            rf.append((bm.verts.new((x, y, zf)), t, v))
            rb.append((bm.verts.new((x, y, zb)), t, v))
        front.append(rf); back.append(rb)

    def quad(a, b, c, d, flip=False):
        vs = [a, b, c, d][::-1] if flip else [a, b, c, d]
        f = bm.faces.new([p[0] for p in vs])
        for loop, p in zip(f.loops, vs):
            loop[uv].uv = (p[1], p[2] * 0.5 + 0.5)
        f.smooth = True
    for i in range(nt):
        for j in range(nv):
            quad(front[i][j], front[i + 1][j], front[i + 1][j + 1], front[i][j + 1])
            quad(back[i][j], back[i + 1][j], back[i + 1][j + 1], back[i][j + 1], flip=True)
    for i in range(nt):                                                    # long side walls
        quad(back[i][0], back[i + 1][0], front[i + 1][0], front[i][0])
        quad(front[i][nv], front[i + 1][nv], back[i + 1][nv], back[i][nv])
    for j in range(nv):                                                    # root and tip walls
        quad(front[0][j], front[0][j + 1], back[0][j + 1], back[0][j])
        quad(back[nt][j], back[nt][j + 1], front[nt][j + 1], front[nt][j])
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    # Hard edges at the ridge line and the rims: split edges sharper than 35 degrees.
    bm.normal_update()
    sharp = [e for e in bm.edges if e.is_manifold and e.calc_face_angle(0) > math.radians(35)]
    bmesh.ops.split_edges(bm, edges=sharp)
    me = bpy.data.meshes.new("Plate_" + shape)
    bm.to_mesh(me); bm.free()
    return me

def obj(name, me, coll):
    o = bpy.data.objects.new(name, me); coll.objects.link(o); return o

def uv_sphere(name, r, seg=48, rings=24, scale=(1, 1, 1)):
    bm = bmesh.new()
    bm.loops.layers.uv.new("st")
    bmesh.ops.create_uvsphere(bm, u_segments=seg, v_segments=rings, radius=r, calc_uvs=True)
    for v in bm.verts: v.co = Vector((v.co.x * scale[0], v.co.y * scale[1], v.co.z * scale[2]))
    for f in bm.faces: f.smooth = True
    me = bpy.data.meshes.new(name); bm.to_mesh(me); bm.free()
    return me

def ring_mesh(name, r_out, r_in, depth, seg=64):
    """Eye housing: a bevelled ring facing +Z."""
    bm = bmesh.new()
    prof = [(r_in, -depth / 2), (r_in, depth / 2 - 0.012), (r_in + 0.012, depth / 2),
            (r_out - 0.016, depth / 2), (r_out, depth / 2 - 0.016), (r_out, -depth / 2)]
    rows = []
    for k in range(seg):
        a = 2 * math.pi * k / seg
        rows.append([bm.verts.new((r * math.cos(a), r * math.sin(a), z)) for r, z in prof])
    for k in range(seg):
        a, b = rows[k], rows[(k + 1) % seg]
        for i in range(len(prof) - 1):
            f = bm.faces.new([a[i], b[i], b[i + 1], a[i + 1]]); f.smooth = True
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new(name); bm.to_mesh(me); bm.free()
    return me

def disc_mesh(name, r, seg=64):
    bm = bmesh.new()
    uv = bm.loops.layers.uv.new("st")
    c = bm.verts.new((0, 0, 0))
    ring = [bm.verts.new((r * math.cos(2 * math.pi * k / seg), r * math.sin(2 * math.pi * k / seg), 0)) for k in range(seg)]
    for k in range(seg):
        f = bm.faces.new([c, ring[k], ring[(k + 1) % seg]])
        for loop in f.loops:
            p = loop.vert.co
            loop[uv].uv = (p.x / (2 * r) + 0.5, p.y / (2 * r) + 0.5)
    me = bpy.data.meshes.new(name); bm.to_mesh(me); bm.free()
    return me

# ---------------------------------------------------------------- scene

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
parts = bpy.data.collections.new("GhostParts"); scene.collection.children.link(parts)

plates = {s: obj("Plate_" + s, plate_mesh(s), parts) for s in SHAPES}
core = obj("Core", uv_sphere("Core", 0.5), parts)
housing = obj("EyeHousing", ring_mesh("EyeHousing", 0.30, 0.225, 0.10), parts); housing.location = (0, 0, 0.52)
lens = obj("EyeLens", uv_sphere("EyeLens", 0.235, scale=(1, 1, 0.32)), parts); lens.location = (0, 0, 0.53)
light = obj("EyeLight", disc_mesh("EyeLight", 0.21), parts); light.location = (0, 0, 0.61)
for i, o in enumerate(plates.values()): o.location = (0, 0, 0)

# ---------------------------------------------------------------- materials (Blender preview; the app sets its own)

def mat(name, col, metal=0.5, rough=0.4, emit=None, strength=0.0):
    m = bpy.data.materials.new(name); m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (*col, 1); b.inputs["Metallic"].default_value = metal
    b.inputs["Roughness"].default_value = rough
    if emit:
        b.inputs["Emission Color"].default_value = (*emit, 1); b.inputs["Emission Strength"].default_value = strength
    return m

def hexcol(h):
    h = h.lstrip("#"); c = [int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    return tuple(x / 12.92 if x <= 0.04045 else ((x + 0.055) / 1.055) ** 2.4 for x in c)

def shell_material(spec):
    """Base, accent, trim, pattern, metallic, wear and glow in one node tree, keyed on the plate UV (t, v)."""
    m = bpy.data.materials.new("Shell_" + spec["id"]); m.use_nodes = True
    nt = m.node_tree; N = nt.nodes; L = nt.links
    b = N["Principled BSDF"]
    tc = N.new("ShaderNodeUVMap"); tc.uv_map = "st"
    sep = N.new("ShaderNodeSeparateXYZ"); L.new(tc.outputs[0], sep.inputs[0])
    # v in -1..1, |v|
    v = N.new("ShaderNodeMath"); v.operation = "MULTIPLY_ADD"; v.inputs[1].default_value = 2; v.inputs[2].default_value = -1
    L.new(sep.outputs[1], v.inputs[0])
    av = N.new("ShaderNodeMath"); av.operation = "ABSOLUTE"; L.new(v.outputs[0], av.inputs[0])
    pat = spec["pattern"]
    mask = N.new("ShaderNodeMath"); mask.operation = "LESS_THAN"
    if pat == "stripe": L.new(av.outputs[0], mask.inputs[0]); mask.inputs[1].default_value = 0.28
    elif pat == "split": mask.operation = "GREATER_THAN"; L.new(v.outputs[0], mask.inputs[0]); mask.inputs[1].default_value = 0
    elif pat == "tips": mask.operation = "GREATER_THAN"; L.new(sep.outputs[0], mask.inputs[0]); mask.inputs[1].default_value = 0.66
    elif pat == "band":
        d = N.new("ShaderNodeMath"); d.operation = "SUBTRACT"; L.new(sep.outputs[0], d.inputs[0]); d.inputs[1].default_value = 0.55
        a = N.new("ShaderNodeMath"); a.operation = "ABSOLUTE"; L.new(d.outputs[0], a.inputs[0])
        L.new(a.outputs[0], mask.inputs[0]); mask.inputs[1].default_value = 0.12
    else: mask.inputs[0].default_value = 1; mask.inputs[1].default_value = 0     # 0: base only
    mix = N.new("ShaderNodeMix"); mix.data_type = "RGBA"
    L.new(mask.outputs[0], mix.inputs["Factor"])
    mix.inputs["A"].default_value = (*hexcol(spec["base"]), 1); mix.inputs["B"].default_value = (*hexcol(spec["accent"]), 1)
    # Trim at the rims.
    edge = N.new("ShaderNodeMath"); edge.operation = "GREATER_THAN"; L.new(av.outputs[0], edge.inputs[0]); edge.inputs[1].default_value = 0.86
    trim = N.new("ShaderNodeMix"); trim.data_type = "RGBA"
    L.new(edge.outputs[0], trim.inputs["Factor"]); L.new(mix.outputs["Result"], trim.inputs["A"])
    trim.inputs["B"].default_value = (*hexcol(spec["trim"]), 1)
    # Wear: noise scuffs lift the colour and roughen it.
    noise = N.new("ShaderNodeTexNoise"); noise.inputs["Scale"].default_value = 24
    ramp = N.new("ShaderNodeMapRange"); L.new(noise.outputs["Fac"], ramp.inputs[0])
    ramp.inputs[1].default_value = 0.6; ramp.inputs[2].default_value = 0.78; ramp.inputs[4].default_value = spec["wear"] * 0.85
    worn = N.new("ShaderNodeMix"); worn.data_type = "RGBA"
    L.new(ramp.outputs[0], worn.inputs["Factor"]); L.new(trim.outputs["Result"], worn.inputs["A"])
    worn.inputs["B"].default_value = (0.35, 0.35, 0.35, 1)
    L.new(worn.outputs["Result"], b.inputs["Base Color"])
    b.inputs["Metallic"].default_value = spec["metallic"]
    rough = N.new("ShaderNodeMath"); rough.operation = "ADD"; rough.inputs[0].default_value = 0.55 - 0.35 * spec["metallic"]
    L.new(ramp.outputs[0], rough.inputs[1]); L.new(rough.outputs[0], b.inputs["Roughness"])
    if pat in ("circuit", "crack"):
        b.inputs["Emission Color"].default_value = (*hexcol(spec["patternColor"]), 1)
        b.inputs["Emission Strength"].default_value = 0.4 + 2 * spec["glow"]
    return m

# ---------------------------------------------------------------- the reference rig (Blender only)

spec_path = os.path.join(HERE, "reference_shell.json")
spec = json.load(open(spec_path))

rig = bpy.data.collections.new("GhostRig"); scene.collection.children.link(rig)
def empty(name, parent=None):
    e = bpy.data.objects.new(name, None); rig.objects.link(e); e.parent = parent; return e

axes = empty("Axes")                         # SceneKit axes (+Y up, +Z front) inside Blender (+Z up, -Y front)
axes.rotation_euler = (math.radians(90), 0, 0)
body = empty("Body", axes)
ring = empty("FrontRing", body)
backring = empty("BackRing", body)
eye = empty("Eye", body)

m_shell = shell_material(spec)
m_core = mat("Core", (0.03, 0.035, 0.045), metal=0.8, rough=0.35, emit=hexcol(spec["eye"]), strength=0.3)
m_trim = mat("Trim", hexcol(spec["trim"]), metal=0.9, rough=0.3)
m_lens = mat("Lens", (0.01, 0.012, 0.02), metal=0.0, rough=0.05)
m_eye = mat("EyeLight", (0, 0, 0), emit=hexcol(spec["eye"]), strength=8)

def inst(src, name, parent, m):
    o = bpy.data.objects.new(name, src.data); rig.objects.link(o); o.parent = parent
    o.data.materials.clear() if o.data.users == 1 else None
    o.material_slots and None
    o.active_material = m
    return o

for src, m, par in ((core, m_core, body), (housing, m_trim, eye), (lens, m_lens, eye), (light, m_eye, eye)):
    o = inst(src, src.name + "_ref", par, m); o.location = src.location

N = spec["plates"]; L0 = spec["length"]; W = spec["width"] * (1 - spec["gap"]) * math.sin(math.pi / N)
pivots = []
def add_ring(parent, length, offset, back):
    for i in range(N):
        p = empty(f"{parent.name}_{i}", parent); p.rotation_euler = (0, 0, offset + 2 * math.pi * i / N)
        slide = empty(p.name + "_slide", p)                       # animated: open slides along x, twists about z
        tilt = empty(p.name + "_tilt", slide); tilt.location = (0.22, 0, 0.30 if back else 0.52)
        tilt.rotation_euler = (0, math.radians(58 if back else 38), 0)
        o = inst(plates[spec["shape"]], p.name + "_mesh", tilt, m_shell)
        o.scale = (0.8 * length, W, 0.7 + 0.6 * spec["facet"])
        pivots.append((slide, back))
add_ring(ring, L0, 0, False)
if spec["backRing"]: add_ring(backring, L0 * 0.9, math.pi / N, True)

# ---------------------------------------------------------------- actions (curves match GhostBrain / SceneRenderer)

scene.render.fps = 30
def key(o, path, frame, value, index=-1):
    setattr(o, path, value) if index < 0 else getattr(o, path).__setitem__(index, value)
    o.keyframe_insert(path, index=index, frame=frame)

def set_open(frame, k):
    for slide, back in pivots:
        kk = k * (0.8 if back else 1)
        key(slide, "location", frame, 0.34 * kk, 0)
        key(slide, "rotation_euler", frame, 0.35 * kk, 2)
        key(slide, "rotation_euler", frame, -0.35 * kk, 1)        # plates lift away from the core as they part

def action(name, frames, build):
    for o in [body, ring, backring, eye] + [s for s, _ in pivots]:
        o.animation_data_clear()
    build()
    acts = {}
    for o in [body, ring, backring, eye] + [s for s, _ in pivots]:
        if o.animation_data and o.animation_data.action:
            a = o.animation_data.action; a.name = f"{name}.{o.name}"; a.use_fake_user = True; acts[o.name] = a
    return {"name": name, "frames": frames, "actions": acts}

def idle():
    for f in range(0, 121, 10):
        t = f / 30
        key(body, "location", f, 0.06 * math.sin(t * 1.7) + 0.03 * math.sin(t * 0.63), 1)
        key(eye, "rotation_euler", f, 0.18 * math.sin(t * 0.9), 1)
        key(eye, "rotation_euler", f, 0.08 * math.sin(t * 0.5), 0)
        key(ring, "rotation_euler", f, 0.25 * t, 2)
    set_open(0, 0.04); set_open(120, 0.07)

def activate():
    for f, k in ((0, 0), (24, 0.35), (54, 0.85), (72, 0.85), (90, 0.9)):
        set_open(f, k)
    for f in range(0, 91, 6):
        p = min(f / 72, 1); s = p * p * (3 - 2 * p)
        key(ring, "rotation_euler", f, s * 2 * math.pi * 0.75 + max(0, f - 72) / 30 * 0.5, 2)
        key(backring, "rotation_euler", f, -0.6 * s * 2 * math.pi * 0.75, 2)
    m_eye.node_tree.nodes["Principled BSDF"].inputs["Emission Strength"].keyframe_insert("default_value", frame=0)

def scan():
    for f, y in ((0, 0), (30, -0.45), (120, -0.45), (150, 0)):
        key(eye, "rotation_euler", f, y, 0)
    for f in range(30, 121, 15):
        key(body, "rotation_euler", f, 0.5 * math.sin((f - 30) / 90 * 2 * math.pi), 1)
    set_open(0, 0.04); set_open(40, 0.18); set_open(110, 0.18); set_open(150, 0.04)

def spin():
    for f in range(0, 85, 6):
        p = f / 84; key(ring, "rotation_euler", f, 14 * 2.8 * (p - p * p * 0.5) / 1.0, 2)
    set_open(0, 0.04); set_open(30, 0.25); set_open(84, 0.04)

def transmat():
    for f, s in ((0, 1), (30, 1.08), (36, 0.001), (48, 0.001), (54, 1.08), (72, 1)):
        for i in range(3): key(body, "scale", f, s, i)

def nap():
    for f, y in ((0, 0), (40, -0.35), (300, -0.35), (340, 0)):
        key(body, "location", f, y, 1)
    for f, r in ((0, 0), (40, 0.5), (300, 0.5), (340, 0)):
        key(body, "rotation_euler", f, r, 0)
    set_open(0, 0.04); set_open(40, 0.0); set_open(300, 0.0); set_open(340, 0.04)

ACTS = [action("Idle", 120, idle), action("Activate", 90, activate), action("Scan", 150, scan),
        action("Spin", 84, spin), action("Transmat", 72, transmat), action("Nap", 340, nap)]

# ---------------------------------------------------------------- export the parts

bpy.ops.object.select_all(action="DESELECT")
for o in parts.objects: o.select_set(True)
usdz = os.path.join(ROOT, "Resources", "GhostParts.usdz")
bpy.ops.wm.usd_export(filepath=usdz, selected_objects_only=True, export_materials=False, export_uvmaps=True,
                      rename_uvmaps=False, export_normals=True, export_animation=False, convert_orientation=False,
                      triangulate_meshes=True, root_prim_path="/GhostParts")
parts.hide_render = True
for o in parts.objects: o.hide_set(True)

# ---------------------------------------------------------------- lights, camera, save, optional sheet

world = bpy.data.worlds.new("World"); scene.world = world; world.use_nodes = True
world.node_tree.nodes["Background"].inputs[0].default_value = (0.02, 0.025, 0.035, 1)
for name, rot, e, c in (("Key", (50, 0, -35), 4.0, (1, 0.97, 0.92)), ("Fill", (70, 0, 120), 1.2, (0.7, 0.8, 1)),
                        ("Rim", (-40, 0, 180), 3.0, (0.8, 0.9, 1))):
    ld = bpy.data.lights.new(name, "SUN"); ld.energy = e; ld.color = c
    lo = bpy.data.objects.new(name, ld); scene.collection.objects.link(lo)
    lo.rotation_euler = tuple(math.radians(a) for a in rot)
cam = bpy.data.objects.new("Camera", bpy.data.cameras.new("Camera")); scene.collection.objects.link(cam)
cam.data.type = "ORTHO"; cam.data.ortho_scale = 3.6
cam.location = (0, -10, 0); cam.rotation_euler = (math.radians(90), 0, 0)
scene.camera = cam
scene.render.engine = "BLENDER_EEVEE"
scene.render.film_transparent = True
scene.render.resolution_x = scene.render.resolution_y = 360

bpy.ops.wm.save_as_mainfile(filepath=os.path.join(HERE, "ghost.blend"))
print("wrote", usdz)

if "--render" in ARGS:
    out = os.path.join(HERE, "renders"); os.makedirs(out, exist_ok=True)
    shots = []
    for a in ACTS:
        for o in [body, ring, backring, eye] + [s for s, _ in pivots]:
            o.animation_data_clear()
            act = a["actions"].get(o.name)
            if act: o.animation_data_create().action = act
        for k, frac in enumerate((0.0, 0.4, 0.75)):
            scene.frame_set(int(a["frames"] * frac))
            p = os.path.join(out, f"{a['name']}_{k}.png"); scene.render.filepath = p
            bpy.ops.render.render(write_still=True); shots.append(p)
    print("rendered", len(shots))
