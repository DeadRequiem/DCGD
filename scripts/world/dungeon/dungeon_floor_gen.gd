extends Node3D
class_name DungeonFloorGen
## DC1 Dungeon — D1 procedural floor assembly (D2: now a reusable, run-driven floor component).
##
## Generates a floor LAYOUT (DungeonGenerator, the faithful `buildRandomMap` port) and assembles it into a
## walkable scene: for every placed cell it instances that cell's catalog part (render GLB layer(s) +
## trimesh collision from the _a hull + PT_FIRE torches + the _v camera-volume hull on a dedicated camera
## layer), positioned on the 20x20 grid at the cell pitch. Reuses the D0 part-instancing.
##
## D2 additions over D1:
##  - Builds on demand via build() (a run owner — dungeon_run.gd — creates/frees floors), not only _ready.
##  - Exports the _v camera-volume hulls as collision shapes on CAM_LAYER for the follow-cam SpringArm.
##  - Resolves every PT_MARKER (out_2/ura_2/ndoorkey/chr1_*) to a grid cell + world position (markers()).
##  - Exposes entry / stairUp / stairDown world positions + the floor plane Y for the run owner to spawn on.
##
## DEFERRED to D3 (per the plan): event.stb cutscenes, enemies/combat, treasure/Atla, stair cinematics.

const GEDIT := "res://assets/maps/gedit/"
const DUNGEONS := "res://assets/dungeons/"
const CELL_PITCH := 160.0          # decomp-exact: DrawMapCalc @0x1C2578 places tiles at 160.0*x / 160.0*y (tiles span +/-80 = 160u, so 160 tiles them seamlessly; 162 left a 2u seam per boundary)
const CAM_LAYER := 4               # physics layer bit (1<<3) the _v camera-volume hulls live on; SpringArm masks it

@export var tileset := "d01main_a"
@export var dun_idx := 0            # 0 = d01
@export var floor := 1
@export var seed := 12345
@export var build_lighting := true
@export var build_on_ready := true # standalone test scenes leave this true; dungeon_run.gd sets it false

var _set: Dictionary = {}
var _by_no: Dictionary = {}
var layout: Dictionary = {}        # the generated layout (exposed for probes/the run owner)
var _floor_min_y := INF
var _cell_floor_y: Dictionary = {} # Vector2i cell -> that tile's local floor plane Y (for accurate spawning)
var _markers: Array = []           # [{name,eventId,cell:Vector2i,pos:Vector3,range,...}] resolved PT_MARKERs
var _underlay_mat: StandardMaterial3D = null  # shared dark cave-floor material for the seam-fill underlay

func _ready() -> void:
	if build_on_ready:
		build(dun_idx, floor, seed)
		_place_sibling_player()   # standalone D1 test scenes: drop a sibling "Player" onto the entry

## Standalone-only: if a sibling node named "Player" exists (the D1 floorgen test scene), drop it on the entry
## tile. The run owner (dungeon_run.gd) sets build_on_ready=false and spawns the player itself instead.
func _place_sibling_player() -> void:
	var parent := get_parent()
	if parent == null:
		return
	var player := parent.get_node_or_null("Player")
	if player == null or not (player is Node3D):
		return
	var e: Vector2i = layout.get("entry", Vector2i(-1, -1))
	if e.x < 0:
		return
	(player as Node3D).global_position = cell_world(e, 6.0)

## Build (or rebuild) the floor. Idempotent: clears any prior geometry first so dungeon_run can reuse the node.
func build(p_dun_idx: int, p_floor: int, p_seed: int) -> bool:
	dun_idx = p_dun_idx
	floor = p_floor
	seed = p_seed
	_clear()
	_cell_floor_y.clear()
	if not _load_tileset():
		return false
	var gen := DungeonGenerator.new()
	layout = gen.generate(dun_idx, floor, seed)
	_assemble(layout)
	if build_lighting:
		_build_environment()
	_resolve_markers(layout)
	_place_marker_nodes(layout)
	_log_stats(layout)
	return true

func _clear() -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	_floor_min_y = INF
	_markers.clear()

