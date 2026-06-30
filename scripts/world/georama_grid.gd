extends Node3D
## DC1 georama town grid (the EDITAREA build plane). Loads <id>.grid.json — the parsed gdata0.edt default
## layout: a 14x12 lattice of cells (cell 100u, origin -700,0,-700, all Y=0) each tagged with a part `type`
## (the cfg catalog id 0..16) + `flag` + world `pos`. cell_at(i) exposes a cell as a placement target.
##
## D3.5 extends this into the live TOWN-REBUILD target: place_atla(atla_id, cell) marks a cell occupied and
## spawns the resident/structure ACTOR at that cell's world position, restoring + recording through the
## session-level GeoramaState (so a town remembers what was rebuilt across area swaps). This is the Godot-native
## stand-in for CEditGround::SetMapParts -> RemakeGrid -> SetBuildEffect: cell pick -> occupancy mark -> actor.

const GEDIT := "res://assets/maps/gedit/"

@export_file("*.json") var grid_path: String = ""
@export var debug_draw: bool = true
## The town id used to key GeoramaState placements (e.g. "e01"). Defaults from the grid_path stem (e01.grid.json
## -> "e01"). Norune = e01.
@export var town_id: String = ""

var cells: Array = []   ## [{ i:int, type:int, flag:int, pos:Vector3 }]

## cell index -> the spawned actor Node3D (a placed Atla's resident/structure). Mirrors GeoramaState.placements.
var _placed_actors: Dictionary = {}

func _ready() -> void:
	if town_id == "" and grid_path != "":
		town_id = grid_path.get_file().get_basename().get_basename()   # e01.grid.json -> "e01"
	if grid_path == "" or not FileAccess.file_exists(grid_path):
		return
	var data = JSON.parse_string(FileAccess.get_file_as_string(grid_path))
	if not (data is Dictionary and data.has("cells")):
		return
	for c in data["cells"]:
		var p: Array = c["pos"]
		cells.append({"i": int(c["i"]), "type": int(c["type"]), "flag": int(c["flag"]),
			"pos": Vector3(p[0], p[1], p[2])})
	if debug_draw:
		_draw_cells()
	# D3.5: re-spawn any Atla the player already placed on this town this session (the town "remembers"). Deferred
	# a frame so the level's collision/geometry is registered before actors snap to the floor.
	_restore_placements.call_deferred()

func _draw_cells() -> void:
	for cell in cells:
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(90, 4, 90)
		mi.mesh = bm
		mi.position = cell["pos"] + Vector3(0, 1, 0)
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = Color.from_hsv(float(cell["type"] % 16) / 16.0, 0.65, 0.95, 0.4)
		mi.material_override = mat
		add_child(mi)

## Cell record by index — placement targets for step B.
func cell_at(i: int) -> Dictionary:
	return cells[i] if i >= 0 and i < cells.size() else {}

func cell_count() -> int:
	return cells.size()

# =====================================================================================================
# D3.5 — Atla placement (the town-rebuild action)
# =====================================================================================================

## Is `cell` already occupied by a placed Atla this session?
func is_occupied(cell: int) -> bool:
	if _placed_actors.has(cell):
		return true
	var st := _state()
	return st != null and st.is_placed(town_id, cell)

## Place the carried Atla `atla` (a {id, floor, name} record) into grid `cell`. Marks the cell occupied,
## records it in GeoramaState (so it survives area swaps), and spawns the resident/structure actor at the
## cell's world position dropped onto the floor. Returns the placement record, or {} on failure.
func place_atla(atla: Dictionary, cell: int) -> Dictionary:
	if cell < 0 or cell >= cells.size():
		push_warning("georama_grid: cell %d out of range" % cell)
		return {}
	if is_occupied(cell):
		push_warning("georama_grid: cell %d already occupied" % cell)
		return {}
	var st := _state()
	var rec: Dictionary
	if st != null:
		rec = st.record_placement(town_id, cell, atla)
	else:
		rec = {"atla_id": int(atla.get("id", 0)), "part_id": int(atla.get("id", 0)),
			"name": String(atla.get("name", "Atla"))}
	var actor := _spawn_actor(rec, cells[cell]["pos"])
	_placed_actors[cell] = actor
	return rec

