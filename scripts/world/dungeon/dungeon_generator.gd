class_name DungeonGenerator
extends RefCounted
## DC1 Dungeon — D1 procedural floor generator (runtime).
##
## Faithful re-implementation of the PS2 decomp `CDungeonMap::buildRandomMap` (@0x1CB670) and its
## helpers (buildRoom/joinRoom/setRoomObject/setRoomDivid/setUnderDungeonStart/setStair/mapPartsFilter).
## Given a dungeon index + floor number + seed it produces a LAYOUT: a 20x20 grid of resolved catalog
## part-ids (the cfg `no##`) + rotations, plus the room table, the stair-up/stair-down markers, and the
## decoration flags. The assembler (dungeon_floor.gd) turns that grid into a walkable scene.
##
## Re-randomized every entry, exactly like the original (the floor-transition state machine calls
## buildRandomMap with hasSeed=1 each descent). Pure integer/float math; no engine deps.
##
## Spec + addresses: docs/progress/dungeon-deep-dive.md, docs/formats/dungeons.md. The chain tables and
## per-dungeon parameter tables below are dumped verbatim from the SCUS_971.11 ELF .rodata.

# --- grid ---
const GRID := 20                          # 0x14, the universal bound (20x20 cells)
const ROOM_CAP := 6                       # the driver always passes roomCap=6

# --- abstract cell partID placeholders written by the helpers BEFORE mapPartsFilter resolves them ---
const P_EMPTY := -1
const P_ROOM := 0x11                       # 17, generic room-floor placeholder (buildRoom)
const P_ENTRY := 0x24                      # 36, up-stair / floor-entry seed (setUnderDungeonStart)
const P_STAIR_UP := 0x80                   # 128, up-stair dead-end (setStair pass 1)
const P_STAIR_DOWN := 0x100                # 256, down-stair dead-end / out_2 (setStair pass 2)

# --- flag bits (cell +0x48) ---
const F_ROOM := 0x01                       # room/floor interior
const F_CORR := 0x02                       # corridor-connected (dead-end-able)
const F_DOOR := 0x04                       # corridor-carved / door punched through a wall
const F_OBJ := 0x08                        # object/pillar slot (setRoomObject)
const F_DIVID := 0x10                      # divider wall (setRoomDivid)
const F_DIVID_DOOR := 0x20                 # door gap in a divider wall
const F_MARKER := 0x40                     # special marker slot (chest/Atla/NPC eligible)
const F_STAIR_UP := 0x80                   # up-stair marker
const F_STAIR_DOWN := 0x100                # down-stair marker (out_2)
const F_PORTAL := 0x200                    # ura back-portal marker

# --- direction codes (joinRoom): 1=+Y south, 2=-X west, 4=+X east, 8=-Y north ---

# === chain tables (verbatim from ELF .rodata; triplets {contextKey, resolvedPartID, rot}) ===
# context bit layout: N=0x1, E=0x2, W=0x4, S=0x8.  partID indexes the cfg DEF_PATS catalog (no##).
const CHAIN_ROAD := [   # 0x279EE0, 15 entries — corridor straight/corner/T/cross pieces
	[6,0,0],[9,0,1],[5,1,0],[3,1,1],[10,1,2],[12,1,3],
	[0,2,0],[1,3,0],[2,3,1],[8,3,2],[4,3,3],
	[7,4,0],[11,4,1],[14,4,2],[13,4,3],
]
const CHAIN_ROOM := [   # 0x279FA0, 8 entries — room-floor edge/corner variants
	[1,5,0],[2,6,0],[8,7,0],[4,8,0],[5,13,0],[3,14,0],[10,15,0],[12,16,0],
]
const CHAIN_DOOR := [   # 0x279EB0, 4 entries — doorway pieces (room-with-door no09..no12)
	[14,9,0],[13,10,0],[7,11,0],[11,12,0],
]
const CHAIN_DIVID := [  # 0x27A000, 6 entries — subdivision wall pieces
	[232,18,0],[212,19,0],[113,20,0],[178,21,0],[249,26,0],[246,27,0],
]
const CHAIN_DIVID_DOOR := [ # 0x27A050, 2 entries — door gap in a subdivision wall
	[9,22,0],[6,23,0],
]

# === per-dungeon parameter tables (ELF .rodata, indexed by dungeon 0..5 = d01..d06) ===
const MAX_FLOOR := [15, 17, 18, 18, 15, 25]     # MaxFloorTbl @0x279E40
const BGM_ID := [0xC3, 0xC9, 0xCA, 0xCB, 0xCC, 0xCE]  # floor BGM id jump table
# noEntryTbl (forbidden part-ids per dungeon, -1 terminated); d01 = {4,8,11}. mapPartsFilter result
# is rerolled away from these by the engine's load step; we keep them for parity / future use.
const NO_ENTRY := [[4, 8, 11], [], [], [], [4, 9], []]

# ---- LCG RNG: newlib-style. rand() returns a 31-bit value; seed*0x41C64E6D+0x3039, masked 0x7FFFFFFF. ----
var _seed: int = 0

func _srand(s: int) -> void:
	_seed = s & 0xFFFFFFFF

func _rand() -> int:
	# 64-bit-safe LCG (GDScript ints are 64-bit). Keep the low 32 bits of state, return 31-bit value.
	_seed = (_seed * 0x41C64E6D + 0x3039) & 0xFFFFFFFF
	return _seed & 0x7FFFFFFF

