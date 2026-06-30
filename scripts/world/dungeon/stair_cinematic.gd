extends Node3D
class_name StairCinematic
## DC1 Dungeon — D3.3 STAIR-TRANSITION CINEMATICS (the ~2-second descend / ascend sequence).
##
## Replaces D2's instant floor-warp (DungeonRun.go_down/go_up) with the real shipped sequence:
##   DESCENT (down-stair, PT_MARKER out_2 / eventId 160):
##     1. instance the IN-portal (in01.glb) + light a swirl on the down-stair tile, frame-lock player input,
##     2. drive the camera (eye + look-at) and slide the player along the MOT `cha##` path over 60 frames @30fps,
##     3. run D2's floor transition (DungeonRun.go_down -> regenerate + load the next floor),
##     4. play the ASCENT (up_out01) emerging Toan at the NEW floor's up-stair, then release input.
##   ASCENT (up-stair) is the reverse: up_out01 first (Toan rises out of the hole), transition, then settle.
##
## DECOMP GROUNDING (docs/progress/dungeon-deep-dive.md §4.0/§4.1):
##   The stair "cinematics" are LOCATOR-rig MOTs (dwn_in01 / up_out01): 4 root bones, 60 frames @30fps (2s):
##     - `cha##`    (type 2 pos + type 0 quat): the CHARACTER path — Toan walks/slides down the hole.
##         dwn: (0,0,-6) -> (-100,-30,-52)    up: (80,30,-52) -> (0,0,15)
##     - `target##` (type 2 pos): the camera EYE-anchor / focus path that the cam frames the character through.
##         dwn: (-0.5,-3.6,-19) -> (-100,-30,-52)   up: (66.9,26.2,-52) -> (0,0,15)
##     - `chara##`  (type 0 quat): a secondary character orientation (mostly the -90deg facing).
##   These local coords are in WORLD-SCALE units anchored at the stair TILE (162u cell pitch), rotated by the
##   tile rot. The runtime reads the keyframes off the named bones (the engine drove cam/char transforms off
##   `cam##`/`target##`/`cha##` bones). FOV is constant here (the 30/31/33 eye/lookat/FOV channels only appear in
##   the boss fly-through cam.mot — the stair clips carry no FOV channel, so we hold the gameplay FOV).
##
## The camera model for the stair clip (no explicit eye/FOV channel): we put the EYE behind+above the character
## along the `target##`->`cha##` vector and LOOK AT the character, so the framing tracks Toan down the hole the
## way the rig intends (target is the focus the cam keeps on screen). This is the pragmatic, data-grounded read
## (the visual-polish memory: ground it in the MOT data, give a couple knobs, ship).
##
## Reuse: the IN/OUT portals (in01.glb / out01.glb) were exported by D3.2 (the event-director actors 150/160);
## this is the SAME spawn path. DungeonRun owns the floor regen; this node only choreographs around it.

const STAIR_DIR := "res://assets/dungeons/stair/"
const PORTAL_DIR := "res://assets/maps/gedit/"
const FPS := 30.0                 # MOT authored at 30fps; 60 frames = 2.0s
const FRAMES := 60

## Tunable knobs (the "couple of knobs then ship" per the polish memory).
@export var eye_back := 30.0      # how far the eye sits BACK from the focus along the focus->char vector
@export var eye_up := 44.0        # how far the eye sits ABOVE the focus (raised: look DOWN onto the stair mouth
                                  # instead of skimming a cave wall edge-on during the descent — real-play framing)
@export var ease_pow := 1.0       # 1.0 = linear time; >1 eases in. Kept linear (the MOT is already eased).
## Real-play fix (DOWN-STAIR SINK): the authored `cha` path slides Toan to y=-30 / (-100,-52) LOCAL — into the
## original game's modeled stair SHAFT. Our procedural floor has no shaft mesh, so the full path drops him ~35u
## BELOW the floor and ~60u off into open black void ("sinks under the floor"). We keep the descent READABLE by
## (a) capping how far below the tile floor plane he may dip, and (b) scaling the lateral drift so he descends at
## the stair mouth instead of sliding off into the void. He still steps down + the camera tracks; he just never
## sinks through where the landing should hold him. Knobs so it can be retuned without touching the MOT read.
@export var descent_max_dip := 7.0    # max units the player may sink BELOW the stair tile's floor plane.
@export var descent_lateral_scale := 0.18  # scale the authored (x,z) drift so he stays near the stair tile.

