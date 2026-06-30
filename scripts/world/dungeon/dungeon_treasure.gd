extends Node3D
class_name DungeonTreasure
## DC1 Dungeon — D3.1 treasure-chest + Atla spawning & interaction layer.
##
## Given a generated floor LAYOUT (DungeonFloorGen.layout) it runs the faithful buildEventData placement
## (DungeonEntities) and instances:
##   - treasure chests (ibox = normal, iboxs = key/special) at the placed cells, each with an Area3D trigger;
##     on the player entering -> a lid-open animation plays -> the item is added to the run's inventory ->
##     the chest is marked looted (the lid stays open, the trigger disables);
##   - on Atla-bearing floors, the Atla actor (atra.glb) at the placed cell, gently floating/bobbing; on the
##     player entering its trigger -> it floats to the player -> is pushed onto DungeonRun.atla_list -> its
##     name shows (toast/log) -> it despawns.
##
## Built once per floor by DungeonFloorGen.build(); the run owner (DungeonRun) provides the inventory +
## atla_list sinks via add_item()/add_atla(). Deterministic placement (same seed -> same cells).
##
## DEFERRED: trap circles are PLACED by DungeonEntities but not yet visualised (combat is a later phase);
## real item names + the georama town-rebuild meta-loop are D3.2 / D3.5. The atla "float to player" is an
## engine-authored motion (atra.chr ships no MOT), so it's animated here in GDScript.

const GEDIT := "res://assets/maps/gedit/"
const CELL_PITCH := 162.0

# chest GLB layers (already exported into the tileset's gedit dir by dungmesh): body `_0` + lid `_t`.
const CHEST_NORMAL := "ibox"        # normal treasure chest
const CHEST_KEY := "iboxs"          # small/special = key chest
const ATLA_GLB := GEDIT + "atra/atra.glb"

const LID_OPEN_DEG := -95.0         # lid rotates back about its hinge (the back edge, z=+5) when opened
const LID_OPEN_TIME := 0.5
const ATLA_FLOAT_AMP := 3.0         # bob amplitude (world units)
const ATLA_FLOAT_SPEED := 2.0
const ATLA_SCALE := 2.2             # the raw atra mesh is tiny (8u); scale it to read as a chest-sized soul
const ATLA_SEEK_TIME := 0.7         # seconds for the Atla to float into the player on pickup

@export var tileset := "d01main_a"

var _run: Node = null               # DungeonRun (the inventory + atla_list sink); resolved at build()
var _floor_gen: Node = null         # the owning DungeonFloorGen (for per-cell floor Y)
var placement: Dictionary = {}      # the DungeonEntities result for this floor (exposed for probes)
var _chest_nodes: Array = []        # [{node, looted, cell, item, kind}]
var _atla_nodes: Array = []         # [{node, taken, cell, id, t}]

# =====================================================================================================
# Build
# =====================================================================================================

## Spawn the loot layer for `layout`. `floor_gen` is the DungeonFloorGen (for cell_world / per-cell Y);
## `run` is the DungeonRun owning the inventory + atla_list. Idempotent: clears any prior spawns first.
func build(layout: Dictionary, floor_gen: Node, run: Node) -> void:
	_floor_gen = floor_gen
	_run = run
	_clear()

	var Ent = load("res://scripts/world/dungeon/dungeon_entities.gd")
	var ent = Ent.new()
	placement = ent.place(layout)

	for ch in placement.get("chests", []):
		_spawn_chest(ch)
	for at in placement.get("atla", []):
		_spawn_atla(at)

	print("dungeon_treasure: floor %d -> %d chests (%d key), %d atla, %d traps placed" % [
		int(layout.get("floor", 0)),
		placement.chests.size(),
		_count_kind(placement.chests, "key"),
		placement.atla.size(),
		placement.traps.size()])

func _count_kind(chests: Array, kind: String) -> int:
	var n := 0
	for c in chests:
		if String(c.get("kind", "")) == kind:
			n += 1
	return n

