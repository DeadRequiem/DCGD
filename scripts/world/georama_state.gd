extends Node
## D3.5 — session-level georama / town-rebuild state (the Atla -> town meta-loop bridge).
##
## This autoload is the runtime analogue of the decomp's CSaveData Atra fields + CEditGround/CEditPartsInfo
## placement records. game_root frees and reloads each area scene on every warp, so per-scene state would be
## lost between dungeon and town; this node lives ABOVE the swapped levels and therefore SURVIVES the
## dungeon->town return and any subsequent area changes within a play session.
##
## It owns three things:
##   1. carried_atla        — Atla collected in the dungeon and brought back, not yet placed. This is the
##                            town-side mirror of DungeonRun.atla_list once a run ends (the getAtraToSaveData
##                            bridge in the decomp: dungeon collect -> CSaveData inventory).
##   2. placements[town_id] — the parts the player has PLACED on a given town's grid this session:
##                            { cell -> {atla_id, part_id, name} }. The town remembers what was built (the
##                            placement IS the save state, per the decomp; georama_grid restores from this on load).
##   3. rebuild_pending     — true right after a dungeon return so the loaded town auto-enters Rebuild Mode.
##
## DEFERRED (honest scope): real save-file serialisation (this is session-only, lost on quit), the +5-to-required
## AtraPartsGet quantity accounting, the Parts-vs-Chip bucket split, and per-resident request/completion gating
## (docs/systems/atla-georama.md §4). D3.5 closes the COLLECT -> RETURN -> PLACE -> VISIBLE loop; the request
## meta-gate is a later slice.

## Atla id -> georama part identity. Grounded in docs/systems/atla-georama.md §3.4 (the Norune e01 cfg part
## catalog, type ids 0..16) and dungeon_run.gd's NORUNE resident stand-ins. `mesh` is the .pts-derived GLB id
## under assets/maps/gedit/<town>/ when one is extracted; only e01h06 (Ornet's house) is currently exported,
## so everything else falls back to a placeholder actor (the brief explicitly accepts this). `npc` is the
## resident stand-in name shown on placement (per-NPC dialog is deferred -> a generic greeting).
const PART_CATALOG := {
	0:  {"name": "Toan's House",      "mesh": "e01h01", "npc": "Toan",   "kind": "building"},
	1:  {"name": "Macho's House",     "mesh": "e01h02", "npc": "Macho",  "kind": "building"},
	2:  {"name": "Lola's House",      "mesh": "e01h03", "npc": "Lola",   "kind": "building"},
	3:  {"name": "Paige's House",     "mesh": "e01h10", "npc": "Paige",  "kind": "building"},
	4:  {"name": "Claude's House",    "mesh": "e01h04", "npc": "Claude", "kind": "building"},
	5:  {"name": "Obaba's House",     "mesh": "e01h11", "npc": "Obaba",  "kind": "building"},
	6:  {"name": "Ornet's House",     "mesh": "e01h06", "npc": "Ornet",  "kind": "building"},
	7:  {"name": "Old Man's Wagon",   "mesh": "e01h09", "npc": "Gaffer", "kind": "building"},
	8:  {"name": "Dran Windmill",     "mesh": "e01h07", "npc": "Rando",  "kind": "building"},
	9:  {"name": "Small Windmill",    "mesh": "e01h08", "npc": "",       "kind": "object"},
	10: {"name": "Small Windmill",    "mesh": "e01h08", "npc": "",       "kind": "object"},
	11: {"name": "Small Windmill",    "mesh": "e01h08", "npc": "",       "kind": "object"},
	12: {"name": "Pond",              "mesh": "e01m01", "npc": "",       "kind": "object"},
	13: {"name": "Tree",              "mesh": "e01t01", "npc": "",       "kind": "object"},
	16: {"name": "Komari",            "mesh": "",       "npc": "Komari", "kind": "person"},
	17: {"name": "Erika",             "mesh": "",       "npc": "Erika",  "kind": "person"},
}

## Atla brought back from the dungeon, awaiting placement. Each entry mirrors DungeonRun.atla_list:
## {id:int, floor:int, name:String}. Cleared as they get placed (moved into `placements`).
var carried_atla: Array = []

## town_id -> { cell_index:int -> {atla_id:int, part_id:int, name:String} }. The placed-part record per town.
var placements: Dictionary = {}

## Set true by the dungeon-return flow; georama_grid / the town reads + clears it to auto-open Rebuild Mode.
var rebuild_pending: bool = false

signal atla_placed(town_id: String, cell: int, atla_id: int, part_name: String)

func _ready() -> void:
	# autoload — nothing to do at boot; state accrues as the player collects + returns.
	pass

# =====================================================================================================
# Dungeon -> town bridge (getAtraToSaveData analogue)
# =====================================================================================================

## Pull a finished dungeon run's atla_list into the carried inventory and flag the town to open Rebuild Mode.
## Called by the return-to-town flow when a run ends with collected Atla.
func bring_back(atla_list: Array) -> int:
	for a in atla_list:
		carried_atla.append({
			"id": int(a.get("id", 0)),
			"floor": int(a.get("floor", 0)),
			"name": String(a.get("name", "")),
		})
	rebuild_pending = carried_atla.size() > 0
	print("georama_state: brought back %d Atla (carried now %d) -> rebuild_pending=%s" % [
		atla_list.size(), carried_atla.size(), str(rebuild_pending)])
	return carried_atla.size()

# =====================================================================================================
# Placement bookkeeping (the town side — georama_grid drives the actual spawn; this is the record)
# =====================================================================================================

## Record that `atla` (a carried-list entry) was placed on `town_id` at `cell`. Removes it from carried_atla,
## resolves its part identity from the catalog, and stores the placement. Returns the placement record.
func record_placement(town_id: String, cell: int, atla: Dictionary) -> Dictionary:
	var atla_id := int(atla.get("id", 0))
	var info := part_info(atla_id)
	var rec := {
		"atla_id": atla_id,
		"part_id": atla_id,
		"name": String(info.get("name", atla.get("name", "Atla %d" % atla_id))),
	}
	if not placements.has(town_id):
		placements[town_id] = {}
	placements[town_id][cell] = rec
	# remove the first carried entry matching this Atla id
	for i in carried_atla.size():
		if int(carried_atla[i].get("id", -1)) == atla_id:
			carried_atla.remove_at(i)
			break
	if carried_atla.is_empty():
		rebuild_pending = false
	atla_placed.emit(town_id, cell, atla_id, rec["name"])
	print("georama_state: placed Atla id=%d ('%s') on %s cell %d — carried now %d" % [
		atla_id, rec["name"], town_id, cell, carried_atla.size()])
	return rec

## The placements recorded for a town (cell -> record). Empty dict if none.
func placements_for(town_id: String) -> Dictionary:
	return placements.get(town_id, {})

## Is a cell already occupied by a session placement?
func is_placed(town_id: String, cell: int) -> bool:
	return placements_for(town_id).has(cell)

# =====================================================================================================
# Catalog lookup
# =====================================================================================================

## Part identity for an Atla id (name / mesh / npc / kind). Falls back to a generic person record so an
## unknown id still places a visible marker rather than failing.
func part_info(atla_id: int) -> Dictionary:
	if PART_CATALOG.has(atla_id):
		return PART_CATALOG[atla_id]
	return {"name": "Atla %d" % atla_id, "mesh": "", "npc": "Resident", "kind": "person"}

## Test/verification convenience: wipe all session state.
func reset() -> void:
	carried_atla.clear()
	placements.clear()
	rebuild_pending = false