var _run: Node = null             # DungeonRun (owns go_down/go_up + the player + the active floor)
var _player: Node3D = null

# parsed MOT tracks: { "cha":[Vector3..], "chaQuat":[Quaternion..], "target":[Vector3..], "chara":[Quaternion..] }
var _down := {}
var _up := {}

# cinematic state
var _active := false
var _cine_cam: Camera3D = null
var _saved_cam: Camera3D = null
var _portal: Node3D = null
var _prev_floor := 0

signal cinematic_started(direction: int)   # +1 descend, -1 ascend
signal cinematic_finished(direction: int, new_floor: int)

func _ready() -> void:
	_down = _parse_stair_mot(STAIR_DIR + "dwn_in01.mot", STAIR_DIR + "dwn_in01.mds")
	_up = _parse_stair_mot(STAIR_DIR + "up_out01.mot", STAIR_DIR + "up_out01.mds")

## Bind to the run + player. Called by DungeonRun on _ready (the cinematic persists across floors).
func bind(run: Node, player: Node3D) -> void:
	_run = run
	_player = player

func is_active() -> bool:
	return _active

# =====================================================================================================
# MOT parsing — the locator-rig MOT (32-byte channel header + 32-byte keyframes; vec3/quat at +16).
# =====================================================================================================

## Parse a stair MOT into per-role keyframe arrays expanded to FRAMES+1 entries (index 0..60).
## MDS gives bone index -> name (`down_in`/`up_out` root, `target##`, `cha##`, `chara##`).
func _parse_stair_mot(mot_path: String, mds_path: String) -> Dictionary:
	var names := _mds_bone_names(mds_path)
	var f := FileAccess.open(mot_path, FileAccess.READ)
	if f == null:
		push_error("stair_cinematic: cannot open MOT " + mot_path)
		return {}
	# FileAccess defaults to little-endian (big_endian=false); the DC1 MOT/MDS are little-endian.
	var size := f.get_length()
	# per-bone, per-type sparse keyframe maps: { boneIdx: { "pos":{frame:Vector3}, "quat":{frame:Quaternion} } }
	var raw := {}
	while f.get_position() + 32 <= size:
		var bone_index := f.get_32()
		var _u2 := f.get_32()
		var ch_type := f.get_32()
		var hdr_size := f.get_32()
		var kf_count := f.get_32()
		var _anim_size := f.get_32()
		f.get_32(); f.get_32()
		if hdr_size != 0x20:
			break
		if not raw.has(bone_index):
			raw[bone_index] = {"pos": {}, "quat": {}}
		for k in range(kf_count):
			if f.get_position() + 32 > size:
				break
			var kidx := f.get_32()          # 1-based keyframe index (frame number); we keep it as-is (1..60)
			f.get_32(); f.get_32(); f.get_32()   # 12-byte 0xCD sentinel
			var a := f.get_float()
			var b := f.get_float()
			var c := f.get_float()
			var d := f.get_float()
			if ch_type == 2:                 # position vec3 (w = garbage sentinel)
				raw[bone_index]["pos"][kidx] = Vector3(a, b, c)
			elif ch_type == 0:               # quaternion stored (x,y,z,w) per the DC1 WXYZ->xyzw read
				raw[bone_index]["quat"][kidx] = Quaternion(a, b, c, d)
			# (no scale / 30/31/33 channels in the stair clips)
	f.close()

	# resolve role -> bone index by name suffix
	var i_target := _find_bone(names, "target")
	var i_cha := _find_bone_exact_prefix(names, "cha", "chara")   # `cha##` but NOT `chara##`
	var i_chara := _find_bone(names, "chara")

	var out := {}
	out["target"] = _expand_pos(raw.get(i_target, {}).get("pos", {}))
	out["cha"] = _expand_pos(raw.get(i_cha, {}).get("pos", {}))
	out["chaQuat"] = _expand_quat(raw.get(i_cha, {}).get("quat", {}))
	out["chara"] = _expand_quat(raw.get(i_chara, {}).get("quat", {}))
	return out

