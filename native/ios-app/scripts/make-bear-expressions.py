"""Builds the bear's facial expression overlays (Bear/Model/PokiBear-expressions.usdz).

Run: blender -b --python make-bear-expressions.py -- <PokiBear_r15.glb> <old PokiBear-expressions.usdz> <out.usdz>

The glb is the bear's source model. The old usdz supplies the thinking meshes (kept as they are); this
script adds the meshes for done, error (sad), needs you (ask), asleep and surprised, drawn on the head's
surface at the standing pose with the same projection the thinking face uses, and writes them all to one
usdz. Each mesh is named Expr_<Face><Part>[_R|_L]; the app finds them by that prefix.

Adapted from a design prototype of the faces. Positions of the pupil decorations are for the pupils where
the app puts them: the model's rest centres moved outward by 0.018, as BearEyeBounds does.
"""
import math
import sys
import bpy
import bmesh
from mathutils import Matrix, Vector
from mathutils.bvhtree import BVHTree

CAM_LOC = Vector((0.0, -3.68, 0.89))


def barycentric_weights_poly(p_verts, pt):
    # Inverse-distance / triangle barycentric interpolation on polygon
    if len(p_verts) >= 3:
        a, b, c = p_verts[0], p_verts[1], p_verts[2]
        v0, v1, v2 = b - a, c - a, pt - a
        d00, d01, d11 = v0.dot(v0), v0.dot(v1), v1.dot(v1)
        d20, d21 = v2.dot(v0), v2.dot(v1)
        denom = d00 * d11 - d01 * d01
        if abs(denom) > 1e-12 and len(p_verts) == 3:
            v = (d11 * d20 - d01 * d21) / denom
            w = (d00 * d21 - d01 * d20) / denom
            u = 1.0 - v - w
            return [u, v, w]
    ws = [1.0 / max((pt - pv).length, 1e-6) for pv in p_verts]
    s = sum(ws)
    return [w / s for w in ws]


def srgb_to_lin(c):
    return tuple((x / 12.92 if x <= 0.04045 else ((x + 0.055) / 1.055) ** 2.4) for x in c)


def emissive(name, srgb):
    """An unlit colour, as the thinking face's materials: black base, the colour as emission."""
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    bsdf = m.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (0, 0, 0, 1)
    lin = srgb_to_lin(srgb)
    bsdf.inputs["Emission Color"].default_value = (lin[0], lin[1], lin[2], 1.0)
    bsdf.inputs["Emission Strength"].default_value = 1.0
    bsdf.inputs["Roughness"].default_value = 1.0
    return m


def load_bear(glb):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=glb)
    scene = bpy.context.scene
    rig = next(o for o in scene.objects if o.type == "ARMATURE")
    act = next(a for a in bpy.data.actions if a.name.startswith("PokiR13Timeline"))
    rig.animation_data.action = act
    if act.slots:
        rig.animation_data.action_slot = act.slots[0]
    scene.frame_set(95)  # the standing pose, which the app binds the overlay to
    return scene, rig


