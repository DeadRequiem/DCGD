extends Node3D
class_name DungeonEventDirector
## DC1 Dungeon — D3.2 floor EVENT DIRECTOR (the runtime side of event.stb / SetupEvent).
##
## The decomp's SetupEvent binds each floor's PT_MARKER eventIds to the per-event records decoded from
## dun/script/d01/event.stb (the "STB\0" event manifest). This node is the Godot counterpart: given the
## decoded manifest (Project/assets/dungeons/<set>_event_manifest.json, produced by the C# `dungevents`
## command) it routes a marker's eventId to a handler and spawns that event's structural actor(s) at the
## marker's world cell.
##
## WHAT event.stb GIVES US (fully decoded + verified — see EventScriptParser.cs / docs/formats/dungeons.md):
##   - the 22-entry (eventId -> block) MASTER DIRECTORY, every id matching a cfg PT_MARKER eventId, and
##   - the per-event actor list + the floor's 143-asset / 46-distinct-.chr actor roster.
## WHAT IT DOES NOT GIVE US: a baked spawn position. In DC1 the event actor's POSITION is the runtime
## PT_MARKER cell (the marker is placed by the procedural generator + buildEventData), so this director takes
## the position from the marker, NOT from the binary. (The per-event token tree — pose/camera/timeline — is
## NOT byte-decoded; full cutscene CHOREOGRAPHY is deferred to D3.3. Here we spawn the actor + LOG the beat.)
##
## ROUTING (by the manifest's "kind", which mirrors the cfg marker vocabulary):
##   - stair_down (160)         : left to DungeonRun.go_down() (D2 already wires the descent) — director no-ops.
##   - cutscene (300/102/100/..) : spawn the event's structural actor at the marker + LOG the cutscene trigger.
##   - boss (500/510)           : spawn the boss actor (or placeholder) at the marker + LOG the boss-start beat.
##   - ura (200)                : LOG the back-floor entrance (the actual 2nd buildRandomMap is D3.4).
##   - door/gatekey/bosskey     : LOG the key-gate (the key/unlock logic is a later content pass).
##   - char_key (350/351/..)    : LOG the Xiao character-key spot.
##   - auto (5/15/16/90/150/199): the floor's ambient/auto beats — spawn any named actor + LOG.
##
## Actor resolution: a manifest .chr name -> the exported GLB under assets/maps/gedit/<name>/<name>.glb (the
## same dungmesh output path D3.1's atra uses). If a given event actor isn't exported yet (most event/cutscene
## actors are NOT — that's asset-pipeline work, not event-director work), the director spawns a clearly-visible
## PLACEHOLDER marker so the routing + spawn is still provable on screen. This keeps D3.3+ unblocked.

const GEDIT := "res://assets/maps/gedit/"
const DUNGEONS := "res://assets/dungeons/"

@export var manifest_id := "d01"     # which <id>_event_manifest.json to load

var _manifest: Dictionary = {}
var _by_event: Dictionary = {}       # eventId(int) -> event record dict
var _run: Node = null                # the DungeonRun (optional; for context/logging)
var _floor_gen: Node = null          # the active DungeonFloorGen (for cell_world)
var _spawned: Array = []             # [{eventId, node, actor}] — every actor this director spawned (for probes)
var _fired: Dictionary = {}          # eventId -> times fired (one-shot guard for non-repeating beats)

signal event_fired(event_id: int, kind: String, actor: String, pos: Vector3)

# =====================================================================================================
# Setup
# =====================================================================================================

## Load the decoded event manifest. Returns false (and logs) if it's missing — the run still works (D2 stairs
## are independent of the director), the director just becomes a no-op.
func load_manifest(id := "") -> bool:
	if id != "":
		manifest_id = id
	var path := DUNGEONS + manifest_id + "_event_manifest.json"
	if not FileAccess.file_exists(path):
		push_warning("dungeon_event_director: manifest missing: " + path)
		return false
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		push_error("dungeon_event_director: manifest parse failed: " + path)
		return false
	_manifest = parsed
	_by_event.clear()
	for e in _manifest.get("events", []):
		_by_event[int(e.get("eventId", -1))] = e
	print("dungeon_event_director: loaded %s — %d events, %d unique assets" % [
		manifest_id, _by_event.size(), int(_manifest.get("uniqueAssetCount", 0))])
	return true

## Bind the director to the active floor + run. Clears any actors spawned for the previous floor.
func bind(floor_gen: Node, run: Node) -> void:
	_floor_gen = floor_gen
	_run = run
	_clear_spawned()
	_fired.clear()

func _clear_spawned() -> void:
	for s in _spawned:
		var node = s.get("node")
		if node and is_instance_valid(node):
			node.queue_free()
	_spawned.clear()

# =====================================================================================================
# Routing
# =====================================================================================================