func _mds_bone_names(mds_path: String) -> Array:
	var names := []
	var f := FileAccess.open(mds_path, FileAccess.READ)
	if f == null:
		return names
	var size := f.get_length()
	var off := 0x10
	while off + 0x70 <= size:
		f.seek(off)
		var idx := f.get_32()
		var bsize := f.get_32()
		if bsize != 0x70:
			break
		var raw := f.get_buffer(16)
		var nm := raw.get_string_from_ascii()
		names.append(nm)
		off += 0x70
	f.close()
	return names

func _find_bone(names: Array, sub: String) -> int:
	for i in names.size():
		if String(names[i]).findn(sub) >= 0:
			return i
	return -1

## Find a bone whose name contains `want` but NOT `avoid` (so `cha` != `chara`).
func _find_bone_exact_prefix(names: Array, want: String, avoid: String) -> int:
	for i in names.size():
		var n := String(names[i])
		if n.findn(want) >= 0 and n.findn(avoid) < 0:
			return i
	return -1

## Expand a sparse {frameIndex: Vector3} (1-based) into a dense Array of FRAMES+1 Vector3 (index 0..60),
## linearly interpolating between authored keyframes (matches the MOT Expand/Interpolate semantics).
func _expand_pos(sparse: Dictionary) -> Array:
	var dense := []
	dense.resize(FRAMES + 1)
	if sparse.is_empty():
		for i in dense.size():
			dense[i] = Vector3.ZERO
		return dense
	var keys := sparse.keys()
	keys.sort()
	for fr in range(FRAMES + 1):
		dense[fr] = _lerp_at(sparse, keys, fr)
	return dense

func _expand_quat(sparse: Dictionary) -> Array:
	var dense := []
	dense.resize(FRAMES + 1)
	if sparse.is_empty():
		for i in dense.size():
			dense[i] = Quaternion.IDENTITY
		return dense
	var keys := sparse.keys()
	keys.sort()
	for fr in range(FRAMES + 1):
		dense[fr] = _slerp_at(sparse, keys, fr)
	return dense

func _bracket(keys: Array, fr: int) -> Array:
	# returns [lowKey, highKey] bracketing frame fr (clamped at the ends)
	var lo: int = keys[0]
	var hi: int = keys[keys.size() - 1]
	for k in keys:
		if int(k) <= fr:
			lo = int(k)
		if int(k) >= fr:
			hi = int(k)
			break
	return [lo, hi]

func _lerp_at(sparse: Dictionary, keys: Array, fr: int) -> Vector3:
	var br := _bracket(keys, fr)
	var lo: int = br[0]
	var hi: int = br[1]
	var a: Vector3 = sparse[lo]
	if lo == hi:
		return a
	var b: Vector3 = sparse[hi]
	var t := float(fr - lo) / float(hi - lo)
	return a.lerp(b, t)

func _slerp_at(sparse: Dictionary, keys: Array, fr: int) -> Quaternion:
	var br := _bracket(keys, fr)
	var lo: int = br[0]
	var hi: int = br[1]
	var a: Quaternion = sparse[lo]
	if lo == hi:
		return a
	var b: Quaternion = sparse[hi]
	var t := float(fr - lo) / float(hi - lo)
	return a.slerp(b, t)

# =====================================================================================================
# Coordinate mapping — rig-local -> world at the stair tile.
# =====================================================================================================

## The stair tile world transform: cell world position (at the tile floor plane) + tile yaw. The rig coords are
## authored relative to the stair tile, so we rotate by the tile yaw and translate to the tile origin.
func _tile_xform(cell: Vector2i, floor_gen: Node) -> Transform3D:
	var origin: Vector3 = floor_gen.call("cell_world", cell, 0.0)
	var yaw := 0.0   # the generator places the down/up stair at rot 0/2; the path is broadly symmetric, keep 0.
	var basis := Basis(Vector3.UP, yaw)
	return Transform3D(basis, origin)

# =====================================================================================================
# Public entry points — DungeonRun calls these instead of go_down/go_up when a cinematic is wanted.
# =====================================================================================================

## Run the full DESCENT: portal + descend animation -> floor transition -> ascent arrival on the new floor.
func play_descent() -> void:
	if _active or _run == null:
		return
	_run_cinematic(1)

