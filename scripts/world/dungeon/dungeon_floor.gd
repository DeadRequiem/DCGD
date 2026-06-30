extends Node3D
## DC1 Dungeon — D0 static floor assembly.
##
## Reads a dungeon tileset JSON (Project/assets/dungeons/<set>.tileset.json, produced by the C# `dungcfg`
## command) and instances ONE part tile statically at the origin: its render GLB layer(s), a trimesh
## collision body from the part's _a collision hull (<mesh>_a.col.json from `dungmesh`), a flame + warm
## point-light at every PT_FIRE torch, and lighting/fog/ambient from the cfg header (LIGHT_C/AMBIENT/FOG/
## BG_COL). This proves the dungeon part pipeline end-to-end before procedural generation (D1).
##
## NO procgen, NO events/markers, NO stairs, NO camera-volume (_v) — all deferred (see dungeon-d0-plan.md).
## The cfg's PT_BASE offset is (0,0,0) for procedural tilesets, so the tile sits at the floor's local origin.

const GEDIT := "res://assets/maps/gedit/"
const DUNGEONS := "res://assets/dungeons/"

@export var tileset := "d01main_a"      # tileset basename under assets/dungeons (<tileset>.tileset.json)
@export var tile_no := 9                 # which DEF_PATS no## to instance (no09 = room-with-door + 2 torches)
@export var build_lighting := true       # set up WorldEnvironment + DirectionalLight from the cfg header
@export var spawn_y_offset := 6.0        # how high above the tile's floor the Spawn marker sits

var _set: Dictionary = {}

func _ready() -> void:
	var path := DUNGEONS + tileset + ".tileset.json"
	if not FileAccess.file_exists(path):
		push_error("dungeon_floor: tileset JSON missing: " + path)
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		push_error("dungeon_floor: tileset JSON parse failed: " + path)
		return
	_set = parsed

	var part := _find_part(tile_no)
	if part.is_empty():
		push_error("dungeon_floor: tile no%d not found in %s" % [tile_no, tileset])
		return

	var geom := Node3D.new()
	geom.name = "Geometry"
	add_child(geom)

	# --- render layers (PT_BASE): a tile can stack several (a room wall _1 + shared floor _2 + decor) ---
	var dir := GEDIT + tileset + "/"
	for b in part.get("bases", []):
		var mesh_name := String(b["mesh"])
		var glb_path := dir + mesh_name + ".glb"
		if not ResourceLoader.exists(glb_path):
			push_warning("dungeon_floor: render GLB missing: " + glb_path)
			continue
		var ps := load(glb_path) as PackedScene
		if ps == null:
			continue
		var inst := ps.instantiate() as Node3D
		inst.name = mesh_name
		# PT_BASE offset is (0,0,0) for procedural tiles; honour it anyway for authored floors later.
		var off: Array = b.get("offset", [0, 0, 0])
		inst.position = Vector3(off[0], off[1], off[2])
		geom.add_child(inst)

	# --- collision: trimesh StaticBody3D from each PT_COLS _a hull (<mesh>.col.json) ---
	var hull := StaticBody3D.new()
	hull.name = "CollisionHull"
	add_child(hull)
	var floor_min_y := INF
	var floor_max_y := -INF
	for c in part.get("cols", []):
		var col_path := dir + String(c["mesh"]) + ".col.json"
		if not FileAccess.file_exists(col_path):
			push_warning("dungeon_floor: collision JSON missing: " + col_path)
			continue
		var cdata = JSON.parse_string(FileAccess.get_file_as_string(col_path))
		if not (cdata is Dictionary and cdata.has("faces")):
			continue
		var arr: Array = cdata["faces"]
		var pts := PackedVector3Array()
		var i := 0
		while i + 2 < arr.size():
			var y := float(arr[i + 1])
			pts.append(Vector3(arr[i], y, arr[i + 2]))
			floor_min_y = minf(floor_min_y, y)
			floor_max_y = maxf(floor_max_y, y)
			i += 3
		if pts.size() >= 3:
			var shape := ConcavePolygonShape3D.new()
			shape.set_faces(pts)
			# あたりポリゴン floor tris are wound facing DOWN; the player's down-ray floor solver needs
			# backface collision on or the hull is invisible to the probe (same lesson as towns/interiors).
			shape.backface_collision = true
			var cs := CollisionShape3D.new()
			cs.name = "Hull_" + String(c["mesh"])
			cs.shape = shape
			hull.add_child(cs)

	# --- torches (PT_FIRE): a flame billboard + a warm omni light (dungeon AMBIENT is 0,0,0 — torches light it) ---
	for f in part.get("fires", []):
		var pos := Vector3(f[0], f[1], f[2])
		_add_torch(pos)

	# --- lighting / environment from the cfg header ---
	if build_lighting:
		_build_environment()

	# --- spawn marker: above the floor centre (the lowest collision Y = floor plane) ---
	var spawn := Marker3D.new()
	spawn.name = "Spawn"
	var floor_y := (floor_min_y if floor_min_y != INF else 0.0)
	spawn.position = Vector3(0.0, floor_y + spawn_y_offset, 0.0)
	add_child(spawn)

	print("dungeon_floor: built %s no%d — %d render, collision y[%.2f..%.2f], %d torches, spawn y=%.2f" % [
		tileset, tile_no, geom.get_child_count(),
		(floor_min_y if floor_min_y != INF else 0.0), (floor_max_y if floor_max_y != -INF else 0.0),
		part.get("fires", []).size(), spawn.position.y])

