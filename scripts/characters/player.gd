extends CharacterBody3D

@export var walk_speed := 22.0
@export var run_speed := 48.0
@export var acceleration := 320.0
@export var deceleration := 420.0
@export var gravity := 70.0
@export var turn_speed := 12.0
@export var blend_smooth := 12.0
@export var mouse_sensitivity := 0.005
@export var stick_look_speed := 3.0
@export var cam_follow := true
@export var auto_trail_speed := 2.0
@export var center_speed := 9.0
@export var cam_input_grace := 1.2
@export var adjust_cam_speed := 2.2
@export var fp_pivot_height := 14.0

@onready var _model: Node3D = $Model
@onready var _pivot: Node3D = $CamPivot
@onready var _spring: SpringArm3D = $CamPivot/SpringArm3D
@onready var _anim: AnimationPlayer = find_child("AnimationPlayer", true, false)

var _tree: AnimationTree
var _blend := 0.0 
var _pitch := -0.35
var _using_gamepad := false
var _cam_cooldown := 0.0
var _centering := false
var _first_person := false
var _tp_distance := 0.0
var _tp_pivot_y := 0.0
# --- DC1-style raycast floor solver, classified by the あたりポリゴン normal (replaces capsule physics) ---
# DC1 has no step-climb: it drops the foot onto the collision triangle and reads Y off its plane. The hull's
# triangles are AUTHORED as floor/ramp (|ny|≈1) or WALL (|ny|≈0) with a hard empty gap between — so "can I
# stand here?" is a per-triangle NORMAL test, not a slope guess. We step horizontally ONLY onto a triangle
# whose |normal.y| > FLOOR_NY (walkable floor/ramp), never onto a wall tri (mountain/fence) and never off the
# mesh; then ease the body onto that triangle's Y. No capsule physics, no invented thresholds.
const FLOOR_NY := 0.3          # |normal.y| above this = walkable floor/ramp; below = an authored WALL.
const PROBE_UP := 3.0          # floor pick reaches only this far ABOVE the feet -> NEAREST floor, not an overhang.
const PROBE_DOWN := 5.0        # ...and only this far below. Past it = no floor near -> FALL (gravity) until caught.
const WALL_PROBE_H := 3.0      # wall-check ray runs at FOOT level (this far above feet): blocks walls rising from
const WALL_LOOKAHEAD := 3.0    # the floor (fence/behind-house/body base) but passes UNDER overhangs (the body).
@export var floor_ease := 40.0 # rate (u/s) the body eases onto a near floor; a real fall snaps on landing.

