extends Node3D
class_name DungeonBossFloor
## DC1 Dungeon — D3.4 AUTHORED boss-arena floor (the Dran arena, d01boss).
##
## The boss floor is NOT procedural. The decomp picks it via `floor >= MaxFloorTbl[dun]` (d01=15): instead of
## `BtCleatRandomMap` (buildRandomMap), the driver runs `BtCleatFreeMap` — it name-loads a HAND-AUTHORED layout
## whose cfg DEF_PATS carry EXPLICIT PT_BASE x,y,z world placements (procedural tiles are always 0,0,0). This
## script is the runtime counterpart: it reads the authored manifest the C# `dungboss` command emitted
## (Project/assets/dungeons/d01boss.boss.json) and assembles the arena directly — no generator, no grid.
##
## Assembled:
##  - the ~7 arena-shell parts (d01g01 outer wall .. d01g08 VC wall) at their explicit cfg positions/rotations,
##    with the _a collision hull (trimesh, backface-on) and _v camera-volume hull (CAM_LAYER, like the tileset),
##  - the 12-segment Dran actor: each DRANS_PARTS motNN.glb (its vertices already carry the segment's authored
##    world placement) instanced at the arena origin so they assemble into the dragoon's body, parented to one
##    "Dran" node that plays an IDLE/rest bob (no combat — Phase 4),
##  - the boss markers: event01_2 (eventId 500, boss-start) on the outer wall, bosskey_2 (400) on the entry
##    landing — exposed via markers() exactly like the procedural floor so DungeonRun wires Area3Ds to them,
##  - LIGHT_C / AMBIENT / FOG lighting from the cfg header, the PT_FIRE braziers, the PT_GLIGHT crystal glow.
##
## Drop-in for DungeonFloorGen: it exposes the same surface DungeonRun consumes (build/layout/markers/
## entry_pos/stair_*_pos/cell_world/floor_y), so the run owner swaps to it for the terminus floor transparently.
##
## DEFERRED (per the plan): Dran does NOT fight — instanced + idle only. Combat is Phase 4.

const GEDIT := "res://assets/maps/gedit/"
const DUNGEONS := "res://assets/dungeons/"
const CAM_LAYER := 4               # matches DungeonFloorGen.CAM_LAYER (the follow-cam SpringArm masks it)

@export var tileset := "d01boss"   # the boss manifest basename (<tileset>.boss.json)
@export var dun_idx := 0
@export var floor := 15
@export var seed := 0
@export var build_lighting := true
@export var build_on_ready := false

var _man: Dictionary = {}
var layout: Dictionary = {}        # the DungeonFloorGen-compatible layout dict (entry/stairUp/stairDown + meta)
var _markers: Array = []
var _floor_min_y := INF
var _entry_world := Vector3.ZERO   # the player spawn (the entry-landing part, d01g05)
var _dran_seg_count := 0
var _dran_node: Node3D = null

func _ready() -> void:
	if build_on_ready:
		build(dun_idx, floor, seed)

## Build (or rebuild) the authored boss arena. Signature matches DungeonFloorGen.build so DungeonRun can call
## it identically. dun_idx/floor/seed are accepted for parity (the authored floor ignores the seed).
func build(p_dun_idx: int, p_floor: int, p_seed: int) -> bool:
	dun_idx = p_dun_idx
	floor = p_floor
	seed = p_seed
	_clear()
	if not _load_manifest():
		return false
	_assemble()
	_assemble_dran()
	if build_lighting:
		_build_environment()
	_resolve_markers()
	_build_layout()
	_log_stats()
	return true

func _clear() -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	_markers.clear()
	_floor_min_y = INF
	_entry_world = Vector3.ZERO
	_dran_seg_count = 0
	_dran_node = null

func _load_manifest() -> bool:
	var path := DUNGEONS + tileset + ".boss.json"
	if not FileAccess.file_exists(path):
		push_error("dungeon_boss_floor: boss manifest missing: " + path)
		return false
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		push_error("dungeon_boss_floor: boss manifest parse failed: " + path)
		return false
	_man = parsed
	return true

