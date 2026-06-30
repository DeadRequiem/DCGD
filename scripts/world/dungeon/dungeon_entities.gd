class_name DungeonEntities
extends RefCounted
## DC1 Dungeon — D3.1 entity placement (the faithful `buildEventData` port).
##
## After a floor LAYOUT is generated (DungeonGenerator / buildRandomMap), the decomp driver calls
## `buildEventData(dunIdx, floor, mode, hasAtla)` @0x1C8540 to populate the floor with the LOOT/REWARD
## layer: treasure chests, a guaranteed key chest, trap circles, and — on Atla-bearing floors — the sealed
## townsfolk (Atla). This class re-implements that placement DETERMINISTICALLY from the floor seed, so the
## same (dunIdx, floor, seed) always yields the same chest/Atla cells (and different seeds vary).
##
## Decomp grounding (buildEventData.txt disassembly):
##   - chest count   = rand0(4) + 1   (lui 0x4080 = 4.0; +1)  -> 1..4 treasure chests
##   - guaranteed key chest: itemNo 0xE9 (first) / 0xEA (second) — a special/key chest after the loop
##   - up to 3 trap circles (rand0(100) < 21 gate each) — placed-flag only (D3.x combat owns the runtime)
##   - Atla: count from BtAtraFloorCyoice(dunIdx,floor) reading AtraFloorPtrTbl @0x279E00. The per-dungeon
##     Atla-bearing FLOOR lists are baked below (verbatim ELF .rodata @0x279D90). On a listed floor we place
##     ONE Atla (the deterministic D3.1 choice; the save-state-dependent count is D3.5's georama meta-loop).
##   - every entity is placed via SearchiDoPutArea (a valid-floor-cell picker) and rejected if it collides
##     with an already-placed entity inside a spacing radius (CheckTreasureBox/CheckAtra/CheckTrapCircle, 20u).
##
## SearchiDoPutArea (@0x1C03C0) itself reads per-tile authored "iDoPutArea" sub-rectangles that are NOT in
## our extracted tileset JSON (the spec flags it "not disassembled / room-interior weighted"). We honor the
## INTENT: pick from walkable floor cells, weighted toward plain room interiors, with the spacing rejection.
## Item-id resolution (PresetSmallItemNo_Get) is a deterministic stand-in here — the real per-dungeon
## item-rate tables / event.stb pool are D3.2 (the spec says place from buildEventData's own pool for now).

# --- cell flag bits (mirror DungeonGenerator) ---
const F_ROOM := 0x01
const F_CORR := 0x02
const F_DOOR := 0x04
const F_OBJ := 0x08
const F_DIVID := 0x10
const F_DIVID_DOOR := 0x20
const F_MARKER := 0x40
const F_STAIR_UP := 0x80
const F_STAIR_DOWN := 0x100
const F_PORTAL := 0x200

const CELL_PITCH := 162.0          # world units per grid cell (matches dungeon_floor_gen.gd)
const SPACING := 1.5               # min cell-distance between two placed entities (the 20u Check* radius,
								   # ~1.5 cells at the 162u pitch — keeps chests/Atla from overlapping)

# Special chest item ids (decomp: 0xE9/0xEA guaranteed key/special chest).
const ITEM_KEY_A := 0xE9           # 233 — gate/key chest (first)
const ITEM_KEY_B := 0xEA           # 234 — gate/key chest (second)

# AtraFloorPtrTbl @0x279E00 -> per-dungeon Atla-bearing floor lists (verbatim ELF .rodata @0x279D90,
# -1 terminated). d01={4,8,11}, d02={4,9,12}, d03={5,9,12}, d04={5,9,13}, d05={4,8,11}, d06={19..23}.
const ATRA_FLOORS := [
	[4, 8, 11],
	[4, 9, 12],
	[5, 9, 12],
	[5, 9, 13],
	[4, 8, 11],
	[19, 20, 21, 22, 23],
]

# ---- the SAME newlib LCG as DungeonGenerator (so placement is reproducible per seed) ----
var _seed: int = 0

func _srand(s: int) -> void:
	_seed = s & 0xFFFFFFFF

func _rand() -> int:
	_seed = (_seed * 0x41C64E6D + 0x3039) & 0xFFFFFFFF
	return _seed & 0x7FFFFFFF

func _rand0(n: int) -> int:
	if n <= 0:
		return 0
	return int(float(_rand()) * float(n) / 2147483648.0)

# =====================================================================================================
# Public API
# =====================================================================================================

## Whether `floor` (1-based) is an Atla-bearing floor for `dun_idx` (0..5).
static func is_atla_floor(dun_idx: int, floor: int) -> bool:
	if dun_idx < 0 or dun_idx >= ATRA_FLOORS.size():
		return false
	return floor in ATRA_FLOORS[dun_idx]

## How many Atla this floor carries (D3.1: 1 on a listed floor, else 0 — the save-state count is D3.5).
static func atla_count_for(dun_idx: int, floor: int) -> int:
	return 1 if is_atla_floor(dun_idx, floor) else 0