## Re-spawn placements recorded in GeoramaState for this town (called on load so the town remembers).
func _restore_placements() -> void:
	var st := _state()
	if st == null:
		return
	for cell in st.placements_for(town_id):
		if _placed_actors.has(int(cell)):
			continue
		var rec: Dictionary = st.placements_for(town_id)[cell]
		var ci := int(cell)
		if ci < 0 or ci >= cells.size():
			continue
		var actor := _spawn_actor(rec, cells[ci]["pos"])
		_placed_actors[ci] = actor

## Spawn the actor for a placement record at a grid cell. Tries the part's extracted .pts GLB (only e01h06 is
## currently exported); otherwise builds a placeholder NPC (a capsule body + colour marker + floating name) so
## a not-yet-extracted resident/structure still APPEARS in the town. Snaps onto the floor below the cell.
func _spawn_actor(rec: Dictionary, cell_pos: Vector3) -> Node3D:
	var root := Node3D.new()
	root.name = "Placed_%d_%s" % [int(rec.get("atla_id", 0)), String(rec.get("name", "atla")).replace(" ", "_").replace("'", "")]
	add_child(root)
	root.global_position = _floor_drop(cell_pos)

	var st := _state()
	var info: Dictionary = st.part_info(int(rec.get("atla_id", 0))) if st != null else {}
	var mesh_id := String(info.get("mesh", ""))
	var spawned_mesh := false
	if mesh_id != "":
		var glb_path := GEDIT + "%s/%s.glb" % [town_id, mesh_id]
		if ResourceLoader.exists(glb_path):
			var ps := load(glb_path) as PackedScene
			if ps != null:
				root.add_child(ps.instantiate())
				spawned_mesh = true
	if not spawned_mesh:
		_build_placeholder(root, info)

	# a floating name plate so the placed resident/structure is identifiable on sight in renders.
	var label := Label3D.new()
	label.text = String(rec.get("name", "Atla"))
	label.font_size = 64
	label.outline_size = 16
	label.modulate = Color(1, 1, 0.55)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.pixel_size = 0.25
	label.position = Vector3(0, 34, 0)
	root.add_child(label)

	# a gentle build-glow column so a placement reads as freshly built (the SetBuildEffect stand-in).
	var glow := OmniLight3D.new()
	glow.light_color = Color(1.0, 0.92, 0.6)
	glow.light_energy = 2.5
	glow.omni_range = 60.0
	glow.position = Vector3(0, 18, 0)
	root.add_child(glow)
	return root

## A placeholder resident/structure: a coloured capsule (person/object) or box (building) + a base disc, sized
## to read at the town's scale. Used when the part's real .pts mesh isn't extracted yet (accepted by the brief).
func _build_placeholder(root: Node3D, info: Dictionary) -> void:
	var kind := String(info.get("kind", "person"))
	var body := MeshInstance3D.new()
	var mat := StandardMaterial3D.new()
	if kind == "building":
		var bm := BoxMesh.new()
		bm.size = Vector3(60, 60, 60)
		body.mesh = bm
		body.position = Vector3(0, 30, 0)
		mat.albedo_color = Color(0.75, 0.55, 0.35)
	else:
		var cm := CapsuleMesh.new()
		cm.radius = 7.0
		cm.height = 28.0
		body.mesh = cm
		body.position = Vector3(0, 14, 0)
		mat.albedo_color = Color(0.35, 0.7, 1.0) if kind == "person" else Color(0.5, 0.9, 0.5)
	mat.roughness = 0.7
	body.material_override = mat
	root.add_child(body)

## Drop a cell's world position onto the floor below it (raycast), so a placed actor stands on the ground rather
## than at the cell plane's nominal Y. Falls back to the cell pos if nothing is hit.
func _floor_drop(cell_pos: Vector3) -> Vector3:
	var space := get_world_3d().direct_space_state if is_inside_tree() else null
	if space != null:
		var from := cell_pos + Vector3(0, 400, 0)
		var to := cell_pos + Vector3(0, -400, 0)
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(from, to))
		if not hit.is_empty():
			return hit["position"]
	return cell_pos

func _state() -> Node:
	return get_node_or_null("/root/GeoramaState")