# round a double to its 32-bit float value. The R5900 FPU is single-precision; rand() (up to ~2.1e9) loses its
# low ~7 bits when cast to float32, and the subsequent mul/div round again — doing this in Godot's 64-bit double
# diverges at the truncation boundary, which desyncs the entire RNG-driven scatter from the binary.
func _f32(v: float) -> float:
	return PackedFloat32Array([v])[0]

# the universal "random int in [0,N)" idiom: (int)(rand() * (float)N / 2147483648.0) — in SINGLE precision.
func _rand0(n: int) -> int:
	if n <= 0:
		return 0
	var r := _f32(float(_rand()))
	var prod := _f32(r * _f32(float(n)))
	return int(_f32(prod / 2147483648.0))

# ---- cell storage: flat arrays, index = x + y*GRID ----
var _part: PackedInt32Array      # partID
var _rot: PackedInt32Array       # rotation 0..3
var _doors: Array                # per-cell doors[16] (PackedInt32Array each) — joinRoom tags by room id
var _flags: PackedInt32Array     # the cell bitfield
# scratch copies for joinRoom try/rollback
var _wpart: PackedInt32Array
var _wrot: PackedInt32Array
var _wdoors: Array
var _wflags: PackedInt32Array

var _rooms: Array                # room table: {x,y,w,h}; up to 16 (roomStack)
var _room_num: int = 0

# results
var stair_up := Vector2i(-1, -1)
var stair_down := Vector2i(-1, -1)
var entry := Vector2i(-1, -1)    # setUnderDungeonStart spawn cell

func _idx(x: int, y: int) -> int:
	return x + y * GRID

func _in_bounds(x: int, y: int) -> bool:
	return x >= 0 and x < GRID and y >= 0 and y < GRID

# =====================================================================================================
# Public API
# =====================================================================================================

## Generate a floor. dun_idx 0..5 = d01..d06. Returns a Dictionary layout:
##   { grid:20, rooms:[{x,y,w,h}], cells:[{x,y,part,rot,flags}], stairUp:Vector2i, stairDown:Vector2i,
##     entry:Vector2i, seed:int, dunIdx, floor, roomCount, corridorCount, bgm }
func generate(dun_idx: int, floor: int, seed: int, room_cap := ROOM_CAP) -> Dictionary:
	# Seed exactly like the decomp: srand(seed); then srand((int)(rand()/100000)) and stash the derived seed.
	_srand(seed)
	var derived := int(_f32(_f32(float(_rand())) / 100000.0))
	_srand(derived)
	var used_seed := derived

	_alloc()
	_room_num = 0

	# ---- PHASE 1: scatter (decomp 0x1CB8EC). Per-room retry with the attempt counter RESETTING each room:
	# Phase A places the first 2 rooms (≤64 tries each); Phase B fills up to room_cap (≤512 tries each). This —
	# NOT two fixed total-attempt passes — is what keeps the RNG stream aligned with the game's room placement
	# (a failed attempt consumes 4 rand0; the game retries the SAME room, so the budget must reset per room). ----
	_scatter_phase(mini(2, room_cap), 0x40)
	_scatter_phase(room_cap, 0x200)
	# Phase A in the decomp (0x1CBAD0) issues joinRoom(0,1) UNCONDITIONALLY once two rooms exist — from=0,to=1
	# (the carve direction depends on from/to, so order matters). Phase B joins each LATER room to its nearest
	# predecessor. (The old `if _room_num < 2` guard was the inverted condition — it could never link two rooms.)
	if _room_num >= 2:
		_join_room(0, 1)

	# ---- PHASE 2: greedy nearest-PREDECESSOR spanning tree. Metric = int(sqrt(dCx²+dCz²)) between room CENTRES,
	# strict `<`, first-wins on ties (decomp 0x1CBD3C: litodp->sqrt->dptoli, NOT raw squared distance). ----
	for i in range(2, _room_num):
		var best_j := -1
		var best_d := 0x7FFFFFFF
		var ci := _room_center(i)
		for j in range(0, i):
			var cj := _room_center(j)
			var dx := ci.x - cj.x
			var dy := ci.y - cj.y
			var d := int(sqrt(float(dx * dx + dy * dy)))
			if d < best_d:
				best_d = d
				best_j = j
		if best_j >= 0:
			_join_room(i, best_j)

	# ---- PHASE 3: decorate + stairs ----
	_set_room_object()
	_set_room_divid()                  # hasSeed always 1 for the driver
	_set_under_dungeon_start()         # entry / up-stair spawn
	_set_stair()                       # up-stair + down-stair dead-ends (out_2)

	# ---- resolve abstract cells -> concrete catalog {partID, rot} (autotile) ----
	_map_parts_filter()

	return _emit(dun_idx, floor, used_seed)

# =====================================================================================================
# PHASE 1 — room scatter (buildRoom)
# =====================================================================================================

## Scatter rooms up to `target` count, each with up to `max_tries` placement attempts — and the attempt counter
## RESETS per room (decomp 0x1CB8EC). Stops early if a room can't be placed within max_tries. Per attempt the
## four draws are w,h,x,y in that fixed order (4 rand0 each), matching the game's RNG ledger.
func _scatter_phase(target: int, max_tries: int) -> void:
	while _room_num < target:
		var placed := false
		for _t in range(max_tries):
			var w := 3 + _rand0(2)         # w in {3,4} (0x4000 = 2.0 multiplier)
			var h := 3 + _rand0(2)
			var x := _rand0(16 - w)
			var y := _rand0(16 - h)
			if _build_room(x, y, w, h, _room_num) == 1:
				_rooms[_room_num] = {"x": x, "y": y, "w": w, "h": h}
				_room_num += 1
				placed = true
				break
		if not placed:
			return