## Place the loot/reward layer onto a generated LAYOUT. Returns:
##   { chests:[{cell:Vector2i, item:int, kind:"normal"/"key"}], atla:[{cell:Vector2i, id:int}],
##     traps:[Vector2i], seed:int }
## Deterministic: same (layout.seed, dunIdx, floor) -> same result. The placement seed is DERIVED from the
## floor's generation seed so chests don't share the layout RNG stream (they're a distinct buildEventData
## pass, but reproducible).
func place(layout: Dictionary) -> Dictionary:
	var dun_idx := int(layout.get("dunIdx", 0))
	var floor := int(layout.get("floor", 1))
	var gen_seed := int(layout.get("seed", 0))

	# A distinct-but-deterministic stream for the event pass (the real engine re-uses the live rand() state
	# after buildRandomMap; we derive one so the layout RNG and the loot RNG don't entangle across versions).
	_srand((gen_seed * 0x6C078965 + 0x1F123BB5 + floor) & 0xFFFFFFFF)

	var floor_cells := _collect_floor_cells(layout)   # room-interior-weighted valid cells
	var placed: Array[Vector2i] = []                  # for spacing rejection (CheckTreasureBox/CheckAtra)

	var chests: Array = []
	# --- treasure chests: rand0(4)+1 normal chests ---
	var n_chests := _rand0(4) + 1
	for _i in range(n_chests):
		var cell := _pick_cell(floor_cells, placed)
		if cell.x < 0:
			break
		placed.append(cell)
		chests.append({"cell": cell, "item": _preset_item(dun_idx, floor), "kind": "normal"})
	# --- one guaranteed key/special chest (itemNo 0xE9/0xEA) ---
	var key_cell := _pick_cell(floor_cells, placed)
	if key_cell.x >= 0:
		placed.append(key_cell)
		var key_item := ITEM_KEY_A if chests.is_empty() else ITEM_KEY_B
		chests.append({"cell": key_cell, "item": key_item, "kind": "key"})

	# --- trap circles: up to 3, each gated rand0(100) < 21 (decomp slti 0x15) ---
	var traps: Array = []
	for _t in range(3):
		if _rand0(100) >= 21:
			continue
		var tc := _pick_cell(floor_cells, placed)
		if tc.x < 0:
			break
		placed.append(tc)
		traps.append(tc)

	# --- Atla on Atla-bearing floors ---
	var atla: Array = []
	var n_atla := atla_count_for(dun_idx, floor)
	for _a in range(n_atla):
		var ac := _pick_cell(floor_cells, placed)
		if ac.x < 0:
			break
		placed.append(ac)
		# atla id: stable per (dunIdx, floor) so a townsfolk maps to a floor (D3.5 will key the georama meta).
		atla.append({"cell": ac, "id": _atla_id(dun_idx, floor, atla.size())})

	return {"chests": chests, "atla": atla, "traps": traps, "seed": gen_seed}

# =====================================================================================================
# SearchiDoPutArea stand-in — valid-floor-cell picker, room-interior weighted, spacing-rejected
# =====================================================================================================

## Build the candidate pool: walkable floor cells, weighted toward PLAIN room interiors (the decomp's
## iDoPutArea favours room floor over corridors). We add room-interior cells 3x so the weighted random
## draw prefers them, while corridors stay eligible (some chests do sit in corridors).
func _collect_floor_cells(layout: Dictionary) -> Array:
	var pool: Array = []
	for c in layout.get("cells", []):
		var f := int(c.get("flags", 0))
		var cell := Vector2i(int(c.x), int(c.y))
		# exclude stairs, the entry portal, divider walls, object/pillar slots, and divider doors —
		# you can't drop a chest on a stair or inside a wall.
		if f & (F_STAIR_UP | F_STAIR_DOWN | F_PORTAL | F_DIVID | F_DIVID_DOOR | F_OBJ):
			continue
		var is_room := (f & F_ROOM) and not (f & F_DOOR)
		var is_corr := (f & F_CORR) and not (f & F_ROOM)
		if is_room:
			# plain room interior — weight x3 (room-interior preference)
			pool.append(cell)
			pool.append(cell)
			pool.append(cell)
		elif is_corr:
			pool.append(cell)
	return pool

## Pick a valid cell from the pool, rejecting any within SPACING of an already-placed entity (the decomp's
## CheckTreasureBox/CheckAtra/CheckTrapCircle 20u rejection). Up to 64 tries, like the engine's retry loop.
## Returns (-1,-1) if no valid cell remains.
func _pick_cell(pool: Array, placed: Array) -> Vector2i:
	if pool.is_empty():
		return Vector2i(-1, -1)
	for _try in range(64):
		var cell: Vector2i = pool[_rand0(pool.size())]
		var ok := true
		for p in placed:
			var dx := float(cell.x - p.x)
			var dy := float(cell.y - p.y)
			if dx * dx + dy * dy < SPACING * SPACING:
				ok = false
				break
		if ok:
			return cell
	return Vector2i(-1, -1)

# =====================================================================================================
# Item / Atla id stand-ins (deterministic — real tables are D3.2 / the save-state meta is D3.5)
# =====================================================================================================

## PresetSmallItemNo_Get stand-in: a deterministic item id from the floor pool. The real per-dungeon
## ItemSetRateTbl @0x279D30 + event.stb pool is D3.2; we draw a stable id in a plausible small-item range.
func _preset_item(dun_idx: int, floor: int) -> int:
	# 0x20..0x6F is a plausible consumable/material band; deterministic via the event RNG stream.
	return 0x20 + _rand0(0x50)

func _atla_id(dun_idx: int, floor: int, slot: int) -> int:
	# stable id per (dunIdx, floor, slot) — D3.5 maps these to specific sealed townsfolk via save data.
	return dun_idx * 100 + floor * 4 + slot