func _clear() -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	_chest_nodes.clear()
	_atla_nodes.clear()

# =====================================================================================================
# Chests
# =====================================================================================================

func _cell_world(cell: Vector2i) -> Vector3:
	# use the owning floor's per-cell floor Y so the chest sits ON the actual tile (not the global min)
	if _floor_gen and _floor_gen.has_method("cell_world"):
		return _floor_gen.call("cell_world", cell, 0.0)
	return Vector3(cell.x * CELL_PITCH, 0.0, cell.y * CELL_PITCH)

func _spawn_chest(ch: Dictionary) -> void:
	var cell: Vector2i = ch["cell"]
	var kind := String(ch.get("kind", "normal"))
	var base := CHEST_KEY if kind == "key" else CHEST_NORMAL
	var pos := _cell_world(cell)

	var root := Node3D.new()
	root.name = "Chest_%s_%d_%d" % [kind, cell.x, cell.y]
	root.position = pos
	add_child(root)

	# body (ibox_0) — static at the chest origin
	var body := _instance_glb(GEDIT + tileset + "/" + base + "_0.glb")
	if body:
		body.name = "Body"
		root.add_child(body)

	# lid (ibox_t) on a hinge pivot at the back edge (z = +5, the lid's centroid z) so it swings open
	var hinge := Node3D.new()
	hinge.name = "LidHinge"
	hinge.position = Vector3(0, 0, 5.0)
	root.add_child(hinge)
	var lid := _instance_glb(GEDIT + tileset + "/" + base + "_t.glb")
	if lid:
		lid.name = "Lid"
		lid.position = Vector3(0, 0, -5.0)   # un-offset so the lid mesh stays in place; only the hinge rotates
		hinge.add_child(lid)

	# trigger volume
	var area := Area3D.new()
	area.name = "Trigger"
	area.collision_layer = 0
	area.collision_mask = 1               # detect the player CharacterBody3D (default layer 1)
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(36, 28, 36)        # a generous reach around the ~16-wide chest
	cs.shape = box
	cs.position = Vector3(0, 8, 0)
	area.add_child(cs)
	root.add_child(area)

	var rec := {"node": root, "hinge": hinge, "looted": false, "cell": cell,
		"item": int(ch.get("item", 0)), "kind": kind}
	_chest_nodes.append(rec)
	area.body_entered.connect(_on_chest_entered.bind(rec))

func _on_chest_entered(body: Node, rec: Dictionary) -> void:
	if not _is_player(body):
		return
	open_chest(rec)

## Open a chest record (public so verification can trigger it without driving the player solver). Plays the
## lid-open tween, adds the item to the run inventory, and marks the chest looted (no re-trigger).
func open_chest(rec: Dictionary) -> void:
	if rec.get("looted", false):
		return
	rec["looted"] = true
	var item := int(rec.get("item", 0))
	print("dungeon_treasure: OPEN chest (%s) at (%d,%d) -> item 0x%X" % [
		rec.get("kind", "?"), rec.cell.x, rec.cell.y, item])
	# lid-open animation (rotate the hinge back)
	var hinge: Node3D = rec.get("hinge")
	if hinge and is_inside_tree():
		var tw := create_tween()
		tw.tween_property(hinge, "rotation:x", deg_to_rad(LID_OPEN_DEG), LID_OPEN_TIME) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	# add to inventory
	if _run and _run.has_method("add_item"):
		_run.call("add_item", item, 1)
	# disable further triggering (the chest stays open as a looted prop)
	var area := (rec.get("node") as Node3D).get_node_or_null("Trigger")
	if area:
		(area as Area3D).monitoring = false

## Open the first un-looted chest of a given kind ("normal"/"key"/"" = any) — verification convenience.
func open_first_chest(kind := "") -> Dictionary:
	for rec in _chest_nodes:
		if rec.looted:
			continue
		if kind == "" or rec.kind == kind:
			open_chest(rec)
			return rec
	return {}

# =====================================================================================================
# Atla
# =====================================================================================================