## buildRoom: collision-test the (w+2)x(h+2) footprint (1-cell margin); on success stamp the wxh interior.
func _build_room(x: int, y: int, w: int, h: int, room_id: int) -> int:
	# clearance test: scan [x-1 .. x+w+1] × [y-1 .. y+h+1] — the footprint + a 1-cell border, BUT the decomp loop
	# bounds are w+2 / h+2 (i in [-1 .. w+1]), so the window reaches x+w+1 / y+h+1 (an ASYMMETRIC 2-cell right/
	# bottom margin). Empirically (02-scatter §1.1) a room x=3,w=4 reads cols 2..8 = x-1..x+w+1. Fail on any
	# non-empty cell. (The old `< x+w+1` bound was one column short -> rooms sat closer than the game's -> the
	# whole scatter desynced from the binary.)
	var yy := y - 1
	while yy < y + h + 2:
		var xx := x - 1
		while xx < x + w + 2:
			if _in_bounds(xx, yy):
				if _part[_idx(xx, yy)] != P_EMPTY:
					return 0
			xx += 1
		yy += 1
	# stamp interior
	yy = y
	while yy < y + h:
		var xx2 := x
		while xx2 < x + w:
			var i := _idx(xx2, yy)
			_part[i] = P_ROOM
			_door_set(_doors, i, room_id)
			_flags[i] |= F_ROOM
			xx2 += 1
		yy += 1
	return 1

func _room_center(r: int) -> Vector2i:
	var rm: Dictionary = _rooms[r]
	return Vector2i(rm.x + int(rm.w / 2.0), rm.y + int(rm.h / 2.0))

# =====================================================================================================
# PHASE 2 — joinRoom (L-shaped corridor with try/rollback)
# =====================================================================================================

## joinRoom(from, to): carve a 1-wide L/Z corridor on a WORK copy — edge-of-FROM to centre-of-TO — and commit
## only on success. Faithful to joinRoom @0x1C61C0 (docs/decomp/16-VERIFY-join-carve.md — byte-exact + traced):
##   - dominant axis from dZ² < dX² (ties -> vertical); the direction picks the from-edge cell + outward step
##   - a from-edge DOOR on the from-room edge cell at the from-room centre line
##   - leg-1 = bend (= gap/2 + 1) cells OUTWARD along the dominant axis (laid only on empty cells)
##   - leg-2 = perpendicular toward the to-room perpendicular-centre; leg-3 = dominant toward the to-room centre
##   - EMPTY-ONLY laying; STOP each walk on the first occupied cell (room -> ONE door; corridor -> link only)
## Replaces the old centre-to-centre Manhattan walk that NEVER stopped on contact and punched a door through
## every room cell it crossed — the over-connection that made the autotile read every corridor as a junction.
func _join_room(a: int, b: int) -> void:
	if a >= _room_num or b >= _room_num:
		return
	_copy_to_work()
	var rf: Dictionary = _rooms[a]
	var rt: Dictionary = _rooms[b]
	var fx := int(rf.x)
	var fz := int(rf.y)
	var fw := int(rf.w)
	var fh := int(rf.h)
	var tx := int(rt.x)
	var tz := int(rt.y)
	var tw := int(rt.w)
	var th := int(rt.h)
	var d_x := fx - tx
	var d_z := fz - tz
	var cx_f := fx + int(fw / 2.0)
	var cz_f := fz + int(fh / 2.0)
	var mid_col := tx + int(tw / 2.0)
	var mid_row := tz + int(th / 2.0)

	# direction -> from-edge cell (col,row), outward dominant step, and the inter-room gap on the dominant axis
	var col := cx_f
	var row := cz_f
	var leg1 := 0
	var dom_x := (d_z * d_z < d_x * d_x)   # horizontal-dominant when |dX|>|dZ| (strict; ties -> vertical)
	var dstep := 0
	if dom_x:
		if d_x >= 0:                        # from-RIGHT of to: outward -X, from-edge = left interior column
			col = fx
			row = cz_f
			leg1 = fx - (tx + tw)
			dstep = -1
		else:                               # from-LEFT of to: outward +X, from-edge = right interior column
			col = fx + fw - 1
			row = cz_f
			leg1 = tx - (fx + fw)
			dstep = 1
	else:
		if d_z >= 0:                        # from-BELOW to: outward -Z, from-edge = top row
			col = cx_f
			row = fz
			leg1 = fz - (tz + th)
			dstep = -1
		else:                               # from-ABOVE to: outward +Z, from-edge = bottom row
			col = cx_f
			row = fz + fh - 1
			leg1 = tz - (fz + fh)
			dstep = 1

	# from-edge DOOR on the from-room edge cell at its centre line
	if _in_bounds(col, row):
		var di := _idx(col, row)
		_wflags[di] |= F_DOOR
		_door_set(_wdoors, di, a)

	var bend := int(leg1 / 2.0) + 1
	var success := false

	# leg-1: `bend` cells outward along the dominant axis (lay on empty only; no doors, no stop)
	for _i in range(maxi(bend, 0)):
		if dom_x:
			col += dstep
		else:
			row += dstep
		if _in_bounds(col, row):
			var li := _idx(col, row)
			if _wpart[li] == P_EMPTY:
				_wpart[li] = a
				_door_set(_wdoors, li, a)
				_wflags[li] |= F_CORR

	# leg-2: perpendicular axis toward the to-room perpendicular-centre (stop on contact)
	if dom_x:
		var s2 := 1 if mid_row >= row else -1
		while row != mid_row:
			row += s2
			if _carve_cell(col, row, a):
				success = true
				break
	else:
		var s2 := 1 if mid_col >= col else -1
		while col != mid_col:
			col += s2
			if _carve_cell(col, row, a):
				success = true
				break

	# leg-3: dominant axis toward the to-room centre (lands the door on the to-room edge)
	if dom_x:
		var s3 := 1 if mid_col >= col else -1
		while col != mid_col:
			col += s3
			if _carve_cell(col, row, a):
				success = true
				break
	else:
		var s3 := 1 if mid_row >= row else -1
		while row != mid_row:
			row += s3
			if _carve_cell(col, row, a):
				success = true
				break

	if success:
		_commit_work()

