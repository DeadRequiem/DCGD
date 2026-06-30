extends Node3D
class_name DungeonRun
## DC1 Dungeon — D2 floor-to-floor run owner (the multi-floor progression).
##
## Turns a single generated floor into a real multi-floor dungeon. Owns:
##   - the current floor INDEX + dungeon index + base seed,
##   - the single active DungeonFloorGen instance (one floor live at a time; the rest are regenerated on demand),
##   - the Player, which it (re)spawns at the right stair on every transition.
##
## Floor flow (faithful to the decomp BtCleatRandomMap state machine):
##   - Reaching the DOWN-stair (out_2 marker, PT_MARKER eventId 160) advances to the next floor: increment the
##     floor counter, regenerate via DungeonGenerator with the next floor's seed, assemble it, and spawn Toan at
##     the NEW floor's UP-stair (you emerge from the in-stairs, the `in_2`/`up_out01` arrival).
##   - The UP-stair sends you back: decrement, regenerate the prior floor, spawn at its DOWN-stair.
##   - buildRandomMap is RE-RUN every entry (the original re-randomizes per descent). We derive each floor's seed
##     deterministically from (base_seed, floor) so a session's floors are reproducible, but the generation is a
##     genuine fresh buildRandomMap call — no caching of the assembled scene.
##
## Markers: the run attaches an Area3D at every resolved PT_MARKER. Stair markers drive the transition above;
## all others (ndoorkey, ura_2, chr1_* Xiao keys) are logged with their eventId and stubbed for D3.
##
## DEFERRED to D3: stair cinematics (dwn_in01/up_out01), event.stb cutscenes, enemies, treasure/Atla, the Ura
## back-floor. Stubs/logging for non-stair markers is intentional.

const MAX_FLOOR := [15, 17, 18, 18, 15, 25]   # MaxFloorTbl @0x279E40 (d01..d06); the floor where the boss arena loads
const SETTLE_Y_OFF := 6.0                      # spawn this far above the stair floor; the solver settles it down
## The Ura ("裏" / back-floor) seed offset. The decomp runs a SECOND buildRandomMap for the paired hard-mode
## layout (BtCleatRandomMap @0x1DB9140). We don't reproduce the original's exact seed derivation; instead we
## pick a documented deterministic offset so the Ura layout is reproducible AND guaranteed distinct from the
## regular floor's layout at the same depth (a different seed => a different buildRandomMap result).
const URA_SEED_OFFSET := 0x5552415F            # "URA_" — an arbitrary fixed, documented offset

@export var dun_idx := 0          # 0 = d01 Divine Beast Cave
@export var tileset := "d01main_a"
@export var boss_tileset := "d01boss"          # the authored boss-arena manifest (<boss_tileset>.boss.json)
@export var base_seed := 12345
@export var start_floor := 1
@export var trigger_cooldown := 1.0   # seconds after a transition before a stair Area can fire again (anti-bounce)

var floor_index := 1
## The active floor. Either a DungeonFloorGen (procedural regular/Ura floor) or a DungeonBossFloor (the
## authored terminus arena). Both expose the same surface DungeonRun consumes (build/layout/markers/
## entry_pos/stair_*_pos), so the run treats them duck-typed via a plain Node3D handle.
var _floor: Node3D = null
var _floor_is_boss := false           # the active floor is the authored boss arena (terminus)
var _treasure: Node = null            # DungeonTreasure (the D3.1 loot/Atla layer), rebuilt per floor
var _director: Node = null            # DungeonEventDirector (the D3.2 event.stb router), rebound per floor
var _cinematic: Node = null           # StairCinematic (the D3.3 descend/ascent sequence); persists across floors
var _player: Node3D = null
var _cam_rig: Node = null             # the DungeonCamera helper (optional), rebound per floor
var _cooldown := 0.0
## Stair Areas the player SPAWNS inside (you always spawn on a stair tile). They start DISARMED and arm the
## first time the player leaves their radius — otherwise the stair you spawn on instantly fires once the
## anti-bounce cooldown lapses, warping you straight back out (the real engine likewise only re-triggers a
## stair you've stepped off and back onto). Keyed by Area3D instance id.
var _disarmed_stairs: Dictionary = {}