func _load_tileset() -> bool:
	if not _set.is_empty():
		return true
	var path := DUNGEONS + tileset + ".tileset.json"
	if not FileAccess.file_exists(path):
		push_error("dungeon_floor_gen: tileset JSON missing: " + path)
		return false
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		push_error("dungeon_floor_gen: tileset JSON parse failed")
		return false
	_set = parsed
	for p in _set.get("parts", []):
		_by_no[int(p.get("no", -1))] = p
	return true

# =====================================================================================================
# Public accessors the run owner / camera-rig use
# =====================================================================================================

func floor_y() -> float:
	return (_floor_min_y if _floor_min_y != INF else 0.0)

## That cell's local floor plane Y (falls back to the floor min if the cell wasn't tracked).
func cell_floor_y(cell: Vector2i) -> float:
	return float(_cell_floor_y.get(cell, floor_y()))

## World position of a grid cell at THAT cell's floor plane (+y_off above it). Uses the per-cell floor Y so
## a spawn lands on the actual tile, not the floor's global minimum (which deep stair geometry can pull down).
func cell_world(cell: Vector2i, y_off := 0.0) -> Vector3:
	return Vector3(cell.x * CELL_PITCH, cell_floor_y(cell) + y_off, cell.y * CELL_PITCH)

func entry_pos(y_off := 6.0) -> Vector3:
	return cell_world(layout.get("entry", Vector2i(-1, -1)), y_off)

func stair_up_pos(y_off := 6.0) -> Vector3:
	return cell_world(layout.get("stairUp", Vector2i(-1, -1)), y_off)

func stair_down_pos(y_off := 6.0) -> Vector3:
	return cell_world(layout.get("stairDown", Vector2i(-1, -1)), y_off)

func markers() -> Array:
	return _markers

# =====================================================================================================
# Assembly
# =====================================================================================================