func _find_part(no: int) -> Dictionary:
	for p in _set.get("parts", []):
		if int(p.get("no", -1)) == no:
			return p
	return {}

## A torch = an animated flame billboard (mirrors build_level._add_flame) + a warm OmniLight3D so the torch
## actually illuminates the cave (dungeon ambient is black; DC1 relights per-vertex, but for D0 a real light
## pool reads clearly and is cheap). Always lit (interior-style; no day/night in a dungeon).
func _add_torch(pos: Vector3) -> void:
	var node := Node3D.new()
	node.name = "Torch_%d_%d_%d" % [int(pos.x), int(pos.y), int(pos.z)]
	node.position = pos
	add_child(node)

	var flame := GPUParticles3D.new()
	flame.name = "Flame"
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
	lamp.name = "Light"
	lamp.light_color = Color(1.0, 0.62, 0.30)
	lamp.light_energy = 6.0
	lamp.omni_range = 80.0          # room tiles are ~160u wide; a torch lights a broad warm pool
	lamp.omni_attenuation = 1.2
	lamp.position = Vector3(0, 1.0, 0)
	node.add_child(lamp)

## WorldEnvironment (ambient + bg + fog) + a DirectionalLight per LIGHT_C slot, all from the cfg header.
## DC1's lighting model is the town LIGHT_C model (direction is the "to-light" vector); dungeon ambient is
## usually 0,0,0 (pure torch-lit cave), so the directional fill is dim and the torches carry the room.
func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	var bg: Array = _set.get("bgColor", [0, 0, 0])
	env.background_color = _col255(bg)
	# ambient: cfg AMBIENT (0..255). Dungeons are usually 0,0,0 — lift to a faint floor so geometry off the
	# torch pools isn't pure black (the real engine relights per-vertex; this is the pragmatic D0 stand-in).
	var amb: Array = _set.get("ambient", [0, 0, 0])
	var amb_col := _col255(amb)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = (amb_col if amb_col.v > 0.04 else Color(0.06, 0.06, 0.08))
	env.ambient_light_energy = 1.0
	# fog (start, end, r, g, b) — DC1 black short fog gives the cave its claustrophobic depth fade.
	var fog: Array = _set.get("fog", [])
	if fog.size() >= 5:
		env.fog_enabled = true
		env.fog_light_color = _col255([fog[2], fog[3], fog[4]])
		# cfg fog is start/end in world units; map to Godot's depth fade (cheap approximation).
		env.fog_depth_begin = float(fog[0]) * 0.1
		env.fog_depth_end = float(fog[1]) * 0.1
		env.fog_mode = Environment.FOG_MODE_DEPTH
	var we := WorldEnvironment.new()
	we.name = "WorldEnvironment"
	we.environment = env
	add_child(we)

	var slot := 0
	for l in _set.get("lights", []):
		var d: Array = l["dir"]
		var ldir := Vector3(d[0], d[1], d[2])
		if ldir.length() < 0.001:
			continue
		var sun := DirectionalLight3D.new()
		sun.name = "Light%d" % slot
		# LIGHT_C is the direction TO the light; a DirectionalLight3D points along -Z, so face it from ldir
		# toward the origin (look down the -ldir vector).
		sun.look_at_from_position(ldir.normalized() * 50.0, Vector3.ZERO, Vector3.UP)
		sun.light_color = _col255(l["color"])
		sun.light_energy = 1.2 if slot == 0 else 0.6
		sun.shadow_enabled = (slot == 0)
		add_child(sun)
		slot += 1

func _col255(rgb: Array) -> Color:
	if rgb.size() < 3:
		return Color.BLACK
	return Color(float(rgb[0]) / 255.0, float(rgb[1]) / 255.0, float(rgb[2]) / 255.0)