## D3.3: when true, the down/up stairs play the StairCinematic (portal + camera + char anim) around the floor
## transition. When false (or no cinematic), the stairs do the D2 instant warp. Defaults on.
@export var stair_cinematics := true

# --- D3.1 loot/reward state (the run owner is the natural home for collected items + Atla) ---
## A simple inventory stub: item-id -> quantity. Chests add to it; D3.2/D3.5 will replace it with the real
## item DB + georama meta. Kept on the run owner so a session's collected loot survives floor transitions.
var inventory: Dictionary = {}
## The collected sealed townsfolk (Atla) for this dungeon run. Each entry is {id, floor, name}. D3.5's
## town-rebuild meta-loop consumes this; D3.1 only needs it to POPULATE correctly on pickup.
var atla_list: Array = []

# --- D3.4 Ura back-floor state. The Ura is a parallel hard-mode layout at the SAME depth, reached via the
# ura_2 marker (eventId 200). DungeonRun owns the regular<->Ura swap: entering Ura regenerates the floor with
# the Ura-offset seed; exiting returns to the regular floor at the same depth (re-randomized, faithful to the
# per-entry regen). _in_ura tracks which side we are on so go_down/go_up and re-entry behave correctly.
var _in_ura := false

signal floor_changed(new_floor: int, direction: int)   # direction: +1 down, -1 up, 0 initial
signal item_collected(item_id: int, qty: int)          # a chest was opened
signal atla_collected(atla_id: int, atla_name: String) # an Atla was picked up

func _ready() -> void:
	_player = get_node_or_null("Player")
	if _player == null:
		var parent := get_parent()
		if parent:
			_player = parent.get_node_or_null("Player")
	if _player == null:
		# D3.5: when hosted under game_root (the integrated town<->dungeon flow) the persistent Player lives at
		# /root/Game/Player, above this run node. Fall back to the player group so the run binds it either way.
		_player = get_tree().get_first_node_in_group("player") as Node3D
	_cam_rig = get_node_or_null("DungeonCamera")
	# the event director (D3.2) persists across floors (it owns the decoded event.stb manifest); it is RE-BOUND
	# to each new floor in _load_floor. The dungeon id "d01" -> the d01_event_manifest.json the CLI emitted.
	var Director = load("res://scripts/world/dungeon/dungeon_event_director.gd")
	_director = Director.new()
	_director.name = "EventDirector"
	add_child(_director)
	var manifest_id := "d%02d" % (dun_idx + 1)
	_director.call("load_manifest", manifest_id)
	# the stair cinematic (D3.3) also persists across floors; it parses the dwn_in01/up_out01 locator MOTs once
	# and choreographs the descend/ascent around go_down/go_up. Bound to the player here.
	if stair_cinematics:
		var Cine = load("res://scripts/world/dungeon/stair_cinematic.gd")
		_cinematic = Cine.new()
		_cinematic.name = "StairCinematic"
		add_child(_cinematic)
		_cinematic.call("bind", self, _player)
	floor_index = start_floor
	_load_floor(floor_index, 0, true)

func _physics_process(delta: float) -> void:
	_cooldown = maxf(_cooldown - delta, 0.0)
	# Fallback arming for disarmed spawn-stairs: body_exited normally arms them, but if a frame is missed we
	# also arm any stair the player is now clearly outside of (distance > radius). Keeps the disarm from sticking.
	if not _disarmed_stairs.is_empty() and _player != null and _floor != null:
		var pp: Vector3 = (_player as Node3D).global_position
		for area in _floor.get_children():
			if not (area is Area3D) or not _disarmed_stairs.has(area.get_instance_id()):
				continue
			var cs := area.get_node_or_null("CollisionShape3D") as CollisionShape3D
			var r := 24.0
			if cs and cs.shape is SphereShape3D:
				r = (cs.shape as SphereShape3D).radius
			if area.global_position.distance_to(pp) > r + 2.0:
				_disarmed_stairs.erase(area.get_instance_id())

# =====================================================================================================
# Floor loading / transition
# =====================================================================================================