func _assemble(lay: Dictionary) -> void:
	var dir := GEDIT + tileset + "/"
	var geom := Node3D.new()
	geom.name = "Geometry"
	add_child(geom)
	var hull := StaticBody3D.new()
	hull.name = "CollisionHull"
	add_child(hull)
	# the camera-volume hulls live on a SEPARATE body on CAM_LAYER so the player's floor/wall raycasts (which
	# query the default layer) never see them, and the SpringArm (which masks CAM_LAYER) never sees the floor.
	var cam_body := StaticBody3D.new()
	cam_body.name = "CameraVolumes"
	cam_body.collision_layer = 1 << (CAM_LAYER - 1)
	cam_body.collision_mask = 0
	add_child(cam_body)

	for cell in lay.get("cells", []):
		var no := int(cell["part"])
		var part: Dictionary = _by_no.get(no, {})
		if part.is_empty():
			continue
		var cx := int(cell["x"])
		var cy := int(cell["y"])
		var base_rot := int(cell["rot"])   # the cell's rotation; each PT_BASE/COLS/CAM layer adds its own rot
		var origin := Vector3(cx * CELL_PITCH, 0.0, cy * CELL_PITCH)

		# --- render layers ---
		for b in part.get("bases", []):
			var mesh_name := String(b["mesh"])
			var glb_path := dir + mesh_name + ".glb"
			if not ResourceLoader.exists(glb_path):
				continue
			var ps := load(glb_path) as PackedScene
			if ps == null:
				continue
			var inst := ps.instantiate() as Node3D
			inst.name = "%s_%d_%d" % [mesh_name, cx, cy]
			inst.position = origin
			# Each PT_BASE layer carries its OWN rot (cfg: "PT_BASE ...,<rot>"); compose it with the cell
			# rotation. Critical for the SHARED floor meshes (e.g. d01h01_2 reused across the 4 room-edge
			# variants no05..08 at rot 0/1/2/3) — dropping the layer rot left every shared floor at rot 0, so
			# they didn't tile and the underlay showed through. The walls are distinct pre-rotated meshes
			# (rot 0) so they rendered fine; only the shared floors broke.
			var layer_rot := (base_rot + int(b.get("rot", 0))) % 4
			inst.rotation = Vector3(0, -float(layer_rot) * PI / 2.0, 0)
			geom.add_child(inst)

		# --- collision: trimesh from each _a hull, rotated + translated to the cell ---
		var tile_floor_y := INF
		for c in part.get("cols", []):
			var col_path := dir + String(c["mesh"]) + ".col.json"
			if not FileAccess.file_exists(col_path):
				continue
			var cdata = JSON.parse_string(FileAccess.get_file_as_string(col_path))
			if not (cdata is Dictionary and cdata.has("faces")):
				continue
			# per-hull rot (PT_COLS "...",<rot>) composed with the cell rot, same as the render layers so the
			# collision the player stands on matches what renders (shared _a hulls are rotated per variant).
			var col_basis := Basis(Vector3.UP, -float((base_rot + int(c.get("rot", 0))) % 4) * PI / 2.0)
			var arr: Array = cdata["faces"]
			var pts := PackedVector3Array()
			var i := 0
			while i + 2 < arr.size():
				var local := Vector3(arr[i], arr[i + 1], arr[i + 2])
				var world := col_basis * local + origin
				pts.append(world)
				_floor_min_y = minf(_floor_min_y, world.y)
				# track the tile's floor plane (verts near y=0; the floor sits at -5..0 in the hull)
				if local.y >= -6.0 and local.y <= 6.0:
					tile_floor_y = minf(tile_floor_y, world.y)
				i += 3
			if pts.size() >= 3:
				var shape := ConcavePolygonShape3D.new()
				shape.set_faces(pts)
				# あたりポリゴン floor tris are wound facing DOWN; backface on so the down-ray solver sees them.
				shape.backface_collision = true
				var cs := CollisionShape3D.new()
				cs.name = "Hull_%s_%d_%d" % [String(c["mesh"]), cx, cy]
				cs.shape = shape
				hull.add_child(cs)

		# --- camera-volume (_v) hull -> a collision shape on CAM_LAYER (D2: constrains the follow-cam) ---
		for cm in part.get("cams", []):
			var cam_path := dir + String(cm["mesh"]) + ".cam.json"
			if not FileAccess.file_exists(cam_path):
				continue
			var vdata = JSON.parse_string(FileAccess.get_file_as_string(cam_path))
			if not (vdata is Dictionary and vdata.has("faces")):
				continue
			var cam_basis := Basis(Vector3.UP, -float((base_rot + int(cm.get("rot", 0))) % 4) * PI / 2.0)
			var varr: Array = vdata["faces"]
			var vpts := PackedVector3Array()
			var j := 0
			while j + 2 < varr.size():
				vpts.append(cam_basis * Vector3(varr[j], varr[j + 1], varr[j + 2]) + origin)
				j += 3
			if vpts.size() >= 3:
				var vshape := ConcavePolygonShape3D.new()
				vshape.set_faces(vpts)
				vshape.backface_collision = true     # the volume's far wall must stop the SpringArm from either side
				var vcs := CollisionShape3D.new()
				vcs.name = "Cam_%s_%d_%d" % [String(cm["mesh"]), cx, cy]
				vcs.shape = vshape
				cam_body.add_child(vcs)

		# remember this tile's local floor plane Y so spawns land on the actual landing, not the floor's
		# GLOBAL min (deep stair geometry elsewhere can drag the global min far below a given stair tile).
		if tile_floor_y != INF:
			_cell_floor_y[Vector2i(cx, cy)] = tile_floor_y

		# (REMOVED: the full-cell FloorPatch collision box + its diagnostic plane. That box was a flat 160x160
		# collider under EVERY walkable cell — a "don't fall between tiles" band-aid — but it created a continuous
		# flat floor far bigger than the real tile shapes, so the player walked OUT past the actual geometry onto
		# nothing = the green "outside the map" area, seeing tile backfaces/void from outside. The player now
		# stands only on the real per-tile `_a` collision hulls built above.)

		# --- torches (PT_FIRE), rotated by the cell rotation into place ---
		var cell_basis := Basis(Vector3.UP, -float(base_rot) * PI / 2.0)
		for f in part.get("fires", []):
			var fp := cell_basis * Vector3(f[0], f[1], f[2]) + origin
			_add_torch(fp)

