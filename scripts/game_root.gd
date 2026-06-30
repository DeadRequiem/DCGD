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
var _in_dungeon := false       # the active level is a DungeonRun (procedural), not a baked town/interior area

# D3.5: the dungeon "area" id used by the town's Door_dungeon_0 (target="dungeon") maps to this hosted scene —
# a DungeonRun that uses the persistent Player rather than its own. The town the dungeon returns to.
const DUNGEON_SCENE := "res://scenes/dungeons/dungeon.tscn"
@export var dungeon_return_town := "e01"

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
	# D3.5: the dungeon door (target="dungeon") swaps to the hosted DungeonRun scene instead of a baked area.
	if tgt == "dungeon":
		enter_dungeon()
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

# =====================================================================================================
# D3.5 — dungeon entry / town return (the Atla -> rebuild meta-loop transition through game_root)
# =====================================================================================================

## Swap to the dungeon (the persistent-Player-hosted DungeonRun). The DungeonRun spawns the player at floor 1's
## up-stair itself, so we mark _in_dungeon and skip the town spawn-resolve.
func enter_dungeon() -> void:
	_in_dungeon = true
	_current_base = "dungeon"
	_has_pending = false
	load_level.call_deferred(load(DUNGEON_SCENE))

## End a dungeon run and return to `town_id` in Rebuild Mode. Called by DungeonRun.exit_to_town after the
## collected Atla are banked into GeoramaState. The town scene, on load, sees GeoramaState.rebuild_pending and
## opens the RebuildUI (or we open it here directly once the town is live).
func return_to_town(town_id := "e01") -> void:
	_in_dungeon = false
	var path := _resolve_variant(town_id)
	if path == "":
		push_warning("return_to_town: no built scene for town '%s'" % town_id)
		return
	_current_base = town_id
	_has_pending = false
	load_level.call_deferred(load(path), true)

## area id -> a built scene path, trying the bare id then the day/time variants (e.g. i01h06 -> i01h06e/m/n).
func _resolve_variant(area_id: String) -> String:
	for suffix in [TimeOfDay.suffix(), "", "m", "e", "n", "s", "k"]:
		var p := "res://scenes/levels/%s%s.tscn" % [area_id, suffix]
		if ResourceLoader.exists(p):
			return p
	return ""

## Swap the active area. Frees the current one, instances the new, and drops the player at its `Spawn` marker
## (or, for a warp, the named entrance). `scene` may be a baked area, a georama town, or the hosted DungeonRun.
## `open_rebuild` (set by return_to_town) opens the D3.5 Rebuild UI once the town is live + Atla are pending.
func load_level(scene: PackedScene, open_rebuild := false) -> void:
	for c in _level_slot.get_children():
		_level_slot.remove_child(c)
		c.queue_free()
	if scene == null:
		return
	var lvl := scene.instantiate()
	_level_slot.add_child(lvl)
	_current_id = lvl.name
	await get_tree().physics_frame        # let the new area's collision register before resolving the spawn
	# A hosted DungeonRun spawns the player itself (at floor 1's up-stair); don't run the town spawn-resolve.
	if _player and not _in_dungeon:
		_player.global_position = _resolve_warp_spawn(lvl) if _has_pending else _resolve_spawn(lvl)
		_player.velocity = Vector3.ZERO
	_has_pending = false
	_warp_cd = 0.3                        # brief guard so the door you LAND on can't fire on a held/stray press
	# D3.5: returning to a town with collected Atla -> open the Rebuild UI bound to the town's georama grid.
	if open_rebuild:
		_open_rebuild_ui.call_deferred(lvl)
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

# =====================================================================================================
# D3.5 — Rebuild UI hosting
# =====================================================================================================

## Open the town-rebuild UI bound to `lvl`'s GeoramaGrid (if any Atla are pending). The UI is added under
## game_root so it survives independent of the swapped level. Returns the created RebuildUI (or null).
func _open_rebuild_ui(lvl: Node) -> Node:
	var gs := get_node_or_null("/root/GeoramaState")
	if gs != null and not gs.rebuild_pending:
		return null
	if get_node_or_null("RebuildUI") != null:
		return get_node("RebuildUI")
	var grid := lvl.get_node_or_null("GeoramaGrid")
	var ui = load("res://scripts/ui/rebuild_ui.gd").new()
	ui.name = "RebuildUI"
	add_child(ui)
	if grid != null and ui.has_method("bind"):
		ui.call("bind", grid)
	return ui

## The active town's GeoramaGrid (or null when in a dungeon / non-town area). Verification convenience.
func current_grid() -> Node:
	var lvl := _level_slot.get_child(0) if _level_slot.get_child_count() > 0 else null
	return lvl.get_node_or_null("GeoramaGrid") if lvl != null else null