func _seed_for(floor: int) -> int:
	# deterministic per-floor derivation; keeps a session reproducible while every entry is a real regen.
	# the Ura back-floor at the same depth gets a fixed offset so it's a DISTINCT (but reproducible) layout.
	var s := base_seed + floor * 1013904223
	if _in_ura:
		s += URA_SEED_OFFSET
	return s

## Is `floor` the dungeon's terminus (where the authored boss arena loads instead of a procedural floor)?
## The decomp picks BtCleatFreeMap over BtCleatRandomMap at this floor. Ura floors are never the boss.
func _is_boss_floor(floor: int) -> bool:
	if _in_ura:
		return false
	var maxf_i: int = MAX_FLOOR[dun_idx] if dun_idx < MAX_FLOOR.size() else 99
	return floor >= maxf_i

## (Re)generate floor `floor` and spawn the player at the right stair.
## spawn_at: "up" = the up-stair (default for descending / initial), "down" = the down-stair (for ascending).
func _load_floor(floor: int, direction: int, initial := false) -> void:
	var spawn_at := "down" if direction < 0 else "up"
	var want_boss := _is_boss_floor(floor)

	# the active floor node TYPE depends on procedural-vs-authored; recreate it when the kind changes so a
	# DungeonFloorGen is never asked to build an authored arena (and vice-versa).
	if _floor != null and want_boss != _floor_is_boss:
		_floor.queue_free()
		_floor = null
	if _floor == null:
		if want_boss:
			var Boss = load("res://scripts/world/dungeon/dungeon_boss_floor.gd")
			_floor = Boss.new()
			_floor.set("tileset", boss_tileset)
		else:
			var fl := DungeonFloorGen.new()
			fl.tileset = tileset
			_floor = fl
		_floor.name = "ActiveFloor"
		_floor.set("build_on_ready", false)
		add_child(_floor)
	_floor_is_boss = want_boss

	var ok: bool = _floor.call("build", dun_idx, floor, _seed_for(floor))
	if not ok:
		push_error("dungeon_run: failed to build floor %d" % floor)
		return

	_build_treasure()
	_bind_director()
	_disarmed_stairs.clear()
	_wire_markers()
	_spawn_player(spawn_at)
	_disarm_spawn_stairs()   # the stair you spawn ON starts disarmed; it arms once you step off it
	_rebind_camera()
	_cooldown = trigger_cooldown
	var lay: Dictionary = _floor.get("layout")
	print("dungeon_run: %s floor %d%s (dir=%d, spawn=%s) seed=%d entry=%s up=%s down=%s%s" % [
		(boss_tileset if want_boss else tileset), floor, (" [URA]" if _in_ura else ""),
		direction, spawn_at, _seed_for(floor),
		str(lay.get("entry")), str(lay.get("stairUp")), str(lay.get("stairDown")),
		(" BOSS-ARENA Dran=%d" % _floor.call("dran_segment_count")) if want_boss else ""])
	floor_changed.emit(floor, 0 if initial else direction)

## Spawn the player above the chosen stair so the floor solver settles it onto the landing.
func _spawn_player(spawn_at: String) -> void:
	if _player == null:
		return
	var pos: Vector3
	var lay: Dictionary = _floor.get("layout")
	match spawn_at:
		"down":
			pos = _floor.call("stair_down_pos", SETTLE_Y_OFF)
		"up":
			# prefer the up-stair; if a floor has no distinct up-stair, fall back to the entry seed.
			var up: Vector2i = lay.get("stairUp", Vector2i(-1, -1))
			pos = _floor.call("stair_up_pos", SETTLE_Y_OFF) if up.x >= 0 else _floor.call("entry_pos", SETTLE_Y_OFF)
		_:
			pos = _floor.call("entry_pos", SETTLE_Y_OFF)
	(_player as Node3D).global_position = pos
	# zero any inherited velocity so the solver settles cleanly (no carried fall).
	if _player is CharacterBody3D:
		(_player as CharacterBody3D).velocity = Vector3.ZERO
	# Real-play fix (bug 1): face the player toward the OTHER stair and snap the camera behind, so "move_up"
	# drives toward the exit instead of back into the stair geometry he just spawned on. Spawning on the
	# up-stair we head for the down-stair; on the down-stair we head for the up-stair. face() also re-centers
	# the follow-cam behind that heading, which (with the camera fix) gives a clean "walk forward to leave".
	if _player.has_method("face"):
		var here: Vector3 = (_player as Node3D).global_position
		var target: Vector3 = (_floor.call("stair_down_pos", 0.0) if spawn_at == "up" else _floor.call("stair_up_pos", 0.0))
		var to := target - here
		to.y = 0.0
		if to.length() > 1.0:
			_player.call("face", atan2(to.x, to.z))