## Run the full ASCENT: ascent-out animation -> floor transition (go_up) -> descend arrival landing.
func play_ascent() -> void:
	if _active or _run == null:
		return
	_run_cinematic(-1)

func _run_cinematic(direction: int) -> void:
	_active = true
	_prev_floor = int(_run.get("floor_index"))
	_set_input_locked(true)
	cinematic_started.emit(direction)
	# run the choreography on a coroutine so DungeonRun's caller returns immediately (Area3D-callback safe).
	_choreograph(direction)

# =====================================================================================================
# Choreography (coroutine) — the actual 2s sequence.
# =====================================================================================================

func _choreograph(direction: int) -> void:
	var fg = _run.call("active_floor_gen")
	var lay: Dictionary = _run.call("active_layout")
	# DESCENT leaves from the current floor's DOWN-stair; ASCENT from its UP-stair.
	var leave_cell: Vector2i = lay.get("stairDown", Vector2i(-1, -1)) if direction > 0 else lay.get("stairUp", Vector2i(-1, -1))
	var leave_x := _tile_xform(leave_cell, fg)
	var clip := _down if direction > 0 else _up

	# 1. spawn the portal on the leaving stair tile + swap to the cinematic camera + frame-lock.
	_spawn_portal(direction, leave_x.origin)
	_begin_cine_cam()

	# 2a. DESCENT plays the leave clip FIRST (Toan walks down the hole), then transitions.
	#     ASCENT also plays its leave clip (Toan rises out) first; the arrival half plays after the transition.
	await _play_clip(clip, leave_x, false)

	# 3. the D2 floor transition (regenerate + load). go_down/go_up bump the index + defer the rebuild; we
	#    await the rebuild landing (the floor node is rebuilt on the next idle frame).
	if direction > 0:
		_run.call("go_down")
	else:
		_run.call("go_up")
	# wait for the deferred _load_floor to land (a couple of frames), so the new floor + player spawn exist.
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().physics_frame

	# 4. the ARRIVAL half on the NEW floor: play the OPPOSITE clip in reverse-ish to emerge Toan at the stair.
	#    DESCENT arrives at the new floor's UP-stair (you emerge from the in-stairs) -> play up_out01 arrival.
	#    ASCENT arrives at the prior floor's DOWN-stair -> play dwn_in01 arrival (reverse).
	var new_lay: Dictionary = _run.call("active_layout")
	var new_fg = _run.call("active_floor_gen")
	var arrive_cell: Vector2i
	var arrive_clip: Dictionary
	var arrive_reverse := false
	if direction > 0:
		arrive_cell = new_lay.get("stairUp", new_lay.get("entry", Vector2i(-1, -1)))
		arrive_clip = _up           # up_out01 = emerging out of the up-stair
		arrive_reverse = false
	else:
		arrive_cell = new_lay.get("stairDown", Vector2i(-1, -1))
		arrive_clip = _down         # dwn_in01 reversed = emerging from the down-stair
		arrive_reverse = true
	var arrive_x := _tile_xform(arrive_cell, new_fg)
	# re-anchor the portal on the arrival tile for the emerge half
	_move_portal(arrive_x.origin)
	await _play_clip(arrive_clip, arrive_x, arrive_reverse)

	# 5. settle the player onto the arrival landing + restore + release.
	_settle_player_at(arrive_cell, new_fg)
	_end_cine_cam()
	_despawn_portal()
	_set_input_locked(false)
	_active = false
	cinematic_finished.emit(direction, int(_run.get("floor_index")))
	print("stair_cinematic: %s complete -> floor %d (player_y=%.2f)" % [
		"DESCENT" if direction > 0 else "ASCENT", int(_run.get("floor_index")),
		_player.global_position.y if _player else 0.0])