## One work cell on a carve walk. EMPTY -> lay corridor (partID=from, doors[from]=1, flags|=CORR), return false
## (keep walking). OCCUPIED -> contact: a ROOM cell gets ONE door (flags|=DOOR); a corridor gets only the
## doors[] link; return true so the caller STOPS this leg (no plow-through). Decomp 0x1C67B8 / 0x1C6800.
func _carve_cell(x: int, y: int, room_id: int) -> bool:
	if not _in_bounds(x, y):
		return true
	var i := _idx(x, y)
	if _wpart[i] == P_EMPTY:
		_wpart[i] = room_id
		_door_set(_wdoors, i, room_id)
		_wflags[i] |= F_CORR
		return false
	if _wflags[i] & F_ROOM:
		_wflags[i] |= F_DOOR
	_door_set(_wdoors, i, room_id)
	return true

# =====================================================================================================
# PHASE 3 — decoration + stairs
# =====================================================================================================

## setRoomObject: per room, up to 2 object slots (30% roll each) on plain interior cells (flags&5==1),
## plus a 30% special-marker slot (flags&0x4D==1).
## setRoomObject @0x1C6A40 — DECOMP-EXACT. The object/pillar cap is GLOBAL across the whole floor (at most 2),
## NOT per-room; the object pass scans ONLY the room's top row (y = rm.y) with a single rand roll (no retry);
## the marker pass scans the full interior, one per room. (The prior port reset the cap per room and retried in a
## while-loop -> up to ~12 object cells/floor; F_OBJ resolves to no32 = the FOUNTAIN tile, so that bug spammed
## fountains = the "multiples of special areas mashed together" symptom.)
func _set_room_object() -> void:
	var obj_count := 0   # GLOBAL: at most 2 object cells across the ENTIRE floor (decomp $20, init once)
	for r in range(_room_num):
		var rm: Dictionary = _rooms[r]
		# --- object pass: only while under the global cap; single scan of row rm.y, one rand roll, LAST match ---
		if obj_count < 2:
			var found := false
			var fx := 0
			var fy: int = int(rm.y)
			for xx in range(1, int(rm.w) - 1):
				var cx: int = int(rm.x) + xx
				if _in_bounds(cx, fy) and (_flags[_idx(cx, fy)] & 0x5) == F_ROOM:
					fx = cx
					found = true
			if _rand0(100) <= 30 and found:
				_flags[_idx(fx, fy)] |= F_OBJ
				obj_count += 1
		# --- special-marker pass: full interior scan, one per room (no global cap) ---
		var mfound := false
		var mx := 0
		var my := 0
		for yy in range(1, int(rm.h) - 1):
			for xx in range(1, int(rm.w) - 1):
				var cx: int = int(rm.x) + xx
				var cy: int = int(rm.y) + yy
				if _in_bounds(cx, cy) and (_flags[_idx(cx, cy)] & 0x4D) == F_ROOM:
					mx = cx
					my = cy
					mfound = true
		if _rand0(100) <= 30 and mfound:
			_flags[_idx(mx, my)] |= F_MARKER

## setRoomDivid: 40% per room, stamp a straight inner wall (flags|=0x10) across a fully-eligible
## row/column with one door gap (flags|=0x20).
func _set_room_divid() -> void:
	for r in range(_room_num):
		var rm: Dictionary = _rooms[r]
		var cands := []   # {line, base, span, orient}
		# horizontal candidates (a full row of eligible cells)
		for col in range(1, int(rm.w) - 1):
			var ok := true
			for row in range(0, int(rm.h)):
				var cx: int = rm.x + col
				var cy: int = rm.y + row
				if not _in_bounds(cx, cy) or (_flags[_idx(cx, cy)] & 0x4D) != F_ROOM:
					ok = false
					break
			if ok:
				cands.append({"col": col, "orient": 0, "span": int(rm.h)})
		# vertical candidates (a full column of eligible cells)
		for row in range(1, int(rm.h) - 1):
			var ok2 := true
			for col2 in range(0, int(rm.w)):
				var cx2: int = rm.x + col2
				var cy2: int = rm.y + row
				if not _in_bounds(cx2, cy2) or (_flags[_idx(cx2, cy2)] & 0x4D) != F_ROOM:
					ok2 = false
					break
			if ok2:
				cands.append({"row": row, "orient": 1, "span": int(rm.w)})
		if cands.is_empty():
			continue
		if _rand0(100) > 40:
			continue
		var pick: Dictionary = cands[_rand0(cands.size())]
		var span: int = pick.span
		if span < 3:
			continue
		var gap := _rand0(span - 2) + 1
		if pick.orient == 0:
			var col: int = pick.col
			for k in range(span):
				var cx: int = rm.x + col
				var cy: int = rm.y + k
				if _in_bounds(cx, cy):
					if k == gap:
						_flags[_idx(cx, cy)] |= F_DIVID_DOOR
					else:
						_flags[_idx(cx, cy)] |= F_DIVID
		else:
			var row: int = pick.row
			for k in range(span):
				var cx2: int = rm.x + k
				var cy2: int = rm.y + row
				if _in_bounds(cx2, cy2):
					if k == gap:
						_flags[_idx(cx2, cy2)] |= F_DIVID_DOOR
					else:
						_flags[_idx(cx2, cy2)] |= F_DIVID