func _rebind_camera() -> void:
	if _cam_rig and _cam_rig.has_method("rebind"):
		_cam_rig.call("rebind", _floor)

## (Re)build the D3.1 loot/Atla layer for the active floor. The treasure node lives as a child of the
## active floor so it's freed automatically when the floor is cleared on the next transition.
func _build_treasure() -> void:
	var Treasure = load("res://scripts/world/dungeon/dungeon_treasure.gd")
	_treasure = Treasure.new()
	_treasure.name = "Treasure"
	_treasure.set("tileset", tileset)
	_floor.add_child(_treasure)
	_treasure.call("build", _floor.get("layout"), _floor, self)

## (Re)bind the D3.2 event director to the active floor. The director itself persists on the run (it owns the
## decoded event.stb manifest); binding clears the prior floor's spawned event actors and points it at the new
## floor's geometry so spawn positions resolve to the new cells.
func _bind_director() -> void:
	if _director and _director.has_method("bind"):
		_director.call("bind", _floor, self)

# =====================================================================================================
# Transitions — public so verification can trigger AT the stair without driving the player solver
# =====================================================================================================

## Advance to the next floor (down-stair). Clamped at the dungeon's terminus floor. The index bumps
## synchronously; the heavy floor rebuild is DEFERRED so this is safe to call from an Area3D body_entered
## physics callback (freeing collision bodies mid-callback is illegal in Godot).
func go_down() -> int:
	var maxf_i: int = MAX_FLOOR[dun_idx] if dun_idx < MAX_FLOOR.size() else 99
	if floor_index >= maxf_i:
		print("dungeon_run: floor %d is the terminus (max %d) — no down-stair" % [floor_index, maxf_i])
		return floor_index
	floor_index += 1
	_cooldown = trigger_cooldown          # block re-fire immediately, before the deferred rebuild lands
	_load_floor.call_deferred(floor_index, 1, false)
	return floor_index

## Go back up a floor (up-stair). Clamped at floor 1. Ascending from floor 1 EXITS the dungeon -> the town
## return flow (D3.5): the up-stair on floor 1 is the dungeon mouth back to Norune.
func go_up() -> int:
	if floor_index <= 1:
		print("dungeon_run: floor 1 up-stair -> exit the dungeon, return to town")
		exit_to_town()
		return floor_index
	floor_index -= 1
	_cooldown = trigger_cooldown
	_load_floor.call_deferred(floor_index, -1, false)
	return floor_index

## D3.5 — END the run and return to the town in Rebuild Mode. Hands the collected atla_list to GeoramaState
## (the getAtraToSaveData bridge), then asks game_root to swap back to the town. If there is no game_root
## (a standalone dungeon test scene), the Atla are still banked into GeoramaState and a warning is logged so
## the caller/verification can drive the town swap itself.
func exit_to_town(town_id := "e01") -> void:
	var gs := get_node_or_null("/root/GeoramaState")
	if gs != null:
		gs.call("bring_back", atla_list)
	var gr := get_tree().get_first_node_in_group("game_root")
	if gr != null and gr.has_method("return_to_town"):
		gr.call_deferred("return_to_town", town_id)
	else:
		print("dungeon_run: exit_to_town — no game_root; %d Atla banked into GeoramaState (caller drives the town swap)" % atla_list.size())