def build_faces(rig, expr_coll, skin_mat):
    dg = bpy.context.evaluated_depsgraph_get()
    head_obj = bpy.data.objects["Head"]
    head_eval = head_obj.evaluated_get(dg)
    me_head = head_eval.to_mesh()
    mw_head = head_eval.matrix_world.copy()
    uv_head_layer = me_head.uv_layers[0]
    head_uv_name = head_obj.data.uv_layers[0].name
    bvh_head = BVHTree.FromObject(head_obj, dg)

    def project_head_with_uv(x, z, lift=0.006, toward_cam=False):
        hit, norm, fidx, _ = bvh_head.ray_cast(Vector((x, -2.0, z)), Vector((0.0, 1.0, 0.0)))
        if hit is None:
            return Vector((x, -0.45, z)), Vector((0.0, -1.0, 0.0)), Vector((0.5, 0.5))
        # Barycentric UV lookup on Head mesh so PokiSkin eyelid has ZERO color seam!
        poly = me_head.polygons[fidx]
        p_verts = [mw_head @ me_head.vertices[vi].co for vi in poly.vertices]
        weights = barycentric_weights_poly(p_verts, hit)
        uv = Vector((0.0, 0.0))
        for w, li in zip(weights, poly.loop_indices):
            uv += uv_head_layer.data[li].uv * w
        if norm.y > 0:
            norm = -norm
        dir_vec = (CAM_LOC - hit).normalized() if toward_cam else norm
        return hit + dir_vec * lift, norm, uv

    def parent_to_bone(obj, bone_name):
        pb = rig.pose.bones[bone_name]
        mw = obj.matrix_world.copy()
        obj.parent = rig
        obj.parent_type = "BONE"
        obj.parent_bone = bone_name
        bone_tail_mat = rig.matrix_world @ pb.matrix @ Matrix.Translation((0.0, pb.bone.length, 0.0))
        obj.matrix_parent_inverse = bone_tail_mat.inverted()
        obj.matrix_world = mw

    def make_decal_obj(name, bm, mat, bone_name="Head", subdiv=1, is_skin=False):
        me = bpy.data.meshes.new(name)
        bm.to_mesh(me)
        bm.free()
        for p in me.polygons:
            p.use_smooth = True
        ob = bpy.data.objects.new(name, me)
        ob.data.materials.append(mat)
        expr_coll.objects.link(ob)
        if subdiv > 0:
            mod = ob.modifiers.new("Subdiv", "SUBSURF")
            mod.levels = subdiv
            mod.render_levels = subdiv
        ob.visible_shadow = False
        if not is_skin:
            ob.visible_diffuse = False
            ob.visible_glossy = False
        parent_to_bone(ob, bone_name)
        ob.hide_render = True
        return ob

    def make_tube_on_head(name, pts_xz, tube_r, mat, lift=0.0065, taper_ends=0.72, toward_cam=False):
        bm = bmesh.new()
        ctrs = []
        for x, z in pts_xz:
            p, _, _ = project_head_with_uv(x, z, lift=lift, toward_cam=toward_cam)
            ctrs.append(p)
        n = len(ctrs)
        segs = 20
        rings = []
        for i, c in enumerate(ctrs):
            tg = (ctrs[min(n - 1, i + 1)] - ctrs[max(0, i - 1)]).normalized()
            n1 = tg.cross(Vector((0.0, 1.0, 0.0))).normalized()
            n2 = n1.cross(tg).normalized()
            u = i / max(n - 1, 1)
            r_cur = tube_r * (taper_ends + (1.0 - taper_ends) * math.sin(math.pi * u))
            rings.append([
                bm.verts.new(c + (math.cos(2 * math.pi * s / segs) * n1 + math.sin(2 * math.pi * s / segs) * n2) * r_cur)
                for s in range(segs)
            ])
        for i in range(n - 1):
            r0, r1 = rings[i], rings[i + 1]
            for s in range(segs):
                sn = (s + 1) % segs
                bm.faces.new((r0[s], r1[s], r1[sn], r0[sn]))
        for end_i, sgn in ((0, -1.0), (-1, 1.0)):
            c = ctrs[end_i]
            tg = ((ctrs[1] - ctrs[0]) if end_i == 0 else (ctrs[-1] - ctrs[-2])).normalized() * sgn
            n1 = tg.cross(Vector((0.0, 1.0, 0.0))).normalized()
            n2 = n1.cross(tg).normalized()
            r_end = tube_r * taper_ends
            mid = [
                bm.verts.new(c + tg * (r_end * 0.55) + (math.cos(2 * math.pi * s / segs) * n1 + math.sin(2 * math.pi * s / segs) * n2) * (r_end * 0.75))
                for s in range(segs)
            ]
            tip = bm.verts.new(c + tg * (r_end * 0.95))
            pr = rings[end_i]
            for s in range(segs):
                sn = (s + 1) % segs
                if sgn < 0:
                    bm.faces.new((pr[s], pr[sn], mid[sn], mid[s]))
                    bm.faces.new((mid[s], mid[sn], tip))
                else:
                    bm.faces.new((pr[s], mid[s], mid[sn], pr[sn]))
                    bm.faces.new((mid[s], tip, mid[sn]))
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
        return make_decal_obj(name, bm, mat, "Head", subdiv=1, is_skin=False)

    def make_patch_on_head(name, outline_xz, ctr_xz, lift, mat, subdiv=1, copy_head_uv=False, toward_cam=False):
        bm = bmesh.new()
        uv_layer = bm.loops.layers.uv.new(head_uv_name if copy_head_uv else "UVMap")
        rings = 7
        m = len(outline_xz)
        p0, _, uv0 = project_head_with_uv(ctr_xz[0], ctr_xz[1], lift=lift, toward_cam=toward_cam)
        v0 = bm.verts.new(p0)
        vert_uv = {v0: uv0}
        r_verts = []
        for r in range(1, rings + 1):
            s = r / rings
            # Taper lift gently to 0.002 at outer top boundary if copy_head_uv so silhouette hugs head seamlessly
            cur_lift = lift * (1.0 - 0.35 * s) if copy_head_uv else lift
            cur = []
            for ox, oz in outline_xz:
                xx = ctr_xz[0] + (ox - ctr_xz[0]) * s
                zz = ctr_xz[1] + (oz - ctr_xz[1]) * s
                pp, _, uvp = project_head_with_uv(xx, zz, lift=cur_lift, toward_cam=toward_cam)
                vv = bm.verts.new(pp)
                vert_uv[vv] = uvp
                cur.append(vv)
            r_verts.append(cur)
        for k in range(m):
            f = bm.faces.new((v0, r_verts[0][(k + 1) % m], r_verts[0][k]))
            for lp in f.loops:
                lp[uv_layer].uv = vert_uv[lp.vert]
        for r in range(rings - 1):
            for k in range(m):
                kn = (k + 1) % m
                f = bm.faces.new((r_verts[r][k], r_verts[r][kn], r_verts[r + 1][kn], r_verts[r + 1][k]))
                for lp in f.loops:
                    lp[uv_layer].uv = vert_uv[lp.vert]
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
        for f in bm.faces:
            if f.normal.y > 0:
                f.normal_flip()
        return make_decal_obj(name, bm, mat, "Head", subdiv=subdiv, is_skin=copy_head_uv)

    # Materials: the thinking face's three (from the old usdz) are reused by name; the others are unlit
    # colours made here.
    def material(name, srgb):
        return bpy.data.materials.get(name) or emissive(name, srgb)

    mat_mouth = material("ExprMouth", (0.26, 0.14, 0.11))
    mat_lid_rim = material("ExprLidRim", (0.71, 0.77, 0.95))
    mat_arc_white = material("ExprArcWhite", (0.975, 0.980, 0.995))
    mat_cl = material("ExprCatchlight", (1.0, 0.996, 0.990))
    mat_cav = material("ExprMouthOpen", (0.38, 0.14, 0.12))
    mat_tng = material("ExprTongue", (0.96, 0.50, 0.45))
    mat_skin = skin_mat

    # Where the app puts the pupils: the model's rest centres (-0.1363 and 0.1324) moved outward by 0.018.
    pupil_r, pupil_l = -0.1363 - 0.018, 0.1324 + 0.018

    # DONE: crescent eyes, each on a soft white edge (the eyes' own whites and pupils go).
    for side, cx, tilt_d in (("R", -0.168, -5.0), ("L", 0.158, 5.0)):
        ct, st = math.cos(math.radians(tilt_d)), math.sin(math.radians(tilt_d))
        arc_pts = []
        for i in range(33):
            u = -1.0 + 2.0 * i / 32.0
            dx = u * 0.098
            dz = 0.025 - 0.058 * (u * u)
            arc_pts.append((cx + dx * ct - dz * st, 0.912 + dx * st + dz * ct))
        make_tube_on_head(f"Expr_DoneWhite_{side}", arc_pts, 0.0255, mat_arc_white, lift=0.005, taper_ends=0.78, toward_cam=True)
        make_tube_on_head(f"Expr_DoneArc_{side}", arc_pts, 0.0195, mat_mouth, lift=0.013, taper_ends=0.76, toward_cam=True)

    # SAD (an error): worried drooping lids in the skin's own texture, a crease under each, a down-turned mouth.
    for side, sgn, cx, cz in (("R", -1.0, -0.176, 0.912), ("L", 1.0, 0.170, 0.908)):
        ang_slant = math.radians(sgn * -21.0)
        ca_s, sa_s = math.cos(ang_slant), math.sin(ang_slant)
        lid_pts, rim_pts = [], []
        for k in range(44):
            a = 2.0 * math.pi * k / 44
            lx = 0.154 * math.cos(a)
            lz = (0.125 * math.sin(a)) if math.sin(a) >= 0 else (0.014 * math.sin(a))
            lid_pts.append((cx + lx * ca_s - lz * sa_s, (cz + 0.038) + lx * sa_s + lz * ca_s))
        for i in range(25):
            u = -1.0 + 2.0 * i / 24.0
            lx = u * 0.116
            lz = -0.013 * (1.0 - u * u)
            rim_pts.append((cx + lx * ca_s - lz * sa_s, (cz + 0.038) + lx * sa_s + lz * ca_s))
        make_patch_on_head(f"Expr_SadLid_{side}", lid_pts, (cx, cz + 0.08), 0.013, mat_skin, subdiv=1, copy_head_uv=True, toward_cam=True)
        make_tube_on_head(f"Expr_SadRim_{side}", rim_pts, 0.0042, mat_lid_rim, lift=0.0145, taper_ends=0.4, toward_cam=True)
    sad_m_pts = [(0.002 + (-1.0 + 2.0 * i / 28.0) * 0.044, 0.812 - 0.022 * (-1.0 + 2.0 * i / 28.0) ** 2) for i in range(29)]
    make_tube_on_head("Expr_SadMouth", sad_m_pts, 0.0085, mat_mouth, lift=0.0065, toward_cam=True)

    # ASK (needs you): a second small catchlight on each pupil, low and to the outside, and a small round mouth.
    # The stance looks 0.006 up and across, and the pupils go with it.
    gx, gz = 0.006, 0.006
    for side, x_cl, z_cl in (("R", pupil_r - 0.0317 + gx, 0.876 + gz), ("L", pupil_l - 0.0284 + gx, 0.874 + gz)):
        mini_pts = [(x_cl + 0.014 * math.cos(2 * math.pi * k / 24), z_cl + 0.014 * math.sin(2 * math.pi * k / 24)) for k in range(24)]
        make_patch_on_head(f"Expr_AskCatch_{side}", mini_pts, (x_cl, z_cl), 0.015, mat_cl, subdiv=0, toward_cam=True)
    ask_m_pts = [(0.002 + 0.029 * math.cos(2 * math.pi * k / 32), 0.803 + 0.024 * math.sin(2 * math.pi * k / 32)) for k in range(32)]
    make_patch_on_head("Expr_AskMouth", ask_m_pts, (0.002, 0.803), 0.0055, mat_cav, subdiv=1, toward_cam=True)
    ask_t_pts = [(0.002 + 0.019 * math.cos(2 * math.pi * k / 28), 0.791 + 0.010 * math.sin(2 * math.pi * k / 28)) for k in range(28)]
    make_patch_on_head("Expr_AskTongue", ask_t_pts, (0.002, 0.791), 0.0072, mat_tng, subdiv=1, toward_cam=True)

    # SLEEP: closed eyes curving down, and a tiny relaxed mouth.
    for side, cx, tilt_d in (("R", -0.166, 8.0), ("L", 0.156, -8.0)):
        ct, st = math.cos(math.radians(tilt_d)), math.sin(math.radians(tilt_d))
        slp_pts = []
        for i in range(29):
            u = -1.0 + 2.0 * i / 28.0
            dx = u * 0.094
            dz = -0.018 + 0.046 * (u * u)
            slp_pts.append((cx + dx * ct - dz * st, 0.902 + dx * st + dz * ct))
        make_tube_on_head(f"Expr_SleepArc_{side}", slp_pts, 0.0150, mat_mouth, lift=0.026, taper_ends=0.74, toward_cam=True)
    slp_m_pts = [(0.002 + (-1.0 + 2.0 * i / 24.0) * 0.027, 0.806 + 0.010 * (-1.0 + 2.0 * i / 24.0) ** 2) for i in range(25)]
    make_tube_on_head("Expr_SleepMouth", slp_m_pts, 0.0074, mat_mouth, lift=0.020, toward_cam=True)

    # SURPRISE: a four-pointed star and a small dot of light in each eye, and a round open mouth.
    for side, sx_c, sz_c, dx2, dz2 in (("R", pupil_r + 0.0323, 0.952, -0.058, -0.068), ("L", pupil_l + 0.0316, 0.950, -0.058, -0.068)):
        star_pts = []
        for k in range(48):
            a = 2.0 * math.pi * k / 48
            w = 0.5 + 0.5 * math.cos(4.0 * a)
            r = 0.019 + (0.037 - 0.019) * (w ** 1.1)
            star_pts.append((sx_c + r * math.cos(a), sz_c + r * math.sin(a)))
        make_patch_on_head(f"Expr_SurpStar_{side}", star_pts, (sx_c, sz_c), 0.015, mat_cl, subdiv=0, toward_cam=True)
        dot_pts = [(sx_c + dx2 + 0.0125 * math.cos(2 * math.pi * k / 24), sz_c + dz2 + 0.0125 * math.sin(2 * math.pi * k / 24)) for k in range(24)]
        make_patch_on_head(f"Expr_SurpDot_{side}", dot_pts, (sx_c + dx2, sz_c + dz2), 0.015, mat_cl, subdiv=0, toward_cam=True)
    surp_m_pts = [(0.002 + 0.038 * math.cos(2 * math.pi * k / 36), 0.795 + 0.043 * math.sin(2 * math.pi * k / 36)) for k in range(36)]
    make_patch_on_head("Expr_SurpMouth", surp_m_pts, (0.002, 0.795), 0.0055, mat_cav, subdiv=1, toward_cam=True)
    surp_t_pts = [(0.002 + 0.025 * math.cos(2 * math.pi * k / 32), 0.770 + 0.015 * math.sin(2 * math.pi * k / 32)) for k in range(32)]
    make_patch_on_head("Expr_SurpTongue", surp_t_pts, (0.002, 0.770), 0.0072, mat_tng, subdiv=1, toward_cam=True)

    head_eval.to_mesh_clear()