## Play one clip over FRAMES frames, driving the player along `cha` and the cine-cam through `target`->`cha`.
## reverse=true runs the clip end->start (used for the emerge halves). Stepped per rendered frame so it plays at
## the display rate (each MOT frame held one process frame -> ~2s at 30fps source; the render harness samples
## frames mid-move). We advance by real time but clamp the per-frame step so a slow frame can't skip the clip.
func _play_clip(clip: Dictionary, tile_x: Transform3D, reverse: bool) -> void:
	if clip.is_empty():
		return
	var cha: Array = clip.get("cha", [])
	var chaq: Array = clip.get("chaQuat", [])
	var target: Array = clip.get("target", [])
	var dur := float(FRAMES) / FPS         # 2.0s
	var elapsed := 0.0
	while elapsed < dur:
		var raw_t := clampf(elapsed / dur, 0.0, 1.0)
		var t := pow(raw_t, ease_pow)
		if reverse:
			t = 1.0 - t
		var fr := clampi(int(round(t * float(FRAMES))), 0, FRAMES)
		_apply_frame(fr, cha, chaq, target, tile_x)
		await get_tree().process_frame
		# advance time; guard against a 0 / huge delta (headless first frame, breakpoints) with a clamped step.
		var dt := get_process_delta_time()
		if dt <= 0.0 or dt > 0.1:
			dt = 1.0 / 60.0
		elapsed += dt
	# land exactly on the final frame
	_apply_frame(0 if reverse else FRAMES, cha, chaq, target, tile_x)

func _apply_frame(fr: int, cha: Array, chaq: Array, target: Array, tile_x: Transform3D) -> void:
	# CHARACTER: place + orient Toan along the (descent-clamped) cha path.
	if _player and fr < cha.size():
		var world_pos: Vector3 = _clamped_char_world(fr, cha, tile_x)
		_player.global_position = world_pos
		if _player is CharacterBody3D:
			(_player as CharacterBody3D).velocity = Vector3.ZERO
		# orient the model from the cha quaternion (yaw extracted), faced into the tile basis.
		if fr < chaq.size():
			var q: Quaternion = chaq[fr]
			var basis := tile_x.basis * Basis(q)
			var model := _player.get_node_or_null("Model") as Node3D
			if model:
				model.global_basis = basis
	# CAMERA: eye sits back+above the focus(target) along the focus->char vector; look at the character.
	if _cine_cam and fr < target.size():
		var focus_local: Vector3 = target[fr]
		var focus_world: Vector3 = tile_x * focus_local
		# frame where Toan ACTUALLY is (the descent-clamped position), not the raw authored -30 sink.
		var char_world: Vector3 = _clamped_char_world(fr, cha, tile_x) if fr < cha.size() else (tile_x * focus_local)
		var to_char := (char_world - focus_world)
		var back_dir := -to_char.normalized() if to_char.length() > 0.01 else (tile_x.basis * Vector3.BACK)
		var eye := focus_world + back_dir * eye_back + Vector3.UP * eye_up
		_cine_cam.global_position = eye
		var look_target := char_world + Vector3.UP * 8.0
		if (look_target - eye).length() > 0.01:
			_cine_cam.look_at(look_target, Vector3.UP)

## The authored `cha` keyframe mapped to world, but with the descent SINK tamed (real-play fix): the lateral
## (x,z) drift is scaled toward the stair tile and the vertical drop is capped at descent_max_dip below the tile
## floor plane, so Toan steps down INTO the stair mouth instead of sliding ~60u off and ~35u under the floor into
## open void. tile_x.origin is the stair tile's floor plane (cell_world at y_off 0).
func _clamped_char_world(fr: int, cha: Array, tile_x: Transform3D) -> Vector3:
	var local_pos: Vector3 = cha[fr]
	# scale the authored lateral drift (keeps the small step-toward-the-hole, drops the big shaft slide).
	local_pos.x *= descent_lateral_scale
	local_pos.z *= descent_lateral_scale
	var world_pos: Vector3 = tile_x * local_pos
	# cap how far below the floor plane he may dip (no sink through the landing into the void).
	var floor_y := tile_x.origin.y
	world_pos.y = maxf(world_pos.y, floor_y - descent_max_dip)
	return world_pos

# =====================================================================================================
# Camera swap / portal / input lock
# =====================================================================================================

func _begin_cine_cam() -> void:
	_saved_cam = get_viewport().get_camera_3d()
	if _cine_cam == null:
		_cine_cam = Camera3D.new()
		_cine_cam.name = "StairCineCam"
		_cine_cam.far = 8000.0
		add_child(_cine_cam)
	_cine_cam.current = true