# =====================================================================================================
# Markers (PT_MARKER) — resolve each placed tile's cfg markers to a grid cell + world position.
# =====================================================================================================

## Walk the placed cells; for each, pull the cfg part's markers (out_2/ura_2/ndoorkey/chr1_*) and record
## one entry per marker with its world position. The stair markers (out_2 on the down-stair no31, the
## in-stairs no30 = up-stair/entry) are also tagged "kind" so the run owner can wire them to transitions.
func _resolve_markers(lay: Dictionary) -> void:
	var stair_down: Vector2i = lay.get("stairDown", Vector2i(-1, -1))
	var stair_up: Vector2i = lay.get("stairUp", Vector2i(-1, -1))
	for cell in lay.get("cells", []):
		var no := int(cell["part"])
		var part: Dictionary = _by_no.get(no, {})
		var cms: Array = part.get("markers", [])
		if cms.is_empty():
			continue
		var c := Vector2i(int(cell["x"]), int(cell["y"]))
		for m in cms:
			var nm := String(m.get("name", ""))
			var kind := "event"
			# the down-stair tile (no31) carries out_2; classify it only on the actual stairDown cell so we
			# don't fire a transition on every decorative out-stairs tile (there is exactly one per floor).
			if nm == "out_2" and c == stair_down:
				kind = "stair_down"
			elif nm == "ura_2":
				kind = "ura"
			elif nm == "ndoorkey":
				kind = "door"
			elif nm.begins_with("chr1"):
				kind = "char_key"
			_markers.append({
				"name": nm,
				"eventId": int(m.get("eventId", -1)),
				"kind": kind,
				"cell": c,
				"pos": cell_world(c, 0.0),
				"range": float(m.get("range", 10.0)),
			})

## Place Marker3D nodes at the entry / stair-up / stair-down cells (visual debug anchors).
func _place_marker_nodes(lay: Dictionary) -> void:
	_marker_node("StairUp", lay.get("stairUp", Vector2i(-1, -1)), 0.0)
	_marker_node("StairDown", lay.get("stairDown", Vector2i(-1, -1)), 0.0)
	_marker_node("Spawn", lay.get("entry", Vector2i(-1, -1)), 6.0)

func _marker_node(name: String, cell: Vector2i, y_off: float) -> void:
	if cell.x < 0:
		return
	var m := Marker3D.new()
	m.name = name
	m.position = cell_world(cell, y_off)
	add_child(m)

func _log_stats(lay: Dictionary) -> void:
	# DIAGNOSTIC marker [AUTOTILE-V2]: if this line with this exact tag appears in the Output panel, the edited
	# generator IS the running code. The histogram shows how many cells resolved to each catalog part no##.
	var hist: Dictionary = {}
	for cell in lay.get("cells", []):
		var p := int(cell["part"])
		hist[p] = int(hist.get(p, 0)) + 1
	print("dungeon_floor_gen [AUTOTILE-V2]: %s d%02d floor%d seed=%d -> %d rooms, %d corridor cells, %d placed cells; entry=%s up=%s down=%s; %d markers" % [
		tileset, lay.dunIdx + 1, lay.floor, lay.seed,
		lay.roomCount, lay.corridorCount, lay.cells.size(),
		str(lay.entry), str(lay.stairUp), str(lay.stairDown), _markers.size()])
	print("dungeon_floor_gen [AUTOTILE-V2] tile histogram (no##:count): %s" % str(hist))

## Shared material for the full-cell seam-fill underlay: a dark, lit cave-floor grey. Built once and reused
## across cells/rebuilds (it's not a scene child, so _clear() doesn't free it).
func _floor_underlay_mat() -> StandardMaterial3D:
	if _underlay_mat == null:
		_underlay_mat = StandardMaterial3D.new()
		# DIAGNOSTIC (user request): bright emissive GREEN = "ground that is NOT a tile". This plane sits under
		# every walkable cell; where a real map tile renders it's hidden, where it shows = the floor-patch surface
		# with no real tile on it. Emissive so it glows in the dark. (The void/background is pink, set separately.)
		_underlay_mat.albedo_color = Color(0.0, 1.0, 0.0)
		_underlay_mat.emission_enabled = true
		_underlay_mat.emission = Color(0.0, 1.0, 0.0)
		_underlay_mat.emission_energy_multiplier = 2.0
		_underlay_mat.roughness = 1.0
		_underlay_mat.metallic = 0.0
		_underlay_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return _underlay_mat

