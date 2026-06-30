class_name ClothSim extends Node3D
##
## DC1 character cloth (turban + ponchos) as a pragmatic, .clo-driven Verlet sim.
##
## The C# exporter emits each cloth piece as an unweighted `cloth_<frame>` MeshInstance3D skinned 100%
## to its anchor bone (so with `enabled = false` the render is the rigid bone-follow pose, identical to
## pre-sim). Alongside the GLB it writes a `<base>.cloth.json` sidecar carrying everything the runtime
## can't derive: the grid (cols x rows, column-major, vertexIndex = col*rows + row), the row-0 pin set,
## the bone-LOCAL rest verts, the .clo params (gravity/follow/k/windeffect/normal), and the BOUND
## ellipsoid colliders (parented to named bones).
##
## At runtime we run a fixed-60Hz Verlet in WORLD space: pin row-0 to the live anchor-bone pose, droop
## free verts under GRAVITY, pull toward the rigid (anchor-driven) target by a ROW-WEIGHTED FOLLOW
## (full at the pinned neckline, small residual at the free hem so the hem swings instead of sticking),
## relax grid-neighbor distance springs by K, push out of the body colliders (overlapping ellipsoids
## resolved with sub-passes), recompute normals (flipped per NORMAL), and rebuild the ArrayMesh surface
## each frame (positions+normals from sim; uvs/indices/material cached).
##
## The poncho is TWO panels (cloth2 front / cloth3 back) hanging from the same neckline — not a doubled
## sheet — so both are simulated independently. FOLLOW is applied ONCE per substep (not per iteration):
## applying the authored 0.9 follow inside the relax loop glued the whole poncho rigid.
##
## Constants (gravity 0.1, K 0.08, follow) are authored for a 60Hz unit timestep, so we accumulate to
## FIXED substeps rather than scaling by delta. A teleport guard snaps (skips sim) on big anchor jumps.

@export var enabled := true
@export_file("*.json") var cloth_json_path := "res://assets/models/chara/c01d/c01d.cloth.json"
## The skinned GLB scene root (holds the Skeleton3D + the cloth_<frame> MeshInstance3Ds). Defaults to a
## sibling node named "Model".
@export var model_path: NodePath = NodePath("../Model")

## Ship knobs (global multipliers over the per-piece .clo params).
@export_range(0.0, 4.0, 0.05) var wind_strength := 1.0
@export_range(0.0, 4.0, 0.05) var stiffness := 1.0
@export var wind_dir := Vector3(0.2, 0.05, 1.0)
@export_range(1, 8) var iterations := 4
## FLOPPINESS: global multiplier on FOLLOW. 1.0 = authored .clo follow; LOWER = looser/floppier hem
## (more sway/lag). The poncho's authored follow is 0.9 (stiff), so the default scales it down a bit.
@export_range(0.0, 2.0, 0.05) var floppiness := 1.0
## Per-row FOLLOW falloff exponent. The pinned neckline (row 0) follows the body fully; the free hem
## (max row) follows ~0 so it billows. Higher = the hem goes free sooner. follow_w = follow*(1-row/(rows-1))^p.
@export_range(0.5, 4.0, 0.1) var follow_falloff := 1.6
## Clearance (world units) the cloth rides OUTSIDE the fitted body colliders — SNUG, not floaty. Small
## values keep the poncho hugging the body; larger lifts it off. ~0.03 reads as "resting on the wool".
@export_range(0.0, 1.0, 0.01) var collider_margin := 0.08
## Anchor displacement (world units) in one substep above which we SNAP (skip sim) — avoids stretch on
## warps / cutscene cuts.
@export var teleport_threshold := 200.0

const SUBSTEP := 1.0 / 60.0
const MAX_SUBSTEPS := 4          # clamp catch-up so a frame hitch can't spiral
const DAMPING := 0.97            # Verlet velocity retention per substep
const WIND_BASE := 0.03          # base gust force (units/substep) — gravity is 0.1, so wind is a breeze
const MAX_VEL := 0.6             # per-substep velocity clamp (units) so the hem can never launch/explode
const HEM_FOLLOW_MIN := 0.22     # residual follow at the free hem (never 0, or gravity sags it forever)
const BOUND_PASSES := 3          # per-vertex collision sub-iterations so OVERLAPPING ellipsoids converge
const MAX_STRETCH := 1.03        # strain limit: max edge length / rest length, so fast motion can't elongate the fabric