# =====================================================================================================
# D3.3: cinematic-wrapped transitions — the PUBLIC entry points the stair markers (and verification) use.
# These play the descend/ascent sequence around go_down/go_up. If the cinematic is off/absent or we're at a
# terminus, they fall back to the D2 instant warp so the run never deadlocks.
# =====================================================================================================

## Descend with the D3.3 cinematic (portal + camera + character animation, then the floor transition, then the
## arrival emerge). Falls back to the instant go_down() warp if cinematics are off/at-terminus.
func descend() -> int:
	var maxf_i: int = MAX_FLOOR[dun_idx] if dun_idx < MAX_FLOOR.size() else 99
	if floor_index >= maxf_i:
		return go_down()   # terminus: go_down logs + no-ops
	if stair_cinematics and _cinematic and not _cinematic.call("is_active"):
		_cinematic.call("play_descent")
		return floor_index + 1
	return go_down()

## Ascend with the D3.3 cinematic (emerge-out, transition, settle). Falls back to instant go_up().
func ascend() -> int:
	if floor_index <= 1:
		return go_up()
	if stair_cinematics and _cinematic and not _cinematic.call("is_active"):
		_cinematic.call("play_ascent")
		return floor_index - 1
	return go_up()

## The active stair cinematic (for verification probes).
func active_cinematic() -> Node:
	return _cinematic

# =====================================================================================================
# D3.4 — Ura back-floor swap (the parallel hard-mode dungeon at the same depth)
# =====================================================================================================

## Enter or leave the Ura back-floor at the CURRENT depth. The decomp generates a paired Ura layout via a
## second buildRandomMap; here, flipping _in_ura changes the per-floor seed (URA_SEED_OFFSET) so the floor is
## rebuilt into a DISTINCT layout (and the URA_* lighting block, deferred to the tileset). The floor index is
## unchanged — Ura and the regular floor sit at the same depth. Returns true while in Ura.
func toggle_ura() -> bool:
	_in_ura = not _in_ura
	_cooldown = trigger_cooldown
	print("dungeon_run: ura_2 -> %s the Ura back-floor at depth %d" % [
		("ENTER" if _in_ura else "EXIT"), floor_index])
	# rebuild the same depth with the (now toggled) seed. direction 0 = spawn at the up-stair/entry.
	_load_floor.call_deferred(floor_index, 0, false)
	return _in_ura

## Explicitly enter the Ura (idempotent). Used by verification.
func enter_ura() -> void:
	if not _in_ura:
		toggle_ura()

## Explicitly exit the Ura back to the regular floor (idempotent).
func exit_ura() -> void:
	if _in_ura:
		toggle_ura()

func in_ura() -> bool:
	return _in_ura

func is_boss_active() -> bool:
	return _floor_is_boss

func active_floor() -> Node3D:
	return _floor

# =====================================================================================================
# Markers — Area3D triggers per resolved PT_MARKER
# =====================================================================================================

func _wire_markers() -> void:
	# (the prior floor's marker areas are children of _floor, cleared by its build()/_clear())
	for m in _floor.call("markers"):
		var area := Area3D.new()
		var nm := String(m.get("name", "?"))
		var kind := String(m.get("kind", "event"))
		area.name = "Mark_%s_%d_%d" % [nm, m.cell.x, m.cell.y]
		area.position = m.pos
		# detect bodies (the player CharacterBody3D is on the default layer)
		area.collision_layer = 0
		area.collision_mask = 1
		var cs := CollisionShape3D.new()
		var sph := SphereShape3D.new()
		# cfg range is in the tile's local units (~6..30); scale to the 162u cell world. A modest multiplier
		# keeps the trigger inside the tile rather than swallowing neighbours.
		sph.radius = maxf(float(m.get("range", 10.0)) * 1.5, 14.0)
		cs.shape = sph
		area.add_child(cs)
		_floor.add_child(area)
		area.body_entered.connect(_on_marker_entered.bind(m))
		if kind == "stair_down" or kind == "stair_up":
			_register_stair_area(area)
	_wire_up_stair()