func _add_torch(pos: Vector3) -> void:
	var node := Node3D.new()
	node.name = "Torch"
	node.position = pos
	add_child(node)
	var flame := GPUParticles3D.new()
	flame.amount = 16
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
	lamp.light_energy = 5.0
	lamp.omni_range = 90.0
	lamp.omni_attenuation = 1.2
	lamp.position = Vector3(0, 1.0, 0)
	node.add_child(lamp)

func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = _col255(_set.get("bgColor", [0, 0, 0]))
	var amb_col := _col255(_set.get("ambient", [0, 0, 0]))
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	# Real-play fix (bug 3): the d01 tileset ships ambient=[0,0,0], so with only the 2 weak side lights anything
	# not directly torch-lit was pure black -> unnavigable. Raise the ambient FLOOR to a cool, dim cave grey so
	# the whole floor is faintly visible (you can SEE where to walk) while staying moody. A real authored ambient
	# (if a tileset ever ships one) still wins.
	# Real-play fix (residual VOID): raise the ambient floor a touch more so OFF-PATH walls/ceilings/the stairwell
	# don't read as pure-black void at the screen edges (the adversarial frames flagged void off the lit path). Still
	# a cool, dim cave grey — moody, but everything is at least faintly legible. A real authored ambient still wins.
	env.ambient_light_color = (amb_col if amb_col.v > 0.18 else Color(0.22, 0.23, 0.29))
	env.ambient_light_energy = 1.0
	var fog: Array = _set.get("fog", [])
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
	for l in _set.get("lights", []):
		var d: Array = l["dir"]
		var ldir := Vector3(d[0], d[1], d[2])
		if ldir.length() < 0.001:
			continue
		var sun := DirectionalLight3D.new()
		sun.name = "Light%d" % slot
		sun.look_at_from_position(ldir.normalized() * 50.0, Vector3.ZERO, Vector3.UP)
		sun.light_color = _col255(l["color"])
		sun.light_energy = 0.9 if slot == 0 else 0.5
		sun.shadow_enabled = (slot == 0)
		add_child(sun)
		slot += 1
	# Real-play fill (bug 3): a soft, shadowless top-down light so open-topped tiles read as a lit floor from
	# any camera angle instead of going black between torches. Dim + cool so the cave mood survives; the warm
	# torch Omnis still pool the highlights. Shadows OFF so it only lifts the floor out of pure black.
	var fill := DirectionalLight3D.new()
	fill.name = "FillLight"
	fill.look_at_from_position(Vector3(0, 80, 12), Vector3.ZERO, Vector3.FORWARD)
	fill.light_color = Color(0.62, 0.66, 0.78)
	fill.light_energy = 0.7
	fill.shadow_enabled = false
	add_child(fill)
	# Real-play fix (residual VOID at screen edges): a second shadowless fill from a LOW, near-horizontal angle so
	# the vertical cave WALLS (which the top-down fill grazes edge-on and leaves black) catch a little light. Dim,
	# cool, no shadow -> it only lifts the side walls/stairwell out of pure black without flattening the mood.
	var wall_fill := DirectionalLight3D.new()
	wall_fill.name = "WallFill"
	wall_fill.look_at_from_position(Vector3(40, 18, 40), Vector3.ZERO, Vector3.UP)
	wall_fill.light_color = Color(0.46, 0.50, 0.62)
	wall_fill.light_energy = 0.45
	wall_fill.shadow_enabled = false
	add_child(wall_fill)

func _col255(rgb: Array) -> Color:
	if rgb.size() < 3:
		return Color.BLACK
	return Color(float(rgb[0]) / 255.0, float(rgb[1]) / 255.0, float(rgb[2]) / 255.0)