## setUnderDungeonStart: pick a plain room-interior cell (flags&0x15==1) and stamp the entry/up-stair
## seed (partID=0x24, flags|=0x201). The player spawns here on floor entry.
func _set_under_dungeon_start() -> void:
	# DECOMP-EXACT (setUnderDungeonStart @0x1C72A0): collect plain-room cells (flags&0x15==1: room set, door+divider
	# clear), CAPPED at 60 candidates (slti 0x3C @0x7344), then pick one at random whose NORTH is EMPTY and whose EAST
	# and WEST are both rooms (SOUTH is never tested). The portal therefore lands on the NORTH EDGE of a room, where
	# no40's open face (authored facing north at rot 0) points at the empty cell the player emerges onto. (The prior
	# port required N AND S to both be rooms -> it dropped the portal on a room INTERIOR, so no40 overhung room floor
	# and read as "rotated 90 degrees wrong". Verified vs the real generator @0x1C7430/0x746C/0x748C on seeds 1,2,3,7,42.)
	var cands := []
	for y in range(GRID):
		for x in range(GRID):
			if cands.size() >= 0x3C:       # binary caps the candidate list at 60
				break
			if (_flags[_idx(x, y)] & 0x15) == F_ROOM:
				cands.append(Vector2i(x, y))
		if cands.size() >= 0x3C:
			break
	if cands.is_empty():
		entry = Vector2i(1, 1)
		return
	for _t in range(5000):
		var c: Vector2i = cands[_rand0(cands.size())]
		var i := _idx(c.x, c.y)
		# NORTH must be EMPTY (flags==0); the binary reads the raw cleared cell above the top row and passes, so an
		# OOB north counts as empty (the portal can legitimately sit on row 0). EAST and WEST must each be a room
		# (flags&5==1: room set, door clear). SOUTH is never tested.
		var ok_n := (not _in_bounds(c.x, c.y - 1)) or _flags[_idx(c.x, c.y - 1)] == 0
		var ok_e := _in_bounds(c.x + 1, c.y) and (_flags[_idx(c.x + 1, c.y)] & 0x5) == F_ROOM
		var ok_w := _in_bounds(c.x - 1, c.y) and (_flags[_idx(c.x - 1, c.y)] & 0x5) == F_ROOM
		if ok_n and ok_e and ok_w:
			_flags[i] |= F_PORTAL | F_ROOM
			_part[i] = P_ENTRY
			_rot[i] = 0
			entry = c
			return
	entry = cands[0]

## setStair: two passes scanning for dead-end corridor cells (flags&2==2 with an empty neighbour).
## Pass 1 -> up-stair (partID=0x80); pass 2 -> down-stair (partID=0x100, the out_2 warp).
func _set_stair() -> void:
	# DECOMP-EXACT (setStair @0x1C7530): two independent passes. Each scans the grid (y outer, x inner) for a
	# dead-end corridor (flags&0x2) whose FORWARD neighbour — NORTH (y-1) for up, SOUTH (y+1) for down — is
	# totally EMPTY (flags==0), then stamps the EMPTY NEIGHBOUR cell with the stair (the stair EXTENDS the
	# corridor by one cell). The original does NOT exclude pass-1's cell from pass-2; the N-vs-S neighbour split
	# keeps the two stairs on distinct cells even if the same corridor is chosen.
	# (Prior port scanned the X axis (fwd_dx +/-1) and stamped the CORRIDOR cell itself — wrong cell, wrong axis.)
	stair_up = _place_stair(P_STAIR_UP, 0, -1)    # up: forward neighbour = NORTH (y-1)
	stair_down = _place_stair(P_STAIR_DOWN, 2, 1)  # down: forward neighbour = SOUTH (y+1)

func _place_stair(part_id: int, rot: int, fwd_dy: int) -> Vector2i:
	var cands := []
	for y in range(GRID):
		for x in range(GRID):
			if (_flags[_idx(x, y)] & 0x2) != F_CORR:
				continue
			var fy := y + fwd_dy
			# the forward (N/S) neighbour must be in-bounds and totally EMPTY (flags == 0) — a dead-end
			if _in_bounds(x, fy) and _flags[_idx(x, fy)] == 0:
				cands.append(Vector2i(x, y))
	# decomp fallback: no dead-end found -> force corridor cell (1,1)
	var cell: Vector2i = cands[_rand0(cands.size())] if not cands.is_empty() else Vector2i(1, 1)
	# stamp the FORWARD NEIGHBOUR (the empty cell); copy the corridor's partID (mapPartsFilter overrides the
	# render via flags&0x80/0x100 anyway). The stair CELL is the neighbour, so that's what we return/spawn on.
	var ci := _idx(cell.x, cell.y)
	var ny := cell.y + fwd_dy
	var stair_cell: Vector2i = Vector2i(cell.x, ny) if _in_bounds(cell.x, ny) else cell
	var si := _idx(stair_cell.x, stair_cell.y)
	_flags[si] |= part_id
	_part[si] = _part[ci]
	_rot[si] = rot
	# decomp @0x1C7750: neighbour.doors[corridor.partID] = 1 — inherit the corridor's carve-link so the corridor
	# context opens toward the stair (otherwise the stair floats, walled off from the corridor it extends).
	var link: int = _part[ci]
	if link >= 0 and link < 16:
		_door_set(_doors, si, link)
	return stair_cell