# =====================================================================================================
# Arena assembly (the ~7 authored shell parts at explicit cfg positions)
# =====================================================================================================

func _assemble() -> void:
	var dir := GEDIT + tileset + "/"
	var geom := Node3D.new()
	geom.name = "Geometry"
	add_child(geom)
	var hull := StaticBody3D.new()
	hull.name = "CollisionHull"
	add_child(hull)
	var cam_body := StaticBody3D.new()
	cam_body.name = "CameraVolumes"
	cam_body.collision_layer = 1 << (CAM_LAYER - 1)
	cam_body.collision_mask = 0
	add_child(cam_body)

	for part in _man.get("parts", []):
		var ppos: Array = part.get("pos", [0, 0, 0])
		var prot := int(part.get("rot", 0))
		var origin := Vector3(ppos[0], ppos[1], ppos[2])
		var yaw := -prot * PI / 2.0
		var basis := Basis(Vector3.UP, yaw)

		# --- render layers: each base carries its own offset (the authored PT_BASE x,y,z) ---
		for b in part.get("bases", []):
			var mesh_name := String(b["mesh"])
			var glb_path := dir + mesh_name + ".glb"
			if not ResourceLoader.exists(glb_path):
				push_warning("dungeon_boss_floor: render GLB missing: " + glb_path)
				continue
			var ps := load(glb_path) as PackedScene
			if ps == null:
				continue
			var inst := ps.instantiate() as Node3D
			inst.name = mesh_name
			var off: Array = b.get("offset", ppos)
			inst.position = Vector3(off[0], off[1], off[2])
			inst.rotation = Vector3(0, -int(b.get("rot", prot)) * PI / 2.0, 0)
			geom.add_child(inst)

		# --- collision (_a) trimesh, placed at the part transform ---
		# track the WALKABLE floor plane (flat tris, |normal.y| high) near the part centre so the player
		# spawn lands on the surface you stand ON — NOT the lowest edge/wall-base vert.
		var part_floor_y := INF
		var floor_y_sum := 0.0
		var floor_y_n := 0
		for c in part.get("cols", []):
			var col_path := dir + String(c["mesh"]) + ".col.json"
			if not FileAccess.file_exists(col_path):
				continue
			var cdata = JSON.parse_string(FileAccess.get_file_as_string(col_path))
			if not (cdata is Dictionary and cdata.has("faces")):
				continue
			var arr: Array = cdata["faces"]
			var pts := PackedVector3Array()
			var i := 0
			while i + 8 < arr.size():
				var v0 := basis * Vector3(arr[i], arr[i + 1], arr[i + 2]) + origin
				var v1 := basis * Vector3(arr[i + 3], arr[i + 4], arr[i + 5]) + origin
				var v2 := basis * Vector3(arr[i + 6], arr[i + 7], arr[i + 8]) + origin
				pts.append(v0); pts.append(v1); pts.append(v2)
				_floor_min_y = minf(_floor_min_y, minf(v0.y, minf(v1.y, v2.y)))
				# walkable floor tri near the part centre -> contributes to the spawn plane
				var nrm := (v1 - v0).cross(v2 - v0)
				if nrm.length() > 0.0001:
					nrm = nrm.normalized()
					var cy := (v0.y + v1.y + v2.y) / 3.0
					var cxz := Vector2((v0.x + v1.x + v2.x) / 3.0 - origin.x, (v0.z + v1.z + v2.z) / 3.0 - origin.z)
					# a flat tile near the door (tight radius) = the standing plane.
					if absf(nrm.y) > 0.9 and cxz.length() < 45.0:
						part_floor_y = minf(part_floor_y, cy)
						floor_y_sum += cy
						floor_y_n += 1
				i += 9
			if pts.size() >= 3:
				var shape := ConcavePolygonShape3D.new()
				shape.set_faces(pts)
				shape.backface_collision = true
				var cs := CollisionShape3D.new()
				cs.name = "Hull_" + String(c["mesh"])
				cs.shape = shape
				hull.add_child(cs)

		# --- camera-volume (_v) hull on CAM_LAYER ---
		for cm in part.get("cams", []):
			var cam_path := dir + String(cm["mesh"]) + ".cam.json"
			if not FileAccess.file_exists(cam_path):
				continue
			var vdata = JSON.parse_string(FileAccess.get_file_as_string(cam_path))
			if not (vdata is Dictionary and vdata.has("faces")):
				continue
			var varr: Array = vdata["faces"]
			var vpts := PackedVector3Array()
			var j := 0
			while j + 2 < varr.size():
				vpts.append(basis * Vector3(varr[j], varr[j + 1], varr[j + 2]) + origin)
				j += 3
			if vpts.size() >= 3:
				var vshape := ConcavePolygonShape3D.new()
				vshape.set_faces(vpts)
				vshape.backface_collision = true
				var vcs := CollisionShape3D.new()
				vcs.name = "Cam_" + String(cm["mesh"])
				vcs.shape = vshape
				cam_body.add_child(vcs)

		# the entry landing (the part carrying bosskey_2, with a real floor hull) is the player spawn.
		# use the averaged walkable-floor Y near the part centre (the plane you stand on).
		var is_entry := false
		for m in part.get("markers", []):
			if String(m.get("name", "")) == "bosskey_2":
				is_entry = true
		if is_entry and part_floor_y != INF:
			_entry_world = Vector3(origin.x, part_floor_y, origin.z)

		# --- torches (PT_FIRE) ---
		for f in part.get("fires", []):
			_add_torch(basis * Vector3(f[0], f[1], f[2]) + origin)

		# --- crystal glow (PT_GLIGHT): a soft cyan-green point glow per anchor (the d01g07 crystal-light) ---
		if part.get("gLights", []).size() > 0:
			_add_crystal_glow(origin)

	# fall back to the arena floor minimum if no entry hull was found.
	if _entry_world == Vector3.ZERO and _floor_min_y != INF:
		_entry_world = Vector3(0, _floor_min_y, -64)