func _spawn_atla(at: Dictionary) -> void:
	var cell: Vector2i = at["cell"]
	var pos := _cell_world(cell) + Vector3(0, 10.0, 0)   # float above the floor

	var root := Node3D.new()
	root.name = "Atla_%d_%d" % [cell.x, cell.y]
	root.position = pos
	root.scale = Vector3.ONE * ATLA_SCALE
	add_child(root)

	var mesh := _instance_glb(ATLA_GLB)
	if mesh:
		mesh.name = "AtlaMesh"
		root.add_child(mesh)

	# a soft glow so the sealed soul reads in the dark cave
	var glow := OmniLight3D.new()
	glow.light_color = Color(0.6, 0.85, 1.0)
	glow.light_energy = 3.0
	glow.omni_range = 60.0
	root.add_child(glow)

	var area := Area3D.new()
	area.name = "Trigger"
	area.collision_layer = 0
	area.collision_mask = 1
	var cs := CollisionShape3D.new()
	var sph := SphereShape3D.new()
	sph.radius = 22.0
	cs.shape = sph
	area.add_child(cs)
	root.add_child(area)

	var rec := {"node": root, "taken": false, "cell": cell, "id": int(at.get("id", 0)),
		"base_y": pos.y, "t": 0.0}
	_atla_nodes.append(rec)
	area.body_entered.connect(_on_atla_entered.bind(rec))

func _on_atla_entered(body: Node, rec: Dictionary) -> void:
	if not _is_player(body):
		return
	pickup_atla(rec)

## Pick up an Atla (public for verification). Floats it to the player, pushes it onto DungeonRun.atla_list,
## shows its name (via the run's add_atla log/signal), then despawns it.
func pickup_atla(rec: Dictionary) -> void:
	if rec.get("taken", false):
		return
	rec["taken"] = true
	var node: Node3D = rec.get("node")
	# disable re-trigger immediately
	var area := node.get_node_or_null("Trigger")
	if area:
		(area as Area3D).monitoring = false
	# float to the player (if we have one), then despawn
	var target = _player_pos()
	if node and is_inside_tree():
		var tw := create_tween()
		tw.set_parallel(true)
		if target != null:
			tw.tween_property(node, "global_position", target, ATLA_SEEK_TIME).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
		tw.tween_property(node, "scale", Vector3.ONE * 0.1, ATLA_SEEK_TIME)
		tw.chain().tween_callback(node.queue_free)
	elif node:
		node.queue_free()
	# add to atla_list + show name
	if _run and _run.has_method("add_atla"):
		_run.call("add_atla", int(rec.get("id", 0)))

func _process(dt: float) -> void:
	# gentle float/bob for un-taken Atla
	for rec in _atla_nodes:
		if rec.get("taken", false):
			continue
		var node: Node3D = rec.get("node")
		if node == null or not is_instance_valid(node):
			continue
		rec["t"] = float(rec.get("t", 0.0)) + dt * ATLA_FLOAT_SPEED
		node.position.y = float(rec.get("base_y", node.position.y)) + sin(rec["t"]) * ATLA_FLOAT_AMP
		node.rotate_y(dt * 1.2)

# =====================================================================================================
# Helpers
# =====================================================================================================

func _instance_glb(path: String) -> Node3D:
	if not ResourceLoader.exists(path):
		push_warning("dungeon_treasure: GLB missing: " + path)
		return null
	var ps := load(path) as PackedScene
	if ps == null:
		return null
	return ps.instantiate() as Node3D

func _is_player(body: Node) -> bool:
	if _run and "_player" in _run and body == _run.get("_player"):
		return true
	return body is Node and (body.is_in_group("player") or body.name == "Player")

func _player_pos():
	if _run and "_player" in _run:
		var p = _run.get("_player")
		if p and p is Node3D:
			return (p as Node3D).global_position
	return null

# --- accessors for verification probes ---
func chests() -> Array:
	return _chest_nodes

func atla_nodes() -> Array:
	return _atla_nodes