# =====================================================================================================
# mapPartsFilter — resolve abstract flags to concrete catalog {partID, rot} via the chain tables
# =====================================================================================================

func _map_parts_filter() -> void:
	for y in range(GRID):
		for x in range(GRID):
			var i := _idx(x, y)
			var f := _flags[i]
			# --- stair / portal markers resolve first (these win over the autotile) ---
			if f & F_STAIR_UP:
				_part[i] = 30          # no30 = in-stairs
				_rot[i] = 0
				continue
			if f & F_STAIR_DOWN:
				_part[i] = 31          # no31 = out-stairs (out_2); KEEP _rot (setStair set it = 2; the
				continue               # game's stair block doesn't overwrite rot — verified vs emulated mapPartsFilter)
			if f & F_PORTAL:
				# DECOMP-EXACT: flags&0x200 -> partID 0x28 = no40 (the 裏マップ出入口 back-portal you emerge from).
				# (The prior port rendered the entry as no30 in-stairs — a DUPLICATE of the real up-stair, = an
				# extra "entrance". mapPartsFilter @0x1C60D8 loads 0x28 for this block.)
				_part[i] = 40
				_rot[i] = 0
				continue
			# --- corridor cells (flags & 2) ---
			if (f & 0x2) == F_CORR:
				var ctx := _road_context(x, y)
				var res: Array = _chain_lookup(CHAIN_ROAD, ctx)
				if not res.is_empty():
					_part[i] = res[0]
					_rot[i] = res[1]
				continue
			# --- room-interior cells (flags & 1) ---
			if (f & 0x1) == F_ROOM:
				# DECOMP-EXACT block order: the game runs room/door/object/marker/divider/divider-door as
				# independent top-level tests with FALL-THROUGH — the LAST block that applies+hits wins (NOT
				# first-match). So the room autotile is the BASE, and door/divider/etc. OVERRIDE only if their
				# chain lookup hits. (The prior first-match+continue dropped a missed-divider/door cell to bare
				# floor 17 instead of keeping the room-edge piece — verified vs emulated mapPartsFilter.)
				var rr: Array = _chain_lookup(CHAIN_ROOM, _room_context(x, y))   # block 2: room edge/corner
				if not rr.is_empty():
					_part[i] = rr[0]
					_rot[i] = rr[1]
				else:
					_part[i] = 0x11        # bare-floor placeholder (no17)
					_rot[i] = 0
				if (f & 0x404) == F_DOOR:                                       # block 3: door overrides if hit
					var rdo: Array = _chain_lookup(CHAIN_DOOR, _door_context(x, y))
					if not rdo.is_empty():
						_part[i] = rdo[0]
						_rot[i] = rdo[1]
				if f & F_OBJ:                                                   # block 4: object slot
					_part[i] = 0x20
					_rot[i] = 0
				if f & F_MARKER:                                                # block 5: pillar no45/no46 (float 50/50)
					_part[i] = 0x2D if (float(_rand()) * 100.0 / 2147483648.0) <= 50.0 else 0x2E
					_rot[i] = 0
				if f & F_DIVID:                                                 # block 6: divider wall (8-bit ctx) overrides if hit
					var rdv: Array = _chain_lookup(CHAIN_DIVID, _divid_context(x, y))
					if not rdv.is_empty():
						_part[i] = rdv[0]
						_rot[i] = rdv[1]
				if f & F_DIVID_DOOR:                                            # block 7: divider-door (4-bit ctx) overrides if hit
					var rdd: Array = _chain_lookup(CHAIN_DIVID_DOOR, _divid_door_context(x, y))
					if not rdd.is_empty():
						_part[i] = rdd[0]
						_rot[i] = rdd[1]
				continue
			# else: empty cell — leave as -1 (no tile placed)
			# else: empty cell — leave as -1 (no tile placed)

# context bit packing (all four blocks): N=0x1, E=0x2, W=0x4, S=0x8
func _nbr_flag(x: int, y: int) -> int:
	if not _in_bounds(x, y):
		return 0
	return _flags[_idx(x, y)]

## corridor context: a side bit is SET when that side is a WALL (the neighbour is NOT connected).
## GROUNDED in the real mapPartsFilter @0x1C5550: it inits context = 0xF (all walls) and CLEARS a bit
## when a side opens. The chain tables map wall-pattern -> the corridor piece with walls on those sides,
## so e.g. ctx 6 (E|W walls) -> d01g01 straight rot 0 (opens N-S), matching the mesh. (Prior port set the
## bit on OPEN sides -> complement context -> walls/openings swapped on every tile = the void/backface bug.)
func _road_context(x: int, y: int) -> int:
	var ctx := 0
	if not _road_open_side(x, y, x, y - 1): ctx |= 0x1   # N wall
	if not _road_open_side(x, y, x + 1, y): ctx |= 0x2   # E wall
	if not _road_open_side(x, y, x - 1, y): ctx |= 0x4   # W wall
	if not _road_open_side(x, y, x, y + 1): ctx |= 0x8   # S wall
	return ctx