# =====================================================================================================
# The Dran actor — 12 pre-placed segment meshes assembled at the arena origin, idling.
# =====================================================================================================

func _assemble_dran() -> void:
	var dran: Dictionary = _man.get("dran", {})
	var parts: Array = dran.get("parts", [])
	if parts.is_empty():
		return
	var dir := GEDIT + tileset + "/"
	var node := Node3D.new()
	node.name = "Dran"
	# the segment GLBs already carry their authored world placement (ApplyMapPlacement baked the per-bone
	# world matrices into the vertices), so the actor sits at the arena origin — the segments self-assemble.
	add_child(node)
	_dran_node = node
	var loaded := 0
	for seg in parts:
		var glb_path := dir + String(seg) + ".glb"
		if not ResourceLoader.exists(glb_path):
			push_warning("dungeon_boss_floor: Dran segment GLB missing: " + glb_path)
			continue
		var ps := load(glb_path) as PackedScene
		if ps == null:
			continue
		var inst := ps.instantiate() as Node3D
		inst.name = String(seg)
		node.add_child(inst)
		loaded += 1
	_dran_seg_count = loaded
	# idle/rest: a gentle vertical bob + slow sway so the assembled Dran reads as alive but does NOT fight.
	if loaded > 0:
		var idle := _make_idle_anim()
		node.add_child(idle)
		idle.play("idle")