## D3.5 — the up-stair return trigger. The d01 tileset carries an out_2 down-stair marker but NO named in_2
## up-stair marker, so there's no cfg-driven ascend trigger. We attach one explicitly at the layout's resolved
## stairUp cell (real layout data, not an invented marker): stepping onto it ascends a floor, and on floor 1 it
## EXITS the dungeon back to the town (the Atla -> rebuild meta-loop entry). Mirrors the stair_down anti-bounce.
func _wire_up_stair() -> void:
	var lay: Dictionary = _floor.get("layout")
	var up: Vector2i = lay.get("stairUp", Vector2i(-1, -1))
	if up.x < 0:
		return
	var marker := {"name": "up_stair", "eventId": -1, "kind": "stair_up", "cell": up,
		"pos": _floor.call("stair_up_pos", 0.0), "range": 16.0}
	var area := Area3D.new()
	area.name = "UpStair_%d_%d" % [up.x, up.y]
	area.position = marker["pos"]
	area.collision_layer = 0
	area.collision_mask = 1
	var cs := CollisionShape3D.new()
	var sph := SphereShape3D.new()
	sph.radius = 24.0
	cs.shape = sph
	area.add_child(cs)
	_floor.add_child(area)
	area.body_entered.connect(_on_marker_entered.bind(marker))
	_register_stair_area(area)

## Wire a stair Area3D so it can be DISARMED-at-spawn: it arms the first time the player exits its radius.
## _disarm_spawn_stairs (called after the player is placed) flags the one the player spawns inside.
func _register_stair_area(area: Area3D) -> void:
	area.body_exited.connect(func(body: Node):
		if body == _player or (body is Node and body.is_in_group("player")):
			_disarmed_stairs.erase(area.get_instance_id()))

## After the player is placed, DISARM any stair Area whose radius the player is standing in (always the stair
## he spawned on). It re-arms on body_exited. Distance-based so it's synchronous (no physics-frame dependency).
func _disarm_spawn_stairs() -> void:
	if _player == null or _floor == null:
		return
	var pp: Vector3 = (_player as Node3D).global_position
	for area in _floor.get_children():
		if not (area is Area3D):
			continue
		if not (area.name.begins_with("UpStair_") or area.name.begins_with("Mark_out_2_")):
			continue
		var cs := area.get_node_or_null("CollisionShape3D") as CollisionShape3D
		var r := 24.0
		if cs and cs.shape is SphereShape3D:
			r = (cs.shape as SphereShape3D).radius
		if area.global_position.distance_to(pp) <= r + 1.0:
			_disarmed_stairs[area.get_instance_id()] = true

## Is the stair Area for `marker`'s cell currently DISARMED (player spawned on it, hasn't stepped off yet)?
func _stair_disarmed(marker: Dictionary) -> bool:
	if _disarmed_stairs.is_empty() or _floor == null:
		return false
	var cell: Vector2i = marker.get("cell", Vector2i(-1, -1))
	var up := "UpStair_%d_%d" % [cell.x, cell.y]
	var dn := "Mark_out_2_%d_%d" % [cell.x, cell.y]
	for area in _floor.get_children():
		if area is Area3D and (area.name == up or area.name == dn):
			return _disarmed_stairs.has(area.get_instance_id())
	return false