## A corridor side (cur cell -> neighbour) is OPEN per the VERIFIED decomp (17-VERIFY §3; key $4 init 0xF @0x1C55C4).
## The wall bit clears only when BOTH hold:
##   (a) DOOR-CONTEXT — (nbr.flags & 5) != 1, i.e. the neighbour is NOT a plain room interior. A plain room has
##       bit0 set & bit2 clear -> &5==1 -> ineligible (the side stays a WALL even with a shared link). A DOOR cell
##       is &5==5, a corridor/stair is &5==0 -> both eligible.
##   (b) SHARED CARVE LINK — exists slot in 0..15: cur.doors[slot]==1 AND nbr.doors[slot]==1. This is the real
##       connectivity test (the per-room/join id the carve stamps on every cell it links).
## BOTH are required. The prior port treated (a) as an ALTERNATIVE that returned OPEN *toward* plain rooms, so
## corridors sprouted spurious T/cross openings into adjacent room walls (the "3-way/4-way everywhere" symptom).
## A STAIR-flagged neighbour (flags&0x180) has ONE further gate (a2), applied below before (b) — see the sub-test.
## (The decomp's old "doors[16..18]" note was wrong: those E/W reads are struct-aliased W.rot/E.rot, not doors[].)
func _road_open_side(cx: int, cy: int, nx: int, ny: int) -> bool:
	if not _in_bounds(nx, ny):
		return false
	var ni := _idx(nx, ny)
	var nf := _flags[ni]
	if (nf & 0x5) == F_ROOM:                          # (a) plain room interior -> NOT a door-context -> wall
		return false
	# (a2) STAIR SUB-TEST (mapPartsFilter 0x1C566C-0x1C5750, byte-verified + adversarially confirmed): a stair-flagged
	# neighbour opens a side ONLY when the stair's stored rot matches the direction-code back from the stair to THIS
	# cell (N=0, E=1, S=2, W=3). setStair only ever emits up-stair=rot0 / down-stair=rot2, so an up-stair opens ONLY
	# toward the corridor on its SOUTH and a down-stair ONLY toward the corridor on its NORTH; every other side stays a
	# wall even with a shared link. (Without this the stair inherits its dead-end corridor's carve link and any
	# same-link cell beside it opened -> spurious T/cross jammed against the entrance/exit. Gate on rot, the literal
	# game test, not the up/down flag — they coincide today but rot is the faithful condition.)
	if (nf & (F_STAIR_UP | F_STAIR_DOWN)) != 0:
		var sr := _rot[ni]
		var ok := false
		if ny < cy:
			ok = (sr == 0)            # stair to the N of this cell: open iff stair.rot == 0
		elif ny > cy:
			ok = (sr == 2)            # stair to the S: open iff stair.rot == 2
		elif nx > cx:
			ok = (sr == 1)            # stair to the E: open iff stair.rot == 1
		else:
			ok = (sr == 3)            # stair to the W: open iff stair.rot == 3
		if not ok:
			return false
	var cd: PackedInt32Array = _doors[_idx(cx, cy)]   # (b) shared carve link (same room/join id)
	var nd: PackedInt32Array = _doors[ni]
	for r in range(16):
		if cd[r] == 1 and nd[r] == 1:
			return true
	return false

## room context: a side bit is SET when that side is a WALL (the neighbour is NOT a room interior).
## Same polarity as mapPartsFilter's room block: ctx 1 (N wall) -> no05 d01h01 (wall on N); a fully-interior
## cell -> ctx 0 -> not in CHAIN_ROOM -> bare floor no17. (Prior port set the bit when the neighbour WAS a
## room -> the wall piece landed on the open side.)
func _room_context(x: int, y: int) -> int:
	var ctx := 0
	if (_nbr_flag(x, y - 1) & 0x1) != F_ROOM: ctx |= 0x1   # N wall
	if (_nbr_flag(x + 1, y) & 0x1) != F_ROOM: ctx |= 0x2   # E wall
	if (_nbr_flag(x - 1, y) & 0x1) != F_ROOM: ctx |= 0x4   # W wall
	if (_nbr_flag(x, y + 1) & 0x1) != F_ROOM: ctx |= 0x8   # S wall
	return ctx

## door context: side bit SET when the neighbour IS a room interior (flags&1). A door tile is a room-edge
## piece whose door-gap faces the ONE non-room (corridor) side; the 3 room sides carry the bits. Grounded in
## mapPartsFilter's door block (sets the bit on room neighbours): e.g. corridor on N -> ctx 14 (E|W|S) ->
## no09 door rot 0. (Prior port set bits on the corridor side -> ctx never matched CHAIN_DOOR -> no door tile.)
func _door_context(x: int, y: int) -> int:
	var ctx := 0
	if (_nbr_flag(x, y - 1) & F_ROOM) != 0: ctx |= 0x1
	if (_nbr_flag(x + 1, y) & F_ROOM) != 0: ctx |= 0x2
	if (_nbr_flag(x - 1, y) & F_ROOM) != 0: ctx |= 0x4
	if (_nbr_flag(x, y + 1) & F_ROOM) != 0: ctx |= 0x8
	return ctx