func _end_cine_cam() -> void:
	if _saved_cam and is_instance_valid(_saved_cam):
		_saved_cam.current = true

func _spawn_portal(direction: int, world_pos: Vector3) -> void:
	var base := "in01" if direction > 0 else "out01"
	var glb := PORTAL_DIR + base + "/" + base + ".glb"
	if _portal and is_instance_valid(_portal):
		_portal.queue_free()
	if ResourceLoader.exists(glb):
		var ps := load(glb) as PackedScene
		if ps:
			_portal = ps.instantiate() as Node3D
	if _portal == null:
		# fallback visible swirl so the portal beat still reads on screen.
		_portal = _make_portal_fallback()
	_portal.name = "StairPortal"
	_portal.position = world_pos
	add_child(_portal)
	# a swirl light at the portal mouth (the in/out portals glow in DC1).
	var glow := OmniLight3D.new()
	glow.name = "PortalGlow"
	glow.light_color = Color(0.5, 0.8, 1.0)
	glow.light_energy = 6.0
	glow.omni_range = 120.0
	glow.position = Vector3(0, 8, 0)
	_portal.add_child(glow)

func _move_portal(world_pos: Vector3) -> void:
	if _portal and is_instance_valid(_portal):
		_portal.position = world_pos

func _despawn_portal() -> void:
	if _portal and is_instance_valid(_portal):
		_portal.queue_free()
		_portal = null

func _make_portal_fallback() -> Node3D:
	var root := Node3D.new()
	var mi := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 8.0
	torus.outer_radius = 16.0
	mi.mesh = torus
	mi.position = Vector3(0, 6, 0)
	mi.rotation = Vector3(PI / 2.0, 0, 0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.4, 0.7, 1.0)
	mat.emission_enabled = true
	mat.emission = Color(0.4, 0.8, 1.0)
	mat.emission_energy_multiplier = 3.0
	mi.material_override = mat
	root.add_child(mi)
	return root

func _settle_player_at(cell: Vector2i, floor_gen: Node) -> void:
	if _player == null:
		return
	# Real-play fix (arrival framing): the arrival stair cell's TRACKED floor Y can sit far above the actual
	# walkable landing (deep stair geometry skews cell_floor_y high) — dropping the player at cell_world+6 then
	# let him FREE-FALL ~20u, so the follow-cam spends the first second buried in the shaft rock. Instead, RAYCAST
	# straight down through the cell to find the real floor and place him just above it -> a clean, short settle.
	# Place the player just above the arrival stair cell's tracked floor; the player's own DC1 floor solver then
	# settles/walks him onto the real landing. (We deliberately DON'T raycast for a "walkable" tri here — the
	# up-stair render structure has collision at several stacked heights and the topmost is a tiny stranded
	# platform; trusting the cell's tracked floor + letting the solver walk down is what actually keeps floor 2
	# playable.) The arrival camera-fall is tamed by the floor solver catching him quickly.
	var pos: Vector3 = floor_gen.call("cell_world", cell, 6.0)
	_player.global_position = pos
	if _player is CharacterBody3D:
		(_player as CharacterBody3D).velocity = Vector3.ZERO
	# face the player toward the NEXT objective stair so "forward" leads on, and (via face()) snap the follow-cam
	# behind that heading — no first-second back-of-head shot on arrival.
	if _player.has_method("face"):
		var lay: Dictionary = _run.call("active_layout") if _run else {}
		var dn: Vector2i = lay.get("stairDown", Vector2i(-1, -1))
		if dn.x >= 0 and dn != cell:
			var tgt: Vector3 = floor_gen.call("cell_world", dn, 0.0)
			var to := tgt - pos
			to.y = 0.0
			if to.length() > 1.0:
				_player.call("face", atan2(to.x, to.z))

func _set_input_locked(locked: bool) -> void:
	if _player == null:
		return
	# the player script has no built-in lock; we set a flag it can honor + disable its physics/process as a
	# hard stop so input + the DC1 floor solver don't fight the cinematic transform.
	_player.set("cinematic_lock", locked)
	_player.set_physics_process(not locked)
	_player.set_process(not locked)
	_player.set_process_unhandled_input(not locked)
	if locked and _player is CharacterBody3D:
		(_player as CharacterBody3D).velocity = Vector3.ZERO