func _ready() -> void:
	add_to_group("player")            # so world-nav door Area3Ds can detect the player
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if _spring:
		_spring.rotation.x = _pitch
	_setup_locomotion_tree()
	_tp_distance = _spring.spring_length
	_tp_pivot_y = _pivot.position.y

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_pivot.rotation.y -= event.relative.x * mouse_sensitivity
		_pitch = clampf(_pitch - event.relative.y * mouse_sensitivity, -1.2, 0.4)
		_spring.rotation.x = _pitch
		_cam_cooldown = cam_input_grace   # manual orbit overrides auto-trail
		_centering = false
	elif event.is_action_pressed("camControl"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE \
			if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED else Input.MOUSE_MODE_CAPTURED

	# track the active device so the speed model fits it. The >0.5 gate is to ignore idle-stick jitter.
	if event is InputEventJoypadButton or (event is InputEventJoypadMotion and absf(event.axis_value) > 0.5):
		_using_gamepad = true
	elif event is InputEventKey and event.pressed:
		_using_gamepad = false

func _process(delta: float) -> void:
	# right-stick camera orbit
	# switch to look_* actions later for rebindable camera
	var pads := Input.get_connected_joypads()
	if pads.is_empty():
		return
	var pad: int = pads[0]
	var steered := false

	# right-stick free orbit
	var look := Vector2(Input.get_joy_axis(pad, JOY_AXIS_RIGHT_X),
						Input.get_joy_axis(pad, JOY_AXIS_RIGHT_Y))
	if look.length() >= 0.2:                       # deadzone
		_pivot.rotation.y -= look.x * stick_look_speed * delta
		_pitch = clampf(_pitch - look.y * stick_look_speed * delta, -1.2, 0.4)
		_spring.rotation.x = _pitch
		steered = true

	# L1/R1 rotate (When a COMBAT context exists, gate this to EXPLORE only.)
	var spin := 0.0
	if Input.is_joy_button_pressed(pad, JOY_BUTTON_LEFT_SHOULDER): spin += 1.0
	if Input.is_joy_button_pressed(pad, JOY_BUTTON_RIGHT_SHOULDER): spin -= 1.0
	if spin != 0.0:
		_pivot.rotation.y += spin * adjust_cam_speed * delta
		steered = true

	if steered:
		_cam_cooldown = cam_input_grace
		_centering = false

func _physics_process(delta: float) -> void:
	var move := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	var mag := minf(move.length(), 1.0)
	var goal_speed := _goal_speed(mag, _using_gamepad, Input.is_action_pressed("run"))
	var dir := Vector3.ZERO
	
	if mag > 0.0:
		dir = Vector3(move.x, 0.0, move.y).rotated(Vector3.UP, _pivot.global_rotation.y).normalized()
		
	var target := dir * goal_speed
	var rate := acceleration if mag > 0.0 else deceleration
	var hv := Vector3(velocity.x, 0.0, velocity.z).move_toward(target, rate * delta)
	velocity.x = hv.x
	velocity.z = hv.z

	# DC1 solver: step horizontally unless an authored WALL blocks at FOOT level; then settle onto a near floor
	# (walk) or FALL (gravity) to the ground below. The hit-poly (atari) hull supplies both the floor and the walls.
	var cur := global_position
	if hv.length() > 0.5:
		var sv := hv * delta
		for m in [sv, Vector3(sv.x, 0.0, 0.0), Vector3(0.0, 0.0, sv.z)]:   # full move, then wall-slide on X / Z
			if m.length() < 0.001:
				continue
			if _wall_ahead(m):
				continue                          # blocked ONLY by an authored WALL at foot level
			cur.x += m.x; cur.z += m.z            # otherwise step -- even off an edge; gravity drops us to the ground
			break
	var g := _floor_at(cur.x, cur.z, cur.y)
	if not g.is_empty() and absf((g["normal"] as Vector3).y) >= FLOOR_NY:
		var fl: float = g["position"].y
		if velocity.y < -1.0 and fl < cur.y - 0.5:
			cur.y = fl                                 # falling onto a floor below -> land (snap)
		else:
			var d := fl - cur.y                        # walking / descending -> ease onto it
			cur.y += signf(d) * minf(absf(d), floor_ease * delta)
			if absf(fl - cur.y) < 0.5:
				cur.y = fl
		velocity.y = 0.0
	else:
		velocity.y -= gravity * delta                  # no walkable floor near -> FALL
		cur.y += velocity.y * delta
	global_position = cur

	# turn the model to face the move direction
	if dir.length() > 0.01:
		_model.rotation.y = lerp_angle(_model.rotation.y, atan2(dir.x, dir.z), turn_speed * delta)

	# camera auto-trails behind you while moving unless you've recently turned it yourself.
	_cam_cooldown = maxf(_cam_cooldown - delta, 0.0)
	if Input.is_action_just_pressed("center_camera"):
		_centering = true
	if Input.is_action_just_pressed("f_person_toggle"):
		_set_first_person(not _first_person)
	var behind := _model.rotation.y + PI
	if _centering:
		_pivot.rotation.y = lerp_angle(_pivot.rotation.y, behind, center_speed * delta)
		if absf(wrapf(behind - _pivot.rotation.y, -PI, PI)) < 0.03:
			_centering = false
	elif cam_follow and dir.length() > 0.01 and _cam_cooldown <= 0.0:
		_pivot.rotation.y = lerp_angle(_pivot.rotation.y, behind, auto_trail_speed * delta)

	if _tree:
		var spd := Vector2(velocity.x, velocity.z).length()
		var loco := spd / maxf(walk_speed, 0.001)
		if spd > walk_speed:
			loco = 1.0 + (spd - walk_speed) / maxf(run_speed - walk_speed, 0.001)
		loco = clampf(loco, 0.0, 2.0)
		_blend = move_toward(_blend, loco, blend_smooth * delta)
		_tree.set("parameters/blend_position", _blend)

func _setup_locomotion_tree() -> void:
	if _anim == null:
		push_warning("player: no AnimationPlayer found; locomotion blend disabled")
		return
	for n in ["idle", "walk", "run"]:
		if _anim.has_animation(n):
			_anim.get_animation(n).loop_mode = Animation.LOOP_LINEAR
	var bs := AnimationNodeBlendSpace1D.new()
	bs.min_space = 0.0
	bs.max_space = 2.0
	bs.sync = true
	bs.add_blend_point(_clip_node("idle"), 0.0, -1, "idle")
	bs.add_blend_point(_clip_node("walk"), 1.0, -1, "walk")
	bs.add_blend_point(_clip_node("run"), 2.0, -1, "run")
	_tree = AnimationTree.new()
	_tree.name = "AnimationTree"
	_tree.tree_root = bs
	add_child(_tree)
	_tree.anim_player = _tree.get_path_to(_anim)
	_tree.active = true

func _clip_node(anim_name: String) -> AnimationNodeAnimation:
	var node := AnimationNodeAnimation.new()
	node.animation = anim_name
	return node

func _goal_speed(mag: float, gamepad: bool, run_held: bool) -> float:
	if mag <= 0.0:
		return 0.0
	if gamepad:
		return mag * run_speed
	return run_speed if run_held else walk_speed

## Face a world yaw instantly (used when a warp drops the player at a door) and snap the camera behind them.
func face(yaw: float) -> void:
	_model.rotation.y = yaw
	_pivot.rotation.y = yaw + PI
	_centering = false
	_cam_cooldown = 0.0

## Toggle first-person
func _set_first_person(on: bool) -> void:
	_first_person = on
	if on:
		_spring.spring_length = 0.4
		_pivot.position.y = fp_pivot_height
		_model.visible = false
		_pivot.rotation.y = _model.rotation.y + PI   # snap to look where the player is facing
		_centering = false
		_cam_cooldown = 0.0
	else:
		_spring.spring_length = _tp_distance
		_pivot.position.y = _tp_pivot_y
		_model.visible = true

## Raycast straight down for the floor near `ref_y`, ignoring the player's own body. Returns the hit dict
## (incl. "position" + "normal") or {} when nothing is below — the heart of the DC1-style PickUpPoly solver:
## the floor is whatever the ray lands on, and its NORMAL says whether that triangle is walkable or a wall.
func _floor_at(x: float, z: float, ref_y: float) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(Vector3(x, ref_y + PROBE_UP, z), Vector3(x, ref_y - PROBE_DOWN, z))
	q.exclude = [get_rid()]
	return get_world_3d().direct_space_state.intersect_ray(q)   # {} when nothing below

## A WALL the player is walking INTO? The downward floor-pick shoots past vertical walls, so we look sideways.
## The ray runs at FOOT level (WALL_PROBE_H above the feet): it blocks walls that rise from the floor (fences,
## the behind-house wall, the building body base) but passes UNDER an overhang above the head. Data rule: only
## a triangle the game authored as a WALL (|ny| < FLOOR_NY) blocks -- a floor/ramp it grazes is ignored.
func _wall_ahead(m: Vector3) -> bool:
	var dir := Vector3(m.x, 0.0, m.z)
	if dir.length() < 0.001:
		return false
	var a := global_position + Vector3.UP * WALL_PROBE_H
	var b := a + dir.normalized() * (m.length() + WALL_LOOKAHEAD)
	var q := PhysicsRayQueryParameters3D.create(a, b)
	q.exclude = [get_rid()]
	var h := get_world_3d().direct_space_state.intersect_ray(q)
	return not h.is_empty() and absf((h["normal"] as Vector3).y) < FLOOR_NY