## divider context — DECOMP-EXACT 8-BIT (mapPartsFilter block 6 @0x1C5CEC): the low nibble = neighbour is a
## divider wall (flags&0x10), the HIGH nibble = neighbour is a room interior (flags&0x1). CHAIN_DIVID keys are
## 0x71..0xF9 (8-bit), so the prior 4-bit context could NEVER match -> divider walls stayed unresolved = gaps
## inside subdivided rooms. Bit map: N=0x01/0x10, E=0x02/0x20, W=0x04/0x40, S=0x08/0x80.
func _divid_context(x: int, y: int) -> int:
	var ctx := 0
	# low nibble: neighbour IS a divider wall
	if (_nbr_flag(x, y - 1) & 0x10) != 0: ctx |= 0x01
	if (_nbr_flag(x + 1, y) & 0x10) != 0: ctx |= 0x02
	if (_nbr_flag(x - 1, y) & 0x10) != 0: ctx |= 0x04
	if (_nbr_flag(x, y + 1) & 0x10) != 0: ctx |= 0x08
	# high nibble: neighbour IS a room interior
	if (_nbr_flag(x, y - 1) & 0x1) != 0: ctx |= 0x10
	if (_nbr_flag(x + 1, y) & 0x1) != 0: ctx |= 0x20
	if (_nbr_flag(x - 1, y) & 0x1) != 0: ctx |= 0x40
	if (_nbr_flag(x, y + 1) & 0x1) != 0: ctx |= 0x80
	return ctx

## divider-DOOR context — 4-BIT (mapPartsFilter block 7 @0x1C5EDC): only the divider-neighbour low nibble
## (flags&0x10), N=0x1/E=0x2/W=0x4/S=0x8. CHAIN_DIVID_DOOR keys are 9,6.
func _divid_door_context(x: int, y: int) -> int:
	var ctx := 0
	if (_nbr_flag(x, y - 1) & 0x10) != 0: ctx |= 0x1
	if (_nbr_flag(x + 1, y) & 0x10) != 0: ctx |= 0x2
	if (_nbr_flag(x - 1, y) & 0x10) != 0: ctx |= 0x4
	if (_nbr_flag(x, y + 1) & 0x10) != 0: ctx |= 0x8
	return ctx

## Returns [partID, rot] on a hit, or an empty array when the context isn't in the table.
func _chain_lookup(table: Array, ctx: int) -> Array:
	for e in table:
		if e[0] == ctx:
			return [e[1], e[2]]
	return []

# =====================================================================================================
# emit + storage
# =====================================================================================================

func _emit(dun_idx: int, floor: int, used_seed: int) -> Dictionary:
	var cells := []
	var corridor_count := 0
	for y in range(GRID):
		for x in range(GRID):
			var i := _idx(x, y)
			if _part[i] == P_EMPTY:
				continue
			if (_flags[i] & F_CORR) and not (_flags[i] & F_ROOM):
				corridor_count += 1
			cells.append({"x": x, "y": y, "part": _part[i], "rot": _rot[i], "flags": _flags[i]})
	var rooms_out := []
	for r in range(_room_num):
		rooms_out.append(_rooms[r])
	return {
		"grid": GRID,
		"dunIdx": dun_idx,
		"floor": floor,
		"seed": used_seed,
		"rooms": rooms_out,
		"roomCount": _room_num,
		"corridorCount": corridor_count,
		"cells": cells,
		"stairUp": stair_up,
		"stairDown": stair_down,
		"entry": entry,
		"bgm": BGM_ID[dun_idx] if dun_idx < BGM_ID.size() else 0,
	}

func _alloc() -> void:
	var n := GRID * GRID
	_part = PackedInt32Array()
	_part.resize(n)
	_part.fill(P_EMPTY)
	_rot = PackedInt32Array()
	_rot.resize(n)
	_flags = PackedInt32Array()
	_flags.resize(n)
	_doors = []
	_doors.resize(n)
	for i in range(n):
		var d := PackedInt32Array()
		d.resize(16)
		_doors[i] = d
	_rooms = []
	_rooms.resize(16)
	# work copies
	_wpart = PackedInt32Array()
	_wpart.resize(n)
	_wrot = PackedInt32Array()
	_wrot.resize(n)
	_wflags = PackedInt32Array()
	_wflags.resize(n)
	_wdoors = []
	_wdoors.resize(n)
	for i in range(n):
		var d := PackedInt32Array()
		d.resize(16)
		_wdoors[i] = d

func _copy_to_work() -> void:
	_wpart = _part.duplicate()
	_wrot = _rot.duplicate()
	_wflags = _flags.duplicate()
	for i in range(_doors.size()):
		_wdoors[i] = (_doors[i] as PackedInt32Array).duplicate()

func _commit_work() -> void:
	_part = _wpart.duplicate()
	_rot = _wrot.duplicate()
	_flags = _wflags.duplicate()
	for i in range(_wdoors.size()):
		_doors[i] = (_wdoors[i] as PackedInt32Array).duplicate()

## Set cell `idx`'s doors[slot] = 1, WRITING THROUGH. CRITICAL: GDScript Packed arrays are copy-on-write, so
## `(arr[idx] as PackedInt32Array)[slot] = 1` mutates a throwaway temporary and the link code is LOST. That
## silently left every corridor's connection codes at zero -> the autotile could never open a corridor side ->
## corridors kept their placeholder partID (= carving room index) and straight runs rendered as crosses/T's/ends.
## `arr` is the instance _doors/_wdoors (passed by reference, so arr[idx] = d writes back to the member array).
func _door_set(arr: Array, idx: int, slot: int) -> void:
	var d: PackedInt32Array = arr[idx]
	d[slot] = 1
	arr[idx] = d