## A PT_MARKER's Area3D fired. Stairs stay D2-owned (the descent state machine); everything else is routed to
## the D3.2 event director, which decodes the eventId against the event.stb manifest and spawns/logs the beat.
func _on_marker_entered(body: Node, marker: Dictionary) -> void:
	if not (body == _player or (body is Node and body.is_in_group("player"))):
		return
	var kind := String(marker.get("kind", "event"))
	var nm := String(marker.get("name", "?"))
	var event_id := int(marker.get("eventId", -1))
	# stairs: D2 owns the transition (anti-bounce cooldown). The director only observes/logs the tie-in.
	if kind == "stair_down":
		# don't re-fire mid-cinematic (the cinematic moves the player onto the new stair, which could re-enter).
		if _cinematic and _cinematic.call("is_active"):
			return
		if _stair_disarmed(marker):
			return                          # spawned ON this stair; it arms only after stepping off it
		if _cooldown <= 0.0:
			print("dungeon_run: [PT_MARKER %s eventId=%d] DOWN-stair on floor %d -> descend" % [nm, event_id, floor_index])
			if _director and _director.has_method("handle_event"):
				_director.call("handle_event", event_id, marker)
			descend()
		return
	# the up-stair (in_2 on the stairUp cell): ascend a floor; on floor 1 this EXITS to the town (D3.5).
	if kind == "stair_up":
		if _cinematic and _cinematic.call("is_active"):
			return
		if _stair_disarmed(marker):
			return                          # spawned ON this stair; it arms only after stepping off it
		if _cooldown <= 0.0:
			print("dungeon_run: [PT_MARKER %s eventId=%d] UP-stair on floor %d -> %s" % [
				nm, event_id, floor_index, ("ascend" if floor_index > 1 else "exit to town")])
			if _director and _director.has_method("handle_event"):
				_director.call("handle_event", event_id, marker)
			ascend()
		return
	# the ura_2 back-floor entrance (eventId 200): D3.4 owns the regular<->Ura swap at the same depth.
	if kind == "ura":
		if _cooldown <= 0.0:
			if _director and _director.has_method("handle_event"):
				_director.call("handle_event", event_id, marker)
			toggle_ura()
		return
	# everything else -> the event director (D3.2).
	if _director and _director.has_method("handle_event"):
		_director.call("handle_event", event_id, marker)
	else:
		print("dungeon_run: [PT_MARKER %s eventId=%d kind=%s] no director — logged" % [nm, event_id, kind])

## Trigger a marker's event by name from outside (verification convenience — fires the director without
## driving the player solver into the Area). Returns the event record the director routed, or {}.
func fire_marker(marker_name: String) -> Dictionary:
	if _floor == null or _director == null:
		return {}
	for m in _floor.call("markers"):
		if String(m.get("name", "")) == marker_name:
			return _director.call("handle_event", int(m.get("eventId", -1)), m)
	return {}

## The active event director (for verification probes).
func active_director() -> Node:
	return _director

# =====================================================================================================
# Loot / reward collection (D3.1) — the treasure layer (dungeon_treasure.gd) calls these on pickup
# =====================================================================================================

## Add a chest's item to the inventory stub. Returns the new quantity. (D3.2 will resolve real item names.)
func add_item(item_id: int, qty := 1) -> int:
	var n := int(inventory.get(item_id, 0)) + qty
	inventory[item_id] = n
	print("dungeon_run: collected item 0x%X (qty now %d) — inventory has %d distinct ids" % [item_id, n, inventory.size()])
	item_collected.emit(item_id, n)
	return n

## Push a collected Atla onto atla_list. Returns the new list length. The name is a stand-in (D3.5 maps the
## id to a specific sealed townsfolk via the georama meta + save data).
func add_atla(atla_id: int, atla_name := "") -> int:
	var nm := atla_name if atla_name != "" else _atla_name(atla_id)
	atla_list.append({"id": atla_id, "floor": floor_index, "name": nm})
	print("dungeon_run: collected ATLA '%s' (id=%d) on floor %d — atla_list length now %d" % [
		nm, atla_id, floor_index, atla_list.size()])
	atla_collected.emit(atla_id, nm)
	return atla_list.size()

## Stand-in display name for an Atla id (D3.5 keys these to real townsfolk; d01 = Norune residents).
func _atla_name(atla_id: int) -> String:
	const NORUNE := ["Macho", "Paige", "Cacto", "Komari", "Pao", "Gaffer", "Rando", "Erika"]
	return NORUNE[atla_id % NORUNE.size()]

# =====================================================================================================
# Verification helpers (headless probes use these — see scratchpad probes)
# =====================================================================================================

## Current floor's active generated layout (entry/stairUp/stairDown cells, rooms, etc.).
func active_layout() -> Dictionary:
	return _floor.get("layout") if _floor else {}

## The active floor as a DungeonFloorGen (null on the authored boss arena — use active_floor() there).
func active_floor_gen() -> DungeonFloorGen:
	return _floor as DungeonFloorGen

## The active floor's loot/Atla layer (DungeonTreasure) — verification triggers pickups through it.
func active_treasure() -> Node:
	return _treasure