## A tiny AnimationPlayer that bobs/sways the Dran node — the "instanced + idle/rest" the plan calls for.
func _make_idle_anim() -> AnimationPlayer:
	var ap := AnimationPlayer.new()
	ap.name = "Idle"
	var lib := AnimationLibrary.new()
	var anim := Animation.new()
	anim.length = 4.0
	anim.loop_mode = Animation.LOOP_LINEAR
	# position bob (the Dran node is at origin; bob it a few units in Y)
	var pt := anim.add_track(Animation.TYPE_POSITION_3D)
	anim.track_set_path(pt, NodePath("."))
	anim.position_track_insert_key(pt, 0.0, Vector3(0, 0, 0))
	anim.position_track_insert_key(pt, 2.0, Vector3(0, 3.0, 0))
	anim.position_track_insert_key(pt, 4.0, Vector3(0, 0, 0))
	# slow Y sway
	var rt := anim.add_track(Animation.TYPE_ROTATION_3D)
	anim.track_set_path(rt, NodePath("."))
	anim.rotation_track_insert_key(rt, 0.0, Quaternion(Vector3.UP, -0.03))
	anim.rotation_track_insert_key(rt, 2.0, Quaternion(Vector3.UP, 0.03))
	anim.rotation_track_insert_key(rt, 4.0, Quaternion(Vector3.UP, -0.03))
	lib.add_animation("idle", anim)
	ap.add_animation_library("", lib)
	return ap

# =====================================================================================================
# Markers — same shape DungeonFloorGen.markers() returns, so DungeonRun wires Area3Ds identically.
# =====================================================================================================

func _resolve_markers() -> void:
	for part in _man.get("parts", []):
		var ppos: Array = part.get("pos", [0, 0, 0])
		var origin := Vector3(ppos[0], ppos[1], ppos[2])
		for m in part.get("markers", []):
			var nm := String(m.get("name", ""))
			var kind := "event"
			if nm == "event01_2":
				kind = "boss"
			elif nm == "bosskey_2":
				kind = "bosskey"
			_markers.append({
				"name": nm,
				"eventId": int(m.get("eventId", -1)),
				"kind": kind,
				"cell": Vector2i(int(origin.x), int(origin.z)),
				"pos": Vector3(origin.x, (_floor_min_y if _floor_min_y != INF else origin.y), origin.z),
				"range": float(m.get("range", 20.0)),
			})

# =====================================================================================================
# DungeonFloorGen-compatible accessors (so DungeonRun treats the boss floor as a floor)
# =====================================================================================================

func _build_layout() -> void:
	# the authored arena has no grid; expose a layout dict whose stair/entry cells resolve (via cell_world)
	# to the entry-landing world position so DungeonRun spawns the player there. There is no down-stair
	# (boss arenas omit out_2 — it is a terminus), so stairDown == entry too (descend() no-ops at terminus).
	var entry_cell := Vector2i(int(_entry_world.x), int(_entry_world.z))
	layout = {
		"dunIdx": dun_idx,
		"floor": floor,
		"seed": seed,
		"authored": true,
		"boss": true,
		"entry": entry_cell,
		"stairUp": entry_cell,
		"stairDown": entry_cell,
		"rooms": [],
		"roomCount": 0,
		"corridorCount": 0,
		"cells": [],
	}

## The arena floor plane the player stands on (the entry-landing walkable Y) — NOT the global vertex min
## (the arena shell has deep ceiling-crystal / sky verts far below that are not the walkable floor).
func floor_y() -> float:
	return _entry_world.y

func cell_floor_y(_cell: Vector2i) -> float:
	return _entry_world.y

## The authored arena uses world coords directly (the entry cell encodes the entry world XZ); return the
## entry world position + y_off regardless of the cell so spawns land on the landing.
func cell_world(_cell: Vector2i, y_off := 0.0) -> Vector3:
	return Vector3(_entry_world.x, _entry_world.y + y_off, _entry_world.z)

func entry_pos(y_off := 6.0) -> Vector3:
	return cell_world(Vector2i.ZERO, y_off)

func stair_up_pos(y_off := 6.0) -> Vector3:
	return cell_world(Vector2i.ZERO, y_off)

func stair_down_pos(y_off := 6.0) -> Vector3:
	return cell_world(Vector2i.ZERO, y_off)

func markers() -> Array:
	return _markers

func dran_segment_count() -> int:
	return _dran_seg_count

func dran_node() -> Node3D:
	return _dran_node