var _skel: Skeleton3D = null
var _pieces: Array = []          # Array[_Piece]
var _accum := 0.0
var _time := 0.0
var _ready_ok := false
var _pose_init := false           # defer seed + collider fit to the first ANIMATED frame
var _warmup := 0

# DYNAMIC body colliders, fitted ONCE to the real body-skin mesh and attached to torso/arm bones so they
# track the body through animation (this is what keeps the poncho snug as the body moves — the static bake
# couldn't). Each entry: { bone:int, center:Vector3 (bone-LOCAL), radii:Vector3 (bone-LOCAL ellipsoid) }.
# Shared across all pieces (the body is one body). Re-fit only on (re)seed.
var _body_cols: Array = []


# One simulated cloth piece: the mesh, its cached render arrays, and the live Verlet state.
class _Piece:
	var mesh: MeshInstance3D
	var mat: Material
	var cols: int
	var rows: int
	var anchor_idx: int = -1
	var pin_row: int = 0                  # which grid row is the attached/pinned edge (0 or rows-1)
	var gravity: Vector3
	var follow: Vector3
	var k: Vector3
	var windeffect: float
	var normal_sign: float = 1.0
	# Verlet state (WORLD space), indexed by MDS/grid vertex (i = col*rows + row).
	var pos: PackedVector3Array
	var prev: PackedVector3Array
	var rest_local: PackedVector3Array   # bone-LOCAL rest verts (column-major)
	var pinned: PackedInt32Array
	var is_pinned: PackedByteArray
	# Per-vertex FOLLOW weight: 1 at the pinned row, falling toward 0 at the free hem (so the hem swings).
	var follow_w: PackedFloat32Array
	# Distance constraints: pairs (a,b) of grid neighbors + their rest length.
	var con_a: PackedInt32Array
	var con_b: PackedInt32Array
	var con_len: PackedFloat32Array
	# Render topology (cached once).
	var uvs: PackedVector2Array
	var indices: PackedInt32Array
	# Body colliders, resolved to bone indices + their local ellipsoid params.
	var bounds: Array
	var last_anchor_origin: Vector3
	var initialized := false


func _ready() -> void:
	if not enabled:
		return
	var model := get_node_or_null(model_path)
	if model == null:
		push_warning("ClothSim: model_path '%s' not found; disabled" % model_path)
		return
	_skel = _find_skeleton(model)
	if _skel == null:
		push_warning("ClothSim: no Skeleton3D under model; disabled")
		return

	var data := _load_json(cloth_json_path)
	if data.is_empty() or not data.has("pieces"):
		push_warning("ClothSim: could not load cloth json '%s'; disabled" % cloth_json_path)
		return

	# Godot's glTF importer renames our "cloth_<frame>" mesh nodes (e.g. to Mesh10/Mesh13/...), so we
	# can't match by name. Instead pair each piece (in JSON order: cloth1,cloth2,cloth3) to a cloth
	# MeshInstance3D by VERTEX COUNT (== cols*rows), consumed in scene order — exactly the deterministic
	# order the exporter emitted them. The two 63-vert ponchos fall out as the 1st/2nd 63-vert mesh.
	var all_meshes: Array[MeshInstance3D] = []
	_collect_meshes(model, all_meshes)
	var consumed: Array[bool] = []
	consumed.resize(all_meshes.size())

	for pd in data["pieces"]:
		var want_vc: int = int(pd["grid"]["cols"]) * int(pd["grid"]["rows"])
		var mi: MeshInstance3D = _claim_mesh(all_meshes, consumed, want_vc)
		if mi == null:
			push_warning("ClothSim: no unclaimed %d-vert mesh for piece '%s'" % [want_vc, pd.get("frame", "?")])
			continue
		var piece := _build_piece(pd, mi)
		if piece != null:
			_pieces.append(piece)

	_ready_ok = _pieces.size() > 0
	if not _ready_ok:
		push_warning("ClothSim: no cloth pieces resolved; disabled")