def main():
    glb, old_usdz, out = sys.argv[sys.argv.index("--") + 1:][:3]
    scene, rig = load_bear(glb)
    skin = bpy.data.materials["PokiSkin"]
    bpy.ops.wm.usd_import(filepath=old_usdz)  # the thinking meshes and their materials
    # Keep only the thinking meshes from it, so that a file made by this script can be its own input.
    for ob in [o for o in bpy.data.objects if o.name.startswith("Expr_") and not o.name.startswith("Expr_Think")]:
        bpy.data.objects.remove(ob, do_unlink=True)
    expr_coll = bpy.data.collections.new("Expressions")
    scene.collection.children.link(expr_coll)
    build_faces(rig, expr_coll, bpy.data.materials.get("ExprSkin") or skin)
    bpy.ops.object.select_all(action="DESELECT")
    for ob in list(bpy.data.objects):
        if ob.name.startswith("Expr_"):
            ob.parent = None  # keep the world position, which is what the file holds
            ob.matrix_world = ob.matrix_world.copy()
            ob.hide_render = False
            ob.hide_viewport = False
            ob.select_set(True)
    bpy.ops.wm.usd_export(filepath=out, selected_objects_only=True, export_materials=True, export_uvmaps=True,
                          export_armatures=False, export_animation=False, evaluation_mode="RENDER")
    print("exported", sorted(o.name for o in bpy.data.objects if o.name.startswith("Expr_")))


if __name__ == "__main__":
    main()