func is_boss() -> bool:
	return true

# =====================================================================================================
# Lighting / fire / glow (reused from the tileset floor builders)
# =====================================================================================================

func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = _col255(_man.get("bgColor", [0, 0, 0]))
	var amb_col := _col255(_man.get("ambient", [0, 0, 0]))
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = (amb_col if amb_col.v > 0.04 else Color(0.06, 0.07, 0.06))
	env.ambient_light_energy = 1.0
	var fog: Array = _man.get("fog", [])
	if fog.size() >= 5:
		env.fog_enabled = true
		env.fog_light_color = _col255([fog[2], fog[3], fog[4]])
		env.fog_depth_begin = float(fog[0]) * 0.3
		env.fog_depth_end = float(fog[1]) * 0.6
		env.fog_mode = Environment.FOG_MODE_DEPTH
	var we := WorldEnvironment.new()
	we.name = "WorldEnvironment"
	we.environment = env
	add_child(we)
	var slot := 0
	for l in _man.get("lights", []):
		var d: Array = l["dir"]
		var ldir := Vector3(d[0], d[1], d[2])
		if ldir.length() < 0.001:
			continue
		var col := _col255(l["color"])
		if col.r + col.g + col.b < 0.01:
			continue   # the cfg's zeroed 3rd slot is a fill placeholder, not a real light
		var sun := DirectionalLight3D.new()
		sun.name = "Light%d" % slot
		sun.look_at_from_position(ldir.normalized() * 50.0, Vector3.ZERO, Vector3.UP)
		sun.light_color = col
		sun.light_energy = 1.0 if slot == 0 else 0.5
		sun.shadow_enabled = (slot == 0)
		add_child(sun)
		slot += 1

func _add_crystal_glow(pos: Vector3) -> void:
	var lamp := OmniLight3D.new()
	lamp.name = "CrystalGlow"
	lamp.light_color = Color(0.4, 0.9, 0.7)
	lamp.light_energy = 4.0
	lamp.omni_range = 200.0
	lamp.omni_attenuation = 1.4
	lamp.position = pos + Vector3(0, 40, 0)
	add_child(lamp)

func _add_torch(pos: Vector3) -> void:
	var node := Node3D.new()
	node.name = "Torch"
	node.position = pos
	add_child(node)
	var flame := GPUParticles3D.new()
	flame.amount = 24
	flame.lifetime = 0.6
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 12.0
	pm.initial_velocity_min = 1.5
	pm.initial_velocity_max = 3.0
	pm.gravity = Vector3(0, 1.5, 0)
	pm.scale_min = 0.3
	pm.scale_max = 0.7
	pm.color = Color(1.0, 0.55, 0.15)
	flame.process_material = pm
	var qm := QuadMesh.new()
	qm.size = Vector2(0.8, 0.8)
	var dm := StandardMaterial3D.new()
	dm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	dm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	dm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	dm.albedo_color = Color(1.0, 0.5, 0.1)
	qm.material = dm
	flame.draw_pass_1 = qm
	node.add_child(flame)
	var lamp := OmniLight3D.new()
	lamp.light_color = Color(1.0, 0.62, 0.30)
	lamp.light_energy = 6.0
	lamp.omni_range = 90.0
	lamp.omni_attenuation = 1.2
	lamp.position = Vector3(0, 1.0, 0)
	node.add_child(lamp)

func _col255(rgb: Array) -> Color:
	if rgb.size() < 3:
		return Color.BLACK
	return Color(float(rgb[0]) / 255.0, float(rgb[1]) / 255.0, float(rgb[2]) / 255.0)

func _log_stats() -> void:
	print("dungeon_boss_floor: %s (\"%s\") authored arena — %d parts, Dran %d/%d segments, %d markers, floor_y=%.2f, entry=%s" % [
		tileset, String(_man.get("title", "")), _man.get("parts", []).size(),
		_dran_seg_count, _man.get("dran", {}).get("parts", []).size(),
		_markers.size(), floor_y(), str(_entry_world)])
