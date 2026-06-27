extends Node3D

@export_file("*.tscn") var start_level_path := "res://scenes/levels/e01.tscn"

@onready var _player: Node3D = $Player
@onready var _level_slot: Node3D = $CurrentLevel

var _current_id := ""          # the loaded area's id (its root node name) — the RETURN target for the next warp
var _warp_cd := 0.0            # post-spawn cooldown; doors don't fire while > 0 so spawning ON one is safe
var _has_pending := false      # next load_level spawns at a named entrance (a warp), not the default spawn
var _pending_entrance := ""    # node name to land at in the next level
var _return_area := ""         # where an empty-target (return) door sends you back to
var _return_entrance := ""     # the named door node to land back on
var _current_base := ""        # current area's BASE id (no time suffix) — to re-resolve the variant on a time change
var _time_label: Label         # DEBUG time-of-day HUD

func _ready() -> void:
	add_to_group("game_root")
	if start_level_path != "":
		_current_base = start_level_path.get_file().get_basename()
		load_level(load(start_level_path))
	_make_time_hud()
	TimeOfDay.time_changed.connect(func(_t): _update_time_hud())
	TimeOfDay.day_changed.connect(func(_d): _update_time_hud())

func _process(delta: float) -> void:
	_warp_cd = maxf(_warp_cd - delta, 0.0)

## DEBUG (F7): advance the time of day. Interiors reload to the matching e/m/n bake; towns will re-light live once
## the dynamic sky lands (next slice). Eventually driven by the georama clock UI / inn, not a keypress.
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_F7:
		TimeOfDay.cycle()
		if _current_base.begins_with("i"):
			var p := _resolve_variant(_current_base)
			if p != "":
				load_level.call_deferred(load(p))

## DEBUG: a top-left HUD showing the current time of day + day count (F7 advances time).
func _make_time_hud() -> void:
	var cl := CanvasLayer.new()
	cl.name = "DebugHUD"
	_time_label = Label.new()
	_time_label.position = Vector2(12, 10)
	_time_label.add_theme_font_size_override("font_size", 20)
	_time_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_time_label.add_theme_constant_override("outline_size", 5)
	cl.add_child(_time_label)
	add_child(cl)
	_update_time_hud()

func _update_time_hud() -> void:
	if _time_label != null:
		_time_label.text = "%s  —  Day %d      [F7] advance time" % [TimeOfDay.time_name(), TimeOfDay.day]

## A door may fire only after the post-spawn cooldown — this is what stops the door you land ON from instantly
## re-triggering (you spawn inside its volume; you must step out and walk back in).
func can_warp() -> bool:
	return _warp_cd <= 0.0

## A door was entered. Resolve its destination + entrance, remember the way back (so the destination's exit can
## return here), and swap areas. An empty target means RETURN to the caller.
func warp_through(door: Node) -> void:
	var tgt := String(door.get("target"))
	var entrance := String(door.get("dest_entrance"))
	if tgt == "":                                   # interior exit -> return whence we came
		tgt = _return_area
		entrance = _return_entrance
	else:                                           # outbound -> remember how to get back
		_return_area = _current_id
		_return_entrance = String(door.get("return_key"))
	if tgt == "":
		push_warning("warp_through: no destination (no return target set)")
		return
	var path := _resolve_variant(tgt)
	if path == "":
		push_warning("warp_through: no built scene for area '%s'" % tgt)
		return
	_current_base = tgt
	_pending_entrance = entrance
	_has_pending = true
	# Defer the swap: a door fires this from its input check, and freeing the old area's CollisionObjects must
	# happen OUTSIDE any physics/signal callback (Godot forbids removing a CollisionObject mid-callback).
	load_level.call_deferred(load(path))

## area id -> a built scene path, trying the bare id then the day/time variants (e.g. i01h06 -> i01h06e/m/n).
func _resolve_variant(area_id: String) -> String:
	for suffix in [TimeOfDay.suffix(), "", "m", "e", "n", "s", "k"]:
		var p := "res://scenes/levels/%s%s.tscn" % [area_id, suffix]
		if ResourceLoader.exists(p):
			return p
	return ""

## Swap the active area. Frees the current one, instances the new, and drops the player at its `Spawn` marker
## (or, for a warp, the named entrance). `scene` may be a baked area or, later, a generated dungeon floor.
func load_level(scene: PackedScene) -> void:
	for c in _level_slot.get_children():
		_level_slot.remove_child(c)
		c.queue_free()
	if scene == null:
		return
	var lvl := scene.instantiate()
	_level_slot.add_child(lvl)
	_current_id = lvl.name
	await get_tree().physics_frame        # let the new area's collision register before resolving the spawn
	if _player:
		_player.global_position = _resolve_warp_spawn(lvl) if _has_pending else _resolve_spawn(lvl)
		_player.velocity = Vector3.ZERO
		_has_pending = false
	_warp_cd = 0.3                        # brief guard so the door you LAND on can't fire on a held/stray press
	# DEBUG collision overlay (press F3 to toggle): GREEN = walkable floor, RED = wall, by the あたりポリゴン normal.
	var dbg := Node3D.new()
	dbg.name = "CollisionDebug"
	dbg.set_script(load("res://scripts/debug/collision_debug.gd"))
	lvl.add_child(dbg)
	# DEBUG surface highlighter (press F4 to toggle): tints + labels each render surface so a broken/stretched
	# one can be named on sight.
	var mdbg := Node3D.new()
	mdbg.name = "MeshDebug"
	mdbg.set_script(load("res://scripts/debug/mesh_debug.gd"))
	lvl.add_child(mdbg)

## Spawn at a NAMED entrance (a warp destination) and face into the area. Falls back to _resolve_spawn if the
## named node is missing, so a bad/edited link degrades to "land somewhere valid" instead of crashing.
func _resolve_warp_spawn(lvl: Node) -> Vector3:
	var node := lvl.get_node_or_null(_pending_entrance) as Node3D
	if node == null:
		push_warning("warp: entrance '%s' not found in %s — using default spawn" % [_pending_entrance, lvl.name])
		return _resolve_spawn(lvl)
	if _player.has_method("face"):
		_player.face(node.global_rotation.y + PI)   # face AWAY from the door (into the room / out toward town)
	return node.global_position + Vector3(0, 1.5, 0)

## Where to drop the player on a non-warp load. For a GEORAMA town the entry marker can sit inside a terrain
## hill (the town is un-built — no placed parts to enter through), so snap to the lowest buildable-cell floor
## (the valley you actually build on). Otherwise use the area's `Spawn` marker.
func _resolve_spawn(lvl: Node) -> Vector3:
	var grid := lvl.get_node_or_null("GeoramaGrid")
	var space := (lvl as Node3D).get_world_3d().direct_space_state if lvl is Node3D else null
	if grid != null and space != null:
		var best := Vector3.INF
		for c in grid.get("cells"):
			var p: Vector3 = c["pos"]
			var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(p + Vector3(0, 400, 0), p + Vector3(0, -400, 0)))
			if not hit.is_empty() and hit["position"].y < best.y:
				best = hit["position"]
		if best != Vector3.INF:
			return best + Vector3(0, 3, 0)
	var spawn := lvl.get_node_or_null("Spawn") as Node3D
	return spawn.global_position if spawn != null else Vector3(0, 8, 0)