## The marker layer calls this when a marker's Area3D fires (or a probe triggers it directly). `marker` is the
## resolved marker dict from DungeonFloorGen.markers() ({name,eventId,kind,cell,pos,range}). Returns the
## event record routed, or {} if the eventId isn't in the manifest.
func handle_event(event_id: int, marker: Dictionary = {}) -> Dictionary:
	var rec: Dictionary = _by_event.get(event_id, {})
	var kind := String(rec.get("kind", marker.get("kind", "unknown")))
	var meaning := String(rec.get("meaning", ""))
	var pos: Vector3 = marker.get("pos", Vector3.ZERO)
	if rec.is_empty():
		# the marker's eventId isn't in the manifest directory — log and bail (don't invent behaviour).
		print("dungeon_event_director: [eventId=%d] not in manifest (marker '%s') — ignored" % [
			event_id, String(marker.get("name", "?"))])
		return {}

	_fired[event_id] = int(_fired.get(event_id, 0)) + 1
	var actors: Array = rec.get("actors", [])
	var primary := String(actors[0]) if actors.size() > 0 else ""

	match kind:
		"stair_down":
			# D2 owns the descent (DungeonRun.go_down via the stair Area). The director only logs the tie-in.
			print("dungeon_event_director: [eventId=%d] %s — stair handled by DungeonRun (D2)" % [event_id, meaning])
		"cutscene":
			print("dungeon_event_director: [eventId=%d] CUTSCENE TRIGGER: %s (actors=%s) — spawn+log (choreography=D3.3 stub)" % [
				event_id, meaning, str(actors)])
			_spawn_event_actors(event_id, actors, pos)
		"boss":
			print("dungeon_event_director: [eventId=%d] BOSS BEAT: %s (actors=%s) — spawn+log (combat=Phase 4)" % [
				event_id, meaning, str(actors)])
			_spawn_event_actors(event_id, actors, pos)
		"ura":
			print("dungeon_event_director: [eventId=%d] %s — back-floor entrance (2nd buildRandomMap=D3.4 stub)" % [event_id, meaning])
			_spawn_event_actors(event_id, actors, pos)
		"door", "gatekey", "bosskey":
			print("dungeon_event_director: [eventId=%d] %s — key/door gate (unlock logic later) " % [event_id, meaning])
		"char_key":
			print("dungeon_event_director: [eventId=%d] %s — Xiao character-key spot" % [event_id, meaning])
		"auto":
			print("dungeon_event_director: [eventId=%d] AUTO BEAT: %s (actors=%s)" % [event_id, meaning, str(actors)])
			_spawn_event_actors(event_id, actors, pos)
		_:
			print("dungeon_event_director: [eventId=%d] %s [kind=%s] — logged" % [event_id, meaning, kind])

	event_fired.emit(event_id, kind, primary, pos)
	return rec

# =====================================================================================================
# Actor spawning
# =====================================================================================================

## Spawn each named structural actor for an event at `pos`. Resolves a manifest ".chr" name to its exported
## GLB (assets/maps/gedit/<base>/<base>.glb); if not exported, drops a labelled placeholder so the spawn is
## still visible/provable. One-shot per (eventId, actor) so re-entering a marker doesn't duplicate it.
func _spawn_event_actors(event_id: int, actors: Array, pos: Vector3) -> void:
	for a in actors:
		var actor := String(a)
		var base := actor.get_slice(".", 0)        # "e28c01d.chr" -> "e28c01d"; "e16c12a_boss.cfg" -> "e16c12a_boss"
		# already spawned for this event? skip (one-shot).
		var dup := false
		for s in _spawned:
			if int(s.get("eventId", -1)) == event_id and String(s.get("actor", "")) == actor:
				dup = true
				break
		if dup:
			continue
		var node := _resolve_actor_node(base)
		node.name = "Event_%d_%s" % [event_id, base]
		node.position = pos
		add_child(node)
		_spawned.append({"eventId": event_id, "node": node, "actor": actor, "pos": pos, "placeholder": node.get_meta("placeholder", false)})
		print("dungeon_event_director:   spawned actor '%s' at %s%s" % [
			actor, str(pos), "  (placeholder — GLB not exported)" if node.get_meta("placeholder", false) else ""])

## Resolve an actor base name to a Node3D: the exported GLB if present, else a visible placeholder.
func _resolve_actor_node(base: String) -> Node3D:
	var glb := GEDIT + base + "/" + base + ".glb"
	if ResourceLoader.exists(glb):
		var ps := load(glb) as PackedScene
		if ps:
			var inst := ps.instantiate() as Node3D
			inst.set_meta("placeholder", false)
			return inst
	# placeholder: a bright capsule + glow so the spawn reads on screen (event actor not yet GLB-exported).
	var root := Node3D.new()
	root.set_meta("placeholder", true)
	var mesh := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 8.0
	capsule.height = 36.0
	mesh.mesh = capsule
	mesh.position = Vector3(0, 18, 0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.25, 0.85)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.2, 0.8)
	mat.emission_energy_multiplier = 2.0
	mesh.material_override = mat
	root.add_child(mesh)
	var glow := OmniLight3D.new()
	glow.light_color = Color(1.0, 0.4, 0.9)
	glow.light_energy = 4.0
	glow.omni_range = 70.0
	glow.position = Vector3(0, 18, 0)
	root.add_child(glow)
	return root

# =====================================================================================================
# Accessors (probes / the run owner)
# =====================================================================================================

func event_for(event_id: int) -> Dictionary:
	return _by_event.get(event_id, {})

func event_ids() -> Array:
	return _by_event.keys()

func spawned() -> Array:
	return _spawned

func manifest() -> Dictionary:
	return _manifest