func _find_skeleton(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var s := _find_skeleton(c)
		if s != null:
			return s
	return null


func _collect_meshes(n: Node, out: Array[MeshInstance3D]) -> void:
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		_collect_meshes(c, out)


func _mesh_vcount(mi: MeshInstance3D) -> int:
	if mi.mesh == null or mi.mesh.get_surface_count() == 0:
		return -1
	var v: PackedVector3Array = mi.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	return v.size()


func _claim_mesh(meshes: Array[MeshInstance3D], consumed: Array[bool], want_vc: int) -> MeshInstance3D:
	for i in range(meshes.size()):
		if consumed[i]:
			continue
		if _mesh_vcount(meshes[i]) == want_vc:
			consumed[i] = true
			return meshes[i]
	return null


func _build_piece(pd: Dictionary, mi: MeshInstance3D) -> _Piece:
	var node_name: String = pd.get("mesh_node", "")

	var p := _Piece.new()
	p.mesh = mi
	p.cols = int(pd["grid"]["cols"])
	p.rows = int(pd["grid"]["rows"])
	p.gravity = _v3(pd.get("gravity", [0, -0.1, 0]))
	p.follow = _v3(pd.get("follow", [0.3, 0.3, 0.3]))
	p.k = _v3(pd.get("k", [0.08, 0.08, 0.08]))
	p.windeffect = float(pd.get("windeffect", 1.0))
	p.normal_sign = signf(float(pd.get("normal", 1.0)))
	if p.normal_sign == 0.0:
		p.normal_sign = 1.0

	# Anchor bone (the joint the cloth verts are bound to in the GLB) by name.
	var anchor_name: String = pd.get("anchor_bone", "")
	p.anchor_idx = _skel.find_bone(anchor_name)
	if p.anchor_idx < 0:
		push_warning("ClothSim: anchor bone '%s' not found in skeleton" % anchor_name)
		return null

	# Rest verts (bone-LOCAL, column-major).
	var rest: Array = pd.get("rest_positions", [])
	var vc := rest.size()
	if vc != p.cols * p.rows:
		push_warning("ClothSim: piece '%s' rest count %d != %dx%d" % [node_name, vc, p.cols, p.rows])
		return null
	p.rest_local = PackedVector3Array()
	p.rest_local.resize(vc)
	for i in range(vc):
		p.rest_local[i] = _v3(rest[i])

	# Determine the ATTACHED (pinned) edge by GEOMETRY instead of trusting the export's "row 0" convention:
	# the cloth hangs DOWN, so whichever end-row sits HIGHER (world-Y) at the bind pose is the collar/crown
	# that attaches to the body. The exporter pins col*Rows (grid row 0), but if our grid order is inverted
	# vs the .clo, that pins the free tip and frees the attached edge -> the sheet detaches and launches
	# (turban spike, poncho ride-up). Picking the high edge fixes that regardless of grid orientation.
	var ax_rest := _skel.global_transform * _skel.get_bone_global_rest(p.anchor_idx)
	var y0 := 0.0
	var yn := 0.0
	for col in range(p.cols):
		y0 += (ax_rest * p.rest_local[col * p.rows + 0]).y
		yn += (ax_rest * p.rest_local[col * p.rows + (p.rows - 1)]).y
	p.pin_row = 0 if y0 >= yn else (p.rows - 1)

	# Pin the attached row.
	p.is_pinned = PackedByteArray()
	p.is_pinned.resize(vc)
	p.pinned = PackedInt32Array()
	for col in range(p.cols):
		var idx := col * p.rows + p.pin_row
		p.is_pinned[idx] = 1
		p.pinned.append(idx)

	# Per-row FOLLOW weight: 1 at the pinned (attached) edge, decaying to HEM_FOLLOW_MIN at the free edge so
	# the attached edge tracks the body and the hem hangs/sways. (The dropped decomp "rotation-blend falloff".)
	p.follow_w = PackedFloat32Array()
	p.follow_w.resize(vc)
	var denom := maxf(float(p.rows - 1), 1.0)
	for col in range(p.cols):
		for row in range(p.rows):
			var i := col * p.rows + row
			var t := float(abs(row - p.pin_row)) / denom    # 0 at pin row, 1 at the free edge
			p.follow_w[i] = lerpf(HEM_FOLLOW_MIN, 1.0, pow(1.0 - t, follow_falloff))

	# Seed the Verlet state from the current anchor pose (world).
	var ax := _skel.global_transform * _skel.get_bone_global_pose(p.anchor_idx)
	p.pos = PackedVector3Array()
	p.pos.resize(vc)
	p.prev = PackedVector3Array()
	p.prev.resize(vc)
	for i in range(vc):
		var w := ax * p.rest_local[i]
		p.pos[i] = w
		p.prev[i] = w
	p.last_anchor_origin = ax.origin

	# Grid-neighbor distance constraints (rest length from bone-local rest verts).
	p.con_a = PackedInt32Array()
	p.con_b = PackedInt32Array()
	p.con_len = PackedFloat32Array()
	for col in range(p.cols):
		for row in range(p.rows):
			var i := col * p.rows + row
			if row + 1 < p.rows:
				_add_con(p, i, col * p.rows + (row + 1))
			if col + 1 < p.cols:
				_add_con(p, i, (col + 1) * p.rows + row)

	# Render topology (uvs + triangle indices) from the SIDECAR in GRID order -- NOT the GLB surface
	# (SharpGLTF/Godot reorder the cloth verts, so the GLB index/uv order != our column-major grid
	# order; trusting it stitched the wrong points = the shard bug). Material stays from the GLB.
	p.uvs = PackedVector2Array()
	for uv in pd.get("uvs", []):
		p.uvs.append(Vector2(float(uv[0]), float(uv[1])))
	p.indices = PackedInt32Array()
	for ti in pd.get("triangles", []):
		p.indices.append(int(ti))
	p.mat = mi.mesh.surface_get_material(0)

	# Body collision uses the SHARED, body-mesh-FITTED colliders (built in _fit_body_colliders, attached to
	# torso/arm bones so they animate). The .clo BOUND ellipsoids are ignored: their authored extents are in a
	# scale we can't reliably map, so taken raw they balloon/clip — fitting to the real skin is verifiable and snug.
	p.bounds = _body_cols   # same reference for every piece; the body is one body

	# The sim owns the verts now — drop the skin so Godot's skinning doesn't fight us, and pin the
	# instance at world origin (we write WORLD-space positions, then convert to the instance's local
	# space each frame, so the rendered transform is irrelevant — but null skin avoids GPU re-deform).
	mi.skin = null

	# Hand the surface a working mesh we fully own (so we never mutate the imported resource).
	var am := ArrayMesh.new()
	mi.mesh = am
	p.initialized = true
	return p


func _reseed_and_fit() -> void:
	# Fit the dynamic body colliders to the real skin mesh (once, against the current animated pose), THEN
	# re-seed every cloth vert from the current anchor pose AND eject it out of those colliders so the sim
	# starts already snug on the body (not sunk into the authored rest, not floating).
	_fit_body_colliders()
	for p: _Piece in _pieces:
		var ax := _skel.global_transform * _skel.get_bone_global_pose(p.anchor_idx)
		for i in range(p.pos.size()):
			var w: Vector3 = ax * p.rest_local[i]
			p.pos[i] = w
			p.prev[i] = w
		p.last_anchor_origin = ax.origin
		_resolve_bounds(p)             # push the seeded verts onto the body surface immediately
		for i in range(p.pos.size()):
			p.prev[i] = p.pos[i]       # zero implicit velocity after the eject so it doesn't snap


# Fit a small set of body colliders to the actual body-skin mesh and store each relative to a body bone, so
# they MOVE WITH THE BODY through animation. The torso is approximated by a vertical STACK of horizontal
# elliptical-cylinder disks (each a constant XZ ellipse over a Y band — so the chest can be wider/more-forward
# than the belly, and overlapping bands leave no vertical gap). Each disk is attached to the nearest torso
# bone in the spine chain, so a torso lean/bob carries the whole stack — keeping the poncho snug as the body
# moves. This is the verifiable, body-sized alternative to the .clo BOUND ellipsoids (authored scale unmappable).
func _fit_body_colliders() -> void:
	_body_cols.clear()
	var body := _find_body_mesh()
	if body == null:
		push_warning("ClothSim: no body skin mesh found; cloth has no body collision")
		return

	# Body skin verts in WORLD space at the CURRENT pose. The skin is a real skinned mesh, so read its surface
	# and push each vert through the skeleton's current skinning to get its live world position.
	var world_verts := _skinned_world_verts(body)
	if world_verts.is_empty():
		return

	# Selection + fit run in the SKELETON's LOCAL frame so they are INDEPENDENT of where Toan stands/faces in
	# the world. The old code gated torso verts by ABSOLUTE world y/x, which only matched the torso when the
	# model sat at the world origin (the isolated player.tscn test). In the real game Toan spawns out in the
	# town at an arbitrary world position, so that band missed his ENTIRE body and ZERO colliders were fit ->
	# nothing ejected the poncho (it stayed at its sunk-in authored rest). Working in skeleton-local fixes that.
	var s2w := _skel.global_transform
	var w2s := s2w.affine_inverse()
	var lverts := PackedVector3Array()
	lverts.resize(world_verts.size())
	for i in range(world_verts.size()):
		lverts[i] = w2s * world_verts[i]

	# Torso spine chain (root -> chest), lowest to highest. Each disk binds to whichever of these is nearest in Y.
	var spine_names := ["ctr", "chn2", "jnt2_1", "eff2"]
	var spine := []
	for nm in spine_names:
		var bi := _skel.find_bone(nm)
		if bi >= 0:
			spine.append({"bone": bi, "xf": _skel.global_transform * _skel.get_bone_global_pose(bi)})
	if spine.is_empty():
		return

	# Vertical extent of the torso skin (exclude the wide arm/hand fans by an |x| gate so disks fit the core).
	var y_lo := INF
	var y_hi := -INF
	for wv in lverts:
		if absf(wv.x) > 1.8: continue
		y_lo = minf(y_lo, wv.y)
		y_hi = maxf(y_hi, wv.y)
	if y_lo == INF: return
	# Only collide the TORSO band (waist..neck); below the waist the panels hang free past the body.
	y_lo = maxf(y_lo, 8.5)
	y_hi = minf(y_hi, 14.5)

	var disks := 9
	var dy_step: float = (y_hi - y_lo) / float(disks - 1)
	for d in range(disks):
		var yc: float = lerpf(y_lo, y_hi, float(d) / float(disks - 1))
		# Gather torso-core skin verts in a Y slab around yc; fit an XZ ellipse (center + radii) to them. The
		# slab is wide enough (>= the disk spacing) that every disk finds verts — no skipped disk = no hole.
		var cx := 0.0
		var cz := 0.0
		var nslab := 0
		var slab := PackedVector3Array()
		var band: float = maxf(0.8, dy_step)
		for wv in lverts:
			if absf(wv.y - yc) > band: continue
			if absf(wv.x) > 1.8: continue          # torso core only (drop arms)
			cx += wv.x; cz += wv.z; nslab += 1
			slab.append(wv)
		if nslab < 4: continue
		cx /= nslab; cz /= nslab
		# Half-extents in X and Z about the slab center (max abs offset = the surface).
		var rx := 0.0
		var rz := 0.0
		for wv in slab:
			rx = maxf(rx, absf(wv.x - cx))
			rz = maxf(rz, absf(wv.z - cz))
		# Y radius generously overlaps neighbours (1.1x spacing) so the stack is a continuous tube — no vertical
		# gap between disks for a poncho vert to slip through (that gap showed as a shirt patch mid-chest).
		var ry: float = dy_step * 1.1
		var center_w := s2w * Vector3(cx, yc, cz)   # skeleton-local fit center -> world
		# Bind to the nearest spine bone by Y (world), storing the center in that bone's LOCAL frame so it animates.
		var best = spine[0]
		var bestdy := INF
		for s in spine:
			var dy: float = absf((s["xf"] as Transform3D).origin.y - center_w.y)
			if dy < bestdy: bestdy = dy; best = s
		var bx: Transform3D = best["xf"]
		# Store the disk CENTER in the bound bone's LOCAL frame so it tracks the body each frame. Radii are kept
		# world-axis-aligned (XZ ellipse + Y band); the torso stays ~upright through the locomotion clips, so the
		# disks translate/bob with the bone without needing a per-frame basis rotation.
		_body_cols.append({
			"bone": int(best["bone"]),
			"center": bx.affine_inverse() * center_w,        # bone-local center
			"radii_world": Vector3(maxf(rx, 0.05), maxf(ry, 0.05), maxf(rz, 0.05)),
		})


func _find_body_mesh() -> MeshInstance3D:
	var best: MeshInstance3D = null
	var best_vc := -1
	var model := get_node_or_null(model_path)
	if model == null: return null
	var all: Array[MeshInstance3D] = []
	_collect_meshes(model, all)
	for m in all:
		if m.mesh == null or m.mesh.get_surface_count() == 0: continue
		if String(m.name).begins_with("cloth"): continue   # skip the cloth pieces themselves
		var vc := 0
		for s in m.mesh.get_surface_count():
			vc += (m.mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		if vc > best_vc:
			best_vc = vc; best = m
	return best


# World-space positions of a skinned mesh's vertices at the CURRENT pose. Godot doesn't expose skinned
# output directly, so we replicate the skin: for each vert, blend the bound joints' (global_pose * inverse-
# bind) by the vert's weights. Falls back to the mesh's own global_transform if it carries no skin data.
func _skinned_world_verts(mi: MeshInstance3D) -> PackedVector3Array:
	var out := PackedVector3Array()
	var arrays = mi.mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var bones_arr = arrays[Mesh.ARRAY_BONES]
	var weights_arr = arrays[Mesh.ARRAY_WEIGHTS]
	var skin := mi.skin
	# Build joint matrices = skel.global_transform * bone_global_pose * inverse_bind, indexed by skin joint.
	if skin != null and bones_arr != null and weights_arr != null and _skel != null:
		var jcount := skin.get_bind_count()
		var jmats: Array[Transform3D] = []
		jmats.resize(jcount)
		for j in range(jcount):
			var bn := skin.get_bind_name(j)
			var bi := _skel.find_bone(bn) if bn != "" else skin.get_bind_bone(j)
			var ib := skin.get_bind_pose(j)
			if bi >= 0:
				jmats[j] = (_skel.global_transform * _skel.get_bone_global_pose(bi)) * ib
			else:
				jmats[j] = _skel.global_transform * ib
		var nb := 4
		out.resize(verts.size())
		for i in range(verts.size()):
			var v := verts[i]
			var acc := Vector3.ZERO
			var wsum := 0.0
			for k in range(nb):
				var ji: int = bones_arr[i * nb + k]
				var w: float = weights_arr[i * nb + k]
				if w <= 0.0 or ji < 0 or ji >= jcount: continue
				acc += (jmats[ji] * v) * w
				wsum += w
			out[i] = acc / wsum if wsum > 0.0 else (mi.global_transform * v)
		return out
	# Unskinned (rigid) mesh — its verts are already in model space baked by its bone; use the instance xf.
	var xf := mi.global_transform
	out.resize(verts.size())
	for i in range(verts.size()):
		out[i] = xf * verts[i]
	return out


func _add_con(p: _Piece, a: int, b: int) -> void:
	p.con_a.append(a)
	p.con_b.append(b)
	p.con_len.append((p.rest_local[a] - p.rest_local[b]).length())


func _physics_process(delta: float) -> void:
	if not _ready_ok:
		return
	# The cloth bones' BIND/REST pose is a blown-up authoring pose (large scale) that is NOT the in-game
	# pose. Seeding + calibrating colliders against it at _ready corrupts the sim (the poncho gets lifted
	# off the chest, exposing the shirt). Wait a few frames for the AnimationTree to drive the skeleton into
	# a real pose, then (re)seed every vert and calibrate the colliders against THAT.
	if not _pose_init:
		_warmup += 1
		if _warmup < 3:
			return
		_pose_init = true
		_reseed_and_fit()
	_accum += delta
	var steps := 0
	while _accum >= SUBSTEP and steps < MAX_SUBSTEPS:
		_accum -= SUBSTEP
		_time += SUBSTEP
		_step()
		steps += 1
	# Drop any backlog beyond the clamp so we don't spiral after a hitch.
	if _accum > SUBSTEP * MAX_SUBSTEPS:
		_accum = 0.0
	if steps > 0:
		for p: _Piece in _pieces:
			_rebuild(p)


func _step() -> void:
	var wind := wind_dir.normalized() if wind_dir.length() > 0.0001 else Vector3.ZERO
	# A slow, layered gust that OSCILLATES AROUND ZERO (pushes then relaxes) — not a constant shove.
	# Scaled to WIND_BASE so it's a gentle breeze on the order of gravity, never a launch. The dominant
	# sway comes from body motion (Verlet lag as the anchor bone moves) + gravity droop, not wind.
	var gust := wind_strength * WIND_BASE * (0.6 * sin(_time * 1.7) + 0.4 * sin(_time * 0.5 + 1.3))

	for p: _Piece in _pieces:
		var ax := _skel.global_transform * _skel.get_bone_global_pose(p.anchor_idx)

		# Teleport guard: a big anchor jump in one substep -> snap the whole sheet, skip the sim.
		if (ax.origin - p.last_anchor_origin).length() > teleport_threshold:
			for i in range(p.pos.size()):
				var w0: Vector3 = ax * p.rest_local[i]
				p.pos[i] = w0
				p.prev[i] = w0
			p.last_anchor_origin = ax.origin
			continue
		p.last_anchor_origin = ax.origin

		var vc := p.pos.size()
		# Rigid (anchor-driven) targets, in world space, for the pins and the FOLLOW pull.
		var target := PackedVector3Array()
		target.resize(vc)
		for i in range(vc):
			target[i] = ax * p.rest_local[i]

		# Integrate free verts (Verlet) + gravity + wind. Pins are clamped to their rigid target.
		var grav: Vector3 = p.gravity
		for i in range(vc):
			if p.is_pinned[i]:
				p.prev[i] = p.pos[i]
				p.pos[i] = target[i]
				continue
			var cur_p: Vector3 = p.pos[i]
			var prev_p: Vector3 = p.prev[i]
			var vel: Vector3 = (cur_p - prev_p) * DAMPING
			# Clamp implicit velocity so a fast body turn / wind gust can never launch the hem.
			if vel.length() > MAX_VEL:
				vel = vel.normalized() * MAX_VEL
			p.prev[i] = cur_p
			p.pos[i] = cur_p + vel + grav + wind * (gust * p.windeffect)

		# FOLLOW — applied ONCE per substep (not per iteration), ROW-WEIGHTED. Each free vert is pulled
		# toward its rigid (anchor-driven) target by follow * floppiness * follow_w[i], where follow_w
		# is 1 at the pinned neckline and ~0 at the free hem. So the neckline tracks the body and the hem
		# hangs/swings. (Applying this per-iteration at follow 0.9 glued the whole sheet rigid.)
		for i in range(vc):
			if p.is_pinned[i]:
				continue
			var cp: Vector3 = p.pos[i]
			var tp: Vector3 = target[i]
			var fw: float = p.follow_w[i] * floppiness
			p.pos[i] = Vector3(
				lerpf(cp.x, tp.x, clampf(p.follow.x * fw, 0.0, 1.0)),
				lerpf(cp.y, tp.y, clampf(p.follow.y * fw, 0.0, 1.0)),
				lerpf(cp.z, tp.z, clampf(p.follow.z * fw, 0.0, 1.0)))

		# Relax structural springs + body collision iteratively (Gauss-Seidel). FOLLOW is intentionally
		# OUTSIDE this loop so it can't compound to a glued sheet.
		var k_scalar := clampf((p.k.x + p.k.y + p.k.z) / 3.0 * stiffness, 0.0, 1.0)
		for _it in range(iterations):
			# Distance springs along grid neighbors.
			for c in range(p.con_a.size()):
				var a: int = p.con_a[c]
				var b: int = p.con_b[c]
				var pa: Vector3 = p.pos[a]
				var pb: Vector3 = p.pos[b]
				var d := pb - pa
				var cur := d.length()
				if cur < 1e-6:
					continue
				var diff := (cur - p.con_len[c]) / cur
				var corr := d * (0.5 * diff * k_scalar)
				if not p.is_pinned[a]:
					p.pos[a] = pa + corr
				if not p.is_pinned[b]:
					p.pos[b] = pb - corr
			# Body collision: push free verts out of the bone-anchored ellipsoids.
			_resolve_bounds(p)
			# Re-pin (constraints may have nudged pinned verts via neighbors).
			for pv in p.pinned:
				p.pos[pv] = target[pv]

		# STRAIN LIMIT - fast head/body motion was stretching the fabric (the turban tail gained length
		# when running). Hard-cap each edge to rest * MAX_STRETCH so the cloth is inextensible: bending and
		# sway are preserved, only ELONGATION is clamped. No-op at rest, so idle/poncho is unchanged.
		for _sp in range(3):
			for c in range(p.con_a.size()):
				var sa: int = p.con_a[c]
				var sb: int = p.con_b[c]
				var spa: Vector3 = p.pos[sa]
				var spb: Vector3 = p.pos[sb]
				var sd := spb - spa
				var slen := sd.length()
				var smax: float = p.con_len[c] * MAX_STRETCH
				if slen <= smax or slen < 1e-6:
					continue
				var sc: Vector3 = sd * (0.5 * (slen - smax) / slen)
				if not p.is_pinned[sa]: p.pos[sa] = spa + sc
				if not p.is_pinned[sb]: p.pos[sb] = spb - sc
			for pv in p.pinned:
				p.pos[pv] = target[pv]

		# FINAL collision pass — the last word each substep is "outside the body", so the distance
		# springs can't pull a vert back inside after the loop ends (that left poncho verts clipping).
		_resolve_bounds(p)


func _resolve_bounds(p: _Piece) -> void:
	if p.bounds.is_empty():
		return
	# Resolve each fitted collider's LIVE world center ONCE this substep (center tracks its bone, so the whole
	# torso stack follows the body bob/lean — this is what keeps the poncho snug as the body moves). The radii
	# are world-axis-aligned (XZ ellipse + Y capsule); the torso stays ~upright, so no per-frame basis rotation
	# is needed. A small collider_margin makes the cloth ride just OUTSIDE the skin (snug, not floating).
	var n_b := p.bounds.size()
	var centers: Array[Vector3] = []
	var radiis: Array[Vector3] = []
	var margin := Vector3(collider_margin, collider_margin, collider_margin)
	for bd in p.bounds:
		var bx := _skel.global_transform * _skel.get_bone_global_pose(int(bd["bone"]))
		centers.append(bx * (bd["center"] as Vector3))
		radiis.append((bd["radii_world"] as Vector3) + margin)
	# Each disk is a finite ELLIPTICAL CYLINDER (constant XZ ellipse within its Y half-height ry) — NOT a
	# Y-tapering ellipsoid, which would under-push verts between disk centres and leave a shirt patch. A vert
	# inside a disk's Y band that is inside its XZ ellipse is pushed radially OUT in XZ to the ellipse surface.
	# Disks overlap in Y so the stack is a continuous tube; iterate a few passes so a vert ejected by one disk
	# settles outside all of them.
	for i in range(p.pos.size()):
		if p.is_pinned[i]:
			continue
		var pi: Vector3 = p.pos[i]
		for _pass in range(BOUND_PASSES):
			var moved := false
			for j in range(n_b):
				var c: Vector3 = centers[j]
				var r: Vector3 = radiis[j]
				if absf(pi.y - c.y) > r.y:
					continue                         # outside this disk's Y band
				# XZ ellipse test (ignore Y — constant radius across the band).
				var ex := (pi.x - c.x) / r.x
				var ez := (pi.z - c.z) / r.z
				var m := sqrt(ex * ex + ez * ez)
				if m < 1.0 and m > 1e-5:
					var s := 1.0 / m
					pi.x = c.x + (pi.x - c.x) * s
					pi.z = c.z + (pi.z - c.z) * s
					moved = true
			if not moved:
				break
		p.pos[i] = pi


func _rebuild(p: _Piece) -> void:
	var vc := p.pos.size()
	# Convert WORLD sim positions into the mesh instance's local space so the rendered world position
	# equals our computed world position regardless of the parent skeleton transform.
	var to_local := p.mesh.global_transform.affine_inverse()
	var verts := PackedVector3Array()
	verts.resize(vc)
	for i in range(vc):
		verts[i] = to_local * p.pos[i]

	# Per-vertex normals from the grid (averaged face normals), flipped per the .clo NORMAL sign.
	var normals := _compute_normals(p, verts)

	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = normals
	if p.uvs.size() == vc:
		arr[Mesh.ARRAY_TEX_UV] = p.uvs
	if p.indices.size() > 0:
		arr[Mesh.ARRAY_INDEX] = p.indices

	var am: ArrayMesh = p.mesh.mesh
	am.clear_surfaces()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	if p.mat != null:
		am.surface_set_material(0, p.mat)


func _compute_normals(p: _Piece, verts: PackedVector3Array) -> PackedVector3Array:
	var vc := verts.size()
	var normals := PackedVector3Array()
	normals.resize(vc)
	for i in range(vc):
		normals[i] = Vector3.ZERO
	# Accumulate over indexed triangles (local space).
	var ic := p.indices.size()
	var t := 0
	while t + 2 < ic:
		var a: int = p.indices[t]
		var b: int = p.indices[t + 1]
		var c: int = p.indices[t + 2]
		t += 3
		var va: Vector3 = verts[a]
		var vb: Vector3 = verts[b]
		var vc2: Vector3 = verts[c]
		var fn := (vb - va).cross(vc2 - va)
		normals[a] += fn
		normals[b] += fn
		normals[c] += fn
	for i in range(vc):
		var n: Vector3 = normals[i]
		if n.length_squared() < 1e-12:
			n = Vector3.UP
		else:
			n = n.normalized()
		normals[i] = n * p.normal_sign
	return normals


# ---- helpers ----
func _v3(a) -> Vector3:
	if a is Array and a.size() >= 3:
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	return Vector3.ZERO


func _load_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var txt := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(txt)
	if typeof(parsed) == TYPE_DICTIONARY:
		return parsed
	return {}
